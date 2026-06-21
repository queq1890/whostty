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
const build_options = @import("build_options");

const discovery = @import("discovery.zig");

/// The Harfbuzz binding only exists in the `-Dfreetype` build (it's a lazy,
/// freetype-gated dependency — see build.zig). In the no-freetype CI build the
/// module is absent, so the import is comptime-gated and the shaper degrades to
/// the seam (`shape` returns `error.Unimplemented`). Everything below that
/// touches `harfbuzz` sits behind `build_options.freetype`.
const harfbuzz = if (build_options.freetype) @import("harfbuzz") else void;
const font = if (build_options.freetype) @import("main.zig") else void;

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
    /// SGR 8 (invisible). Carried so the renderer keeps an invisible cell off the
    /// shaped path — invisible text must not render, and shaping (which only
    /// splits runs on style/presentation) would otherwise draw it. A run holding
    /// one falls back to the per-cell path, which already honors invisible.
    invisible: bool = false,
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
/// The Harfbuzz shaper. In the `-Dfreetype` build it owns an `hb_font_t`
/// wrapping the primary FreeType face (created via `hb_ft_font_create_referenced`,
/// which refcounts the FT face so the face must outlive the shaper) plus a reused
/// buffer and the configured OpenType feature list. In the no-freetype build it
/// holds nothing and `shape` returns `error.Unimplemented` (the renderer keeps
/// its per-cell glyph path). A default-constructed `Shaper{}` has no font and
/// also returns `error.Unimplemented`, so the seam stays valid in both builds.
pub const Shaper = struct {
    /// The shaper's OWN FreeType library — NOT the rasterizer's `cache.lib`.
    /// FreeType's FT_Library is non-reentrant (shared per-library glyph-loader /
    /// raster state). Interleaving glyph loads on two faces of ONE library — the
    /// shaper's `shape()` (own_face) and the cache's `getByIndex()` (cache.face),
    /// alternating per row every frame — corrupts that shared state and
    /// intermittently spins FT_Load_Glyph / FT_Render_Glyph (the #79 UI hang). A
    /// separate library per independent face-user is FreeType's supported model.
    own_lib: if (build_options.freetype) ?font.Library else void =
        if (build_options.freetype) null else {},
    /// The shaper's OWN FreeType face (opened from `own_lib`), separate from the
    /// rasterizer's face. Harfbuzz shaping mutates the FT face; same font file =>
    /// identical glyph indices, so `GlyphCache.getByIndex` resolves the shaped
    /// indices against its own face correctly.
    own_face: if (build_options.freetype) ?font.Face else void =
        if (build_options.freetype) null else {},
    /// The hb font wrapping `own_face`. `null` until `init` runs (or always in
    /// no-freetype). When null, `shape` is the seam.
    hb_font: if (build_options.freetype) ?harfbuzz.Font else void =
        if (build_options.freetype) null else {},
    /// A buffer reused across runs (reset per shape). Only valid when `hb_font`
    /// is set.
    hb_buf: if (build_options.freetype) ?harfbuzz.Buffer else void =
        if (build_options.freetype) null else {},
    /// The OpenType features applied to every run (e.g. `liga`, `calt`). Empty
    /// means "use the font's defaults" (Cascadia Code's ligatures are `calt`,
    /// on by default, so even an empty list yields `-> => != ===`).
    features: if (build_options.freetype) []const harfbuzz.Feature else void =
        if (build_options.freetype) &.{} else {},

    /// Build a shaper that owns its FreeType library + face (opened from `path` at
    /// `px`) and an hb_font over them. `features` are converted to `hb_feature_t[]`,
    /// allocator-owned and freed by `deinit`. The shaper's library/face are kept
    /// fully separate from the rasterizer's (see `own_lib`).
    pub fn init(
        alloc: std.mem.Allocator,
        path: [:0]const u8,
        px: u32,
        features: []const Feature,
    ) !Shaper {
        comptime std.debug.assert(build_options.freetype);
        // Own library + face for Harfbuzz, fully separate from the rasterizer's
        // (#79): sharing the FT_Library (not just the face) intermittently spins
        // FreeType and hangs the UI thread.
        var own_lib = try font.Library.init();
        errdefer own_lib.deinit();
        var own_face = try font.Face.init(own_lib, path, px);
        errdefer own_face.deinit();
        var hb_font = try harfbuzz.freetype.createFont(own_face.inner.handle);
        errdefer hb_font.destroy();
        var hb_buf = try harfbuzz.Buffer.create();
        errdefer hb_buf.destroy();

        // Convert each project Feature into an hb_feature_t spanning the whole
        // run (HB_FEATURE_GLOBAL_START..END). The tag is a big-endian pack of
        // the 4-byte OpenType tag, matching hb_tag_t.
        const hb_feats = try alloc.alloc(harfbuzz.Feature, features.len);
        errdefer alloc.free(hb_feats);
        for (features, 0..) |f, i| {
            const tag: u32 = (@as(u32, f.tag[0]) << 24) |
                (@as(u32, f.tag[1]) << 16) |
                (@as(u32, f.tag[2]) << 8) |
                @as(u32, f.tag[3]);
            hb_feats[i] = .{
                .tag = tag,
                .value = f.value,
                .start = 0,
                .end = std.math.maxInt(c_uint),
            };
        }

        return .{ .own_lib = own_lib, .own_face = own_face, .hb_font = hb_font, .hb_buf = hb_buf, .features = hb_feats };
    }

    pub fn deinit(self: *Shaper, alloc: std.mem.Allocator) void {
        if (build_options.freetype) {
            if (self.hb_buf) |*b| b.destroy();
            // Destroy hb_font (holds a counted ref to own_face) first, then the
            // face, then the library that owns the face.
            if (self.hb_font) |*f| f.destroy();
            if (self.own_face) |*f| f.deinit();
            if (self.own_lib) |*l| l.deinit();
            alloc.free(self.features);
            self.* = .{};
        }
    }

    /// Shape a run into positioned glyphs. The caller owns the returned slice
    /// (`alloc.free`). Cluster values are run-relative (`run.column(cluster)`
    /// maps back to the grid). Advances/offsets are converted from Harfbuzz's
    /// 26.6 fixed-point to whole pixels (`>> 6`). Returns `error.Unimplemented`
    /// when there is no font (no-freetype, or a default-constructed shaper).
    pub fn shape(
        self: *Shaper,
        alloc: std.mem.Allocator,
        run: Run,
        cells: []const Cell,
    ) ![]ShapedGlyph {
        if (!build_options.freetype) return error.Unimplemented;

        const hb_font = self.hb_font orelse return error.Unimplemented;
        const buf = self.hb_buf orelse return error.Unimplemented;

        buf.reset();
        // After reset the buffer's content type is INVALID; mark it as Unicode
        // input so `guessSegmentProperties`/`hb_shape` accept it (they assert the
        // buffer holds Unicode before shaping).
        buf.setContentType(.unicode);
        // Feed the run's cells with the cluster = run-relative cell index, so a
        // shaped glyph maps back to its starting column via `run.column`.
        // Spacer-tail cells carry no codepoint of their own (the wide char owns
        // both cells); skip them so Harfbuzz doesn't see a stray U+0000.
        var added: usize = 0;
        var i: usize = 0;
        while (i < run.len) : (i += 1) {
            const cell = cells[run.start + i];
            // Skip spacer tails AND empty cells (cp 0 — unwritten grid cells such
            // as a row's trailing blanks); feeding U+0000 would shape to .notdef
            // and draw a box. Spaces (0x20) ARE fed (real space glyphs, no ink).
            if (cell.width == .spacer_tail or cell.codepoint == 0) continue;
            buf.add(cell.codepoint, @intCast(i));
            added += 1;
        }
        // An all-blank run feeds nothing; shaping an empty buffer makes
        // hb_buffer_get_glyph_infos return null (a panic). Emit no glyphs.
        if (added == 0) return alloc.alloc(ShapedGlyph, 0);

        buf.guessSegmentProperties();
        buf.setDirection(.ltr);
        harfbuzz.shape(hb_font, buf, if (self.features.len > 0) self.features else null);

        const infos = buf.getGlyphInfos();
        const pos = buf.getGlyphPositions() orelse return error.ShapeFailed;
        std.debug.assert(infos.len == pos.len);

        const out = try alloc.alloc(ShapedGlyph, infos.len);
        errdefer alloc.free(out);
        for (infos, pos, 0..) |info, p, j| {
            out[j] = .{
                .glyph_index = info.codepoint, // a glyph index after shaping
                .cluster = info.cluster,
                .x_advance = p.x_advance >> 6,
                .y_advance = p.y_advance >> 6,
                .x_offset = p.x_offset >> 6,
                .y_offset = p.y_offset >> 6,
            };
        }
        return out;
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

test "shaper: a default-constructed shaper is seamed (no font)" {
    // A shaper with no font (no-freetype, or before init) returns Unimplemented,
    // so the renderer falls back to its per-cell glyph path.
    const cells = [_]Cell{.{ .codepoint = 'x' }};
    var sh: Shaper = .{};
    try testing.expectError(error.Unimplemented, sh.shape(testing.allocator, .{ .start = 0, .len = 1, .style = .regular }, &cells));
}

test "shaper: a font-backed shaper shapes a run into glyphs (#79)" {
    if (!build_options.freetype) return error.SkipZigTest;
    const path = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf";
    std.fs.accessAbsolute(path, .{}) catch return error.SkipZigTest;
    const alloc = testing.allocator;

    // The shaper opens its OWN FreeType library + face from `path` (#79), so it
    // needs only the path + size.
    var sh = try Shaper.init(alloc, path, 24, &.{});
    defer sh.deinit(alloc);

    // "Hi" — two narrow ASCII cells, one run, no ligature: two glyphs whose
    // clusters are the two cell indices, each with a positive advance.
    const cells = [_]Cell{ .{ .codepoint = 'H' }, .{ .codepoint = 'i' } };
    const run: Run = .{ .start = 0, .len = 2, .style = .regular };
    const glyphs = try sh.shape(alloc, run, &cells);
    defer alloc.free(glyphs);

    try testing.expectEqual(@as(usize, 2), glyphs.len);
    try testing.expectEqual(@as(u32, 0), glyphs[0].cluster);
    try testing.expectEqual(@as(u32, 1), glyphs[1].cluster);
    for (glyphs) |g| {
        try testing.expect(g.glyph_index != 0); // a real glyph, not .notdef
        try testing.expect(g.x_advance > 0); // monospace advance in pixels
    }
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
