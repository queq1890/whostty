//! whostty: native Win32 window with a WGL OpenGL context.
//!
//! Reference: ghostty `src/apprt/gtk/Window.zig` (strategy: template — Win32 has
//! no 1:1 counterpart, so gtk is only a structural reference). slice-0 keeps the
//! window minimal: a class with its own DC, a legacy WGL context (modern GL
//! entry points are loaded via wglGetProcAddress by the renderer), and a
//! message pump that surfaces input/resize/close events. See PORTING.md.
const std = @import("std");
const w = @import("../../os/windows.zig");

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
    /// A virtual key was pressed (WM_KEYDOWN), with the modifiers held.
    key: struct { vk: u32, mods: Mods },
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
    /// Mouse moved to client pixel (x, y).
    mouse_move: struct { x: i32, y: i32 },
    /// Mouse capture was lost (e.g. alt-tab mid-drag) — end any local drag
    /// without synthesizing a reportable button event.
    mouse_capture_lost,
    /// The client area was resized (pixels).
    resize: struct { width: u16, height: u16 },
    /// The user requested the window close.
    close,
};

const queue_len = 256;

pub const Window = struct {
    hwnd: w.HWND,
    hdc: w.HDC,
    hglrc: w.HGLRC,

    // Single-threaded SPSC-on-one-thread event ring (producer = wndproc,
    // consumer = poll, both on the UI thread).
    events: [queue_len]Event = undefined,
    head: usize = 0,
    tail: usize = 0,
    should_close: bool = false,

    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("whosttyWindowClass");

    pub const CreateError = error{
        RegisterClassFailed,
        CreateWindowFailed,
        GetDCFailed,
        PixelFormatFailed,
        ContextFailed,
    };

    /// Create the window and its GL context. `self` must have a stable address
    /// (heap-allocate it) because the window stores a pointer back to it.
    pub fn init(self: *Window, title_utf8: []const u8, width: i32, height: i32) CreateError!void {
        self.* = .{ .hwnd = undefined, .hdc = undefined, .hglrc = undefined };

        const hinstance = w.GetModuleHandleW(null).?;

        const wc: w.WNDCLASSEXW = .{
            .cbSize = @sizeOf(w.WNDCLASSEXW),
            .style = w.CS_OWNDC | w.CS_HREDRAW | w.CS_VREDRAW,
            .lpfnWndProc = wndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = hinstance,
            .hIcon = null,
            .hCursor = w.LoadCursorW(null, w.IDC_ARROW),
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = class_name,
            .hIconSm = null,
        };
        if (w.RegisterClassExW(&wc) == 0) return error.RegisterClassFailed;

        var title_buf: [256]u16 = undefined;
        const title_len = std.unicode.utf8ToUtf16Le(&title_buf, title_utf8) catch
            return error.CreateWindowFailed;
        title_buf[@min(title_len, title_buf.len - 1)] = 0;

        const hwnd = w.CreateWindowExW(
            0,
            class_name,
            title_buf[0..title_len :0].ptr,
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
        try self.initGl();

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
        _ = w.wglMakeCurrent(null, null);
        _ = w.wglDeleteContext(self.hglrc);
        _ = w.ReleaseDC(self.hwnd, self.hdc);
        _ = w.DestroyWindow(self.hwnd);
        self.* = undefined;
    }

    pub fn makeCurrent(self: *Window) void {
        _ = w.wglMakeCurrent(self.hdc, self.hglrc);
    }

    /// The native window handle (for synchronous Win32 calls like the clipboard).
    pub fn handle(self: *Window) w.HWND {
        return self.hwnd;
    }

    pub fn swapBuffers(self: *Window) void {
        _ = w.SwapBuffers(self.hdc);
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
                if (self) |s| s.push(.close);
                return 0;
            },
            w.WM_DESTROY => {
                w.PostQuitMessage(0);
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
            w.WM_CHAR => {
                if (self) |s| s.push(.{ .char = @truncate(wparam) });
                return 0;
            },
            w.WM_KEYDOWN => {
                if (self) |s| s.push(.{ .key = .{ .vk = @truncate(wparam), .mods = currentMods() } });
                return 0;
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
                            last.* = .{ .mouse_move = .{ .x = p.x, .y = p.y } };
                            return 0;
                        }
                    }
                    s.push(.{ .mouse_move = .{ .x = p.x, .y = p.y } });
                }
                return 0;
            },
            else => return w.DefWindowProcW(hwnd, msg, wparam, lparam),
        }
    }
};
