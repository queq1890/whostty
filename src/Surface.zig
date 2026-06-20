//! whostty: a single terminal surface — binds the pty, the terminal IO, and
//! (in #11) the renderer for one window.
//!
//! Reference: ghostty `src/Surface.zig` (strategy: port). slice-0 keeps the
//! surface to what resize needs: deriving the grid size from the client pixel
//! size and propagating it to both the pty (ConPTY) and the terminal grid.
//! See PORTING.md.
const std = @import("std");
const Pty = @import("pty.zig").Pty;
const Termio = @import("termio.zig").Termio;

pub const GridSize = struct { cols: u16, rows: u16 };

/// A viewport cell coordinate (row 0 = top visible row).
pub const Cell = struct { x: u16 = 0, y: u16 = 0 };

/// Client pixel -> viewport cell, clamped to the grid. The viewport tag means
/// scrollback offset is resolved by libghostty-vt when the cell is pinned, so
/// no manual scroll arithmetic is needed here. Pure; host-testable.
pub fn cellFromPixels(px_x: i32, px_y: i32, cell_w: u32, cell_h: u32, cols: u16, rows: u16) Cell {
    const x: u32 = if (px_x < 0) 0 else @as(u32, @intCast(px_x)) / @max(cell_w, 1);
    const y: u32 = if (px_y < 0) 0 else @as(u32, @intCast(px_y)) / @max(cell_h, 1);
    return .{
        .x = @intCast(@min(x, @as(u32, @max(cols, 1)) - 1)),
        .y = @intCast(@min(y, @as(u32, @max(rows, 1)) - 1)),
    };
}

/// Derive the terminal grid (cols x rows) from a client pixel size and the
/// monospace cell size. Always at least 1x1. Pure; host-testable.
pub fn gridFromPixels(px_w: u32, px_h: u32, cell_w: u32, cell_h: u32) GridSize {
    const cw = @max(cell_w, 1);
    const ch = @max(cell_h, 1);
    return .{
        .cols = @intCast(@max(1, px_w / cw)),
        .rows = @intCast(@max(1, px_h / ch)),
    };
}

pub const Surface = struct {
    pty: *Pty,
    termio: *Termio,
    cell_w: u32,
    cell_h: u32,
    cols: u16,
    rows: u16,

    /// Mouse-drag selection state. The selected region itself lives in the
    /// libghostty-vt core (`screen.selection`); the Surface only owns the drag
    /// interaction: whether the left button is down and a *tracked* anchor pin
    /// (stable across scroll/reflow) for the drag origin.
    mouse_left_down: bool = false,
    sel_anchor: ?*Termio.Pin = null,

    /// Handle a window resize (client pixels). Recomputes the grid and, if it
    /// changed, resizes the pseudo console and the terminal grid so reflow
    /// follows the window.
    pub fn resizePixels(self: *Surface, px_w: u32, px_h: u32) !void {
        const g = gridFromPixels(px_w, px_h, self.cell_w, self.cell_h);
        if (g.cols == self.cols and g.rows == self.rows) return;

        self.cols = g.cols;
        self.rows = g.rows;
        try self.pty.setSize(.{ .ws_col = g.cols, .ws_row = g.rows });
        try self.termio.resize(g.cols, g.rows);
    }

    /// Left button pressed: anchor a new selection at the clicked cell.
    pub fn mouseDown(self: *Surface, px_x: i32, px_y: i32) void {
        self.releaseAnchor();
        self.termio.clearSelection();
        const cell = cellFromPixels(px_x, px_y, self.cell_w, self.cell_h, self.cols, self.rows);
        self.sel_anchor = self.termio.pinViewportTracked(cell.x, cell.y);
        self.mouse_left_down = true;
    }

    /// Mouse moved during a left-drag: extend the selection to the current cell.
    pub fn mouseDrag(self: *Surface, px_x: i32, px_y: i32) void {
        if (!self.mouse_left_down) return;
        const anchor = self.sel_anchor orelse return;
        const cell = cellFromPixels(px_x, px_y, self.cell_w, self.cell_h, self.cols, self.rows);
        self.termio.selectTo(anchor, cell.x, cell.y);
    }

    /// Left button released: end the drag (the selection stays set, owning its
    /// own tracked pins, so the anchor can be released).
    pub fn mouseUp(self: *Surface) void {
        self.mouse_left_down = false;
        self.releaseAnchor();
    }

    fn releaseAnchor(self: *Surface) void {
        if (self.sel_anchor) |a| {
            self.termio.untrackPin(a);
            self.sel_anchor = null;
        }
    }

    /// The current selection as UTF-8, or null if nothing is selected. Caller
    /// owns the returned slice.
    pub fn selectionText(self: *Surface, alloc: std.mem.Allocator) !?[:0]const u8 {
        return self.termio.selectionStringAlloc(alloc);
    }
};

test "surface: gridFromPixels divides and floors" {
    const g = gridFromPixels(800, 600, 8, 16);
    try std.testing.expectEqual(@as(u16, 100), g.cols);
    try std.testing.expectEqual(@as(u16, 37), g.rows); // 600/16 = 37.5 -> 37
}

test "surface: gridFromPixels clamps to at least 1x1" {
    const g = gridFromPixels(0, 0, 8, 16);
    try std.testing.expectEqual(@as(u16, 1), g.cols);
    try std.testing.expectEqual(@as(u16, 1), g.rows);
}

test "surface: gridFromPixels guards against zero cell size" {
    const g = gridFromPixels(80, 40, 0, 0);
    try std.testing.expect(g.cols >= 1 and g.rows >= 1);
}

test "surface: cellFromPixels maps, floors, and clamps" {
    // 8x16 cells in a 100x37 grid.
    try std.testing.expectEqual(Cell{ .x = 0, .y = 0 }, cellFromPixels(3, 5, 8, 16, 100, 37));
    try std.testing.expectEqual(Cell{ .x = 1, .y = 1 }, cellFromPixels(8, 16, 8, 16, 100, 37));
    // Negative pixels clamp to the first cell.
    try std.testing.expectEqual(Cell{ .x = 0, .y = 0 }, cellFromPixels(-5, -9, 8, 16, 100, 37));
    // Beyond the grid clamps to the last cell.
    try std.testing.expectEqual(Cell{ .x = 99, .y = 36 }, cellFromPixels(100000, 100000, 8, 16, 100, 37));
}
