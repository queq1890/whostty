//! whostty engine: host-facing foundational Surface geometry (#133, epic E0).
//!
//! Stability: experimental (ADR 0010) — promoted once whomux drives the shape.
//!
//! The platform-bound `Surface` (src/Surface.zig) mixes two things: the *pure*
//! geometry decision (given a client pixel size + DPI-aware cell metrics, what
//! is the grid, where is its origin, did the grid change?) and the *side effect*
//! (push the new size to the ConPTY and the libghostty-vt grid). #133 exports
//! the pure half as `Geometry` so the host (whomux) can track per-pane geometry
//! and drive its OWN pty + VT resize — the platform-bound half stays host-side.
//!
//! The other foundational Surface APIs already live in the engine layer:
//!   * **DPI-aware cell metrics / layout**: `engine.grid.layout` takes the cell
//!     width/height the host derives at the current DPI; `Geometry` carries them.
//!   * **mouse-event VT encoding**: `engine.mouse.encode` (X10 / SGR 1006).
//!   * **text selection**: the selection *range model* lives in the VT core
//!     (libghostty-vt, which the host also imports); the host calls
//!     selectStart/Extend/End on its Termio. There is no separate engine copy.
//!
//! Everything here is a pure function of pixel sizes + cell metrics, so it is
//! fully host-testable and platform-free.

const std = @import("std");
const grid = @import("grid.zig");

/// Per-surface (per-pane) geometry: DPI-aware cell metrics, the current grid,
/// the grid origin in window pixels, and the padding. The host updates it on
/// resize and consults it to map mouse pixels to cells.
pub const Geometry = struct {
    /// Cell metrics, in pixels, at the current DPI. The host recomputes these
    /// when the font or DPI changes and writes them here before the next resize.
    cell_w: u32,
    cell_h: u32,

    /// Current grid size, derived by the last resize (0 until first resize).
    cols: u16 = 0,
    rows: u16 = 0,

    /// Blank padding around the grid (#71). The origin is derived from it.
    pad: grid.Padding = .{},

    /// Top-left pixel of cell (0,0) — the padding offset (plus the pane's window
    /// offset for a split). Both the renderer and mouse mapping key on it.
    origin_x: u32 = 0,
    origin_y: u32 = 0,

    /// The outcome of a resize: the new grid, and whether it actually changed.
    /// `grid_changed` is the signal to resize the pty + VT grid; when it is
    /// false only the origin moved (e.g. padding-balance) and no reflow is due.
    pub const Resize = struct {
        cols: u16,
        rows: u16,
        grid_changed: bool,
    };

    /// Resize to a whole-window client size. Recomputes the grid + origin and
    /// reports whether the grid changed. Mirrors `Surface.resizePixels` minus the
    /// pty/VT side effect.
    pub fn resize(self: *Geometry, px_w: u32, px_h: u32) Resize {
        return self.place(0, 0, px_w, px_h);
    }

    /// Lay out inside a sub-rect of the window (a split pane) at window-pixel
    /// offset (x, y) with size (w, h): the origin is offset by the pane position
    /// so the renderer and mouse mapping (both in absolute window pixels) address
    /// the pane. Mirrors `Surface.resizeInRect` minus the pty/VT side effect.
    pub fn resizeInRect(self: *Geometry, x: u32, y: u32, w: u32, h: u32) Resize {
        return self.place(x, y, w, h);
    }

    fn place(self: *Geometry, x: u32, y: u32, w: u32, h: u32) Resize {
        const l = grid.layout(w, h, self.cell_w, self.cell_h, self.pad);
        self.origin_x = x + l.origin_x;
        self.origin_y = y + l.origin_y;
        const changed = (l.cols != self.cols or l.rows != self.rows);
        self.cols = l.cols;
        self.rows = l.rows;
        return .{ .cols = l.cols, .rows = l.rows, .grid_changed = changed };
    }

    /// Map a window-pixel position to a viewport cell, clamped to the grid.
    pub fn cellAt(self: Geometry, px_x: i32, px_y: i32) grid.Cell {
        return grid.cellFromPixels(
            px_x,
            px_y,
            self.cell_w,
            self.cell_h,
            self.cols,
            self.rows,
            self.origin_x,
            self.origin_y,
        );
    }
};

test "resize derives the grid and flags the first change" {
    var g: Geometry = .{ .cell_w = 8, .cell_h = 16 };
    const r = g.resize(800, 600);
    try std.testing.expectEqual(@as(u16, 100), r.cols);
    try std.testing.expectEqual(@as(u16, 37), r.rows);
    try std.testing.expect(r.grid_changed);
    try std.testing.expectEqual(@as(u16, 100), g.cols);
    try std.testing.expectEqual(@as(u16, 37), g.rows);
}

test "resize to the same grid reports no change (no reflow due)" {
    var g: Geometry = .{ .cell_w = 8, .cell_h = 16 };
    _ = g.resize(800, 600);
    // A few more pixels each way, still within the same whole-cell counts
    // (807/8 -> 100 cols, 607/16 -> 37 rows): the grid is unchanged.
    const r = g.resize(807, 607);
    try std.testing.expect(!r.grid_changed);
    try std.testing.expectEqual(@as(u16, 100), r.cols);
    try std.testing.expectEqual(@as(u16, 37), r.rows);
}

test "resizeInRect offsets the origin by the pane position" {
    var g: Geometry = .{ .cell_w = 10, .cell_h = 20 };
    const r = g.resizeInRect(200, 100, 400, 300);
    try std.testing.expectEqual(@as(u16, 40), r.cols);
    try std.testing.expectEqual(@as(u16, 15), r.rows);
    // No padding, so the origin is exactly the pane offset.
    try std.testing.expectEqual(@as(u32, 200), g.origin_x);
    try std.testing.expectEqual(@as(u32, 100), g.origin_y);
}

test "cellAt maps window pixels to cells honoring the origin" {
    var g: Geometry = .{ .cell_w = 10, .cell_h = 20 };
    _ = g.resizeInRect(200, 100, 400, 300);
    // A pixel one cell right + one cell down from the pane origin.
    const c = g.cellAt(200 + 10 + 3, 100 + 20 + 5);
    try std.testing.expectEqual(@as(u16, 1), c.x);
    try std.testing.expectEqual(@as(u16, 1), c.y);
    // Pixels above/left of the origin clamp to cell 0.
    const c0 = g.cellAt(0, 0);
    try std.testing.expectEqual(@as(u16, 0), c0.x);
    try std.testing.expectEqual(@as(u16, 0), c0.y);
}
