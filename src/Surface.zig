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
