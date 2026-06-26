//! whostty: native Win32 window with a WGL OpenGL context.
//!
//! Reference: ghostty `src/apprt/gtk/Window.zig` (strategy: template — Win32 has
//! no 1:1 counterpart, so gtk is only a structural reference). slice-0 keeps the
//! window minimal: a class with its own DC, a legacy WGL context (modern GL
//! entry points are loaded via wglGetProcAddress by the renderer), and a
//! message pump that surfaces input/resize/close events. See PORTING.md.
const std = @import("std");
const w = @import("../../os/windows.zig");
const input = @import("../../input.zig");

const log = std.log.scoped(.window);

/// Modifier-key state captured at the time of a key event.
pub const Mods = struct {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    super: bool = false,
};

/// Events surfaced from the window message loop.
pub const Event = union(enum) {
    /// A character was typed (WM_CHAR), as a Unicode codepoint. The app drops the
    /// WM_CHAR that follows a handled Enter/Tab/Backspace/Escape WM_KEYDOWN (see
    /// the suppress-next-char logic) so those keys aren't sent twice.
    char: u21,
    /// A virtual key changed state (WM_KEYDOWN / WM_KEYUP and their WM_SYS*
    /// twins), with the modifiers held. `down` is true for a press/repeat and
    /// false for a release; `repeat` is true for auto-repeat presses; `scancode`
    /// is the hardware scan code (lParam bits 16–23). The release/repeat/scancode
    /// fields are only consumed on the kitty-keyboard output path (#82) — the
    /// legacy path acts on presses (`down`) and ignores the rest, so its bytes
    /// are unchanged when kitty is off.
    key: struct {
        vk: u32,
        mods: Mods,
        down: bool = true,
        repeat: bool = false,
        scancode: u32 = 0,
    },
    /// The mouse wheel moved (WM_MOUSEWHEEL); raw signed delta (multiples of
    /// WHEEL_DELTA), positive when rolled away from the user.
    scroll: i32,
    /// A mouse button was pressed (down = true) or released at client pixel
    /// (x, y), with the modifiers held.
    mouse_button: struct {
        button: enum { left, middle, right },
        down: bool,
        x: i32,
        y: i32,
        mods: Mods,
    },
    /// Mouse moved to client pixel (x, y), with the modifiers held (so a drag
    /// under an app's mouse-motion tracking reports the right modifier bits).
    mouse_move: struct { x: i32, y: i32, mods: Mods },
    /// Mouse capture was lost (e.g. alt-tab mid-drag) — end any local drag
    /// without synthesizing a reportable button event.
    mouse_capture_lost,
    /// The client area was resized (pixels).
    resize: struct { width: u16, height: u16 },
    /// The window moved to a monitor with a different DPI (WM_DPICHANGED, #90),
    /// carrying the new DPI. The window proc already applied the OS-suggested
    /// rect (which fires a `.resize`); the app rebuilds the glyph atlas + cell
    /// metrics at the new scale.
    dpi_changed: u32,
    /// The window gained (true) or lost (false) keyboard focus. Drives the
    /// hollow-when-unfocused cursor.
    focus: bool,
    /// The user requested the window close.
    close,
};

const queue_len = 256;

pub const Window = struct {
    hwnd: w.HWND,
    hdc: w.HDC,
    hglrc: w.HGLRC,
    /// Whether a WGL OpenGL context was created. False for the Direct3D backend,
    /// which needs only the HWND and owns its own swap chain — then `hglrc` is
    /// unused and `makeCurrent`/`swapBuffers`/the WGL teardown are no-ops.
    gl_enabled: bool = true,

    // Single-threaded SPSC-on-one-thread event ring (producer = wndproc,
    // consumer = poll, both on the UI thread).
    events: [queue_len]Event = undefined,
    head: usize = 0,
    tail: usize = 0,
    should_close: bool = false,

    // --- Window-state (#91) ---
    /// True while in borderless windowed fullscreen. Flipped ONLY by
    /// toggleFullscreen() — never in the window proc — so a normal user
    /// drag-resize (which fires WM_SIZE) can't corrupt the saved geometry/style.
    fullscreen: bool = false,
    /// The window placement (size/pos + normal/maximized show state) captured
    /// the moment fullscreen was entered, restored verbatim on exit.
    saved_placement: w.WINDOWPLACEMENT = undefined,
    /// The exact GWL_STYLE captured at fullscreen-enter (so a decoration-hidden
    /// window round-trips to its decoration-hidden state, not to a default one).
    saved_style: w.LONG_PTR = 0,
    /// Whether the titlebar + resize border are currently shown. Toggled by
    /// toggleDecorations(); the window is created decorated.
    decorations: bool = true,
    /// The shell child's process id, set by the apprt after spawn (#91). Used by
    /// the close-confirmation probe to detect a running descendant. 0 = unknown
    /// (probe is skipped, so a confirmation never blocks shutdown spuriously).
    shell_pid: w.DWORD = 0,
    /// True while the close-confirmation dialog is modal. MessageBoxW runs its
    /// own message pump that re-enters wndProc, so a second WM_CLOSE (the X
    /// mashed again) would queue another `.close` and re-prompt after the user
    /// answers; wndProc drops WM_CLOSE while this is set.
    close_pending: bool = false,
    /// Whether the window is pinned always-on-top (toggle_window_float_on_top,
    /// #92). The window is created not-topmost.
    topmost: bool = false,
    /// Whether the window is currently hidden (toggle_visibility, #92). The
    /// window is created visible.
    hidden: bool = false,
    /// Caret pixel (client coords) the IME composition + candidate windows are
    /// pinned to (#88). The app refreshes it each loop turn from the focused
    /// pane's cursor; the composition messages read it when the IME opens.
    ime_pos: w.POINT = .{ .x = 0, .y = 0 },

    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("whosttyWindowClass");

    pub const CreateError = error{
        RegisterClassFailed,
        CreateWindowFailed,
        GetDCFailed,
        PixelFormatFailed,
        ContextFailed,
    };

    /// Window classes are a process-global resource: `RegisterClassExW` succeeds
    /// once and every later call for the same class name fails with
    /// `ERROR_CLASS_ALREADY_EXISTS`. With multi-window/thread-per-window (#86) a
    /// second window thread must NOT re-register, so registration is done exactly
    /// once per process behind `std.once`. The class lives for the process
    /// lifetime (never unregistered), shared by every `CreateWindowExW`. The result
    /// is published to `register_ok` so `init` can fail cleanly if the one-time
    /// registration genuinely failed (vs. the benign already-registered case).
    var register_class_once = std.once(registerClassOnce);
    var register_ok: bool = false;

    /// Per-monitor-DPI-v2 must be set process-wide BEFORE any window is created
    /// (#90), so it runs once from `init` ahead of class registration. Best-effort:
    /// on an OS without the API the window stays system-DPI-scaled.
    var dpi_aware_once = std.once(setProcessDpiAware);

    fn setProcessDpiAware() void {
        _ = w.SetProcessDpiAwarenessContext(w.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    }

    /// The DPI of the monitor this window is on (#90); 96 (scale 1.0) if the OS
    /// can't report it.
    pub fn dpiForWindow(self: *Window) u32 {
        const d = w.GetDpiForWindow(self.hwnd);
        return if (d == 0) w.USER_DEFAULT_SCREEN_DPI else d;
    }

    fn registerClassOnce() void {
        const hinstance = w.GetModuleHandleW(null).?;
        const wc: w.WNDCLASSEXW = .{
            .cbSize = @sizeOf(w.WNDCLASSEXW),
            .style = w.CS_OWNDC | w.CS_HREDRAW | w.CS_VREDRAW,
            .lpfnWndProc = wndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = hinstance,
            .hIcon = null,
            // I-beam over the whole client so the terminal reads as text (#52).
            // (Refinements — an arrow over the tab strip and while an app holds
            // mouse tracking — are follow-ups; they need per-region app state.)
            .hCursor = w.LoadCursorW(null, w.IDC_IBEAM),
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = class_name,
            .hIconSm = null,
        };
        // A non-zero ATOM is success; treat ERROR_CLASS_ALREADY_EXISTS (a class
        // left over from a prior partially-failed run in the same process) as
        // success too, since the class we need is present either way.
        register_ok = w.RegisterClassExW(&wc) != 0 or
            w.GetLastError() == w.ERROR_CLASS_ALREADY_EXISTS;
    }

    /// Create the window and its GL context. `self` must have a stable address
    /// (heap-allocate it) because the window stores a pointer back to it.
    pub fn init(self: *Window, title_utf8: []const u8, width: i32, height: i32, use_gl: bool) CreateError!void {
        self.* = .{ .hwnd = undefined, .hdc = undefined, .hglrc = undefined, .gl_enabled = use_gl };

        const hinstance = w.GetModuleHandleW(null).?;

        // Opt into per-monitor DPI awareness (#90) before creating any window so
        // WM_DPICHANGED is delivered and GetDpiForWindow reports the real DPI.
        dpi_aware_once.call();

        // Register the window class once per process (thread-safe via std.once);
        // every window after the first reuses the already-registered class.
        register_class_once.call();
        if (!register_ok) return error.RegisterClassFailed;

        var title_buf: [256]u16 = undefined;
        const title_z = captionUtf16(title_utf8, &title_buf) orelse
            return error.CreateWindowFailed;

        const hwnd = w.CreateWindowExW(
            0,
            class_name,
            title_z.ptr,
            w.WS_OVERLAPPEDWINDOW | w.WS_VISIBLE,
            w.CW_USEDEFAULT,
            w.CW_USEDEFAULT,
            width,
            height,
            null,
            null,
            hinstance,
            null,
        ) orelse return error.CreateWindowFailed;
        self.hwnd = hwnd;

        // Route subsequent messages to this instance.
        _ = w.SetWindowLongPtrW(hwnd, w.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

        self.hdc = w.GetDC(hwnd) orelse return error.GetDCFailed;
        // The Direct3D backend creates its own device + swap chain from the HWND;
        // only the WGL/OpenGL backend needs a GL context here.
        if (use_gl) try self.initGl();

        _ = w.ShowWindow(hwnd, w.SW_SHOW);
        _ = w.UpdateWindow(hwnd);
    }

    fn initGl(self: *Window) CreateError!void {
        var pfd: w.PIXELFORMATDESCRIPTOR = std.mem.zeroes(w.PIXELFORMATDESCRIPTOR);
        pfd.nSize = @sizeOf(w.PIXELFORMATDESCRIPTOR);
        pfd.nVersion = 1;
        pfd.dwFlags = w.PFD_DRAW_TO_WINDOW | w.PFD_SUPPORT_OPENGL | w.PFD_DOUBLEBUFFER;
        pfd.iPixelType = w.PFD_TYPE_RGBA;
        pfd.cColorBits = 32;
        pfd.cDepthBits = 24;
        pfd.cStencilBits = 8;
        pfd.iLayerType = w.PFD_MAIN_PLANE;

        const fmt = w.ChoosePixelFormat(self.hdc, &pfd);
        if (fmt == 0) return error.PixelFormatFailed;
        if (w.SetPixelFormat(self.hdc, fmt, &pfd) == w.FALSE) return error.PixelFormatFailed;

        // Bootstrap a legacy context so wglCreateContextAttribsARB can be
        // resolved, then upgrade to a 3.3 core context. The renderer hard-requires
        // GL >= 3.3 (`#version 330 core` shaders, VAOs, sized R8 textures); a bare
        // wglCreateContext can hand back GL 1.1 (Microsoft GDI generic), which
        // makes shader compilation / VAO loading fail at startup.
        const legacy = w.wglCreateContext(self.hdc) orelse return error.ContextFailed;
        if (w.wglMakeCurrent(self.hdc, legacy) == w.FALSE) {
            _ = w.wglDeleteContext(legacy);
            return error.ContextFailed;
        }

        if (@as(?w.CreateContextAttribsFn, @ptrCast(w.wglProcChecked("wglCreateContextAttribsARB")))) |createAttribs| {
            const attribs = [_:0]w.INT{
                w.WGL_CONTEXT_MAJOR_VERSION_ARB, 3,
                w.WGL_CONTEXT_MINOR_VERSION_ARB, 3,
                w.WGL_CONTEXT_PROFILE_MASK_ARB,  w.WGL_CONTEXT_CORE_PROFILE_BIT_ARB,
            };
            if (createAttribs(self.hdc, null, &attribs)) |core| {
                _ = w.wglMakeCurrent(null, null);
                _ = w.wglDeleteContext(legacy);
                self.hglrc = core;
                if (w.wglMakeCurrent(self.hdc, self.hglrc) == w.FALSE) return error.ContextFailed;
                return;
            }
            log.warn("wglCreateContextAttribsARB failed; falling back to the legacy GL context", .{});
        } else {
            log.warn("wglCreateContextAttribsARB unavailable; falling back to the legacy GL context", .{});
        }

        // Fallback: keep the legacy context (a real ICD often still reports a
        // >= 3.3 compatibility profile, which the renderer can use).
        self.hglrc = legacy;
    }

    pub fn deinit(self: *Window) void {
        if (self.gl_enabled) {
            _ = w.wglMakeCurrent(null, null);
            _ = w.wglDeleteContext(self.hglrc);
        }
        _ = w.ReleaseDC(self.hwnd, self.hdc);
        _ = w.DestroyWindow(self.hwnd);
        self.* = undefined;
    }

    pub fn makeCurrent(self: *Window) void {
        if (self.gl_enabled) _ = w.wglMakeCurrent(self.hdc, self.hglrc);
    }

    /// The native window handle (for synchronous Win32 calls like the clipboard).
    pub fn handle(self: *Window) w.HWND {
        return self.hwnd;
    }

    /// Convert `title_utf8` to a NUL-terminated UTF-16 caption in `buf`, truncating
    /// on a UTF-8 codepoint boundary so it always fits. CRITICAL: `utf8ToUtf16Le`
    /// has NO destination bounds check and does not truncate — feeding it a title
    /// longer than the buffer overflows it (a program-supplied OSC title can be
    /// arbitrarily long). Clamp the INPUT first (≤1 u16 per input byte). Returns
    /// null only on invalid UTF-8.
    fn captionUtf16(title_utf8: []const u8, buf: *[256]u16) ?[:0]u16 {
        var end: usize = title_utf8.len;
        if (end > buf.len - 1) {
            end = buf.len - 1;
            // Back off any UTF-8 continuation bytes so we don't split a codepoint.
            while (end > 0 and (title_utf8[end] & 0xC0) == 0x80) end -= 1;
        }
        const len = std.unicode.utf8ToUtf16Le(buf, title_utf8[0..end]) catch return null;
        buf[len] = 0;
        return buf[0..len :0];
    }

    /// Update the live window caption from a UTF-8 title (OSC 0/2, #89). Over-long
    /// titles are truncated on a codepoint boundary and invalid UTF-8 is ignored
    /// (the caption keeps its previous value) — see `captionUtf16`.
    pub fn setTitle(self: *Window, title_utf8: []const u8) void {
        var buf: [256]u16 = undefined;
        const title_z = captionUtf16(title_utf8, &buf) orelse return;
        _ = w.SetWindowTextW(self.hwnd, title_z.ptr);
    }

    /// Record the shell child's pid for the close-confirmation probe (#91). The
    /// apprt calls this after spawning the shell. Until set, the probe is skipped.
    pub fn setShellPid(self: *Window, pid: w.DWORD) void {
        self.shell_pid = pid;
    }

    /// Toggle borderless windowed fullscreen (#91), the Raymond-Chen pattern:
    /// entering saves the current placement + style, drops the overlapped frame,
    /// and stretches the window over the nearest monitor's full rect; leaving
    /// restores the saved style then the saved placement (size/pos + max state).
    /// The resulting size change fires WM_SIZE, which the apprt's existing resize
    /// path consumes — no extra grid/pty wiring needed.
    pub fn toggleFullscreen(self: *Window) void {
        const style = w.GetWindowLongPtrW(self.hwnd, w.GWL_STYLE);
        if (!self.fullscreen) {
            // Capture exact prior state. Guard so a double-enter (shouldn't
            // happen, but be safe) can't overwrite the good saved snapshot.
            self.saved_style = style;
            self.saved_placement.length = @sizeOf(w.WINDOWPLACEMENT);
            if (w.GetWindowPlacement(self.hwnd, &self.saved_placement) == w.FALSE) return;

            const mon = w.MonitorFromWindow(self.hwnd, w.MONITOR_DEFAULTTONEAREST) orelse return;
            var mi: w.MONITORINFO = undefined;
            mi.cbSize = @sizeOf(w.MONITORINFO);
            if (w.GetMonitorInfoW(mon, &mi) == w.FALSE) return;

            // Drop the titlebar + resize border so the client area can cover the
            // whole monitor (a bordered window can't reach the screen edges).
            _ = w.SetWindowLongPtrW(self.hwnd, w.GWL_STYLE, style & ~@as(w.LONG_PTR, @intCast(w.WS_OVERLAPPEDWINDOW)));
            const r = mi.rcMonitor;
            _ = w.SetWindowPos(
                self.hwnd,
                null,
                r.left,
                r.top,
                r.right - r.left,
                r.bottom - r.top,
                w.SWP_NOZORDER | w.SWP_FRAMECHANGED,
            );
            self.fullscreen = true;
        } else {
            // Restore the saved style FIRST so the frame recomputes, then the
            // saved placement (size/pos + normal-vs-maximized show state).
            _ = w.SetWindowLongPtrW(self.hwnd, w.GWL_STYLE, self.saved_style);
            _ = w.SetWindowPlacement(self.hwnd, &self.saved_placement);
            _ = w.SetWindowPos(
                self.hwnd,
                null,
                0,
                0,
                0,
                0,
                w.SWP_NOMOVE | w.SWP_NOSIZE | w.SWP_NOZORDER | w.SWP_FRAMECHANGED,
            );
            self.fullscreen = false;
        }
    }

    /// Maximize or restore the window (#91). Uses the OS maximize state directly
    /// (IsZoomed) rather than tracking our own bool, so it stays correct even if
    /// the user maximized via the titlebar button. Restoring from a maximized
    /// fullscreen edge case is handled by toggleFullscreen's placement save.
    pub fn toggleMaximize(self: *Window) void {
        // No-op while borderless fullscreen: the window has WS_OVERLAPPEDWINDOW
        // cleared and is stretched to the monitor, so SW_MAXIMIZE here would
        // corrupt the fullscreen geometry/show-state (mirrors toggleDecorations).
        if (self.fullscreen) return;
        const cmd: w.INT = if (w.IsZoomed(self.hwnd) != w.FALSE) w.SW_RESTORE else w.SW_MAXIMIZE;
        _ = w.ShowWindow(self.hwnd, cmd);
    }

    /// Show/hide the titlebar + resize border (#91) by flipping exactly the
    /// WS_CAPTION | WS_THICKFRAME bits — leaving WS_SYSMENU/min/max-box intact —
    /// then SetWindowPos(SWP_FRAMECHANGED) so the non-client frame recomputes
    /// immediately (without it a ghost titlebar lingers until the next resize).
    /// A borderless (decoration-hidden) window can't be user-resized; that's the
    /// intended effect. No-op while fullscreen (the frame is already gone).
    pub fn toggleDecorations(self: *Window) void {
        if (self.fullscreen) return;
        const deco_bits: w.LONG_PTR = @intCast(w.WS_CAPTION | w.WS_THICKFRAME);
        const style = w.GetWindowLongPtrW(self.hwnd, w.GWL_STYLE);
        const new_style = if (self.decorations) style & ~deco_bits else style | deco_bits;
        _ = w.SetWindowLongPtrW(self.hwnd, w.GWL_STYLE, new_style);
        _ = w.SetWindowPos(
            self.hwnd,
            null,
            0,
            0,
            0,
            0,
            w.SWP_NOMOVE | w.SWP_NOSIZE | w.SWP_NOZORDER | w.SWP_FRAMECHANGED,
        );
        self.decorations = !self.decorations;
    }

    /// Bring the window to the foreground and raise it (present_terminal, #92).
    /// Un-hides it first if it was hidden. The OS foreground lock may refuse the
    /// focus change cross-process, so this is best-effort (BringWindowToTop +
    /// SetForegroundWindow), matching ghostty's `present` semantics.
    pub fn present(self: *Window) void {
        if (self.hidden) {
            _ = w.ShowWindow(self.hwnd, w.SW_SHOW);
            self.hidden = false;
        }
        _ = w.BringWindowToTop(self.hwnd);
        _ = w.SetForegroundWindow(self.hwnd);
    }

    /// Toggle always-on-top (toggle_window_float_on_top, #92): re-file the window
    /// at the top of (or out of) the topmost Z-order band without moving, sizing,
    /// or activating it. Tracks the state so the next toggle reverses it.
    pub fn toggleFloat(self: *Window) void {
        const after: w.HWND = if (self.topmost) w.HWND_NOTOPMOST else w.HWND_TOPMOST;
        _ = w.SetWindowPos(self.hwnd, after, 0, 0, 0, 0, w.SWP_NOMOVE | w.SWP_NOSIZE | w.SWP_NOACTIVATE);
        self.topmost = !self.topmost;
    }

    /// Show/hide the window (toggle_visibility, #92). Hiding removes it from the
    /// screen + taskbar (SW_HIDE) without closing it (its shell keeps running);
    /// showing restores it and brings it forward so it's usable again.
    pub fn toggleVisibility(self: *Window) void {
        if (self.hidden) {
            _ = w.ShowWindow(self.hwnd, w.SW_SHOW);
            _ = w.SetForegroundWindow(self.hwnd);
            self.hidden = false;
        } else {
            _ = w.ShowWindow(self.hwnd, w.SW_HIDE);
            self.hidden = true;
        }
    }

    /// Update where the IME composition/candidate windows appear (#88). The app
    /// passes the focused pane's caret pixel each loop turn so the candidate list
    /// tracks the cursor; the value is read when composition starts/updates.
    pub fn setImePosition(self: *Window, x: i32, y: i32) void {
        self.ime_pos = .{ .x = x, .y = y };
    }

    /// Pin the IME composition + candidate windows to the caret (`ime_pos`) so
    /// they open at the cursor, not the window's top-left (#88). Best-effort: no
    /// IME context (no IME active for this window) is a clean no-op.
    fn placeImeWindows(self: *Window) void {
        const himc = w.ImmGetContext(self.hwnd) orelse return;
        defer _ = w.ImmReleaseContext(self.hwnd, himc);
        const comp: w.COMPOSITIONFORM = .{
            .dwStyle = w.CFS_POINT,
            .ptCurrentPos = self.ime_pos,
            .rcArea = std.mem.zeroes(w.RECT),
        };
        _ = w.ImmSetCompositionWindow(himc, &comp);
        const cand: w.CANDIDATEFORM = .{
            .dwIndex = 0,
            .dwStyle = w.CFS_CANDIDATEPOS,
            .ptCurrentPos = self.ime_pos,
            .rcArea = std.mem.zeroes(w.RECT),
        };
        _ = w.ImmSetCandidateWindow(himc, &cand);
    }

    /// Read the committed IME result string and queue it as `.char` events (#88),
    /// reusing the same text path as a typed key. Bounded by a fixed UTF-16
    /// scratch (commit strings are short); an over-long result is truncated on a
    /// unit boundary rather than overflowing (the #89 stack-overflow precedent).
    fn pushImeResult(self: *Window) void {
        const himc = w.ImmGetContext(self.hwnd) orelse return;
        defer _ = w.ImmReleaseContext(self.hwnd, himc);
        var buf: [256]u16 = undefined;
        const bytes = w.ImmGetCompositionStringW(himc, w.GCS_RESULTSTR, &buf, @sizeOf(@TypeOf(buf)));
        if (bytes <= 0) return;
        const units: usize = @min(@as(usize, @intCast(bytes)) / 2, buf.len);
        var it = std.unicode.Utf16LeIterator.init(buf[0..units]);
        while (it.nextCodepoint() catch null) |cp| self.push(.{ .char = @intCast(cp) });
    }

    /// Close-confirmation gate (#91), mirroring ghostty's `needsConfirmQuit`
    /// semantics for the `.true` default: prompt ONLY when a foreground command
    /// is running, i.e. the shell has a live child process. Returns true if the
    /// window should proceed to close, false if the user chose to keep it open.
    /// When nothing is running (bare prompt), or the pid is unknown, it returns
    /// true with no dialog so shutdown is never blocked spuriously. The dialog is
    /// modal on the UI thread; the apprt calls this from its `.close` handling
    /// (where the shell pid was wired in), NOT from the window proc.
    pub fn confirmClose(self: *Window) bool {
        if (self.shell_pid == 0) return true;
        if (!w.shellHasRunningChild(self.shell_pid)) return true;

        // The dialog runs a modal pump that re-enters wndProc; flag so a second
        // WM_CLOSE during it is dropped (not queued into a repeat prompt).
        self.close_pending = true;
        defer self.close_pending = false;

        const text = std.unicode.utf8ToUtf16LeStringLiteral(
            "A process is still running in this terminal. Close anyway?",
        );
        const caption = std.unicode.utf8ToUtf16LeStringLiteral("whostty");
        const r = w.MessageBoxW(self.hwnd, text, caption, w.MB_YESNO | w.MB_ICONQUESTION);
        return r == w.IDYES;
    }

    pub fn swapBuffers(self: *Window) void {
        if (self.gl_enabled) _ = w.SwapBuffers(self.hdc);
    }

    pub fn clientSize(self: *Window) struct { width: u16, height: u16 } {
        var rect: w.RECT = undefined;
        _ = w.GetClientRect(self.hwnd, &rect);
        return .{
            .width = @intCast(@max(0, rect.right - rect.left)),
            .height = @intCast(@max(0, rect.bottom - rect.top)),
        };
    }

    /// Drain all pending OS messages into the event ring. Returns false once a
    /// quit/close has been observed.
    pub fn pump(self: *Window) bool {
        var msg: w.MSG = undefined;
        while (w.PeekMessageW(&msg, null, 0, 0, w.PM_REMOVE) != w.FALSE) {
            if (msg.message == w.WM_QUIT) self.should_close = true;
            _ = w.TranslateMessage(&msg);
            _ = w.DispatchMessageW(&msg);
        }
        return !self.should_close;
    }

    /// Pop the next queued event, or null if the queue is empty.
    pub fn poll(self: *Window) ?Event {
        if (self.head == self.tail) return null;
        const ev = self.events[self.head % queue_len];
        self.head += 1;
        return ev;
    }

    fn push(self: *Window, ev: Event) void {
        // Drop on overflow rather than block; slice-0 keeps it simple.
        if (self.tail - self.head >= queue_len) return;
        self.events[self.tail % queue_len] = ev;
        self.tail += 1;
    }

    fn keyDown(vk: w.INT) bool {
        // GetKeyState's high bit is set while the key is held.
        return (@as(u16, @bitCast(w.GetKeyState(vk))) & 0x8000) != 0;
    }

    fn currentMods() Mods {
        return .{
            .ctrl = keyDown(w.VK_CONTROL),
            .shift = keyDown(w.VK_SHIFT),
            .alt = keyDown(w.VK_MENU),
            .super = keyDown(w.VK_LWIN) or keyDown(w.VK_RWIN),
        };
    }

    /// Decode the scan code (bits 16–23) and the auto-repeat flag (bit 30, set
    /// while a key repeats from being held) packed into a key message's lParam.
    fn keyLParam(lparam: w.LPARAM) struct { scancode: u32, repeat: bool } {
        const lp: usize = @bitCast(lparam);
        return .{
            .scancode = @truncate((lp >> 16) & 0xFF),
            .repeat = (lp >> 30) & 1 != 0,
        };
    }

    /// Decode the signed client-area x/y packed in a mouse message's lParam.
    fn mouseXY(lparam: w.LPARAM) struct { x: i32, y: i32 } {
        const lp: usize = @bitCast(lparam);
        const x: i32 = @as(i16, @bitCast(@as(u16, @truncate(lp & 0xFFFF))));
        const y: i32 = @as(i16, @bitCast(@as(u16, @truncate((lp >> 16) & 0xFFFF))));
        return .{ .x = x, .y = y };
    }

    fn fromHwnd(hwnd: w.HWND) ?*Window {
        const ud = w.GetWindowLongPtrW(hwnd, w.GWLP_USERDATA);
        if (ud == 0) return null;
        return @ptrFromInt(@as(usize, @bitCast(ud)));
    }

    fn wndProc(hwnd: w.HWND, msg: w.UINT, wparam: w.WPARAM, lparam: w.LPARAM) callconv(.winapi) w.LRESULT {
        const self = fromHwnd(hwnd);
        switch (msg) {
            w.WM_CLOSE => {
                // Drop close requests arriving while a close-confirmation dialog
                // is modal (its pump re-enters here) — else they'd queue and
                // re-prompt after the user answers.
                if (self) |s| if (!s.close_pending) s.push(.close);
                return 0;
            },
            w.WM_DESTROY => {
                w.PostQuitMessage(0);
                return 0;
            },
            w.WM_SETFOCUS => {
                if (self) |s| s.push(.{ .focus = true });
                return 0;
            },
            w.WM_KILLFOCUS => {
                if (self) |s| s.push(.{ .focus = false });
                return 0;
            },
            w.WM_SIZE => {
                if (self) |s| {
                    const width: u16 = @truncate(@as(usize, @bitCast(lparam)) & 0xFFFF);
                    const height: u16 = @truncate((@as(usize, @bitCast(lparam)) >> 16) & 0xFFFF);
                    s.push(.{ .resize = .{ .width = width, .height = height } });
                }
                return 0;
            },
            w.WM_DPICHANGED => {
                if (self) |s| {
                    // wParam LOWORD = the new DPI (X and Y are equal here).
                    const new_dpi: u32 = @as(u16, @truncate(wparam & 0xFFFF));
                    // Queue the rebuild BEFORE applying the suggested rect, so the
                    // app updates cell metrics before the `.resize` that the move
                    // generates re-grids the panes with them.
                    s.push(.{ .dpi_changed = new_dpi });
                    // lParam points at the OS-suggested window rect for the new DPI
                    // (position + size); apply it so the window scales to match.
                    const r: *const w.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
                    _ = w.SetWindowPos(
                        hwnd,
                        null,
                        r.left,
                        r.top,
                        r.right - r.left,
                        r.bottom - r.top,
                        w.SWP_NOZORDER | w.SWP_NOACTIVATE,
                    );
                }
                return 0;
            },
            w.WM_CHAR => {
                if (self) |s| s.push(.{ .char = @truncate(wparam) });
                return 0;
            },
            w.WM_KEYDOWN => {
                if (self) |s| {
                    const lp = keyLParam(lparam);
                    s.push(.{ .key = .{
                        .vk = @truncate(wparam),
                        .mods = currentMods(),
                        .down = true,
                        .repeat = lp.repeat,
                        .scancode = lp.scancode,
                    } });
                }
                return 0;
            },
            w.WM_KEYUP => {
                // Release events drive the kitty keyboard `report_events` mode
                // (#82). The app forwards them to the encoder only when an app
                // has enabled that mode; otherwise (the common case) they are
                // ignored, so legacy behavior is unchanged.
                if (self) |s| {
                    const lp = keyLParam(lparam);
                    s.push(.{ .key = .{
                        .vk = @truncate(wparam),
                        .mods = currentMods(),
                        .down = false,
                        .scancode = lp.scancode,
                    } });
                }
                return 0;
            },
            w.WM_SYSKEYDOWN => {
                // Alt is held, so Windows routes the key here instead of
                // WM_KEYDOWN and would otherwise consume it (menu/beep). Forward
                // the nav/arrow/function keys we encode to the shell; leave
                // Alt+F4 (close), Alt+Space (system menu), Alt+letter, etc. to
                // Windows' default handling.
                const vk: u32 = @truncate(wparam);
                if (self) |s| if (input.altSpecialToShell(vk)) {
                    const lp = keyLParam(lparam);
                    s.push(.{ .key = .{
                        .vk = vk,
                        .mods = currentMods(),
                        .down = true,
                        .repeat = lp.repeat,
                        .scancode = lp.scancode,
                    } });
                    return 0;
                };
                return w.DefWindowProcW(hwnd, msg, wparam, lparam);
            },
            w.WM_SYSKEYUP => {
                // The release twin of WM_SYSKEYDOWN (Alt held). Forward only the
                // same nav/arrow/function keys, for kitty `report_events`.
                const vk: u32 = @truncate(wparam);
                if (self) |s| if (input.altSpecialToShell(vk)) {
                    const lp = keyLParam(lparam);
                    s.push(.{ .key = .{
                        .vk = vk,
                        .mods = currentMods(),
                        .down = false,
                        .scancode = lp.scancode,
                    } });
                    return 0;
                };
                return w.DefWindowProcW(hwnd, msg, wparam, lparam);
            },
            w.WM_MOUSEWHEEL => {
                if (self) |s| {
                    // The wheel delta is the signed high word of wParam.
                    const hi: u16 = @truncate((wparam >> 16) & 0xFFFF);
                    s.push(.{ .scroll = @as(i16, @bitCast(hi)) });
                }
                return 0;
            },
            w.WM_LBUTTONDOWN => {
                if (self) |s| {
                    const p = mouseXY(lparam);
                    // Capture so a left-drag that leaves the window still
                    // delivers moves/up to this window.
                    _ = w.SetCapture(hwnd);
                    s.push(.{ .mouse_button = .{ .button = .left, .down = true, .x = p.x, .y = p.y, .mods = currentMods() } });
                }
                return 0;
            },
            w.WM_LBUTTONUP => {
                if (self) |s| {
                    const p = mouseXY(lparam);
                    _ = w.ReleaseCapture();
                    s.push(.{ .mouse_button = .{ .button = .left, .down = false, .x = p.x, .y = p.y, .mods = currentMods() } });
                }
                return 0;
            },
            w.WM_RBUTTONDOWN => {
                if (self) |s| {
                    const p = mouseXY(lparam);
                    s.push(.{ .mouse_button = .{ .button = .right, .down = true, .x = p.x, .y = p.y, .mods = currentMods() } });
                }
                return 0;
            },
            w.WM_RBUTTONUP => {
                if (self) |s| {
                    const p = mouseXY(lparam);
                    s.push(.{ .mouse_button = .{ .button = .right, .down = false, .x = p.x, .y = p.y, .mods = currentMods() } });
                }
                return 0;
            },
            w.WM_MBUTTONDOWN => {
                if (self) |s| {
                    const p = mouseXY(lparam);
                    s.push(.{ .mouse_button = .{ .button = .middle, .down = true, .x = p.x, .y = p.y, .mods = currentMods() } });
                }
                return 0;
            },
            w.WM_MBUTTONUP => {
                if (self) |s| {
                    const p = mouseXY(lparam);
                    s.push(.{ .mouse_button = .{ .button = .middle, .down = false, .x = p.x, .y = p.y, .mods = currentMods() } });
                }
                return 0;
            },
            w.WM_CAPTURECHANGED => {
                // Capture was revoked without an LBUTTONUP (alt-tab / modal /
                // Win+L mid-drag). End the drag (free the anchor pin) without
                // emitting a reportable button event.
                if (self) |s| s.push(.mouse_capture_lost);
                return 0;
            },
            w.WM_MOUSEMOVE => {
                if (self) |s| {
                    const p = mouseXY(lparam);
                    // Coalesce: replace a pending trailing move rather than
                    // flooding the ring during a fast drag (which could push the
                    // mouse-up out).
                    if (s.tail > s.head) {
                        const last = &s.events[(s.tail - 1) % queue_len];
                        if (std.meta.activeTag(last.*) == .mouse_move) {
                            last.* = .{ .mouse_move = .{ .x = p.x, .y = p.y, .mods = currentMods() } };
                            return 0;
                        }
                    }
                    s.push(.{ .mouse_move = .{ .x = p.x, .y = p.y, .mods = currentMods() } });
                }
                return 0;
            },
            w.WM_IME_STARTCOMPOSITION => {
                // Open the IME's own composition + candidate UI at the caret, then
                // let DefWindowProc run that default UI.
                if (self) |s| s.placeImeWindows();
                return w.DefWindowProcW(hwnd, msg, wparam, lparam);
            },
            w.WM_IME_COMPOSITION => {
                if (self) |s| {
                    s.placeImeWindows();
                    // A committed result: feed it to the pty and CONSUME the
                    // message so DefWindowProc doesn't also deliver it as
                    // WM_IME_CHAR/WM_CHAR (which would double the input).
                    if ((@as(usize, @bitCast(lparam)) & @as(usize, w.GCS_RESULTSTR)) != 0) {
                        s.pushImeResult();
                        return 0;
                    }
                }
                // In-progress composition (GCS_COMPSTR / caret move): let the
                // default IME composition window draw it at the pinned caret.
                return w.DefWindowProcW(hwnd, msg, wparam, lparam);
            },
            else => return w.DefWindowProcW(hwnd, msg, wparam, lparam),
        }
    }
};
