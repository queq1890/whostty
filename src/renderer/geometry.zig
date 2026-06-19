//! whostty: backend-neutral renderer geometry.
//!
//! Reference: ghostty `src/renderer/` cell geometry (strategy: port). The quad
//! and vertex types plus the pixel-rect → NDC / atlas-uv math are independent
//! of any GPU API, so they live here and are shared by the renderer backends
//! (OpenGL today; Direct3D is the long-term native target, #15). Keeping the
//! geometry backend-neutral is the seam the renderer abstraction is built on.
//! Pure + host-testable. See PORTING.md.
const std = @import("std");

/// A drawable glyph: a glyph region in the atlas placed at a pixel position,
/// tinted by a foreground color.
pub const Cell = struct {
    /// Top-left pixel position of the glyph bitmap in the window.
    px: i32,
    py: i32,
    /// Source region in the atlas (texels).
    sx: u32,
    sy: u32,
    sw: u32,
    sh: u32,
    /// Foreground color (0..1).
    r: f32 = 1,
    g: f32 = 1,
    b: f32 = 1,
};

/// A solid filled rectangle in window pixels, tinted by a color. Used for SGR
/// background fills and the underline / strikethrough / overline decorations.
pub const SolidRect = struct {
    px: i32,
    py: i32,
    w: u32,
    h: u32,
    /// Fill color (0..1).
    r: f32,
    g: f32,
    b: f32,
};

/// A single drawable primitive. Quads are drawn in slice order, so callers
/// control layering: emit a cell's background solid before its glyph, and any
/// decoration solids after it.
pub const Quad = union(enum) {
    glyph: Cell,
    solid: SolidRect,
};

/// Per-vertex draw mode discriminator (consumed by the backend's shader): 0 =
/// sample the atlas coverage (glyph), 1 = solid fill.
pub const mode_glyph: f32 = 0;
pub const mode_solid: f32 = 1;

/// Interleaved vertex: position (NDC) + atlas uv + color + draw mode. The
/// layout is shared by all backends.
pub const Vertex = extern struct {
    x: f32,
    y: f32,
    u: f32,
    v: f32,
    r: f32,
    g: f32,
    b: f32,
    m: f32,
};

/// Pixel rect -> NDC. y is flipped (pixel y grows down, NDC y grows up).
/// Returns the four NDC corners as (x0, x1, y0, y1).
fn ndcRect(px: i32, py: i32, w: u32, h: u32, screen_w: u32, screen_h: u32) struct {
    x0: f32,
    x1: f32,
    y0: f32,
    y1: f32,
} {
    const sw: f32 = @floatFromInt(screen_w);
    const sh: f32 = @floatFromInt(screen_h);
    const x0f: f32 = @floatFromInt(px);
    const y0f: f32 = @floatFromInt(py);
    const x1f: f32 = @floatFromInt(px + @as(i32, @intCast(w)));
    const y1f: f32 = @floatFromInt(py + @as(i32, @intCast(h)));
    return .{
        .x0 = (x0f / sw) * 2.0 - 1.0,
        .x1 = (x1f / sw) * 2.0 - 1.0,
        .y0 = 1.0 - (y0f / sh) * 2.0,
        .y1 = 1.0 - (y1f / sh) * 2.0,
    };
}

/// Append the 6 vertices (two triangles) for one glyph cell into `out`. Pure
/// geometry: pixel rect -> NDC, atlas rect -> uv. Host-testable.
pub fn pushQuad(
    out: *std.ArrayList(Vertex),
    alloc: std.mem.Allocator,
    cell: Cell,
    screen_w: u32,
    screen_h: u32,
    atlas_size: u32,
) !void {
    const as: f32 = @floatFromInt(atlas_size);
    const n = ndcRect(cell.px, cell.py, cell.sw, cell.sh, screen_w, screen_h);

    const su0: f32 = @as(f32, @floatFromInt(cell.sx)) / as;
    const su1: f32 = @as(f32, @floatFromInt(cell.sx + cell.sw)) / as;
    const sv0: f32 = @as(f32, @floatFromInt(cell.sy)) / as;
    const sv1: f32 = @as(f32, @floatFromInt(cell.sy + cell.sh)) / as;

    const tl: Vertex = .{ .x = n.x0, .y = n.y0, .u = su0, .v = sv0, .r = cell.r, .g = cell.g, .b = cell.b, .m = mode_glyph };
    const tr: Vertex = .{ .x = n.x1, .y = n.y0, .u = su1, .v = sv0, .r = cell.r, .g = cell.g, .b = cell.b, .m = mode_glyph };
    const bl: Vertex = .{ .x = n.x0, .y = n.y1, .u = su0, .v = sv1, .r = cell.r, .g = cell.g, .b = cell.b, .m = mode_glyph };
    const br: Vertex = .{ .x = n.x1, .y = n.y1, .u = su1, .v = sv1, .r = cell.r, .g = cell.g, .b = cell.b, .m = mode_glyph };

    try out.appendSlice(alloc, &.{ tl, bl, br, tl, br, tr });
}

/// Append the 6 vertices for one solid filled rect into `out`. uv is unused
/// (the backend ignores the atlas in solid mode). Host-testable.
pub fn pushSolid(
    out: *std.ArrayList(Vertex),
    alloc: std.mem.Allocator,
    rect: SolidRect,
    screen_w: u32,
    screen_h: u32,
) !void {
    const n = ndcRect(rect.px, rect.py, rect.w, rect.h, screen_w, screen_h);
    const tl: Vertex = .{ .x = n.x0, .y = n.y0, .u = 0, .v = 0, .r = rect.r, .g = rect.g, .b = rect.b, .m = mode_solid };
    const tr: Vertex = .{ .x = n.x1, .y = n.y0, .u = 0, .v = 0, .r = rect.r, .g = rect.g, .b = rect.b, .m = mode_solid };
    const bl: Vertex = .{ .x = n.x0, .y = n.y1, .u = 0, .v = 0, .r = rect.r, .g = rect.g, .b = rect.b, .m = mode_solid };
    const br: Vertex = .{ .x = n.x1, .y = n.y1, .u = 0, .v = 0, .r = rect.r, .g = rect.g, .b = rect.b, .m = mode_solid };
    try out.appendSlice(alloc, &.{ tl, bl, br, tl, br, tr });
}

/// Build the full vertex buffer for a frame from an ordered quad list. Shared
/// by every backend; the backend only uploads `out` and issues the draw.
pub fn build(
    out: *std.ArrayList(Vertex),
    alloc: std.mem.Allocator,
    quads: []const Quad,
    screen_w: u32,
    screen_h: u32,
    atlas_size: u32,
) !void {
    out.clearRetainingCapacity();
    for (quads) |q| switch (q) {
        .glyph => |cell| try pushQuad(out, alloc, cell, screen_w, screen_h, atlas_size),
        .solid => |rect| try pushSolid(out, alloc, rect, screen_w, screen_h),
    };
}

test "geometry: pushQuad maps pixel rect to NDC and emits 6 verts" {
    const alloc = std.testing.allocator;
    var verts: std.ArrayList(Vertex) = .empty;
    defer verts.deinit(alloc);

    // A 10x10 glyph at top-left of a 100x100 window, atlas 100.
    try pushQuad(&verts, alloc, .{ .px = 0, .py = 0, .sx = 0, .sy = 0, .sw = 10, .sh = 10 }, 100, 100, 100);
    try std.testing.expectEqual(@as(usize, 6), verts.items.len);

    // Top-left pixel (0,0) -> NDC (-1, +1).
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), verts.items[0].x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), verts.items[0].y, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), verts.items[0].u, 0.0001);
}

test "geometry: center pixel maps near NDC origin" {
    const alloc = std.testing.allocator;
    var verts: std.ArrayList(Vertex) = .empty;
    defer verts.deinit(alloc);
    try pushQuad(&verts, alloc, .{ .px = 50, .py = 50, .sx = 0, .sy = 0, .sw = 0, .sh = 0 }, 100, 100, 100);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), verts.items[0].x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), verts.items[0].y, 0.0001);
}

test "geometry: glyph quads carry the glyph mode" {
    const alloc = std.testing.allocator;
    var verts: std.ArrayList(Vertex) = .empty;
    defer verts.deinit(alloc);
    try pushQuad(&verts, alloc, .{ .px = 0, .py = 0, .sx = 0, .sy = 0, .sw = 4, .sh = 4 }, 100, 100, 100);
    for (verts.items) |v| try std.testing.expectEqual(mode_glyph, v.m);
}

test "geometry: pushSolid maps full cell rect, solid mode, zero uv" {
    const alloc = std.testing.allocator;
    var verts: std.ArrayList(Vertex) = .empty;
    defer verts.deinit(alloc);

    try pushSolid(&verts, alloc, .{ .px = 0, .py = 0, .w = 10, .h = 10, .r = 1, .g = 0, .b = 0 }, 100, 100);
    try std.testing.expectEqual(@as(usize, 6), verts.items.len);

    for (verts.items) |v| {
        try std.testing.expectEqual(mode_solid, v.m);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), v.u, 0.0001);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), v.v, 0.0001);
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), v.r, 0.0001);
    }
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), verts.items[0].x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), verts.items[0].y, 0.0001);
}

test "geometry: build emits background solid before glyph in order" {
    const alloc = std.testing.allocator;
    var verts: std.ArrayList(Vertex) = .empty;
    defer verts.deinit(alloc);

    const quads = [_]Quad{
        .{ .solid = .{ .px = 0, .py = 0, .w = 8, .h = 16, .r = 0, .g = 0, .b = 1 } },
        .{ .glyph = .{ .px = 0, .py = 0, .sx = 0, .sy = 0, .sw = 8, .sh = 16, .r = 1, .g = 1, .b = 1 } },
    };
    try build(&verts, alloc, &quads, 800, 600, 512);

    // 2 quads -> 12 verts; the first 6 are the solid (mode 1), then the glyph.
    try std.testing.expectEqual(@as(usize, 12), verts.items.len);
    try std.testing.expectEqual(mode_solid, verts.items[0].m);
    try std.testing.expectEqual(mode_glyph, verts.items[6].m);
}
