//! whostty engine: the platform-free terminal-engine layer (#129, epic E0 #141).
//!
//! This namespace is the importable engine boundary whomux builds on. It holds
//! the pure terminal-engine model with ZERO Windows / ConPTY / WGL dependency:
//!
//!   * `grid`  — grid/cell/layout geometry (`GridSize`, `Cell`, `Padding`,
//!     `Layout`, `layout()`, `cellFromPixels()`, `gridFromPixels()`).
//!   * `split` — the `SplitTree` (binary tree of panes) + `TabList` model, with
//!     pixel layout, directional focus, hit-testing and divider geometry.
//!   * `mouse` — VT mouse-report encoding (X10 / SGR 1006).
//!   * `scroll`— wheel-delta accumulation, scrollbar thumb + page-scroll math.
//!   * `frame` — frame-pacing decisions (redraw-on-change, idle wait).
//!
//! The platform-bound surface (pty + terminal IO + renderer wiring) lives in
//! `src/Surface.zig` and the Win32 host in `src/apprt/win32/`; neither is
//! reachable from here. The `engine-test` build target compiles + unit-tests
//! this module for a non-Windows host, so CI goes red if a platform import ever
//! leaks into the engine namespace. See PORTING.md.

pub const grid = @import("grid.zig");
pub const split = @import("SplitTree.zig");
pub const mouse = @import("mouse.zig");
pub const scroll = @import("scroll.zig");
pub const frame = @import("frame.zig");

// Convenience re-exports of the common engine types.
pub const SplitTree = split.SplitTree;
pub const TabList = split.TabList;
pub const SurfaceId = split.SurfaceId;
pub const GridSize = grid.GridSize;
pub const Cell = grid.Cell;
pub const Padding = grid.Padding;
pub const Layout = grid.Layout;

test {
    // Pull in every engine submodule's unit tests so `zig build engine-test`
    // (and the non-Windows link check) covers the whole platform-free layer.
    _ = grid;
    _ = split;
    _ = mouse;
    _ = scroll;
    _ = frame;
}
