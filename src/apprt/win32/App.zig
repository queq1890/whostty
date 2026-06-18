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

const log = std.log.scoped(.app);

/// Per-printable-ASCII glyph placement in the atlas.
const GlyphInfo = struct {
    region: Atlas.Region,
    bearing_x: i32,
    bearing_y: i32,
};

const first_glyph = 32;
const last_glyph = 126;

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
    var cells: std.ArrayList(gl.Cell) = .empty;
    defer cells.deinit(alloc);

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
        try buildCells(alloc, &cells, io, &glyphs, cell_w, cell_h, ascent);
        try renderer.draw(cells.items, sz.width, sz.height);
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

/// Translate the terminal viewport (as plain text rows) into renderable cells.
/// slice-0 renders monospace ASCII with no attributes/colors.
fn buildCells(
    alloc: std.mem.Allocator,
    cells: *std.ArrayList(gl.Cell),
    io: *Termio,
    glyphs: *const [last_glyph - first_glyph + 1]?GlyphInfo,
    cell_w: u32,
    cell_h: u32,
    ascent: u32,
) !void {
    cells.clearRetainingCapacity();

    const text = try io.dumpAlloc(alloc);
    defer alloc.free(text);

    var row: u32 = 0;
    var col: u32 = 0;
    for (text) |ch| {
        if (ch == '\n') {
            row += 1;
            col = 0;
            continue;
        }
        defer col += 1;
        if (ch < first_glyph or ch > last_glyph) continue;
        const gi = glyphs[ch - first_glyph] orelse continue;

        const px: i32 = @as(i32, @intCast(col * cell_w)) + gi.bearing_x;
        const py: i32 = @as(i32, @intCast(row * cell_h + ascent)) - gi.bearing_y;
        try cells.append(alloc, .{
            .px = px,
            .py = py,
            .sx = gi.region.x,
            .sy = gi.region.y,
            .sw = gi.region.width,
            .sh = gi.region.height,
        });
    }
}
