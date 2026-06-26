//! whostty: a single terminal surface — binds the pty, the terminal IO, and
//! (in #11) the renderer for one window.
//!
//! Reference: ghostty `src/Surface.zig` (strategy: port). slice-0 keeps the
//! surface to what resize needs: deriving the grid size from the client pixel
//! size and propagating it to both the pty (ConPTY) and the terminal grid.
//! See PORTING.md.
//!
//! The pure grid/cell/layout geometry was split into the platform-free engine
//! layer (`engine/grid.zig`, #129) so whomux can import it without Windows; this
//! file keeps the platform-bound `Surface` (it holds a ConPTY `*Pty`) and
//! re-exports the geometry types so the Win32 apprt keeps addressing them as
//! `surface.layout` / `surface.Padding` / `surface.GridSize`, etc.
const std = @import("std");
const Pty = @import("pty.zig").Pty;
const Termio = @import("termio.zig").Termio;
const grid = @import("engine/grid.zig");
const mouse = @import("engine/mouse.zig");

// Re-export the platform-free grid geometry (now in `engine/grid.zig`) so the
// apprt and offscreen proof can keep referring to it through `Surface`.
pub const GridSize = grid.GridSize;
pub const Cell = grid.Cell;
pub const Padding = grid.Padding;
pub const Layout = grid.Layout;
pub const layout = grid.layout;
pub const cellFromPixels = grid.cellFromPixels;
pub const gridFromPixels = grid.gridFromPixels;

pub const Surface = struct {
    pty: *Pty,
    termio: *Termio,
    cell_w: u32,
    cell_h: u32,
    cols: u16,
    rows: u16,

    /// Blank padding around the grid (#71). The grid origin is derived from it.
    pad: Padding = .{},
    /// Top-left pixel of cell (0,0) — the padding offset, recomputed on resize.
    /// The renderer and mouse mapping both honor it.
    origin_x: u32 = 0,
    origin_y: u32 = 0,

    /// Whether the left mouse button is held (a drag is in progress). The
    /// selected region and the drag anchor live in the libghostty-vt core,
    /// managed by Termio's selectStart/Extend/End under its lock.
    mouse_left_down: bool = false,

    /// The last cell a motion report was emitted for, so a drag under an
    /// app's mouse-motion tracking (modes 1002/1003) reports only when the
    /// cursor crosses a cell boundary (xterm semantics, #52). Seeded by the
    /// reported left-press and cleared on its release.
    last_motion_cell: ?struct { x: u16, y: u16 } = null,

    /// Handle a window resize (client pixels). Recomputes the layout; the grid
    /// origin always tracks the new size (padding-balance depends on it), and the
    /// pseudo console + terminal grid are resized only when the cell dimensions
    /// actually change, so reflow follows the window.
    pub fn resizePixels(self: *Surface, px_w: u32, px_h: u32) !void {
        const l = grid.layout(px_w, px_h, self.cell_w, self.cell_h, self.pad);
        self.origin_x = l.origin_x;
        self.origin_y = l.origin_y;
        if (l.cols == self.cols and l.rows == self.rows) return;

        self.cols = l.cols;
        self.rows = l.rows;
        try self.pty.setSize(.{ .ws_col = l.cols, .ws_row = l.rows });
        try self.termio.resize(l.cols, l.rows);
    }

    /// Lay the grid out inside a sub-rect of the window (a split pane, #87) at
    /// window-pixel offset (x, y) with size (w, h). Like `resizePixels` but the
    /// grid origin is offset by the pane's position, so the renderer and mouse
    /// mapping (both keyed on `origin_*`, in absolute window pixels) address the
    /// pane correctly. The pty + terminal grid are resized only when the cell
    /// dimensions actually change.
    pub fn resizeInRect(self: *Surface, x: u32, y: u32, w: u32, h: u32) !void {
        const l = grid.layout(w, h, self.cell_w, self.cell_h, self.pad);
        self.origin_x = x + l.origin_x;
        self.origin_y = y + l.origin_y;
        if (l.cols == self.cols and l.rows == self.rows) return;
        self.cols = l.cols;
        self.rows = l.rows;
        try self.pty.setSize(.{ .ws_col = l.cols, .ws_row = l.rows });
        try self.termio.resize(l.cols, l.rows);
    }

    /// A mouse button was pressed/released. When an application has enabled
    /// mouse tracking the event is encoded and written to the pty (unless Shift
    /// is held, which forces local selection like xterm); otherwise the left
    /// button drives text selection.
    pub fn mouseButton(self: *Surface, button: mouse.Button, action: mouse.Action, px_x: i32, px_y: i32, mods: mouse.Mods) void {
        const cell = grid.cellFromPixels(px_x, px_y, self.cell_w, self.cell_h, self.cols, self.rows, self.origin_x, self.origin_y);

        if (!mods.shift) {
            var buf: [32]u8 = undefined;
            if (self.termio.encodeMouseReport(&buf, cell.x, cell.y, button, action, mods)) |bytes| {
                _ = self.pty.write(bytes) catch {};
                // Seed (press) / clear (release) the motion dedup so a reported
                // left-drag only emits on a cell change (#52).
                if (button == .left) self.last_motion_cell = switch (action) {
                    .press => .{ .x = cell.x, .y = cell.y },
                    else => null,
                };
                return;
            }
        }

        if (button == .left) switch (action) {
            .press => {
                self.termio.selectStart(cell.x, cell.y);
                self.mouse_left_down = true;
            },
            .release => {
                self.mouse_left_down = false;
                self.termio.selectEnd();
            },
            .motion => {},
        };
    }

    /// Mouse moved during a left-drag. When a local selection is in progress it
    /// is extended to the current cell; otherwise — i.e. an app has mouse
    /// tracking on, so the press was reported rather than starting a selection —
    /// the move is reported as a motion event for button/any tracking modes
    /// (1002/1003), deduped per cell so it only fires on a cell change (#52).
    /// (No-button motion in `any` mode, which needs every move routed, not just
    /// the held-button drag, is a follow-up.)
    pub fn mouseDrag(self: *Surface, px_x: i32, px_y: i32, mods: mouse.Mods) void {
        const cell = grid.cellFromPixels(px_x, px_y, self.cell_w, self.cell_h, self.cols, self.rows, self.origin_x, self.origin_y);

        if (self.mouse_left_down) {
            self.termio.selectExtend(cell.x, cell.y);
            return;
        }

        if (self.last_motion_cell) |lc| if (lc.x == cell.x and lc.y == cell.y) return;
        var buf: [32]u8 = undefined;
        if (self.termio.encodeMouseReport(&buf, cell.x, cell.y, .left, .motion, mods)) |bytes| {
            _ = self.pty.write(bytes) catch {};
            self.last_motion_cell = .{ .x = cell.x, .y = cell.y };
        }
    }

    /// Mouse moved with no button held. For an app in any-event tracking (mode
    /// 1003) this reports no-button motion, deduped per cell; in every other mode
    /// it is a no-op (button/normal modes don't report hover, and there is no
    /// local selection to extend). (#52)
    pub fn mouseHover(self: *Surface, px_x: i32, px_y: i32, mods: mouse.Mods) void {
        const cell = grid.cellFromPixels(px_x, px_y, self.cell_w, self.cell_h, self.cols, self.rows, self.origin_x, self.origin_y);
        if (self.last_motion_cell) |lc| if (lc.x == cell.x and lc.y == cell.y) return;
        var buf: [32]u8 = undefined;
        if (self.termio.encodeMouseReport(&buf, cell.x, cell.y, null, .motion, mods)) |bytes| {
            _ = self.pty.write(bytes) catch {};
            self.last_motion_cell = .{ .x = cell.x, .y = cell.y };
        }
    }

    /// End an in-progress drag (button release already handled, or capture was
    /// lost). Releases the selection anchor (keeping the selection) and the motion
    /// dedup, so neither outlives the drag — the next left-press re-establishes
    /// both.
    pub fn endDrag(self: *Surface) void {
        self.last_motion_cell = null;
        if (self.mouse_left_down) {
            self.mouse_left_down = false;
            self.termio.selectEnd();
        }
    }

    /// The current selection as UTF-8, or null if nothing is selected. Caller
    /// owns the returned slice.
    pub fn selectionText(self: *Surface, alloc: std.mem.Allocator) !?[:0]const u8 {
        return self.termio.selectionStringAlloc(alloc);
    }
};

test {
    // The pure grid geometry + its tests now live in the engine layer.
    _ = grid;
}
