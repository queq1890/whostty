//! whostty engine: grid/cell geometry — the pure terminal-grid model.
//!
//! Reference: ghostty `src/Surface.zig` layout/cell math (strategy: port). This
//! is the platform-free half of the surface, split out of `src/Surface.zig`
//! (#129) so the grid/cell/layout logic compiles and unit-tests with ZERO
//! Windows / ConPTY / WGL dependency — whomux drives it from its own host layer
//! (epic E0, #141). The platform-bound `Surface` (pty + terminal IO + renderer
//! wiring) stays in `src/Surface.zig` and re-exports these types for the apprt.
//!
//! Everything here is a pure function of pixel sizes and cell metrics, so it is
//! fully host-testable. See PORTING.md.
const std = @import("std");

pub const GridSize = struct { cols: u16, rows: u16 };

/// A viewport cell coordinate (row 0 = top visible row).
pub const Cell = struct { x: u16 = 0, y: u16 = 0 };

/// Blank padding around the grid, in pixels, applied on each side. `balance`
/// distributes the pixels left over from a non-even cell division into the
/// padding so the grid is centered (#71). Defaults to none.
pub const Padding = struct { x: u16 = 0, y: u16 = 0, balance: bool = false };

/// The computed grid layout: its size in cells and the top-left pixel of cell
/// (0,0). The renderer offsets every cell by `origin_*`; the padding region
/// (outside the grid) shows the background via the framebuffer clear color.
pub const Layout = struct { cols: u16, rows: u16, origin_x: u32, origin_y: u32 };

/// Lay the grid out inside a client area: reserve `pad` on each side, fit as
/// many whole cells as the remaining area holds (always at least 1x1), and
/// place the grid origin. Without `balance` the origin is exactly the padding
/// and any sub-cell remainder sits on the right/bottom edge; with `balance` the
/// remainder is split so the grid is centered. Pure; host-testable.
pub fn layout(px_w: u32, px_h: u32, cell_w: u32, cell_h: u32, pad: Padding) Layout {
    const cw = @max(cell_w, 1);
    const ch = @max(cell_h, 1);
    // Saturating so a window narrower than the padding degrades to a 1-cell
    // grid instead of underflowing; the padding shrinks before the grid does.
    const avail_w = px_w -| 2 * @as(u32, pad.x);
    const avail_h = px_h -| 2 * @as(u32, pad.y);
    const cols: u32 = @max(1, avail_w / cw);
    const rows: u32 = @max(1, avail_h / ch);
    var ox: u32 = pad.x;
    var oy: u32 = pad.y;
    if (pad.balance) {
        ox += (avail_w -| cols * cw) / 2;
        oy += (avail_h -| rows * ch) / 2;
    }
    return .{ .cols = @intCast(cols), .rows = @intCast(rows), .origin_x = ox, .origin_y = oy };
}

/// Client pixel -> viewport cell, clamped to the grid. `origin_*` is the grid's
/// top-left pixel (the padding offset); pixels left of/above it map to the first
/// cell. The viewport tag means scrollback offset is resolved by libghostty-vt
/// when the cell is pinned, so no manual scroll arithmetic is needed here.
/// Pure; host-testable.
pub fn cellFromPixels(px_x: i32, px_y: i32, cell_w: u32, cell_h: u32, cols: u16, rows: u16, origin_x: u32, origin_y: u32) Cell {
    const lx = px_x - @as(i32, @intCast(origin_x));
    const ly = px_y - @as(i32, @intCast(origin_y));
    const x: u32 = if (lx < 0) 0 else @as(u32, @intCast(lx)) / @max(cell_w, 1);
    const y: u32 = if (ly < 0) 0 else @as(u32, @intCast(ly)) / @max(cell_h, 1);
    return .{
        .x = @intCast(@min(x, @as(u32, @max(cols, 1)) - 1)),
        .y = @intCast(@min(y, @as(u32, @max(rows, 1)) - 1)),
    };
}

/// Derive the terminal grid (cols x rows) from a client pixel size and the
/// monospace cell size, with no padding. Always at least 1x1. Pure;
/// host-testable. (Thin wrapper over `layout` for callers that don't pad.)
pub fn gridFromPixels(px_w: u32, px_h: u32, cell_w: u32, cell_h: u32) GridSize {
    const l = layout(px_w, px_h, cell_w, cell_h, .{});
    return .{ .cols = l.cols, .rows = l.rows };
}

test "grid: gridFromPixels divides and floors" {
    const g = gridFromPixels(800, 600, 8, 16);
    try std.testing.expectEqual(@as(u16, 100), g.cols);
    try std.testing.expectEqual(@as(u16, 37), g.rows); // 600/16 = 37.5 -> 37
}

test "grid: gridFromPixels clamps to at least 1x1" {
    const g = gridFromPixels(0, 0, 8, 16);
    try std.testing.expectEqual(@as(u16, 1), g.cols);
    try std.testing.expectEqual(@as(u16, 1), g.rows);
}

test "grid: gridFromPixels guards against zero cell size" {
    const g = gridFromPixels(80, 40, 0, 0);
    try std.testing.expect(g.cols >= 1 and g.rows >= 1);
}

test "grid: cellFromPixels maps, floors, and clamps" {
    // 8x16 cells in a 100x37 grid, no padding (origin 0,0).
    try std.testing.expectEqual(Cell{ .x = 0, .y = 0 }, cellFromPixels(3, 5, 8, 16, 100, 37, 0, 0));
    try std.testing.expectEqual(Cell{ .x = 1, .y = 1 }, cellFromPixels(8, 16, 8, 16, 100, 37, 0, 0));
    // Negative pixels clamp to the first cell.
    try std.testing.expectEqual(Cell{ .x = 0, .y = 0 }, cellFromPixels(-5, -9, 8, 16, 100, 37, 0, 0));
    // Beyond the grid clamps to the last cell.
    try std.testing.expectEqual(Cell{ .x = 99, .y = 36 }, cellFromPixels(100000, 100000, 8, 16, 100, 37, 0, 0));
}

test "grid: cellFromPixels subtracts the padding origin" {
    // 8x16 cells, grid origin at (10, 6) from padding.
    // A click inside the padding (left of/above the origin) maps to cell (0,0).
    try std.testing.expectEqual(Cell{ .x = 0, .y = 0 }, cellFromPixels(4, 2, 8, 16, 100, 37, 10, 6));
    // The grid origin itself is cell (0,0).
    try std.testing.expectEqual(Cell{ .x = 0, .y = 0 }, cellFromPixels(10, 6, 8, 16, 100, 37, 10, 6));
    // One cell in from the origin is cell (1,1).
    try std.testing.expectEqual(Cell{ .x = 1, .y = 1 }, cellFromPixels(10 + 8, 6 + 16, 8, 16, 100, 37, 10, 6));
}

test "grid: layout with no padding matches a plain division" {
    const l = layout(800, 600, 8, 16, .{});
    try std.testing.expectEqual(@as(u16, 100), l.cols);
    try std.testing.expectEqual(@as(u16, 37), l.rows); // 600/16 = 37.5 -> 37
    try std.testing.expectEqual(@as(u32, 0), l.origin_x);
    try std.testing.expectEqual(@as(u32, 0), l.origin_y);
}

test "grid: layout reserves padding on each side and offsets the origin" {
    // 10px x-padding, 8px y-padding: 780x584 usable -> 97 cols, 36 rows.
    const l = layout(800, 600, 8, 16, .{ .x = 10, .y = 8 });
    try std.testing.expectEqual(@as(u16, 97), l.cols); // 780/8 = 97.5 -> 97
    try std.testing.expectEqual(@as(u16, 36), l.rows); // 584/16 = 36.5 -> 36
    // Without balance the origin is exactly the padding.
    try std.testing.expectEqual(@as(u32, 10), l.origin_x);
    try std.testing.expectEqual(@as(u32, 8), l.origin_y);
}

test "grid: layout balance centers the grid by splitting the remainder" {
    // Same area; with balance the sub-cell remainder is split into the padding.
    // usable_w = 780, 97 cols * 8 = 776, remainder 4 -> +2 each side: origin_x = 12.
    // usable_h = 584, 36 rows * 16 = 576, remainder 8 -> +4 each side: origin_y = 12.
    const l = layout(800, 600, 8, 16, .{ .x = 10, .y = 8, .balance = true });
    try std.testing.expectEqual(@as(u16, 97), l.cols);
    try std.testing.expectEqual(@as(u16, 36), l.rows);
    try std.testing.expectEqual(@as(u32, 12), l.origin_x);
    try std.testing.expectEqual(@as(u32, 12), l.origin_y);
}

test "grid: layout degrades gracefully when padding exceeds the window" {
    // Padding wider than the window: saturating math keeps a 1x1 grid, no panic.
    const l = layout(10, 10, 8, 16, .{ .x = 100, .y = 100, .balance = true });
    try std.testing.expectEqual(@as(u16, 1), l.cols);
    try std.testing.expectEqual(@as(u16, 1), l.rows);
}
