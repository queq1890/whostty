//! whostty: text shaping — run segmentation + the pure shaping types.
//!
//! Reference: ghostty `src/font/shaper/` — `run.zig` (the `RunIterator` that
//! groups a row's cells into shapable runs) and `harfbuzz.zig` (the shaper that
//! turns a run into positioned glyphs). Strategy: port. The run iterator and the
//! feature grammar are portable logic and are ported + host-tested here; the
//! HarfBuzz `Shaper` itself lives in `harfbuzz.zig` (it links the HarfBuzz C
//! library and is only compiled under `-Dharfbuzz`) and consumes these types.
//! See PORTING.md.
//!
//! Run segmentation is the prerequisite for shaping: without it the renderer
//! draws one glyph per cell (no ligatures/complex text). Shaping replaces a
//! run's cells with a shaped glyph sequence; before that can happen the row must
//! be split into runs that share a font/style so HarfBuzz can shape each.
//!
//! This module is free of the `freetype`/`harfbuzz` imports and of any platform
//! types, so it compiles and unit-tests on the host.
const std = @import("std");

const discovery = @import("discovery.zig");

/// The face style of a cell, reused from discovery so the two layers agree on
/// the regular/bold/italic/bold-italic split.
pub const Style = discovery.Style;

/// Text vs emoji presentation, reused from discovery. Runs don't cross it: text
/// and emoji come from different faces.
pub const Presentation = discovery.Presentation;

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
    presentation: Presentation = .text,
    width: Width = .narrow,
};

/// A maximal sequence of cells that can be shaped together: same face style,
/// contiguous in the row. `start`/`len` index into the row's cell slice
/// (`len` counts spacer tails so the mapping back to columns is exact).
pub const Run = struct {
    start: usize,
    len: usize,
    style: Style,
    presentation: Presentation = .text,

    /// The absolute cell column of a shaped glyph, mapping its run-relative
    /// cluster (as Harfbuzz reports it) back to the row.
    pub fn column(self: Run, cluster: u32) usize {
        return self.start + cluster;
    }
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
        const pres = self.cells[start].presentation;
        self.i += 1;

        // Extend while the style and presentation match. Spacer tails always
        // continue the run regardless of their (unused) style/presentation.
        while (self.i < self.cells.len) : (self.i += 1) {
            const cell = self.cells[self.i];
            if (cell.width == .spacer_tail) continue;
            if (cell.style != style or cell.presentation != pres) break;
        }

        return .{ .start = start, .len = self.i - start, .style = style, .presentation = pres };
    }
};

/// An OpenType font feature toggle (e.g. ligatures `liga`, contextual
/// alternates `calt`, stylistic sets `ss01`). Faithful to ghostty's
/// `font-feature` config: a 4-byte tag (space-padded for short tags, as
/// OpenType requires) plus an integer value (0 = off, 1 = on, or an explicit
/// count). These feed `hb_shape`'s feature array.
pub const Feature = struct {
    tag: [4]u8,
    value: u32,

    /// Parse one `font-feature` value. Accepts: a bare tag (`liga` -> on),
    /// a `+`/`-` prefix (`+liga` on, `-liga` off), or an explicit `tag=value`
    /// (`ss01=2`). A prefix and an explicit value together is an error.
    pub fn parse(input: []const u8) !Feature {
        var s = std.mem.trim(u8, input, " \t");
        if (s.len == 0) return error.InvalidValue;

        var value: ?u32 = null;
        if (s[0] == '-') {
            value = 0;
            s = s[1..];
        } else if (s[0] == '+') {
            value = 1;
            s = s[1..];
        }

        if (std.mem.indexOfScalar(u8, s, '=')) |eq| {
            if (value != null) return error.InvalidValue; // both a sign and =value
            value = std.fmt.parseInt(u32, std.mem.trim(u8, s[eq + 1 ..], " \t"), 10) catch
                return error.InvalidValue;
            s = std.mem.trim(u8, s[0..eq], " \t");
        }

        if (s.len == 0 or s.len > 4) return error.InvalidValue;

        // OpenType tags are 4 ASCII graphic chars, right-padded with spaces.
        var tag = [_]u8{' '} ** 4;
        for (s, 0..) |ch, i| {
            if (ch <= ' ' or ch > '~') return error.InvalidValue;
            tag[i] = ch;
        }
        return .{ .tag = tag, .value = value orelse 1 };
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

/// The HarfBuzz `Shaper` — which consumes a `Run` plus these `ShapedGlyph` /
/// `Feature` types and calls `hb_shape` — lives in `harfbuzz.zig` (it links the
/// HarfBuzz C library and is only built under `-Dharfbuzz`). Keeping it out of
/// this module is what lets the run segmentation + feature grammar above stay
/// dependency-free and host-testable.
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

test "shaper: presentation change breaks the run" {
    const cells = [_]Cell{
        .{ .codepoint = 'h', .presentation = .text },
        .{ .codepoint = 'i', .presentation = .text },
        .{ .codepoint = 0x1F600, .presentation = .emoji, .width = .wide },
        .{ .codepoint = 0, .presentation = .text, .width = .spacer_tail }, // stays with emoji
        .{ .codepoint = '!', .presentation = .text },
    };
    var it = RunIterator.init(&cells);

    const r0 = it.next().?;
    try testing.expectEqual(@as(usize, 0), r0.start);
    try testing.expectEqual(@as(usize, 2), r0.len);
    try testing.expectEqual(Presentation.text, r0.presentation);

    const r1 = it.next().?;
    try testing.expectEqual(@as(usize, 2), r1.start);
    try testing.expectEqual(@as(usize, 2), r1.len); // emoji + its spacer tail
    try testing.expectEqual(Presentation.emoji, r1.presentation);

    const r2 = it.next().?;
    try testing.expectEqual(@as(usize, 4), r2.start);
    try testing.expectEqual(@as(usize, 1), r2.len);
    try testing.expectEqual(Presentation.text, r2.presentation);

    try testing.expect(it.next() == null);
}

test "shaper: Run.column maps a cluster to its grid column" {
    const r: Run = .{ .start = 5, .len = 3, .style = .regular };
    try testing.expectEqual(@as(usize, 5), r.column(0));
    try testing.expectEqual(@as(usize, 7), r.column(2));
}

test "shaper: empty input yields no runs" {
    const cells = [_]Cell{};
    var it = RunIterator.init(&cells);
    try testing.expect(it.next() == null);
}

test "shaper: Feature.parse forms" {
    // Bare tag enables it.
    const liga = try Feature.parse("liga");
    try testing.expectEqualSlices(u8, "liga", &liga.tag);
    try testing.expectEqual(@as(u32, 1), liga.value);

    // Sign prefixes.
    try testing.expectEqual(@as(u32, 0), (try Feature.parse("-liga")).value);
    try testing.expectEqual(@as(u32, 1), (try Feature.parse("+calt")).value);

    // Explicit value.
    const ss = try Feature.parse("ss01=2");
    try testing.expectEqualSlices(u8, "ss01", &ss.tag);
    try testing.expectEqual(@as(u32, 2), ss.value);
    try testing.expectEqual(@as(u32, 0), (try Feature.parse("calt=0")).value);

    // Short tags are right-padded with spaces.
    const short = try Feature.parse("aa");
    try testing.expectEqualSlices(u8, "aa  ", &short.tag);
}

test "shaper: Feature.parse rejects malformed input" {
    try testing.expectError(error.InvalidValue, Feature.parse(""));
    try testing.expectError(error.InvalidValue, Feature.parse("toolong"));
    try testing.expectError(error.InvalidValue, Feature.parse("-liga=2")); // sign + value
    try testing.expectError(error.InvalidValue, Feature.parse("ss01=x")); // non-numeric
}
