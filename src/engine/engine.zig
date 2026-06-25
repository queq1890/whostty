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

/// The apprt-free host vtable the engine calls back through for window services
/// (GL context, redraw, clipboard, title, cursor, IME). Stability: experimental
/// (ADR 0010) — the host (whomux) implements it; #132.
pub const host = @import("host.zig");

/// Host-facing foundational Surface geometry (#133): DPI-aware cell metrics + the
/// pure resize/reflow decision, extracted from the platform-bound Surface.
/// Stability: experimental (ADR 0010).
pub const surface = @import("surface.zig");

/// The unified per-pane working-directory store (#134): one canonical cwd path
/// fed by OSC 7 and OSC 133, with the OSC 7 empty-url reset. Stability:
/// experimental (ADR 0010).
pub const cwd = @import("cwd.zig");

/// The attention side channel (#135): typed BEL / OSC 9-777 notification / OSC
/// 9;4 progress events plus the host `Sink` callback. The engine reports the
/// events; the host owns OS surfacing. Stability: experimental (ADR 0010).
pub const attention = @import("attention.zig");

/// OSC 133 semantic prompt marks (#136): the per-pane semantic `State`
/// (at-prompt / running / done), the last exit code, and enumerable command
/// boundaries for navigation. Stability: experimental (ADR 0010).
pub const semantic = @import("semantic.zig");

/// OSC 8 hyperlink ranges (#139): the host-facing `Range` type for a resolved
/// hyperlink (viewport cell run + target URI). The query/enumeration over live
/// cells lives on `Termio`. Stability: experimental (ADR 0010).
pub const hyperlink = @import("hyperlink.zig");

// Convenience re-exports of the common engine types.
pub const SplitTree = split.SplitTree;
pub const TabList = split.TabList;
pub const SurfaceId = split.SurfaceId;
pub const GridSize = grid.GridSize;
pub const Cell = grid.Cell;
pub const Padding = grid.Padding;
pub const Layout = grid.Layout;
pub const Host = host.Host;
pub const CursorShape = host.CursorShape;
pub const Geometry = surface.Geometry;
pub const Cwd = cwd.Cwd;
pub const AttentionEvent = attention.Event;
pub const AttentionSink = attention.Sink;
pub const SemanticState = semantic.State;
pub const SemanticMark = semantic.Mark;
pub const HyperlinkRange = hyperlink.Range;

test {
    // Pull in every engine submodule's unit tests so `zig build engine-test`
    // (and the non-Windows link check) covers the whole platform-free layer.
    _ = grid;
    _ = split;
    _ = mouse;
    _ = scroll;
    _ = frame;
    _ = host;
    _ = surface;
    _ = cwd;
    _ = attention;
    _ = semantic;
    _ = hyperlink;
}
