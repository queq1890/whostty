//! whostty: Win32 application runtime — the slice-0 integration.
//!
//! Reference: ghostty `src/apprt/gtk/App.zig` (strategy: template). Composes
//! every slice-0 layer into a running terminal: a Win32 window + WGL/OpenGL
//! renderer on the UI thread, a ConPTY-backed shell, a reader thread pumping
//! pty output into libghostty-vt, keyboard input written back to the pty, and
//! resize propagation. The glyph atlas is built from Freetype when `-Dfreetype`
//! is enabled; otherwise the pipeline runs with an empty atlas (blank glyphs).
//! See PORTING.md.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const Pty = @import("../../pty.zig").Pty;
const Child = @import("../../pty.zig").Child;
const Termio = @import("../../termio.zig").Termio;
const Window = @import("Window.zig").Window;
const st = @import("SplitTree.zig");
const gl = @import("../../renderer/OpenGL.zig");
const d3d = @import("../../renderer/Direct3D11.zig");
const rcursor = @import("../../renderer/cursor.zig");
const rcolor = @import("../../renderer/color.zig");
const decoration = @import("../../renderer/decoration.zig");
const input = @import("../../input.zig");
const surface = @import("../../Surface.zig");
const Atlas = @import("../../font/Atlas.zig");
const w = @import("../../os/windows.zig");

/// Whether the Freetype-backed glyph cache is compiled in. When false (the
/// bring-up / link-check build) the renderer draws solids only — no glyphs —
/// exactly as before.
const ft = build_options.freetype;
const GlyphCache = if (ft) @import("../../font/GlyphCache.zig") else void;
const vt = @import("ghostty-vt");
const config = @import("../../config.zig");
const scroll = @import("../../scroll.zig");
const binding = @import("../../input/Binding.zig");
const keymap = @import("keymap.zig");
const mouse = @import("../../mouse.zig");
const cli = @import("../../cli.zig");
const frame = @import("../../frame.zig");
const discovery = @import("../../font/discovery.zig");
const apprt = @import("../action.zig");

const log = std.log.scoped(.app);

/// Lowest codepoint we attempt to draw. Below this are the empty-cell sentinel
/// (0), control chars, and space (0x20) — all of which draw nothing — so we skip
/// the cache lookup for them.
const first_drawable: u21 = 0x21;

/// The bundled default monospace face, used when DirectWrite discovery (#74)
/// can't resolve the configured `font-family` (off-Windows, family absent, or a
/// COM failure). The configured family is preferred when discovery succeeds.
const default_font_path = "C:\\Windows\\Fonts\\consola.ttf";

/// Fallback fonts tried (in order) for codepoints the primary font lacks (#75) —
/// CJK, then a monochrome symbol font, then the color emoji font. The cache
/// prefers a color-capable face for emoji-presentation codepoints regardless of
/// order (see `GlyphCache.faceFor`/`wantsEmoji`), so Segoe UI Emoji renders true
/// color emoji even though Segoe UI Symbol also carries monochrome versions (#78).
/// Each missing path is skipped; per-family discovery + a configurable chain via
/// DirectWrite are #74.
const default_fallback_fonts = [_][:0]const u8{
    "C:\\Windows\\Fonts\\YuGothM.ttc", // Yu Gothic Medium (JP, Win10+)
    "C:\\Windows\\Fonts\\msgothic.ttc", // MS Gothic (JP/CJK)
    "C:\\Windows\\Fonts\\malgun.ttf", // Malgun Gothic (KR)
    "C:\\Windows\\Fonts\\simsun.ttc", // SimSun (Simplified Chinese)
    "C:\\Windows\\Fonts\\seguisym.ttf", // Segoe UI Symbol
    "C:\\Windows\\Fonts\\seguiemj.ttf", // Segoe UI Emoji (color, #78)
};

/// Atlas dimension (square, texels). Holds a few hundred packed glyphs; styled
/// text keys glyphs by (codepoint, bold, italic), so a single codepoint can
/// consume up to 4 regions (#77). Atlas growth/eviction when it fills is
/// follow-up work.
const atlas_size: u32 = 512;

/// The resolved color theme the renderer uses: default fg/bg for cells with no
/// explicit SGR color, plus the effective 256-color palette (vt defaults with
/// any config `palette` overrides applied). Built once from the config.
const Theme = struct {
    fg: vt.color.RGB,
    bg: vt.color.RGB,
    palette: vt.color.Palette,
    /// Selection highlight (renderer floats). Defaults to reverse video (the
    /// cell's fg becomes the selection bg and vice versa) when unconfigured.
    sel_bg: [3]f32,
    sel_fg: [3]f32,
    /// Minimum WCAG contrast for glyphs vs. their background (1 = disabled).
    min_contrast: f32,
    /// Opacity applied to faint/dim (SGR 2) glyphs.
    faint_opacity: f32,
    /// Render bold text with the bright (8–15) palette color (#70).
    bold_is_bright: bool,

    fn fromConfig(cfg: *const config.Config) Theme {
        var palette: vt.color.Palette = vt.color.default;
        for (cfg.palette, 0..) |override, i| {
            if (override) |c| palette[i] = toVtRgb(c);
        }
        const fg = toVtRgb(cfg.foreground);
        const bg = toVtRgb(cfg.background);
        return .{
            .fg = fg,
            .bg = bg,
            .palette = palette,
            .sel_bg = rgbf(if (cfg.selection_background) |c| toVtRgb(c) else fg),
            .sel_fg = rgbf(if (cfg.selection_foreground) |c| toVtRgb(c) else bg),
            .min_contrast = cfg.minimum_contrast,
            .faint_opacity = cfg.faint_opacity,
            .bold_is_bright = cfg.bold_is_bright,
        };
    }
};

/// libghostty-vt's bold-color option type for `Style.fg` (`union { color, bright }`),
/// reached through the field so we don't depend on ghostty's config package being
/// exported. We only use the `.bright` variant (`bold-is-bright`); a fixed
/// `bold-color` would need ghostty's config Color and is deferred.
const BoldColor = @typeInfo(@FieldType(vt.Style.Fg, "bold")).optional.child;

/// Convert a config color to a libghostty-vt RGB (both are 8-bit per channel).
fn toVtRgb(c: config.Color) vt.color.RGB {
    return .{ .r = c.r, .g = c.g, .b = c.b };
}

/// Convert a libghostty-vt RGB (0..255 per channel) to the renderer's 0..1.
fn rgbf(c: vt.color.RGB) [3]f32 {
    return .{
        @as(f32, @floatFromInt(c.r)) / 255.0,
        @as(f32, @floatFromInt(c.g)) / 255.0,
        @as(f32, @floatFromInt(c.b)) / 255.0,
    };
}

/// Resolve a style color (the underline color in particular) against the
/// palette. `none` falls back to `fallback` (the cell's foreground).
fn resolveColor(c: vt.Style.Color, palette: *const vt.color.Palette, fallback: vt.color.RGB) vt.color.RGB {
    return switch (c) {
        .none => fallback,
        .palette => |idx| palette[idx],
        .rgb => |rgb| rgb,
    };
}

/// A config color as renderer floats, or null when unset (so the caller derives
/// a default from the cell under the cursor).
fn cfgColor(c: ?config.Color) ?[3]f32 {
    return if (c) |x| rgbf(toVtRgb(x)) else null;
}

/// Per-frame cursor inputs the renderer needs that don't live in the VT state:
/// window focus, the blink phase, and the configured cursor colors/opacity. The
/// VT-owned state (position, DECTCEM, blink mode, style) is read in `buildQuads`.
const CursorRender = struct {
    focused: bool,
    blink_visible: bool,
    /// Block-cursor text color; null derives it from the cell's background.
    text: ?[3]f32,
    opacity: f32,
    /// Bar width / underline & hollow border thickness, in pixels.
    thickness: u32,
};

/// Load the user config from `%APPDATA%\whostty\config`, falling back to
/// defaults if it is missing or unreadable. The configured `font-family` is
/// resolved to a concrete face via DirectWrite discovery (#74); size/colors
/// also take effect.
fn loadConfig(alloc: std.mem.Allocator, override_text: []const u8) config.Config {
    var cfg = loadConfigFile(alloc) catch config.Config.init(alloc);
    // CLI `--key value` flags arrive as `key = value` lines applied on top of
    // the file config (same grammar), so the command line wins.
    if (override_text.len > 0) cfg.loadString(override_text) catch {};
    return cfg;
}

fn loadConfigFile(alloc: std.mem.Allocator) !config.Config {
    const appdata = try std.process.getEnvVarOwned(alloc, "APPDATA");
    defer alloc.free(appdata);
    const path = try std.fs.path.join(alloc, &.{ appdata, "whostty", "config" });
    defer alloc.free(path);
    const data = try std.fs.cwd().readFileAlloc(alloc, path, 1 << 20);
    defer alloc.free(data);
    return try config.Config.parse(alloc, data);
}

/// The small, heap-allocated state shared across every window thread (#86). It is
/// the ONLY cross-thread mutable object: it holds the allocator (std GPA, thread-
/// safe by default), the read-only CLI options, and the multi-window lifecycle
/// bookkeeping (a live-window counter + a tracked thread list, both guarded by a
/// mutex). NO per-window resource lives here — each window thread owns its own
/// Window/GL-context/Pty/io/GlyphCache(FT_Library)/binding.Set/config, so there is
/// zero shared mutable per-window state and FreeType/GL isolation is automatic.
/// `config` is loaded per-window inside `runSurface` (each thread parses its own,
/// owning its arena) rather than shared, so one window's `cfg.deinit()` can never
/// free memory another reads.
const App = struct {
    alloc: std.mem.Allocator,
    /// Parsed CLI options — read-only after `main` parses them, freely shared
    /// (each window's Pty borrows `opts.command`, which outlives all windows).
    opts: cli.Options,

    /// Guards `live` and `threads`. Held only briefly (counter bump + list
    /// append/iterate); never held across a blocking window operation.
    mutex: std.Thread.Mutex = .{},
    /// Number of live windows. A window thread increments this on entry and
    /// decrements on exit; `run` returns only once it reaches 0.
    live: usize = 0,
    /// Signaled whenever `live` transitions to 0 so the orchestrator can wake and
    /// (after joining the threads) tear down. A plain `Condition` on `mutex`.
    empty: std.Thread.Condition = .{},
    /// Every spawned window thread, joined by `run` before it returns so no thread
    /// handle leaks. Threads are tracked (not detached) precisely so the
    /// orchestrator can join them all. NOTE: finished threads are reaped only at
    /// the final join (when the last window closes), not eagerly as each window
    /// closes — so a session that opens/closes many windows holds one thread
    /// handle per closed window until exit. Bounded and freed at exit (every
    /// thread IS joined), not a true leak; eager reaping is a follow-up (it needs
    /// per-slot done-flags + join-under-mutex, which deserves its own review and
    /// shouldn't be bolted onto this refactor). Join-at-end is also what makes the
    /// lifecycle race-free: it guarantees every thread has fully exited before
    /// `App` (which holds the mutex/condition) is destroyed.
    threads: std.ArrayList(std.Thread) = .empty,
    /// The first error any window thread hit during startup, captured so `run`
    /// can return a non-zero exit (matching the pre-#86 inline behavior where a
    /// first-window startup failure propagated to `main`). First-writer-wins;
    /// a normal window close returns void and never sets this.
    first_error: ?anyerror = null,

    /// Spawn a fully independent new window on its own thread (#86). Called both
    /// for the first window (from `run`) and re-entrantly from a live window
    /// thread handling `new_window`. Only touches `App` (the counter, the thread
    /// list) — never the caller's per-window resources. `live` is bumped BEFORE
    /// the thread is spawned so the count can never transiently read 0 between an
    /// old window closing and the new one starting.
    fn spawnWindow(self: *App) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Reserve the tracking slot BEFORE spawning so that once the thread is
        // live there is no fallible step left that could fail and orphan it. The
        // counter is then the running thread's to decrement (exactly once) on
        // exit; `spawnWindow` owns the matching increment.
        try self.threads.ensureUnusedCapacity(self.alloc, 1);

        self.live += 1;
        errdefer self.live -= 1; // only fires if spawn itself fails (no thread yet)
        const t = try std.Thread.spawn(.{}, surfaceThread, .{self});
        self.threads.appendAssumeCapacity(t); // infallible: capacity reserved above
    }

    /// A window thread's body: run one window to completion, then decrement the
    /// live counter and wake the orchestrator if this was the last window. The
    /// per-thread COM apartment, FT_Library, and GL context are all created and
    /// destroyed inside `runSurface`.
    fn surfaceThread(self: *App) void {
        const result = runSurface(self);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (result) |_| {} else |e| {
            log.err("window thread failed: {}", .{e});
            if (self.first_error == null) self.first_error = e;
        }
        self.live -= 1;
        if (self.live == 0) self.empty.signal();
    }

    /// Block until every window has closed (live count == 0). The first window is
    /// spawned before this is called, so `live` is already >= 1 on entry and the
    /// wait can't return spuriously-early before any window started.
    fn waitUntilEmpty(self: *App) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.live != 0) self.empty.wait(&self.mutex);
    }
};

/// One terminal pane inside a window (#87): a fully independent terminal — its
/// own ConPTY + shell, libghostty-vt state, reader thread, and `Surface` (grid +
/// mouse mapping). Heap-allocated so its address is stable (the reader thread and
/// `sfc.pty`/`sfc.termio` hold pointers into it). The `SplitTree`/`TabList` models
/// refer to a pane only by its opaque `id`; this maps that id to the live state.
const Pane = struct {
    id: st.SurfaceId,
    pty: Pty,
    child: Child,
    io: *Termio,
    stop: std.atomic.Value(bool),
    reader: std.Thread,
    sfc: surface.Surface,
    wheel: scroll.WheelAccumulator = .{},
    /// The pane's last OSC 0/2 title (owned), shown in the window caption while
    /// this pane is focused. Null until the program sets one.
    title: ?[]const u8 = null,
};

/// Divider line thickness between split panes, in pixels (drawn over the panes).
const divider_px: f32 = 1;

/// The per-window multi-pane state (#87). Owns the tab list (each tab is a
/// `SplitTree` of pane ids) and the live `Pane` objects, tracks which pane is
/// focused, and mints pane ids. This is the whostty stand-in for ghostty's
/// per-window surface tree; every surface-scoped apprt action acts through it.
/// All of it lives on, and is only ever touched by, the owning window thread.
const WinState = struct {
    alloc: std.mem.Allocator,
    app: *App,
    win: *Window,
    opts: cli.Options,
    cfg: *const config.Config,
    theme: *const Theme,
    binds: *const binding.Set,
    cell_w: u32,
    cell_h: u32,
    pad: surface.Padding,

    tabs: st.TabList,
    panes: std.ArrayList(*Pane) = .empty,
    /// The focused pane (in the active tab). Receives keyboard input; drawn with
    /// a solid (vs. hollow) cursor.
    focused_id: st.SurfaceId = 0,
    /// Next pane id to mint (monotonic; ids are never reused within a window).
    next_id: st.SurfaceId = 0,
    /// The pane that owns the in-progress left-drag (selection), so moves and the
    /// release route to it even if the cursor crosses into another pane.
    drag_id: ?st.SurfaceId = null,
    /// Set by `close_surface` on the last pane / by the WM_CLOSE path to break the
    /// window loop next iteration.
    close_requested: bool = false,
    /// Window keyboard focus (drives the hollow-when-unfocused cursor).
    win_focused: bool = true,

    fn paneById(self: *WinState, id: st.SurfaceId) ?*Pane {
        for (self.panes.items) |p| if (p.id == id) return p;
        return null;
    }

    fn focusedPane(self: *WinState) ?*Pane {
        return self.paneById(self.focused_id);
    }

    fn activeTree(self: *WinState) *st.SplitTree {
        return self.tabs.activeTree().?;
    }

    /// Height reserved at the top for the tab strip (only when >1 tab).
    fn tabBarHeight(self: *WinState) u32 {
        return if (self.tabs.count() > 1) self.cell_h + 6 else 0;
    }

    /// The window region the active tab's panes are laid out in: the client area
    /// minus the tab strip.
    fn contentBounds(self: *WinState) st.Rect {
        const sz = self.win.clientSize();
        const tb: f32 = @floatFromInt(self.tabBarHeight());
        const h: f32 = @floatFromInt(sz.height);
        return .{ .x = 0, .y = tb, .width = @floatFromInt(sz.width), .height = @max(0, h - tb) };
    }

    /// Spawn a fresh pane: ConPTY + shell + Termio + reader thread + Surface.
    /// The id is consumed only on success.
    fn createPane(self: *WinState, cols: u16, rows: u16) !*Pane {
        const alloc = self.alloc;
        const pane = try alloc.create(Pane);
        errdefer alloc.destroy(pane);

        pane.id = self.next_id;
        pane.wheel = .{};
        pane.title = null;
        pane.stop = std.atomic.Value(bool).init(false);

        pane.pty = try Pty.open(.{ .ws_col = cols, .ws_row = rows });
        errdefer pane.pty.deinit();
        pane.child = try pane.pty.spawn(alloc, self.opts.command orelse shellCommandLine());
        errdefer {
            pane.child.kill();
            pane.child.deinit();
        }
        pane.io = try Termio.create(alloc, cols, rows, self.cfg.scrollback_limit);
        errdefer pane.io.destroy();
        pane.io.seedColors(self.theme.fg, self.theme.bg, if (self.cfg.cursor_color) |c| toVtRgb(c) else null, &self.theme.palette);

        pane.sfc = .{
            .pty = &pane.pty,
            .termio = pane.io,
            .cell_w = self.cell_w,
            .cell_h = self.cell_h,
            .cols = cols,
            .rows = rows,
            .pad = self.pad,
        };

        // Spawn the reader LAST so no fallible step remains that could orphan it.
        pane.reader = try std.Thread.spawn(.{}, readerLoop, .{ &pane.pty, pane.io, &pane.stop, self.win.handle() });

        self.next_id += 1;
        return pane;
    }

    /// Tear a pane down (stop + join its reader, kill the shell, free vt/pty),
    /// then free the pane. Does NOT touch the tree or the pane list.
    fn destroyPane(self: *WinState, pane: *Pane) void {
        pane.stop.store(true, .monotonic);
        pane.child.kill();
        // Killing the shell doesn't unblock conhost's ReadFile; cancel it so the
        // reader returns and join() doesn't hang (same as the single-pane path).
        pane.pty.cancelRead();
        pane.reader.join();
        pane.io.destroy();
        pane.child.deinit();
        pane.pty.deinit();
        if (pane.title) |t| self.alloc.free(t);
        self.alloc.destroy(pane);
    }

    /// Remove a pane from the tracking list (by id) and return it (the caller
    /// destroys it). Null if absent.
    fn takePane(self: *WinState, id: st.SurfaceId) ?*Pane {
        for (self.panes.items, 0..) |p, i| if (p.id == id) return self.panes.swapRemove(i);
        return null;
    }

    /// Resize every pane in the active tab to its laid-out rect (origin + grid).
    /// Called after any structural change (split / close / tab switch) and on a
    /// window resize.
    fn layoutActive(self: *WinState) void {
        var list: std.ArrayList(st.Placement) = .empty;
        defer list.deinit(self.alloc);
        self.activeTree().layout(self.contentBounds(), self.alloc, &list) catch return;
        for (list.items) |pl| {
            if (self.paneById(pl.surface)) |pane| {
                pane.sfc.resizeInRect(
                    @intFromFloat(@max(0, pl.rect.x)),
                    @intFromFloat(@max(0, pl.rect.y)),
                    @intFromFloat(@max(1, pl.rect.width)),
                    @intFromFloat(@max(1, pl.rect.height)),
                ) catch {};
            }
        }
    }

    /// A pane adjacent to `id` in any direction, used to pick the next focus when
    /// `id` is about to close.
    fn neighborOf(self: *WinState, tree: *st.SplitTree, id: st.SurfaceId) ?st.SurfaceId {
        const bounds = self.contentBounds();
        for ([_]st.Direction{ .right, .left, .down, .up }) |d| {
            if (tree.focusTarget(id, d, bounds, self.alloc) catch null) |t| return t;
        }
        return null;
    }

    /// Reflect the newly focused pane in window-global state: the caption tracks
    /// the focused pane's title and the close-confirmation probe its shell pid.
    /// A pane with no title yet resets the caption to the default rather than
    /// leaving the previously focused pane's title showing.
    fn syncWindowForFocus(self: *WinState) void {
        if (self.focusedPane()) |p| {
            self.win.setShellPid(w.GetProcessId(p.child.process));
            self.win.setTitle(p.title orelse "whostty");
        }
    }

    /// End any in-progress left-drag selection and forget the dragging pane.
    /// Called when the active tab changes so a drag started in a now-hidden pane
    /// can't keep extending its selection (Win32 capture stays on the HWND, so
    /// moves keep arriving with no intervening button-up).
    fn clearDrag(self: *WinState) void {
        if (self.drag_id) |d| {
            if (self.paneById(d)) |p| p.sfc.endDrag();
            self.drag_id = null;
        }
    }
};

/// Map a keybind direction to the split-tree direction (same four values).
fn toSplitDir(d: binding.Direction) st.Direction {
    return switch (d) {
        .left => .left,
        .right => .right,
        .up => .up,
        .down => .down,
    };
}

/// whostty's entry point (called from `main`). The orchestrator for the
/// multi-window, thread-per-window runtime (#86): build the shared `App`, spawn
/// the FIRST window (which runs on its own thread exactly like every later one —
/// it is NOT special), then block until the last window closes before tearing the
/// app down and returning. Returning exits the process, so this MUST NOT return
/// while any window lives.
///
/// Single-window behavior is unchanged: with one window this spawns one thread,
/// waits for it, joins it, and returns — the same setup/render/teardown as before,
/// just hosted on a window thread via `App` instead of inline on the main thread.
pub fn run(alloc: std.mem.Allocator, opts: cli.Options) !void {
    var app: App = .{ .alloc = alloc, .opts = opts };
    defer app.threads.deinit(alloc);

    // Spawn the first window. If even that fails there is nothing to wait for.
    try app.spawnWindow();

    // Block until the live-window count hits 0 (the last window closed). Never
    // returns while a window is alive — the process stays up as long as any
    // window does.
    app.waitUntilEmpty();

    // Every window thread has signaled exit; join them so no thread handle leaks
    // before `run` (and thus the process) returns. Each thread has already run its
    // own full teardown (pty.cancelRead, reader.join, GL/FT/COM teardown) before
    // decrementing the counter, so joining here only reaps the handles.
    for (app.threads.items) |t| t.join();

    // Surface a first-window startup failure as a non-zero exit (the pre-#86
    // inline run() propagated it to main; the threaded surfaceThread otherwise
    // swallows it after logging). A normal close leaves first_error null.
    if (app.first_error) |e| return e;
}

/// One window, start to finish, on its OWN thread (#86). This is the OLD `run`
/// body verbatim — it creates and owns every per-window resource (Window + WGL/GL
/// context, GlyphCache with its own FT_Library, Pty + shell, Termio, the reader
/// thread, the binding set, the surface, all loop-locals) and runs the blocking
/// message loop until the window closes, then runs the teardown defers. The shared
/// `app` is read for the allocator + CLI opts and reached only for `new_window`
/// (which spawns a sibling window thread) and the close flag.
fn runSurface(app: *App) !void {
    const alloc = app.alloc;
    const opts = app.opts;

    // Per-thread COM apartment. DirectWrite font discovery today uses
    // DWriteCreateFactory(SHARED), which needs no apartment init, so this is a
    // forward-looking safety net: any apartment-bound COM added later (the
    // apartment state is thread-local) needs a CoInitializeEx on EACH window
    // thread, not once per process. Harmless if it returns S_FALSE (already
    // initialized). Paired with CoUninitialize on thread exit.
    // CoUninitialize must be paired only with a SUCCEEDED CoInitializeEx (S_OK or
    // S_FALSE, both >= 0); a failure like RPC_E_CHANGED_MODE must NOT be balanced.
    const co_hr = w.CoInitializeEx(null, w.COINIT_APARTMENTTHREADED);
    defer if (co_hr >= 0) w.CoUninitialize();

    // --- Config (colors, font size, palette overrides) ---
    // Loaded before the window so the renderer backend choice can drive whether
    // the window creates a WGL/OpenGL context (Direct3D owns its own swap chain).
    var cfg = loadConfig(alloc, opts.config_text);
    defer cfg.deinit();
    const theme: Theme = .fromConfig(&cfg);

    // --- Window + render backend (UI thread) ---
    const win = try alloc.create(Window);
    defer alloc.destroy(win);
    try win.init("whostty", 960, 540, cfg.renderer == .opengl);
    defer win.deinit();
    win.makeCurrent();

    // The selected backend (config `renderer`). Both expose the identical
    // init/deinit/setAtlas/setColorAtlas/draw shape; `inline else` resolves the
    // concrete method at compile time, so there's no hot-path vtable. OpenGL
    // presents via `win.swapBuffers`; Direct3D owns its swap chain (`present`).
    const RendererImpl = union(enum) {
        opengl: gl.Renderer,
        direct3d: d3d.Renderer,
    };
    var renderer: RendererImpl = switch (cfg.renderer) {
        .opengl => .{ .opengl = try gl.Renderer.init(alloc, w.wglGetProcAddress) },
        .direct3d => .{ .direct3d = try d3d.Renderer.init(alloc, win.handle()) },
    };
    defer switch (renderer) {
        inline else => |*r| r.deinit(),
    };

    // Keybindings: seed defaults, then apply user `keybind` overrides.
    var binds: binding.Set = .{};
    defer binds.deinit(alloc);
    binding.addDefaults(&binds, alloc) catch {};
    for (cfg.keybinds.list.items) |b| binds.put(alloc, b) catch {};

    // --- Glyph cache + cell metrics ---
    // Glyphs are rasterized on demand from the cache (any codepoint the face
    // supports, not just ASCII) and packed into the atlas, which is re-uploaded
    // to GL whenever it gains a new glyph. The non-freetype build keeps `void`
    // here and draws solids only. The cache is constructed in the declaration so
    // there is never an `undefined` window the cleanup defer could act on: a
    // failed init returns before the defer is registered.
    // Resolve the primary face path from the configured `font-family` via
    // DirectWrite (#74). On any failure (off-Windows, family not found, COM
    // error) fall back to the bundled default. The discovered path is duped to a
    // sentinel-terminated buffer for `GlyphCache.init` and kept alive (freed)
    // for the lifetime of `run`.
    var primary_path_buf: ?[:0]u8 = null;
    defer if (primary_path_buf) |p| alloc.free(p);
    const primary_path: [:0]const u8 = if (ft) blk: {
        const fam: ?[]const u8 = if (cfg.font_family) |f|
            (if (f.len == 0) null else f)
        else
            null;
        const desc = discovery.Descriptor.forStyle(fam, cfg.font_size, .regular);
        const resolved = discovery.discover(alloc, desc) catch |err| {
            log.info("font discovery failed ({s}); using default {s}", .{ @errorName(err), default_font_path });
            break :blk default_font_path;
        };
        defer alloc.free(resolved.family);
        defer alloc.free(resolved.path);
        primary_path_buf = alloc.dupeZ(u8, resolved.path) catch break :blk default_font_path;
        log.info("font-family '{s}' resolved to {s}", .{ resolved.family, primary_path_buf.? });
        break :blk primary_path_buf.?;
    } else default_font_path;

    var cache: GlyphCache = if (ft)
        try GlyphCache.init(alloc, primary_path, @intFromFloat(@max(1, @round(cfg.font_size))), atlas_size)
    else {};
    defer if (ft) cache.deinit();

    var cell_w: u32 = 8;
    var cell_h: u32 = 16;
    var ascent: u32 = 12;
    if (ft) {
        cell_w = cache.cell_w;
        cell_h = cache.cell_h;
        ascent = cache.ascent;
        // Per-codepoint fallback (#75): register fallback faces (before any glyph
        // is cached) so codepoints the primary font lacks — CJK, symbols — render
        // from another font instead of drawing blank. Missing fonts are skipped.
        for (default_fallback_fonts) |fb| cache.addFallback(fb);
        // Upload the (empty) atlas once so the glyph texture + its sampling
        // params are configured before the first draw; new glyphs re-upload.
        switch (renderer) {
            inline else => |*r| r.setAtlas(cache.atlas.data, cache.atlas.size),
        }
    }

    // --- Initial grid from the client size, honoring window padding (#71) ---
    const pad: surface.Padding = .{
        .x = cfg.window_padding_x,
        .y = cfg.window_padding_y,
        .balance = cfg.window_padding_balance,
    };
    const size0 = win.clientSize();
    const layout0 = surface.layout(size0.width, size0.height, cell_w, cell_h, pad);
    const grid0: surface.GridSize = .{ .cols = layout0.cols, .rows = layout0.rows };

    // --- Multi-pane window state (#87) ---
    // The window hosts one tab list; each tab is a SplitTree of panes. Borrows
    // cfg/theme/binds by pointer (all stable for the window's life). Start with a
    // single tab holding one pane sized to the whole client area.
    var ws: WinState = .{
        .alloc = alloc,
        .app = app,
        .win = win,
        .opts = opts,
        .cfg = &cfg,
        .theme = &theme,
        .binds = &binds,
        .cell_w = cell_w,
        .cell_h = cell_h,
        .pad = pad,
        .tabs = st.TabList.init(alloc),
    };
    // Teardown: destroy every pane (stop + join its reader, kill its shell, free
    // vt/pty), then the list + the tab models (which own only ids). This replaces
    // the old single-pane pty/io/reader teardown.
    defer {
        for (ws.panes.items) |p| ws.destroyPane(p);
        ws.panes.deinit(alloc);
        ws.tabs.deinit();
    }

    // The first pane + tab. On any failure here the partially-built state is
    // unwound so the outer defer never sees a half-tracked pane.
    {
        const first = try ws.createPane(grid0.cols, grid0.rows);
        ws.panes.append(alloc, first) catch |e| {
            ws.destroyPane(first);
            return e;
        };
        _ = ws.tabs.addTab(first.id) catch |e| {
            _ = ws.takePane(first.id);
            ws.destroyPane(first);
            return e;
        };
        ws.focused_id = first.id;
    }
    ws.layoutActive();
    ws.syncWindowForFocus();

    // --- Main loop ---
    var quads: std.ArrayList(gl.Quad) = .empty;
    defer quads.deinit(alloc);

    // One-shot render self-verification (WHOSTTY_RENDER_DEBUG=1) — counts lit
    // pixels a few frames in so a build that can't be screenshotted can confirm
    // glyphs reached the framebuffer. See Renderer.debugCountLitPixels.
    var dbg_frame: u32 = 0;
    const render_debug = blk: {
        const v = std.process.getEnvVarOwned(alloc, "WHOSTTY_RENDER_DEBUG") catch break :blk false;
        defer alloc.free(v);
        break :blk std.mem.eql(u8, v, "1");
    };

    // Enter/Tab/Backspace/Escape are VT-encoded on their WM_KEYDOWN; Windows also
    // posts a WM_CHAR control char for them. This one-shot flag, set when such a
    // key is seen, drops that trailing WM_CHAR so the key isn't sent twice — while
    // still letting Ctrl+[ / Ctrl+M / etc. (which have no WM_KEYDOWN path) pass.
    var suppress_next_char = false;

    // --- Cursor render state (window keyboard focus lives in ws.win_focused) ---
    // Blink phase. The interval matches ghostty's default (600ms); the timer is
    // reset on input so the cursor reappears immediately when the user types.
    // If no monotonic clock is available, the cursor is treated as always-on.
    const blink_interval_ns: u64 = 600 * std.time.ns_per_ms;
    var blink_timer: ?std.time.Timer = std.time.Timer.start() catch null;
    // The cursor's fill color lives in `terminal.colors.cursor` (seeded from
    // config, overridable by OSC 12), read per-frame in buildQuads. The text
    // color and thickness are constant for the run; focus + blink vary per frame.
    const cursor_thickness: u32 = @max(1, cell_h / 10);
    const cursor_text = cfgColor(cfg.cursor_text);

    // --- Frame pacing (#72) ---
    // Render only when something changed; sleep while idle instead of rebuilding
    // and swapping every iteration. `fs_prev` is the last drawn frame's state;
    // `first_frame` forces the initial paint.
    var fs_prev: frame.FrameState = .{};
    var first_frame = true;

    while (win.pump()) {
        // Any OS event (key/mouse/resize/focus/scroll) may change the frame, so
        // it forces a redraw this iteration.
        var ui_event = false;
        while (win.poll()) |ev| {
            ui_event = true;
            switch (ev) {
                // Typing snaps the FOCUSED pane back to the bottom and is written
                // to its shell.
                .char => |cp| {
                    // Drop the WM_CHAR that trails a handled Enter/Tab/Backspace/
                    // Escape WM_KEYDOWN (flagged below) so the key isn't sent twice.
                    if (suppress_next_char) {
                        suppress_next_char = false;
                        continue;
                    }
                    const fp = ws.focusedPane() orelse continue;
                    if (blink_timer) |*t| t.reset();
                    fp.io.scrollToBottom();
                    writeChar(&fp.pty, cp);
                },
                .key => |k| {
                    const fp = ws.focusedPane() orelse continue;
                    // Read the live key-encode options fresh per press: the reader
                    // thread can flip the kitty keyboard flags between keystrokes.
                    const enc_opts = fp.io.keyEncodeOptions();
                    const kitty = enc_opts.kitty_flags.int() != 0;

                    if (kitty) {
                        // --- Kitty keyboard output path (#82) ---
                        // Printables and specials alike route through the encoder,
                        // which produces CSI-u (or passes text through, per flags).
                        // Keybinds still take priority, but only on a press.
                        if (blink_timer) |*t| t.reset();
                        if (k.down and handleKeybind(k, &ws)) {
                            // A consumed chord still posts a trailing WM_CHAR for
                            // a text key; drop it so the bound key isn't also typed.
                            suppress_next_char = switch (k.vk) {
                                input.vk.back, input.vk.tab, input.vk.enter, input.vk.escape => true,
                                else => false,
                            };
                            continue;
                        }
                        // The action may have changed the focused pane (split /
                        // focus-nav / tab); re-fetch before writing the key.
                        const tp = ws.focusedPane() orelse continue;
                        if (k.down) tp.io.scrollToBottom();
                        const km = input.mods(k.mods.shift, k.mods.ctrl, k.mods.alt);
                        suppress_next_char = writeKeyKitty(&tp.pty, k.vk, k.scancode, k.down, k.repeat, km, enc_opts);
                        continue;
                    }

                    // --- Legacy path (kitty off): byte-identical to pre-#82 ---
                    // Releases never produced output legacy-mode, so drop them.
                    if (!k.down) {
                        suppress_next_char = false;
                        continue;
                    }
                    // These keys are VT-encoded here and ALSO post a WM_CHAR; mark the
                    // trailing WM_CHAR for suppression whether the key is sent to the
                    // shell or consumed as a keybind. Other keys clear the flag.
                    suppress_next_char = switch (k.vk) {
                        input.vk.back, input.vk.tab, input.vk.enter, input.vk.escape => true,
                        else => false,
                    };
                    if (blink_timer) |*t| t.reset();

                    // A bound chord is consumed as an action; otherwise it's a
                    // normal key written to the focused pane's shell.
                    if (handleKeybind(k, &ws)) continue;
                    const tp = ws.focusedPane() orelse continue;
                    tp.io.scrollToBottom();
                    writeKey(&tp.pty, k.vk, input.mods(k.mods.shift, k.mods.ctrl, k.mods.alt), enc_opts);
                },
                .scroll => |raw| {
                    const fp = ws.focusedPane() orelse continue;
                    const delta = fp.wheel.feed(raw);
                    if (delta != 0) fp.io.scrollViewport(delta);
                },
                .mouse_button => |m| {
                    const btn: mouse.Button = switch (m.button) {
                        .left => .left,
                        .middle => .middle,
                        .right => .right,
                    };
                    // A left click in the tab strip switches tabs (and never
                    // reaches a pane). Segment math mirrors appendTabBar.
                    const tab_h: i32 = @intCast(ws.tabBarHeight());
                    if (m.down and m.button == .left and ws.tabs.count() > 1 and m.y >= 0 and m.y < tab_h) {
                        const sz = ws.win.clientSize();
                        const n = ws.tabs.count();
                        const seg_w: u32 = @max(1, @as(u32, @intCast(sz.width)) / @as(u32, @intCast(n)));
                        // Clamp to the last segment so the remainder pixels on the
                        // right (which the last segment absorbs visually) still hit
                        // the last tab.
                        const idx: usize = @min(n - 1, @as(usize, @intCast(@divFloor(@as(u32, @intCast(@max(0, m.x))), seg_w))));
                        if (idx != ws.tabs.active) {
                            ws.clearDrag();
                            ws.tabs.activate(idx);
                            ws.focused_id = ws.activeTree().anyLeaf();
                            ws.layoutActive();
                            ws.syncWindowForFocus();
                        }
                        continue;
                    }
                    // Route to the pane under the cursor; a press also focuses it,
                    // and a left-press claims the ensuing drag.
                    const bounds = ws.contentBounds();
                    var target_id: ?st.SurfaceId = ws.activeTree().surfaceAt(
                        @floatFromInt(m.x),
                        @floatFromInt(m.y),
                        bounds,
                    );
                    if (m.down) {
                        if (target_id) |id| if (id != ws.focused_id) {
                            ws.focused_id = id;
                            ws.syncWindowForFocus();
                        };
                        if (m.button == .left) ws.drag_id = target_id;
                    } else if (m.button == .left) {
                        // The release goes to the dragging pane even if the cursor
                        // wandered out of it.
                        if (ws.drag_id) |d| target_id = d;
                        ws.drag_id = null;
                    }
                    if (target_id) |id| if (ws.paneById(id)) |pane| {
                        pane.sfc.mouseButton(btn, if (m.down) .press else .release, m.x, m.y, .{
                            .shift = m.mods.shift,
                            .alt = m.mods.alt,
                            .ctrl = m.mods.ctrl,
                        });
                    };
                },
                .mouse_move => |m| {
                    if (ws.drag_id) |d| if (ws.paneById(d)) |pane| pane.sfc.mouseDrag(m.x, m.y);
                },
                .mouse_capture_lost => {
                    if (ws.drag_id) |d| if (ws.paneById(d)) |pane| pane.sfc.endDrag();
                    ws.drag_id = null;
                },
                // Re-grid every pane in the active tab to the new client size.
                .resize => |_| ws.layoutActive(),
                .focus => |f| {
                    // Only act on a real change so a redundant WM_SETFOCUS/KILLFOCUS
                    // can't emit a duplicate report.
                    if (ws.win_focused != f) {
                        ws.win_focused = f;
                        // Report the change to the focused pane's app (mode 1004).
                        if (ws.focusedPane()) |fp| {
                            if (fp.io.focusReport(f)) |r| _ = fp.pty.write(r) catch {};
                        }
                    }
                },
                // Close-confirmation (#91): the window proc swallowed the OS
                // destroy and queued this event, so the window still exists. Only
                // proceed to break the loop (which runs the pane teardown defer) if
                // the user confirms — or if nothing is running, in which case
                // confirmClose returns true with no prompt. The probe is keyed on
                // the focused pane's shell (set via syncWindowForFocus).
                .close => if (win.confirmClose()) {
                    ws.close_requested = true;
                },
            }
        }
        if (ws.close_requested) break;

        // Drain each pane's side channels (VT replies, OSC 52 clipboard, bell,
        // notification, title). Each pane's reader runs independently, so this
        // services all of them — a background pane's DSR reply still gets written
        // back, its bell still flashes the window, etc.
        var resp_buf: [256]u8 = undefined;
        for (ws.panes.items) |pane| {
            while (true) {
                const n = pane.io.takeResponse(&resp_buf);
                if (n == 0) break;
                _ = pane.pty.write(resp_buf[0..n]) catch {};
            }
            if (pane.io.takeClipboardWrite()) |text| {
                defer alloc.free(text);
                w.clipboardWrite(alloc, win.handle(), text) catch {};
            }
            if (pane.io.takeBellCount() > 0) w.flashWindow(win.handle());
            if (pane.io.takeNotification()) |note| {
                var n = note;
                defer n.deinit(alloc);
                log.info("desktop notification: {s}: {s}", .{ n.title, n.body });
            }
            // OSC 0/2 title: kept per-pane (so it survives a focus switch) and
            // applied to the live caption while this pane is focused.
            if (pane.io.takeTitle()) |title| {
                if (pane.title) |old| alloc.free(old);
                pane.title = title;
                if (pane.id == ws.focused_id) win.setTitle(title);
            }
        }

        const sz = win.clientSize();
        const blink_elapsed: u64 = if (blink_timer) |*t| t.read() else 0;
        const blink_visible = if (blink_timer != null)
            (blink_elapsed / blink_interval_ns) % 2 == 0
        else
            true;

        // Lay out the active tab's panes for this frame (cheap; few panes). Reused
        // for the dirty-gen sum, the render pass, dividers, and scrollbars.
        var placements: std.ArrayList(st.Placement) = .empty;
        defer placements.deinit(alloc);
        ws.activeTree().layout(ws.contentBounds(), alloc, &placements) catch {};

        // Frame pacing (#72): combine every visible pane's dirty generation with
        // the structural state (focused pane, active tab, pane count) so a focus
        // switch / split / tab change also forces a redraw. Wrapping multiplies
        // (rather than shifts) fold the small structural ids in without any
        // shift-overflow risk.
        var gen: u64 = (@as(u64, ws.focused_id) *% 0x9E3779B97F4A7C15) ^
            (@as(u64, @intCast(ws.tabs.active)) *% 0x100000001B3) ^
            (@as(u64, @intCast(ws.panes.items.len)) *% 0xD1B54A32D192ED03);
        for (placements.items) |pl| {
            if (ws.paneById(pl.surface)) |pane| gen +%= pane.io.dirtyGen();
        }
        const fp = ws.focusedPane();
        const cursor_blinks = if (fp) |p| p.io.cursorBlinks(ws.win_focused) else false;
        const eff_blink = if (cursor_blinks) blink_visible else true;
        const fs_cur: frame.FrameState = .{ .gen = gen, .blink = eff_blink, .focused = ws.win_focused };
        if (!first_frame and !frame.needsRedraw(fs_prev, fs_cur, ui_event)) {
            // Nothing changed: sleep until input, a reader's wake message, or the
            // next blink toggle — instead of re-rendering every iteration.
            const wait_blinking = cursor_blinks and blink_timer != null;
            w.waitForMessage(frame.idleWaitMs(wait_blinking, blink_elapsed, blink_interval_ns, 1000));
            continue;
        }
        fs_prev = fs_cur;
        first_frame = false;

        // --- Render: every pane in the active tab, then dividers + tab strip ---
        quads.clearRetainingCapacity();
        for (placements.items) |pl| {
            const pane = ws.paneById(pl.surface) orelse continue;
            // Fill the pane's rect with its own (OSC 11) background first, so each
            // pane shows the correct bg even when panes differ and so default-bg
            // cells read right regardless of the single window clear color.
            const pbg = rgbf(pane.io.backgroundColor(theme.bg));
            try quads.append(alloc, .{ .solid = .{
                .px = @intFromFloat(pl.rect.x),
                .py = @intFromFloat(pl.rect.y),
                .w = @intFromFloat(@max(0, pl.rect.width)),
                .h = @intFromFloat(@max(0, pl.rect.height)),
                .r = pbg[0],
                .g = pbg[1],
                .b = pbg[2],
            } });
            const cursor_render: CursorRender = .{
                // Only the focused pane (in a focused window) shows a solid cursor;
                // others render hollow via resolveStyle's unfocused path.
                .focused = (pane.id == ws.focused_id) and ws.win_focused,
                .blink_visible = blink_visible,
                .text = cursor_text,
                .opacity = cfg.cursor_opacity,
                .thickness = cursor_thickness,
            };
            try buildQuads(alloc, &quads, pane.io, if (ft) &cache else {}, cell_w, cell_h, ascent, pane.sfc.origin_x, pane.sfc.origin_y, &theme, cursor_render);
            // Per-pane scrollbar within the pane's rect.
            appendScrollbar(alloc, &quads, pane.io.scrollbar(), pl.rect, cell_w, theme.fg) catch {};
        }
        // buildQuads (across all panes) may have packed new glyphs into the shared
        // atlas; re-upload once before drawing.
        if (ft and cache.takeDirty()) switch (renderer) {
            inline else => |*r| r.setAtlas(cache.atlas.data, cache.atlas.size),
        };
        if (ft and cache.takeColorDirty()) switch (renderer) {
            inline else => |*r| r.setColorAtlas(cache.color_atlas.data, cache.color_atlas.size),
        };

        // Split dividers, then (with >1 tab) the tab strip, both drawn on top.
        appendDividers(&ws, &quads, alloc) catch {};
        appendTabBar(&ws, &quads, alloc, if (ft) &cache else {}, ascent) catch {};

        // Default-background cells show through the clear color, so it tracks the
        // focused pane's OSC 11 background override (falling back to config bg).
        const clear_bg = if (fp) |p| rgbf(p.io.backgroundColor(theme.bg)) else rgbf(theme.bg);
        try switch (renderer) {
            inline else => |*r| r.draw(quads.items, clear_bg, sz.width, sz.height),
        };

        dbg_frame += 1;
        // The render-debug back-buffer self-check is OpenGL-only (glReadPixels).
        if (render_debug and dbg_frame == 10) switch (renderer) {
            .opengl => |*r| r.debugCountLitPixels(clear_bg, sz.width, sz.height),
            .direct3d => {},
        };

        // Present: OpenGL via the window's double buffer, Direct3D via its swap chain.
        switch (renderer) {
            .opengl => win.swapBuffers(),
            .direct3d => |*r| r.present(),
        }
    }
}

/// The shell to launch. Honors COMSPEC, defaulting to cmd.exe.
fn shellCommandLine() []const u8 {
    return "cmd.exe";
}

fn readerLoop(pty: *Pty, io: *Termio, stop: *std.atomic.Value(bool), hwnd: w.HWND) void {
    var buf: [4096]u8 = undefined;
    while (!stop.load(.monotonic)) {
        const n = pty.read(&buf) catch break;
        io.process(buf[0..n]) catch {};
        // Wake the (possibly idle) UI thread so it renders the new output and
        // drains any VT reply this frame, instead of waiting out its timeout
        // (frame pacing, #72). PostMessage is thread-safe; a failure (window
        // gone during shutdown) is harmless.
        _ = w.PostMessageW(hwnd, w.WM_WHOSTTY_WAKE, 0, 0);
    }
}

fn writeChar(pty: *Pty, cp: u21) void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch return;
    _ = pty.write(buf[0..n]) catch {};
}

fn writeKey(pty: *Pty, code: u32, key_mods: input.Mods, opts: input.Options) void {
    const key = input.keyFromVk(code);
    if (key == .unidentified) return; // printable keys arrive via WM_CHAR
    var buf: [32]u8 = undefined;
    const out = input.encode(&buf, .{ .key = key, .mods = key_mods }, opts) catch return;
    if (out.len > 0) _ = pty.write(out) catch {};
}

/// What `deriveKeyText` produced for a key press: the actual generated text
/// (`utf8`, a slice into the caller-owned buffer), the unshifted base codepoint,
/// which mods were consumed to produce the text, and whether the key left the
/// keyboard in a dead-key (composing) state.
const KeyText = struct {
    utf8: []const u8,
    unshifted_codepoint: u21,
    consumed_mods: input.Mods,
    composing: bool,
};

/// Derive the base (unshifted) codepoint and the actual typed text for a key
/// press, for the kitty-keyboard output path (#82). Windows-only: uses the live
/// keyboard layout (MapVirtualKeyW for the unshifted codepoint; ToUnicodeEx +
/// GetKeyboardState for the layout-translated text incl. Shift/AltGr).
///
/// `utf8_buf` is borrowed for the returned `utf8` slice (so it must outlive the
/// returned struct). Every buffer is fixed-size and bounds-checked (the #89
/// stack-overflow precedent): the UTF-16 scratch is 8 units, and the conversion
/// into `utf8_buf` is length-checked.
///
/// Dead keys: ToUnicodeEx returns -1 and leaves the dead-key state pending; we
/// flag `composing` and immediately call ToUnicodeEx a SECOND time with the same
/// key so the pending state is consumed back out (otherwise it would corrupt the
/// NEXT keystroke — a documented Win32 footgun).
fn deriveKeyText(vk: u32, scancode: u32, down: bool, mods: input.Mods, utf8_buf: []u8) KeyText {
    // Unshifted base codepoint via the layout's VK->char map. The high bit
    // (0x80000000) marks a dead key; mask it off. ASCII letters come back
    // uppercase, so lowercase them for the canonical base codepoint ('a' for A).
    var unshifted: u21 = 0;
    const mapped = w.MapVirtualKeyW(vk, w.MAPVK_VK_TO_CHAR) & 0x7FFFFFFF;
    if (mapped != 0 and mapped <= 0x10FFFF) {
        var cp: u21 = @intCast(mapped);
        if (cp >= 'A' and cp <= 'Z') cp += 32;
        unshifted = cp;
    }

    // Releases (and key repeats reported as releases) generate no committed text
    // and must NOT touch the dead-key state via ToUnicodeEx. The encoder skips
    // associated text on release anyway (`seq.event != .release`), so the
    // unshifted codepoint alone is enough to key the CSI-u release sequence.
    if (!down) {
        return .{ .utf8 = "", .unshifted_codepoint = unshifted, .consumed_mods = .{}, .composing = false };
    }

    // Actual typed text via the full layout translation. GetKeyboardState gives
    // the live modifier/lock state ToUnicodeEx needs.
    var key_state: [256]u8 = undefined;
    if (w.GetKeyboardState(&key_state) == w.FALSE) {
        return .{ .utf8 = "", .unshifted_codepoint = unshifted, .consumed_mods = .{}, .composing = false };
    }

    const layout = w.GetKeyboardLayout(0);
    var utf16: [8]u16 = undefined;
    const n = w.ToUnicodeEx(vk, scancode, &key_state, &utf16, utf16.len, 0, layout);

    if (n < 0) {
        // Dead key: re-feed the same key so the pending dead-key state is not
        // leaked into the next keystroke. Report composing with no committed text.
        _ = w.ToUnicodeEx(vk, scancode, &key_state, &utf16, utf16.len, 0, layout);
        return .{ .utf8 = "", .unshifted_codepoint = unshifted, .consumed_mods = .{}, .composing = true };
    }

    if (n == 0) {
        // No translation (e.g. a bare modifier, or ctrl that yields nothing).
        return .{ .utf8 = "", .unshifted_codepoint = unshifted, .consumed_mods = .{}, .composing = false };
    }

    // n > 0: that many UTF-16 units. `utf16LeToUtf8` does NOT bounds-check its
    // destination — it asserts internally and writes — so an oversized
    // translation would overflow the stack buffer (#89 class). Convert ONLY when
    // the worst case provably fits: each UTF-16 unit is at most 3 UTF-8 bytes (a
    // surrogate pair is 2 units -> 4 bytes = 2 bytes/unit), so `units * 3` is a
    // safe upper bound. Bail to empty text rather than overflow.
    const units: usize = @min(@as(usize, @intCast(n)), utf16.len);
    const utf8: []const u8 = if (units != 0 and units * 3 <= utf8_buf.len)
        utf8_buf[0..(std.unicode.utf16LeToUtf8(utf8_buf, utf16[0..units]) catch 0)]
    else
        "";

    // Mods consumed to produce the text, so the encoder's effectiveMods drops
    // them. AltGr on Windows is delivered as Ctrl+Alt: when BOTH are held and
    // text was produced, AltGr is what produced it, so consume BOTH — otherwise
    // the leftover ctrl makes binding_mods non-empty and the AltGr character
    // (e.g. German '@' = AltGr+Q, '{' '}' '[' ']' '\' '~' on EU layouts)
    // mis-encodes as a CSI-u escape instead of passing through as text. Plain
    // ctrl (no alt) never yields printable text here, so it stays unconsumed and
    // shows in the CSI-u modifier field (ctrl+a -> ESC[97;5u).
    var consumed: input.Mods = .{};
    if (utf8.len > 0) {
        consumed.shift = mods.shift;
        if (mods.ctrl and mods.alt) {
            consumed.ctrl = true;
            consumed.alt = true;
        } else {
            consumed.alt = mods.alt;
        }
    }

    return .{
        .utf8 = utf8,
        .unshifted_codepoint = unshifted,
        .consumed_mods = consumed,
        .composing = false,
    };
}

/// Kitty-keyboard output path (#82): build a full KeyEvent from a Win32 key
/// event and encode it. Returns true if a trailing WM_CHAR for this key should
/// be suppressed (it was already consumed into the encoded sequence or passed
/// through as text). Only called when `opts.kitty_flags.int() != 0`.
fn writeKeyKitty(
    pty: *Pty,
    vk: u32,
    scancode: u32,
    down: bool,
    repeat: bool,
    key_mods: input.Mods,
    opts: input.Options,
) bool {
    const key = input.kittyKeyFromVk(vk);
    if (key == .unidentified) return false; // unknown key: leave it to WM_CHAR.

    // Sized for the [8]u16 ToUnicodeEx scratch worst case (8 units * 3 bytes/unit
    // = 24); 32 matches the other fixed buffers and leaves headroom.
    var text_buf: [32]u8 = undefined;
    const text = deriveKeyText(vk, scancode, down, key_mods, &text_buf);

    const action: input.Action = if (!down) .release else if (repeat) .repeat else .press;
    const event = input.kittyKeyEvent(.{
        .key = key,
        .unshifted_codepoint = text.unshifted_codepoint,
        .utf8 = text.utf8,
        .mods = key_mods,
        .consumed_mods = text.consumed_mods,
        .action = action,
        .composing = text.composing,
    });

    // Buffer sized for a kitty sequence with associated text + alternates (the
    // legacy 32 bytes is too small once report_associated is on). The fixed
    // writer truncates rather than overflowing; 128 covers realistic sequences.
    var buf: [128]u8 = undefined;
    const out = input.encode(&buf, event, opts) catch return false;
    if (out.len > 0) _ = pty.write(out) catch {};

    // Suppress the trailing WM_CHAR Windows posts for a press of a text-producing
    // key (printables) or the control keys (Enter/Tab/Backspace/Escape), since
    // we already encoded/passed them. Release/repeat-with-no-char don't post a
    // fresh WM_CHAR to worry about, but a press that produced text always does.
    if (!down) return false;
    return text.utf8.len > 0 or switch (vk) {
        input.vk.back, input.vk.tab, input.vk.enter, input.vk.escape => true,
        else => false,
    };
}

/// Look up a key event in the binding set and run the bound action. Returns true
/// if a binding matched and was handled (so the key is not also sent to the pty).
/// The matched `binding.Action` is translated to the formal `apprt.Action` and
/// dispatched through `performAction`, mirroring ghostty's
/// `Surface.performBindingAction`.
fn handleKeybind(k: anytype, ws: *WinState) bool {
    const key = keymap.keyFromVk(k.vk) orelse return false;
    const trigger: binding.Trigger = .{ .key = key, .mods = .{
        .ctrl = k.mods.ctrl,
        .shift = k.mods.shift,
        .alt = k.mods.alt,
        .super = k.mods.super,
    } };
    const action = ws.binds.get(trigger) orelse return false;
    _ = performAction(ws, apprt.fromBinding(action));
    return true;
}

/// The formal apprt action dispatch (#86/#87) — the whostty mirror of ghostty's
/// `App.performAction` / the GTK `performAction` switch. Routes each `apprt.Action`
/// to its effect: app-scoped actions spawn a sibling window; surface-scoped ones
/// act on the calling window's `WinState` (its focused pane / tab tree). Returns
/// whether the action was handled.
///
/// Threading: every surface-scoped effect touches only THIS window's resources,
/// so this always runs on the owning window thread. `.new_window` is the only
/// cross-thread step (it spawns an independent window thread).
fn performAction(ws: *WinState, action: apprt.Action) bool {
    switch (action) {
        // --- App-scoped ---
        .new_window => {
            ws.app.spawnWindow() catch |e| log.err("new_window: spawn failed: {}", .{e});
            return true;
        },

        // --- In-window subdivision (#87) ---
        .new_split => |d| {
            splitFocused(ws, toSplitDir(d));
            return true;
        },
        .goto_split => |d| {
            const bounds = ws.contentBounds();
            const target = ws.activeTree().focusTarget(ws.focused_id, toSplitDir(d), bounds, ws.alloc) catch null;
            if (target) |t| {
                ws.focused_id = t;
                ws.syncWindowForFocus();
            }
            return true;
        },
        .new_tab => {
            newTab(ws);
            return true;
        },
        .next_tab => {
            switchTab(ws, .next);
            return true;
        },
        .previous_tab => {
            switchTab(ws, .prev);
            return true;
        },
        .goto_tab => |n| {
            // 1-based; ignore 0, out-of-range, and a no-op jump to the current
            // tab (otherwise focus would be yanked to the tab's first pane).
            const idx: usize = if (n >= 1) @as(usize, n) - 1 else std.math.maxInt(usize);
            if (idx < ws.tabs.count() and idx != ws.tabs.active) {
                ws.clearDrag();
                ws.tabs.activate(idx);
                ws.focused_id = ws.activeTree().anyLeaf();
                ws.layoutActive();
                ws.syncWindowForFocus();
            }
            return true;
        },

        // --- Surface-scoped: the focused pane / calling window ---
        .close_surface => {
            closeFocused(ws);
            return true;
        },
        .scroll_page_up => {
            if (ws.focusedPane()) |p| p.io.scrollViewport(-@as(isize, @intCast(scroll.pageRows(p.sfc.rows))));
            return true;
        },
        .scroll_page_down => {
            if (ws.focusedPane()) |p| p.io.scrollViewport(@as(isize, @intCast(scroll.pageRows(p.sfc.rows))));
            return true;
        },
        .scroll_to_bottom => {
            if (ws.focusedPane()) |p| p.io.scrollToBottom();
            return true;
        },
        .scroll_to_top => {
            if (ws.focusedPane()) |p| p.io.scrollViewport(-1_000_000); // clamps at the top
            return true;
        },
        .copy_to_clipboard => {
            copyToClipboard(ws);
            return true;
        },
        .paste_from_clipboard => {
            pasteFromClipboard(ws);
            return true;
        },
        // Window-state actions (#91) act on the whole window.
        .toggle_fullscreen => {
            ws.win.toggleFullscreen();
            return true;
        },
        .toggle_maximize => {
            ws.win.toggleMaximize();
            return true;
        },
        .toggle_window_decorations => {
            ws.win.toggleDecorations();
            return true;
        },
    }
}

/// Split the focused pane (#87): mint a new pane sized to the focused one, insert
/// it into the active tree in `dir`, focus it, and re-grid the tab. Best-effort:
/// any failure is logged and unwound, leaving the existing panes intact.
fn splitFocused(ws: *WinState, dir: st.Direction) void {
    const tree = ws.activeTree();
    const fp = ws.focusedPane() orelse return;
    const pane = ws.createPane(fp.sfc.cols, fp.sfc.rows) catch |e| {
        log.err("new_split: create pane failed: {}", .{e});
        return;
    };
    tree.split(ws.focused_id, dir, pane.id) catch |e| {
        log.err("new_split: tree split failed: {}", .{e});
        ws.destroyPane(pane);
        return;
    };
    ws.panes.append(ws.alloc, pane) catch {
        tree.close(pane.id) catch {};
        ws.destroyPane(pane);
        return;
    };
    ws.focused_id = pane.id;
    ws.layoutActive();
    ws.syncWindowForFocus();
}

/// Close the focused pane (#87). With siblings in the tab, the sibling takes its
/// space and focus moves to a neighbor. As the tab's last pane, the tab closes
/// (or, as the last tab's last pane, the whole window).
fn closeFocused(ws: *WinState) void {
    const tree = ws.activeTree();
    if (tree.count() > 1) {
        const closing = ws.focused_id;
        const next = ws.neighborOf(tree, closing);
        tree.close(closing) catch return;
        if (ws.takePane(closing)) |p| ws.destroyPane(p);
        ws.focused_id = next orelse tree.anyLeaf();
        ws.layoutActive();
        ws.syncWindowForFocus();
        return;
    }
    // The tab's only pane.
    if (ws.tabs.count() > 1) {
        const closing = ws.focused_id;
        _ = ws.tabs.closeActiveTab(); // frees that tab's (single-leaf) tree
        if (ws.takePane(closing)) |p| ws.destroyPane(p);
        ws.focused_id = ws.activeTree().anyLeaf();
        ws.layoutActive();
        ws.syncWindowForFocus();
        return;
    }
    // Last pane of the last tab: close the window (teardown frees the pane).
    ws.close_requested = true;
}

/// Open a new tab (#87): a fresh pane in its own tab, made active and focused.
fn newTab(ws: *WinState) void {
    const fp = ws.focusedPane();
    const cols: u16 = if (fp) |p| p.sfc.cols else 80;
    const rows: u16 = if (fp) |p| p.sfc.rows else 24;
    const pane = ws.createPane(cols, rows) catch |e| {
        log.err("new_tab: create pane failed: {}", .{e});
        return;
    };
    ws.panes.append(ws.alloc, pane) catch {
        ws.destroyPane(pane);
        return;
    };
    _ = ws.tabs.addTab(pane.id) catch |e| {
        log.err("new_tab: addTab failed: {}", .{e});
        _ = ws.takePane(pane.id);
        ws.destroyPane(pane);
        return;
    };
    ws.focused_id = pane.id;
    ws.layoutActive();
    ws.syncWindowForFocus();
}

/// Activate the next/previous tab and focus a pane within it.
fn switchTab(ws: *WinState, comptime which: enum { next, prev }) void {
    if (ws.tabs.count() <= 1) return;
    ws.clearDrag();
    switch (which) {
        .next => ws.tabs.nextTab(),
        .prev => ws.tabs.prevTab(),
    }
    ws.focused_id = ws.activeTree().anyLeaf();
    ws.layoutActive();
    ws.syncWindowForFocus();
}

/// Paste the system clipboard into the focused pane's shell. Reads
/// CF_UNICODETEXT, encodes via libghostty-vt's paste encoder (strips unsafe
/// bytes, applies bracketed-paste fenceposts when mode 2004 is on), and writes
/// the result to that pane's pty.
fn pasteFromClipboard(ws: *WinState) void {
    const pane = ws.focusedPane() orelse return;
    const alloc = ws.alloc;
    const text = (w.clipboardRead(alloc, ws.win.handle()) catch return) orelse return;
    defer alloc.free(text);
    if (text.len == 0) return;

    const bracketed = blk: {
        pane.io.lock();
        defer pane.io.unlock();
        break :blk pane.io.terminal.modes.get(.bracketed_paste);
    };

    pane.io.scrollToBottom();

    // encodePaste mutates the buffer in place (control-byte stripping / \n->\r),
    // so pass a mutable copy to use the infallible []u8 overload.
    const buf = alloc.dupe(u8, text) catch return;
    defer alloc.free(buf);
    const parts = vt.input.encodePaste(buf, .{ .bracketed = bracketed });
    for (parts) |part| {
        if (part.len > 0) _ = pane.pty.write(part) catch {};
    }
}

/// Copy the focused pane's selection to the system clipboard. A no-op when there
/// is no selection (selection is set by mouse-drag, #51).
fn copyToClipboard(ws: *WinState) void {
    const pane = ws.focusedPane() orelse return;
    const alloc = ws.alloc;
    const text = blk: {
        pane.io.lock();
        defer pane.io.unlock();
        const screen = pane.io.terminal.screens.active; // *Screen
        const sel = screen.selection orelse break :blk null;
        break :blk screen.selectionString(alloc, .{ .sel = sel, .trim = true }) catch null;
    } orelse return;
    defer alloc.free(text);
    if (text.len == 0) return;
    w.clipboardWrite(alloc, ws.win.handle(), text) catch |e| log.warn("clipboard write failed: {}", .{e});
}

/// Append a pane's scrollbar overlay (#73): a faint track and a brighter,
/// grabbable thumb on the pane's right edge, sized and positioned from the VT
/// viewport's scrollback counts (`scroll.scrollbarThumb`). Nothing is appended
/// when the content fits the viewport (no history to scroll). `rect` is the
/// pane's pixel rect within the window; the bar is placed inside it so each split
/// pane gets its own scrollbar.
fn appendScrollbar(
    alloc: std.mem.Allocator,
    quads: *std.ArrayList(gl.Quad),
    sb: Termio.Scrollbar,
    rect: st.Rect,
    cell_w: u32,
    fg: vt.color.RGB,
) !void {
    const rect_w: u32 = @intFromFloat(@max(0, rect.width));
    const rect_h: u32 = @intFromFloat(@max(0, rect.height));
    if (sb.total <= sb.len or rect_h == 0 or rect_w == 0) return;
    const rect_x: i32 = @intFromFloat(rect.x);
    const rect_y: i32 = @intFromFloat(rect.y);
    const bar_w: u32 = @max(4, cell_w / 3);
    const bar_x: i32 = rect_x + @as(i32, @intCast(rect_w -| bar_w));
    const thumb = scroll.scrollbarThumb(sb.total, sb.len, sb.offset, @floatFromInt(rect_h));
    const c = rgbf(fg);
    // Faint full-height track over the pane.
    try quads.append(alloc, .{ .solid = .{ .px = bar_x, .py = rect_y, .w = bar_w, .h = rect_h, .r = c[0], .g = c[1], .b = c[2], .a = 0.12 } });
    // The thumb, clamped so it never spills past the track bottom on rounding.
    const off: u32 = @intFromFloat(@round(thumb.offset));
    const size: u32 = @min(@max(1, @as(u32, @intFromFloat(@round(thumb.size)))), rect_h -| off);
    try quads.append(alloc, .{ .solid = .{ .px = bar_x, .py = rect_y + @as(i32, @intCast(off)), .w = bar_w, .h = size, .r = c[0], .g = c[1], .b = c[2], .a = 0.5 } });
}

/// Append the split-divider lines for the active tab over the content area, as
/// thin solid quads in a color halfway between bg and fg so the seam reads on any
/// theme. Nothing is appended for a single (unsplit) pane.
fn appendDividers(ws: *WinState, quads: *std.ArrayList(gl.Quad), alloc: std.mem.Allocator) !void {
    var ds: std.ArrayList(st.Rect) = .empty;
    defer ds.deinit(alloc);
    try ws.activeTree().dividers(ws.contentBounds(), divider_px, alloc, &ds);
    if (ds.items.len == 0) return;
    const bg = rgbf(ws.theme.bg);
    const fg = rgbf(ws.theme.fg);
    const c: [3]f32 = .{ (bg[0] + fg[0]) / 2, (bg[1] + fg[1]) / 2, (bg[2] + fg[2]) / 2 };
    for (ds.items) |r| {
        try quads.append(alloc, .{ .solid = .{
            .px = @intFromFloat(r.x),
            .py = @intFromFloat(r.y),
            .w = @intFromFloat(@max(1, r.width)),
            .h = @intFromFloat(@max(1, r.height)),
            .r = c[0],
            .g = c[1],
            .b = c[2],
        } });
    }
}

/// Append a minimal tab strip at the top of the window (#87) when more than one
/// tab is open: one segment per tab (the active one brighter) with its 1-based
/// index drawn as a glyph. The strip occupies `tabBarHeight` px; the panes are
/// laid out below it (see `contentBounds`). `cache` is the shared glyph cache
/// (or `void` in the no-Freetype build, where only the segments draw).
fn appendTabBar(
    ws: *WinState,
    quads: *std.ArrayList(gl.Quad),
    alloc: std.mem.Allocator,
    cache: anytype,
    ascent: u32,
) !void {
    const n = ws.tabs.count();
    if (n <= 1) return;
    const h = ws.tabBarHeight();
    const sz = ws.win.clientSize();
    if (sz.width == 0 or h == 0) return;

    const fg = rgbf(ws.theme.fg);
    const bg = rgbf(ws.theme.bg);
    const inactive: [3]f32 = .{ (bg[0] * 3 + fg[0]) / 4, (bg[1] * 3 + fg[1]) / 4, (bg[2] * 3 + fg[2]) / 4 };
    const active: [3]f32 = .{ (bg[0] + fg[0]) / 2, (bg[1] + fg[1]) / 2, (bg[2] + fg[2]) / 2 };
    const seg_w: u32 = @max(1, @as(u32, @intCast(sz.width)) / @as(u32, @intCast(n)));

    const total_w: u32 = @intCast(sz.width);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const x0: u32 = @as(u32, @intCast(i)) * seg_w;
        const x: i32 = @intCast(x0);
        // The last segment absorbs the remainder so the strip tiles the full
        // client width (no undrawn gap on the right edge).
        const seg: u32 = if (i == n - 1) total_w -| x0 else seg_w;
        const c = if (i == ws.tabs.active) active else inactive;
        try quads.append(alloc, .{ .solid = .{ .px = x, .py = 0, .w = seg, .h = h, .r = c[0], .g = c[1], .b = c[2] } });
        // Tab number glyph (1-based). Tabs past 9 reuse the digits 1-9 (a minimal
        // affordance; full per-tab labels are a follow-up).
        if (ft) {
            const digit: u21 = @as(u21, '1') + @as(u21, @intCast(i % 9));
            if (cache.get(digit, false, false)) |gi| {
                try quads.append(alloc, .{ .glyph = .{
                    .px = x + 6 + gi.bearing_x,
                    .py = @as(i32, @intCast(ascent)) - gi.bearing_y + 3,
                    .sx = gi.region.x,
                    .sy = gi.region.y,
                    .sw = gi.region.width,
                    .sh = gi.region.height,
                    .r = fg[0],
                    .g = fg[1],
                    .b = fg[2],
                } });
            }
        }
    }
}

/// Translate the terminal viewport into renderable quads, honoring SGR colors
/// and attributes (#12): per-cell foreground/background colors (default, 256
/// palette, or truecolor), inverse video, and the underline / strikethrough /
/// overline decorations. For each cell we emit, in order, an optional
/// background fill, the foreground glyph, then any decoration lines, so the
/// renderer layers them correctly.
///
/// Color resolution is delegated to libghostty-vt (`Style.fg`/`Style.bg` and
/// the default palette) rather than reimplemented here, per the hybrid
/// architecture (ADR 0002); bold also brightens palette colors via vt's
/// resolution. Bold/italic glyphs are synthesized from the single regular face
/// (the cache rasterizes an emboldened / sheared variant, #77); they aren't
/// clipped to the cell, so a heavy/slanted glyph may overhang a neighbor by a
/// pixel or two — cosmetic, and addressed with the per-style-family work.
fn buildQuads(
    alloc: std.mem.Allocator,
    quads: *std.ArrayList(gl.Quad),
    io: *Termio,
    cache: anytype,
    cell_w: u32,
    cell_h: u32,
    ascent: u32,
    /// Top-left pixel of cell (0,0): the window-padding offset (#71). Every cell
    /// and the cursor are shifted by it; the padding region shows the clear color.
    origin_x: u32,
    origin_y: u32,
    theme: *const Theme,
    cursor_render: CursorRender,
) !void {
    // The caller clears `quads` once per frame and then calls this for every pane
    // in the active tab, so each pane's quads accumulate into one draw (#87).

    // Reused across cells to hold an underline's decoration rects (#80); cleared
    // per underlined cell, so its capacity amortizes over the frame.
    var deco_rects: std.ArrayList(decoration.Rect) = .empty;
    defer deco_rects.deinit(alloc);

    io.lock();
    defer io.unlock();

    const term = &io.terminal;
    const screen = term.screens.active;
    const sel = screen.selection;
    // Effective default colors come from `terminal.colors` (seeded from config,
    // overridable at runtime via OSC 10/11/4), so dynamic-color changes render.
    // `seedColors` primes these, so the `orelse` is only a defensive fallback.
    const palette = &term.colors.palette.current;
    const eff_fg = term.colors.foreground.get() orelse theme.fg;
    const eff_bg = term.colors.background.get() orelse theme.bg;
    // bold-is-bright (#70): when set, libghostty-vt's `Style.fg` maps a bold
    // cell's palette color 0–7 to its bright 8–15 counterpart. Constant per frame.
    const bold_opt: ?BoldColor = if (theme.bold_is_bright) .bright else null;
    const rows: u32 = term.rows;
    const cols: u32 = term.cols;
    const line_h: u32 = @max(1, cell_h / 16);
    const ascent_i: i32 = @intCast(ascent);

    var row: u32 = 0;
    while (row < rows) : (row += 1) {
        var col: u32 = 0;
        while (col < cols) : (col += 1) {
            const gc = screen.pages.getCell(.{ .viewport = .{
                .x = @intCast(col),
                .y = @intCast(row),
            } }) orelse continue;
            const cell = gc.cell;
            const style = gc.style();

            // Resolve fg/bg against the configured theme, then apply inverse
            // video by swapping them.
            const fg_rgb = style.fg(.{ .default = eff_fg, .palette = palette, .bold = bold_opt });
            var fg = rgbf(fg_rgb);
            var bg: ?[3]f32 = if (style.bg(cell, palette)) |c| rgbf(c) else null;
            if (style.flags.inverse) {
                const old_fg = fg;
                fg = bg orelse rgbf(eff_bg);
                bg = old_fg;
            }

            // Minimum-contrast: lift the foreground to black/white if it falls
            // below the configured ratio against its (resolved) background. A
            // ratio of 1 is a no-op. The decorations below intentionally reuse
            // this adjusted `fg`: in ghostty they are sprite glyphs drawn through
            // the same cell-text pipeline that applies `contrasted_color`, so a
            // strikethrough matches the (possibly re-colored) text rather than
            // diverging from it. Applied before the selection override, whose
            // fg/bg are configured directly. ghostty also exempts graphics
            // glyphs (box-drawing / blocks / Powerline) via `noMinContrast`;
            // whostty's atlas is ASCII-only today (none of those codepoints), so
            // that exemption is deferred with the sprite work (#66/#71).
            if (theme.min_contrast > 1) {
                fg = rcolor.contrastedColor(fg, bg orelse rgbf(eff_bg), theme.min_contrast);
            }

            // Selection highlight overrides the cell colors (reverse-video by
            // default). Per-cell containment is fine for whostty's already
            // per-cell loop; only queried when a selection exists.
            if (sel) |s| {
                if (screen.pages.pin(.{ .viewport = .{ .x = @intCast(col), .y = @intCast(row) } })) |p| {
                    if (s.contains(screen, p)) {
                        bg = theme.sel_bg;
                        fg = theme.sel_fg;
                    }
                }
            }

            const cell_x: i32 = @intCast(origin_x + col * cell_w);
            const cell_y: i32 = @intCast(origin_y + row * cell_h);

            // Background fill. The cleared framebuffer already provides the
            // default background, so only non-default backgrounds emit a quad.
            if (bg) |c| try quads.append(alloc, .{ .solid = .{
                .px = cell_x,
                .py = cell_y,
                .w = cell_w,
                .h = cell_h,
                .r = c[0],
                .g = c[1],
                .b = c[2],
            } });

            // Foreground glyph (invisible attribute suppresses it). The glyph is
            // rasterized on demand and packed into the atlas the first time its
            // codepoint is seen. Faint/dim (SGR 2) text is drawn at reduced
            // opacity via the per-quad alpha.
            if (ft and !style.flags.invisible) {
                const cp = cell.codepoint();
                if (cp >= first_drawable) {
                    if (cache.get(cp, style.flags.bold, style.flags.italic)) |gi| {
                        const glyph_alpha: f32 = if (style.flags.faint) theme.faint_opacity else 1;
                        const gcell: gl.Cell = .{
                            .px = cell_x + gi.bearing_x,
                            .py = cell_y + ascent_i - gi.bearing_y,
                            .sx = gi.region.x,
                            .sy = gi.region.y,
                            .sw = gi.region.width,
                            .sh = gi.region.height,
                            .r = fg[0],
                            .g = fg[1],
                            .b = fg[2],
                            .a = glyph_alpha,
                        };
                        // Color glyphs (emoji, #78) come from the RGBA atlas and
                        // are drawn untinted; everything else is alpha-tinted.
                        try quads.append(alloc, if (gi.color) .{ .color_glyph = gcell } else .{ .glyph = gcell });
                    }
                }
            }

            // Decorations, drawn on top. Underlines use the explicit underline
            // color when set; strikethrough/overline use the foreground. The
            // underline style (single/double/dotted/dashed/curly) is drawn as a
            // set of solid rects (#80) instead of always one line.
            if (style.flags.underline != .none) {
                const uc = if (style.underline_color != .none)
                    rgbf(resolveColor(style.underline_color, palette, fg_rgb))
                else
                    fg;
                const dstyle: decoration.Underline = switch (style.flags.underline) {
                    .none => .none,
                    .single => .single,
                    .double => .double,
                    .dotted => .dotted,
                    .dashed => .dashed,
                    .curly => .curly,
                };
                deco_rects.clearRetainingCapacity();
                try decoration.underlineRects(&deco_rects, alloc, dstyle, cell_w, ascent_i + 1, line_h);
                for (deco_rects.items) |r| try quads.append(alloc, .{ .solid = .{
                    .px = cell_x + r.x,
                    .py = cell_y + r.y,
                    .w = r.w,
                    .h = r.h,
                    .r = uc[0],
                    .g = uc[1],
                    .b = uc[2],
                } });
            }
            if (style.flags.strikethrough) try quads.append(alloc, .{ .solid = .{
                .px = cell_x,
                .py = cell_y + @divTrunc(ascent_i, 2),
                .w = cell_w,
                .h = line_h,
                .r = fg[0],
                .g = fg[1],
                .b = fg[2],
            } });
            if (style.flags.overline) try quads.append(alloc, .{ .solid = .{
                .px = cell_x,
                .py = cell_y,
                .w = cell_w,
                .h = line_h,
                .r = fg[0],
                .g = fg[1],
                .b = fg[2],
            } });
        }
    }

    // --- Cursor (drawn last, above the cell contents) ---
    // Map the cursor's active-area position into the viewport. A null point, or
    // one past the viewport bounds, means the cursor scrolled out of view —
    // resolveStyle then renders nothing.
    const cpt = screen.pages.pointFromPin(.viewport, screen.cursor.page_pin.*);
    const cx: u32 = if (cpt) |p| p.viewport.x else 0;
    const cy: u32 = if (cpt) |p| p.viewport.y else 0;
    const in_viewport = cpt != null and cx < cols and cy < rows;

    const term_style: rcursor.TermStyle = switch (screen.cursor.cursor_style) {
        .bar => .bar,
        .block => .block,
        .underline => .underline,
        .block_hollow => .block_hollow,
    };
    const cstyle = rcursor.resolveStyle(.{
        .in_viewport = in_viewport,
        .visible = term.modes.get(.cursor_visible),
        .focused = cursor_render.focused,
        .blinking = term.modes.get(.cursor_blinking),
        .blink_visible = cursor_render.blink_visible,
        .term_style = term_style,
    });
    if (cstyle) |cs| {
        const ccx: i32 = @intCast(origin_x + cx * cell_w);
        const ccy: i32 = @intCast(origin_y + cy * cell_h);

        // Cursor fill: the configured/OSC-12 cursor color if set (so OSC 12
        // both answers queries and renders), else the cell's foreground.
        var cur_fg = eff_fg;
        if (screen.pages.getCell(.{ .viewport = .{ .x = @intCast(cx), .y = @intCast(cy) } })) |gc| {
            cur_fg = gc.style().fg(.{ .default = eff_fg, .palette = palette, .bold = bold_opt });
        }
        const fill = if (term.colors.cursor.get()) |c| rgbf(c) else rgbf(cur_fg);

        try rcursor.shapeQuads(quads, alloc, cs, .{
            .px = ccx,
            .py = ccy,
            .cell_w = cell_w,
            .cell_h = cell_h,
            .thickness = cursor_render.thickness,
        }, fill, cursor_render.opacity);

        // A solid block hides the glyph beneath it; re-draw it in the cursor
        // text color (default: the cell's background, so the cell inverts).
        if (ft) {
            if (cs == .block) {
                if (screen.pages.getCell(.{ .viewport = .{ .x = @intCast(cx), .y = @intCast(cy) } })) |gc| {
                    const cp = gc.cell.codepoint();
                    const cs_style = gc.style();
                    if (cp >= first_drawable) {
                        if (cache.get(cp, cs_style.flags.bold, cs_style.flags.italic)) |gi| {
                            const cur_bg = if (cs_style.bg(gc.cell, palette)) |c| c else eff_bg;
                            const text_color = cursor_render.text orelse rgbf(cur_bg);
                            const gcell: gl.Cell = .{
                                .px = ccx + gi.bearing_x,
                                .py = ccy + ascent_i - gi.bearing_y,
                                .sx = gi.region.x,
                                .sy = gi.region.y,
                                .sw = gi.region.width,
                                .sh = gi.region.height,
                                .r = text_color[0],
                                .g = text_color[1],
                                .b = text_color[2],
                            };
                            // A color glyph (emoji) under a block cursor shows
                            // through untinted; a normal glyph uses the cursor
                            // text color.
                            try quads.append(alloc, if (gi.color) .{ .color_glyph = gcell } else .{ .glyph = gcell });
                        }
                    }
                }
            }
        }
    }
}
