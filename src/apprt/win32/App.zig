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
const Termio = @import("../../termio.zig").Termio;
const Window = @import("Window.zig").Window;
const gl = @import("../../renderer/OpenGL.zig");
const rcursor = @import("../../renderer/cursor.zig");
const rcolor = @import("../../renderer/color.zig");
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

const log = std.log.scoped(.app);

/// Lowest codepoint we attempt to draw. Below this are the empty-cell sentinel
/// (0), control chars, and space (0x20) — all of which draw nothing — so we skip
/// the cache lookup for them.
const first_drawable: u21 = 0x21;

/// The default monospace font on Windows. font-family selection via DirectWrite
/// discovery is #74; the configured size applies now.
const default_font_path = "C:\\Windows\\Fonts\\consola.ttf";

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
/// defaults if it is missing or unreadable. font-family discovery is deferred
/// to #14, so only size/colors take effect today.
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

/// The full slice-0 terminal. Run on the main thread.
pub fn run(alloc: std.mem.Allocator, opts: cli.Options) !void {
    // --- Window + GL context (UI thread) ---
    const win = try alloc.create(Window);
    defer alloc.destroy(win);
    try win.init("whostty", 960, 540);
    defer win.deinit();
    win.makeCurrent();

    var renderer = try gl.Renderer.init(alloc, w.wglGetProcAddress);
    defer renderer.deinit();

    // --- Config (colors, font size, palette overrides) ---
    var cfg = loadConfig(alloc, opts.config_text);
    defer cfg.deinit();
    const theme: Theme = .fromConfig(&cfg);

    // Direct3D (#15) is selectable in config but not implemented yet; OpenGL is
    // the only backend, so warn and fall back rather than failing to start.
    if (cfg.renderer == .direct3d) {
        log.warn("renderer = direct3d is not implemented yet; using OpenGL", .{});
    }

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
    var cache: GlyphCache = if (ft)
        try GlyphCache.init(alloc, default_font_path, @intFromFloat(@max(1, @round(cfg.font_size))), atlas_size)
    else {};
    defer if (ft) cache.deinit();

    var cell_w: u32 = 8;
    var cell_h: u32 = 16;
    var ascent: u32 = 12;
    if (ft) {
        cell_w = cache.cell_w;
        cell_h = cache.cell_h;
        ascent = cache.ascent;
        // Upload the (empty) atlas once so the glyph texture + its sampling
        // params are configured before the first draw; new glyphs re-upload.
        renderer.setAtlas(cache.atlas.data, cache.atlas.size);
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

    // --- ConPTY + shell ---
    var pty = try Pty.open(.{ .ws_col = grid0.cols, .ws_row = grid0.rows });
    var child = try pty.spawn(alloc, opts.command orelse shellCommandLine());
    const io = try Termio.create(alloc, grid0.cols, grid0.rows, cfg.scrollback_limit);
    // Prime the terminal's dynamic colors with the configured defaults so OSC
    // 10/11/12/4 changes and queries resolve against `terminal.colors` (#83).
    io.seedColors(theme.fg, theme.bg, if (cfg.cursor_color) |c| toVtRgb(c) else null, &theme.palette);

    // --- Reader thread: pty -> libghostty-vt ---
    var stop = std.atomic.Value(bool).init(false);
    const reader = try std.Thread.spawn(.{}, readerLoop, .{ &pty, io, &stop });

    // Cleanup order: stop the shell so the reader's blocking read returns,
    // join it, then tear down the pty/io.
    defer {
        stop.store(true, .monotonic);
        child.kill();
        reader.join();
        io.destroy();
        child.deinit();
        pty.deinit();
    }

    var sfc: surface.Surface = .{
        .pty = &pty,
        .termio = io,
        .cell_w = cell_w,
        .cell_h = cell_h,
        .cols = grid0.cols,
        .rows = grid0.rows,
        .pad = pad,
        .origin_x = layout0.origin_x,
        .origin_y = layout0.origin_y,
    };

    // --- Main loop ---
    var quads: std.ArrayList(gl.Quad) = .empty;
    defer quads.deinit(alloc);
    var wheel: scroll.WheelAccumulator = .{};

    // One-shot render self-verification (WHOSTTY_RENDER_DEBUG=1) — counts lit
    // pixels a few frames in so a build that can't be screenshotted can confirm
    // glyphs reached the framebuffer. See Renderer.debugCountLitPixels.
    var frame: u32 = 0;
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

    // --- Cursor render state ---
    // A freshly shown, foreground window has keyboard focus until told otherwise
    // (WM_KILLFOCUS). Drives the hollow-when-unfocused cursor.
    var focused = true;
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

    while (win.pump()) {
        var closed = false;
        while (win.poll()) |ev| switch (ev) {
            // Typing snaps back to the bottom, matching common terminals.
            .char => |cp| {
                // Drop the WM_CHAR that trails a handled Enter/Tab/Backspace/
                // Escape WM_KEYDOWN (flagged below) so the key isn't sent twice.
                if (suppress_next_char) {
                    suppress_next_char = false;
                    continue;
                }
                if (blink_timer) |*t| t.reset();
                io.scrollToBottom();
                writeChar(&pty, cp);
            },
            .key => |k| {
                // These keys are VT-encoded here and ALSO post a WM_CHAR; mark the
                // trailing WM_CHAR for suppression whether the key is sent to the
                // shell or consumed as a keybind. Other keys clear the flag.
                suppress_next_char = switch (k.vk) {
                    input.vk.back, input.vk.tab, input.vk.enter, input.vk.escape => true,
                    else => false,
                };
                if (blink_timer) |*t| t.reset();

                // A bound chord is consumed as an action; otherwise it's a
                // normal key written to the shell.
                const ctx: KeybindCtx = .{
                    .binds = &binds,
                    .io = io,
                    .rows = sfc.rows,
                    .alloc = alloc,
                    .win = win,
                    .pty = &pty,
                };
                if (handleKeybind(k, ctx)) continue;
                io.scrollToBottom();
                writeKey(&pty, k.vk, input.mods(k.mods.shift, k.mods.ctrl, k.mods.alt), io.keyEncodeOptions());
            },
            .scroll => |raw| {
                const delta = wheel.feed(raw);
                if (delta != 0) io.scrollViewport(delta);
            },
            .mouse_button => |m| {
                const btn: mouse.Button = switch (m.button) {
                    .left => .left,
                    .middle => .middle,
                    .right => .right,
                };
                sfc.mouseButton(btn, if (m.down) .press else .release, m.x, m.y, .{
                    .shift = m.mods.shift,
                    .alt = m.mods.alt,
                    .ctrl = m.mods.ctrl,
                });
            },
            .mouse_move => |m| sfc.mouseDrag(m.x, m.y),
            .mouse_capture_lost => sfc.endDrag(),
            .resize => |r| sfc.resizePixels(r.width, r.height) catch {},
            .focus => |f| {
                // Only act on a real change so a redundant WM_SETFOCUS/KILLFOCUS
                // can't emit a duplicate report.
                if (focused != f) {
                    focused = f;
                    // Report the change to apps that asked for it (mode 1004).
                    if (io.focusReport(f)) |r| _ = pty.write(r) catch {};
                }
            },
            .close => closed = true,
        };
        if (closed) break;

        // Drain VT replies the terminal owes the pty (DSR/DA/DECRQM), generated
        // on the reader thread as it parses queries. Writing them here keeps
        // every pty write on this thread, so responses never interleave with
        // keyboard input mid-sequence. The loop handles a reply set larger than
        // the buffer; in practice each is well under 256 bytes.
        var resp_buf: [256]u8 = undefined;
        while (true) {
            const n = io.takeResponse(&resp_buf);
            if (n == 0) break;
            _ = pty.write(resp_buf[0..n]) catch {};
        }

        // Drain a pending OSC 52 clipboard write (decoded on the reader thread)
        // to the system clipboard, which is a UI-thread operation.
        if (io.takeClipboardWrite()) |text| {
            defer alloc.free(text);
            w.clipboardWrite(alloc, win.handle(), text) catch {};
        }

        // Out-of-band terminal events (BEL / OSC 9 / 777). A bell flashes the
        // window (visual bell); a desktop notification is logged for now — the
        // Windows toast / tray surfacing is host-only work (#43). Both are
        // captured on the reader thread and acted on here, on the UI thread.
        if (io.takeBellCount() > 0) w.flashWindow(win.handle());
        if (io.takeNotification()) |note| {
            var n = note;
            defer n.deinit(alloc);
            log.info("desktop notification: {s}: {s}", .{ n.title, n.body });
        }

        const sz = win.clientSize();
        const blink_visible = blk: {
            if (blink_timer) |*t| break :blk (t.read() / blink_interval_ns) % 2 == 0;
            break :blk true;
        };
        const cursor_render: CursorRender = .{
            .focused = focused,
            .blink_visible = blink_visible,
            .text = cursor_text,
            .opacity = cfg.cursor_opacity,
            .thickness = cursor_thickness,
        };
        try buildQuads(alloc, &quads, io, if (ft) &cache else {}, cell_w, cell_h, ascent, sfc.origin_x, sfc.origin_y, &theme, cursor_render);
        // buildQuads may have packed new glyphs into the atlas; re-upload before
        // drawing so the texture has them.
        if (ft and cache.takeDirty()) renderer.setAtlas(cache.atlas.data, cache.atlas.size);

        // Scrollbar (#73): an overlay thumb on the right edge marking the
        // viewport's position within the scrollback. Appended after the grid so
        // it draws on top; shown only when there is history to scroll. The thumb
        // geometry comes from the VT core's authoritative row counts.
        appendScrollbar(alloc, &quads, io.scrollbar(), sz.width, sz.height, cell_w, theme.fg) catch {};
        // Default-background cells show through the clear color, so it must track
        // the OSC 11 background override (falling back to the configured bg).
        const clear_bg = rgbf(io.backgroundColor(theme.bg));
        try renderer.draw(quads.items, clear_bg, sz.width, sz.height);

        frame += 1;
        if (render_debug and frame == 10) renderer.debugCountLitPixels(clear_bg, sz.width, sz.height);

        win.swapBuffers();
    }
}

/// The shell to launch. Honors COMSPEC, defaulting to cmd.exe.
fn shellCommandLine() []const u8 {
    return "cmd.exe";
}

fn readerLoop(pty: *Pty, io: *Termio, stop: *std.atomic.Value(bool)) void {
    var buf: [4096]u8 = undefined;
    while (!stop.load(.monotonic)) {
        const n = pty.read(&buf) catch break;
        io.process(buf[0..n]) catch {};
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

/// Context a keybind action needs: the binding set, the terminal io, and the
/// window/pty/allocator that clipboard actions reach into.
const KeybindCtx = struct {
    binds: *const binding.Set,
    io: *Termio,
    rows: u16,
    alloc: std.mem.Allocator,
    win: *Window,
    pty: *Pty,
};

/// Look up a key event in the binding set and run the bound action. Returns true
/// if a binding matched and was handled (so the key is not also sent to the pty).
fn handleKeybind(k: anytype, ctx: KeybindCtx) bool {
    const key = keymap.keyFromVk(k.vk) orelse return false;
    const trigger: binding.Trigger = .{ .key = key, .mods = .{
        .ctrl = k.mods.ctrl,
        .shift = k.mods.shift,
        .alt = k.mods.alt,
        .super = k.mods.super,
    } };
    const action = ctx.binds.get(trigger) orelse return false;
    dispatchAction(action, ctx);
    return true;
}

/// Run a bound action. Scrollback + clipboard actions act on the single current
/// surface; split/tab actions are recognized but need multi-surface support
/// (#18) before they can do anything, so they're logged for now.
fn dispatchAction(action: binding.Action, ctx: KeybindCtx) void {
    switch (action) {
        .scroll_page_up => ctx.io.scrollViewport(-@as(isize, @intCast(scroll.pageRows(ctx.rows)))),
        .scroll_page_down => ctx.io.scrollViewport(@as(isize, @intCast(scroll.pageRows(ctx.rows)))),
        .scroll_to_bottom => ctx.io.scrollToBottom(),
        .scroll_to_top => ctx.io.scrollViewport(-1_000_000), // clamps at the top of history
        .copy_to_clipboard => copyToClipboard(ctx),
        .paste_from_clipboard => pasteFromClipboard(ctx),
        .new_split, .goto_split, .new_tab, .close_surface, .next_tab, .previous_tab, .goto_tab => {
            log.debug("keybind action '{s}' needs multi-surface support (not yet wired)", .{@tagName(std.meta.activeTag(action))});
        },
    }
}

/// Paste the system clipboard into the shell. Reads CF_UNICODETEXT, encodes via
/// libghostty-vt's paste encoder (strips unsafe bytes, applies bracketed-paste
/// fenceposts when mode 2004 is on), and writes the result to the pty.
fn pasteFromClipboard(ctx: KeybindCtx) void {
    const text = (w.clipboardRead(ctx.alloc, ctx.win.handle()) catch return) orelse return;
    defer ctx.alloc.free(text);
    if (text.len == 0) return;

    const bracketed = blk: {
        ctx.io.lock();
        defer ctx.io.unlock();
        break :blk ctx.io.terminal.modes.get(.bracketed_paste);
    };

    ctx.io.scrollToBottom();

    // encodePaste mutates the buffer in place (control-byte stripping / \n->\r),
    // so pass a mutable copy to use the infallible []u8 overload.
    const buf = ctx.alloc.dupe(u8, text) catch return;
    defer ctx.alloc.free(buf);
    const parts = vt.input.encodePaste(buf, .{ .bracketed = bracketed });
    for (parts) |part| {
        if (part.len > 0) _ = ctx.pty.write(part) catch {};
    }
}

/// Copy the current selection to the system clipboard. A no-op when there is no
/// selection (selection is set by mouse-drag, #51).
fn copyToClipboard(ctx: KeybindCtx) void {
    const text = blk: {
        ctx.io.lock();
        defer ctx.io.unlock();
        const screen = ctx.io.terminal.screens.active; // *Screen
        const sel = screen.selection orelse break :blk null;
        break :blk screen.selectionString(ctx.alloc, .{ .sel = sel, .trim = true }) catch null;
    } orelse return;
    defer ctx.alloc.free(text);
    if (text.len == 0) return;
    w.clipboardWrite(ctx.alloc, ctx.win.handle(), text) catch |e| log.warn("clipboard write failed: {}", .{e});
}

/// Append the scrollbar overlay (#73): a faint full-height track and a brighter,
/// grabbable thumb on the right edge, sized and positioned from the VT viewport's
/// scrollback counts (`scroll.scrollbarThumb`). Nothing is appended when the
/// content fits the viewport (no history to scroll). The thumb color is derived
/// from the foreground so it contrasts with any background. Drawn translucent so
/// the cells beneath it remain legible (it overlays the rightmost column).
fn appendScrollbar(
    alloc: std.mem.Allocator,
    quads: *std.ArrayList(gl.Quad),
    sb: Termio.Scrollbar,
    screen_w: u32,
    screen_h: u32,
    cell_w: u32,
    fg: vt.color.RGB,
) !void {
    if (sb.total <= sb.len or screen_h == 0 or screen_w == 0) return;
    const bar_w: u32 = @max(4, cell_w / 3);
    const bar_x: i32 = @intCast(screen_w -| bar_w);
    const thumb = scroll.scrollbarThumb(sb.total, sb.len, sb.offset, @floatFromInt(screen_h));
    const c = rgbf(fg);
    // Faint full-height track.
    try quads.append(alloc, .{ .solid = .{ .px = bar_x, .py = 0, .w = bar_w, .h = screen_h, .r = c[0], .g = c[1], .b = c[2], .a = 0.12 } });
    // The thumb, clamped so it never spills past the track bottom on rounding.
    const off: u32 = @intFromFloat(@round(thumb.offset));
    const size: u32 = @min(@max(1, @as(u32, @intFromFloat(@round(thumb.size)))), screen_h -| off);
    try quads.append(alloc, .{ .solid = .{ .px = bar_x, .py = @intCast(off), .w = bar_w, .h = size, .r = c[0], .g = c[1], .b = c[2], .a = 0.5 } });
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
    quads.clearRetainingCapacity();

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
                        try quads.append(alloc, .{ .glyph = .{
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
                        } });
                    }
                }
            }

            // Decorations, drawn on top. Underlines use the explicit underline
            // color when set; strikethrough/overline use the foreground.
            if (style.flags.underline != .none) {
                const uc = if (style.underline_color != .none)
                    rgbf(resolveColor(style.underline_color, palette, fg_rgb))
                else
                    fg;
                try quads.append(alloc, .{ .solid = .{
                    .px = cell_x,
                    .py = cell_y + ascent_i + 1,
                    .w = cell_w,
                    .h = line_h,
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
                            try quads.append(alloc, .{ .glyph = .{
                                .px = ccx + gi.bearing_x,
                                .py = ccy + ascent_i - gi.bearing_y,
                                .sx = gi.region.x,
                                .sy = gi.region.y,
                                .sw = gi.region.width,
                                .sh = gi.region.height,
                                .r = text_color[0],
                                .g = text_color[1],
                                .b = text_color[2],
                            } });
                        }
                    }
                }
            }
        }
    }
}
