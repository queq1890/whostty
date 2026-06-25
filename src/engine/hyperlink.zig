//! whostty engine: OSC 8 hyperlink ranges (#139, epic E0 #141).
//!
//! Stability: experimental (ADR 0010) — promoted once whomux drives the shape.
//!
//! OSC 8 attaches a URI to a run of cells; libghostty-vt interprets the open/close
//! sequences and tags the cells with their hyperlink as the stream is parsed.
//! whomux renders these as clickable links (Ctrl-click to open) and underlines
//! them, alongside its own heuristic URL detection. This module is the pure,
//! host-facing *shape* of a resolved hyperlink — a viewport cell range plus its
//! target URI. Reading the live cell state needs the VT core, so the actual query
//! / enumeration lives on `Termio` (`hyperlinkAt`, `hyperlinkRanges`); this is the
//! type that crosses the engine boundary. Click handling and the pointer shape
//! stay host-side: the engine reports ranges + targets, whomux owns the action.

const std = @import("std");

/// A contiguous run of cells on one viewport row that share a hyperlink, with its
/// target URI. A hyperlink spanning multiple rows is reported as one `Range` per
/// row (each row's run), which is what an underline / hit-test consumes. Columns
/// are inclusive viewport coordinates.
pub const Range = struct {
    /// Viewport row, 0 = top visible row.
    y: u16,
    /// Inclusive start column of the run.
    x_start: u16,
    /// Inclusive end column of the run.
    x_end: u16,
    /// The target URI. Owned by the allocator passed to the producing accessor
    /// (`Termio.hyperlinkRanges`); release the whole result with `freeRanges`.
    target: []const u8,
};

/// Free a `Range` slice returned by `Termio.hyperlinkRanges` (each `target` plus
/// the backing slice), with the same allocator that produced it.
pub fn freeRanges(alloc: std.mem.Allocator, ranges: []Range) void {
    for (ranges) |r| alloc.free(r.target);
    alloc.free(ranges);
}

test "hyperlink: freeRanges releases the targets and the slice" {
    const alloc = std.testing.allocator;
    var ranges = try alloc.alloc(Range, 2);
    ranges[0] = .{ .y = 0, .x_start = 2, .x_end = 6, .target = try alloc.dupe(u8, "https://a.example") };
    ranges[1] = .{ .y = 1, .x_start = 0, .x_end = 3, .target = try alloc.dupe(u8, "https://b.example") };
    // If freeRanges leaked, the testing allocator would flag it.
    freeRanges(alloc, ranges);
}

test "hyperlink: range columns are inclusive" {
    const r: Range = .{ .y = 3, .x_start = 4, .x_end = 9, .target = "x" };
    try std.testing.expectEqual(@as(u16, 6), r.x_end - r.x_start + 1); // 6 cells wide
}
