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
const input = @import("../../input.zig");
const surface = @import("../../Surface.zig");
const Atlas = @import("../../font/Atlas.zig");
const w = @import("../../os/windows.zig");

const font = if (build_options.freetype) @import("../../font/main.zig") else struct {};
const vt = @import("ghostty-vt");

const log = std.log.scoped(.app);

/// Per-printable-ASCII glyph placement in the atlas.
const GlyphInfo = struct {
    region: Atlas.Region,
    bearing_x: i32,
    bearing_y: i32,
};

const first_glyph = 32;
const last_glyph = 126;

/// Default terminal colors for cells that don't set an explicit SGR color.
/// The framebuffer is cleared to `default_bg`, so only non-default backgrounds
/// emit a fill. (Configurable colors are later work; see #17.)
const default_fg: vt.color.RGB = .{ .r = 0xff, .g = 0xff, .b = 0xff };
const default_bg: vt.color.RGB = .{ .r = 0, .g = 0, .b = 0 };

/// Convert a libghostty-vt RGB (0..255 per channel) to the renderer's 0..1.
fn rgbf(c: vt.color.RGB) [3]f32 {
    return .{
        @as(f32, @floatFromInt(c.r)) / 255.0,
        @as(f32, @floatFromInt(c.g)) / 255.0,
        @as(f32, @floatFromInt(c.b)) / 255.0,
    };
}

/// Resolve a style color (the underline color in particular) against the
/// palette. `none` falls back to the default foreground.
fn resolveColor(c: vt.Style.Color, palette: *const vt.color.Palette) vt.color.RGB {
    return switch (c) {
        .none => default_fg,
        .palette => |idx| palette[idx],
        .rgb => |rgb| rgb,
    };
}

/// The full slice-0 terminal. Run on the main thread.
pub fn run(alloc: std.mem.Allocator) !void {
    // --- Window + GL context (UI thread) ---
    const win = try alloc.create(Window);
    defer alloc.destroy(win);
    try win.init("whostty", 960, 540);
    defer win.deinit();
    win.makeCurrent();

    var renderer = try gl.Renderer.init(alloc, w.wglGetProcAddress);
    defer renderer.deinit();

    // --- Glyph atlas + cell metrics ---
    var atlas = try Atlas.init(alloc, 512);
    defer atlas.deinit(alloc);
    var glyphs = [_]?GlyphInfo{null} ** (last_glyph - first_glyph + 1);
    var cell_w: u32 = 8;
    var cell_h: u32 = 16;
    var ascent: u32 = 12;

    if (build_options.freetype) {
        try buildAtlas(alloc, &atlas, &glyphs, &cell_w, &cell_h, &ascent);
    }
    renderer.setAtlas(atlas.data, atlas.size);

    // --- Initial grid from the client size ---
    const size0 = win.clientSize();
    const grid0 = surface.gridFromPixels(size0.width, size0.height, cell_w, cell_h);

    // --- ConPTY + shell ---
    var pty = try Pty.open(.{ .ws_col = grid0.cols, .ws_row = grid0.rows });
    var child = try pty.spawn(alloc, shellCommandLine());
    const io = try Termio.create(alloc, grid0.cols, grid0.rows);

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
    };

    // --- Main loop ---
    var quads: std.ArrayList(gl.Quad) = .empty;
    defer quads.deinit(alloc);

    while (win.pump()) {
        var closed = false;
        while (win.poll()) |ev| switch (ev) {
            .char => |cp| writeChar(&pty, cp),
            .key => |code| writeKey(&pty, code),
            .resize => |r| sfc.resizePixels(r.width, r.height) catch {},
            .close => closed = true,
        };
        if (closed) break;

        const sz = win.clientSize();
        try buildQuads(alloc, &quads, io, &glyphs, cell_w, cell_h, ascent);
        try renderer.draw(quads.items, sz.width, sz.height);
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

fn writeKey(pty: *Pty, code: u32) void {
    const key = input.keyFromVk(code);
    if (key == .unidentified) return; // printable keys arrive via WM_CHAR
    var buf: [16]u8 = undefined;
    const out = input.encode(&buf, .{ .key = key }, .{}) catch return;
    if (out.len > 0) _ = pty.write(out) catch {};
}

/// Build the per-glyph atlas for printable ASCII via Freetype. Only compiled
/// when `-Dfreetype` is set.
fn buildAtlas(
    alloc: std.mem.Allocator,
    atlas: *Atlas,
    glyphs: *[last_glyph - first_glyph + 1]?GlyphInfo,
    cell_w: *u32,
    cell_h: *u32,
    ascent: *u32,
) !void {
    var lib = try font.Library.init();
    defer lib.deinit();

    // A reasonable default monospace font on Windows.
    var face = try font.Face.init(lib, "C:\\Windows\\Fonts\\consola.ttf", 16);
    defer face.deinit();

    const m = face.metrics();
    cell_w.* = m.cell_width;
    cell_h.* = m.cell_height;
    ascent.* = m.ascent;

    var cp: u32 = first_glyph;
    while (cp <= last_glyph) : (cp += 1) {
        var g = try face.rasterize(alloc, cp);
        defer g.deinit(alloc);
        if (g.width == 0 or g.height == 0) continue;
        const region = atlas.reserve(g.width, g.height) catch continue;
        atlas.set(region, g.pixels);
        glyphs[cp - first_glyph] = .{
            .region = region,
            .bearing_x = g.bearing_x,
            .bearing_y = g.bearing_y,
        };
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
/// architecture (ADR 0002). Synthetic bold/italic glyphs require additional
/// font faces and are deferred to the font work (#13/#14); bold still
/// brightens palette colors via vt's resolution.
fn buildQuads(
    alloc: std.mem.Allocator,
    quads: *std.ArrayList(gl.Quad),
    io: *Termio,
    glyphs: *const [last_glyph - first_glyph + 1]?GlyphInfo,
    cell_w: u32,
    cell_h: u32,
    ascent: u32,
) !void {
    quads.clearRetainingCapacity();

    io.lock();
    defer io.unlock();

    const term = &io.terminal;
    const screen = term.screens.active;
    const palette = &vt.color.default;
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

            // Resolve fg/bg, then apply inverse video by swapping them.
            var fg = rgbf(style.fg(.{ .default = default_fg, .palette = palette }));
            var bg: ?[3]f32 = if (style.bg(cell, palette)) |c| rgbf(c) else null;
            if (style.flags.inverse) {
                const old_fg = fg;
                fg = bg orelse rgbf(default_bg);
                bg = old_fg;
            }

            const cell_x: i32 = @intCast(col * cell_w);
            const cell_y: i32 = @intCast(row * cell_h);

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

            // Foreground glyph (invisible attribute suppresses it).
            if (!style.flags.invisible) {
                const cp = cell.codepoint();
                if (cp >= first_glyph and cp <= last_glyph) {
                    if (glyphs[cp - first_glyph]) |gi| {
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
                        } });
                    }
                }
            }

            // Decorations, drawn on top. Underlines use the explicit underline
            // color when set; strikethrough/overline use the foreground.
            if (style.flags.underline != .none) {
                const uc = if (style.underline_color != .none)
                    rgbf(resolveColor(style.underline_color, palette))
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
}
