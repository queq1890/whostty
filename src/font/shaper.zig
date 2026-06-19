//! whostty: text shaping — run segmentation now, Harfbuzz shaping seamed.
//!
//! Reference: ghostty `src/font/shaper/` — `run.zig` (the `RunIterator` that
//! groups a row's cells into shapable runs) and `harfbuzz.zig` (the shaper that
//! turns a run into positioned glyphs). Strategy: port. The run iterator is
//! portable logic and is ported + host-tested here; the Harfbuzz binding is a
//! build dependency that can't be added or verified without compiling, so it is
//! seamed (see `Shaper.shape`). See PORTING.md.
//!
//! Run segmentation is the prerequisite for shaping: the renderer currently
//! draws one glyph per cell (no ligatures/complex text). Shaping replaces the
//! per-run cells with a shaped glyph sequence; before that can happen the row
//! must be split into runs that share a font/style so Harfbuzz can shape each.
//!
//! This module is free of the `freetype`/`harfbuzz` imports and of any platform
//! types, so it compiles and unit-tests on the host.
const std = @import("std");

/// The face style of a cell, reused from discovery so the two layers agree on
/// the regular/bold/italic/bold-italic split.
pub const Style = @import("discovery.zig").Style;

/// How a cell participates in character width. A wide character (CJK, some
/// emoji) occupies its own cell plus a trailing `spacer_tail` cell; the tail
/// carries no codepoint of its own and stays within the wide cell's run.
pub const Width = enum { narrow, wide, spacer_tail };

/// One terminal cell as the shaper sees it: a codepoint, its face style, and its
/// width role. This is the host-testable projection of a libghostty-vt cell —
/// the apprt fills it from the VT grid.
pub const Cell = struct {
    codepoint: u21,
    style: Style = .regular,
    width: Width = .narrow,
};

/// A maximal sequence of cells that can be shaped together: same face style,
/// contiguous in the row. `start`/`len` index into the row's cell slice
/// (`len` counts spacer tails so the mapping back to columns is exact).
pub const Run = struct {
    start: usize,
    len: usize,
    style: Style,
};

/// Splits a row of cells into runs. A run breaks when the face style changes;
/// `spacer_tail` cells never start a run, they extend the current one (they
/// belong to the preceding wide cell's cluster). Faithful to the grouping in
/// ghostty's `shaper/run.zig`, minus bidi levels (not yet modeled).
pub const RunIterator = struct {
    cells: []const Cell,
    i: usize = 0,

    pub fn init(cells: []const Cell) RunIterator {
        return .{ .cells = cells };
    }

    pub fn next(self: *RunIterator) ?Run {
        if (self.i >= self.cells.len) return null;

        const start = self.i;
        const style = self.cells[start].style;
        self.i += 1;

        // Extend while the style matches. Spacer tails always continue the run
        // regardless of their (unused) style field.
        while (self.i < self.cells.len) : (self.i += 1) {
            const cell = self.cells[self.i];
            if (cell.width == .spacer_tail) continue;
            if (cell.style != style) break;
        }

        return .{ .start = start, .len = self.i - start, .style = style };
    }
};

/// A glyph produced by shaping: the font's glyph index plus its cluster (the
/// originating cell offset within the run) and pen advance/offset in pixels.
/// Mirrors the fields whostty needs from a Harfbuzz `hb_glyph_info_t` +
/// `hb_glyph_position_t` pair.
pub const ShapedGlyph = struct {
    glyph_index: u32,
    cluster: u32,
    x_advance: i32,
    y_advance: i32 = 0,
    x_offset: i32 = 0,
    y_offset: i32 = 0,
};

/// The Harfbuzz shaper seam. Shaping a run requires an `hb_font_t` wrapping the
/// Freetype face plus the Harfbuzz library, both build dependencies. The call
/// shape is:
///
///   hb_buffer_reset(buf)
///   hb_buffer_add_utf32(buf, run codepoints, ...)  // or add per cluster
///   hb_buffer_guess_segment_properties(buf)
///   hb_shape(hb_font, buf, features, n)
///   infos = hb_buffer_get_glyph_infos(buf, &n)
///   pos   = hb_buffer_get_glyph_positions(buf, &n)
///   -> emit ShapedGlyph{ glyph_index, cluster, x_advance>>6, ... }
///
/// Wiring this needs the harfbuzz dependency in build.zig.zon and a compiler to
/// verify the binding, neither of which is available in this environment, so it
/// is not landed blind. Until then the renderer keeps its per-cell glyph path
/// (no ligatures). The run segmentation above is the part that's ready.
pub const Shaper = struct {
    pub fn shape(
        self: *Shaper,
        alloc: std.mem.Allocator,
        run: Run,
        cells: []const Cell,
    ) ![]ShapedGlyph {
        _ = self;
        _ = alloc;
        _ = run;
        _ = cells;
        return error.Unimplemented;
    }
};

const testing = std.testing;

test "shaper: a uniform row is a single run" {
    const cells = [_]Cell{
        .{ .codepoint = 'h' },
        .{ .codepoint = 'i' },
        .{ .codepoint = '!' },
    };
    var it = RunIterator.init(&cells);
    const r = it.next().?;
    try testing.expectEqual(@as(usize, 0), r.start);
    try testing.expectEqual(@as(usize, 3), r.len);
    try testing.expectEqual(Style.regular, r.style);
    try testing.expect(it.next() == null);
}

test "shaper: a style change breaks the run" {
    const cells = [_]Cell{
        .{ .codepoint = 'a', .style = .regular },
        .{ .codepoint = 'b', .style = .bold },
        .{ .codepoint = 'c', .style = .bold },
        .{ .codepoint = 'd', .style = .italic },
    };
    var it = RunIterator.init(&cells);

    const r0 = it.next().?;
    try testing.expectEqual(@as(usize, 0), r0.start);
    try testing.expectEqual(@as(usize, 1), r0.len);
    try testing.expectEqual(Style.regular, r0.style);

    const r1 = it.next().?;
    try testing.expectEqual(@as(usize, 1), r1.start);
    try testing.expectEqual(@as(usize, 2), r1.len);
    try testing.expectEqual(Style.bold, r1.style);

    const r2 = it.next().?;
    try testing.expectEqual(@as(usize, 3), r2.start);
    try testing.expectEqual(@as(usize, 1), r2.len);
    try testing.expectEqual(Style.italic, r2.style);

    try testing.expect(it.next() == null);
}

test "shaper: a wide cell keeps its spacer tail in the same run" {
    const cells = [_]Cell{
        .{ .codepoint = 'a', .style = .regular },
        .{ .codepoint = 0x4E00, .style = .regular, .width = .wide },
        .{ .codepoint = 0, .style = .bold, .width = .spacer_tail }, // style ignored
        .{ .codepoint = 'b', .style = .regular },
    };
    var it = RunIterator.init(&cells);
    const r = it.next().?;
    // All four cells share one regular run; the spacer tail did not split it
    // despite its differing style field.
    try testing.expectEqual(@as(usize, 0), r.start);
    try testing.expectEqual(@as(usize, 4), r.len);
    try testing.expect(it.next() == null);
}

test "shaper: empty input yields no runs" {
    const cells = [_]Cell{};
    var it = RunIterator.init(&cells);
    try testing.expect(it.next() == null);
}

test "shaper: shape is seamed until the harfbuzz binding lands" {
    const cells = [_]Cell{.{ .codepoint = 'x' }};
    var sh: Shaper = .{};
    try testing.expectError(error.Unimplemented, sh.shape(testing.allocator, .{ .start = 0, .len = 1, .style = .regular }, &cells));
}
