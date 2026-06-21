//! whostty: on-demand glyph cache.
//!
//! Reference: ghostty `src/font/` (glyph cache + atlas; strategy: port — a
//! slice of it). The bring-up renderer pre-rasterized only printable ASCII into
//! a fixed array, so every non-ASCII codepoint (accents, box-drawing, symbols)
//! drew blank. This rasterizes ANY codepoint the face supports on first sight,
//! packs it into the atlas, and caches the placement, marking the atlas dirty so
//! the caller re-uploads the GL texture. It is the foundation the per-codepoint
//! fallback (#75), styled faces (#77), and decoration sprites (#80) build on.
//!
//! Only compiled when `-Dfreetype` is set (it owns a Freetype face). See
//! PORTING.md.
const std = @import("std");
const Atlas = @import("Atlas.zig");
const font = @import("main.zig");
const sprite = @import("sprite.zig");

const GlyphCache = @This();
const log = std.log.scoped(.font);

/// Cache key: an id (a codepoint, or a shaped glyph index when `by_index`) plus
/// its synthetic style. The same id in regular / bold / italic / bold-italic
/// packs four distinct atlas entries. `by_index` keeps shaped-glyph entries (#79)
/// from colliding with codepoint entries that happen to share the numeric value
/// (a glyph index is not a codepoint).
pub const Key = struct {
    id: u32,
    by_index: bool = false,
    bold: bool = false,
    italic: bool = false,
};

alloc: std.mem.Allocator,
lib: font.Library,
/// null when the configured face could not be opened (missing font / bring-up):
/// every lookup then misses (unless a fallback has the glyph) and the renderer
/// draws blank, as before.
face: ?font.Face,
/// Pixel size faces are opened at; fallback faces added later use it too.
px: u32,
/// Per-codepoint fallback faces (#75), tried in order when the primary face
/// lacks a glyph — so CJK / symbols / rare scripts render from another font
/// instead of drawing blank. Empty by default (behaves exactly as before).
fallbacks: std.ArrayListUnmanaged(font.Face),
atlas: Atlas,
/// RGBA atlas for color glyphs (emoji, #78). Separate from `atlas` because color
/// glyphs are 4 bytes/texel and sampled untinted.
color_atlas: Atlas,
/// (codepoint, style) -> placement, or a cached null meaning "draw nothing" (a
/// blank glyph such as space, a codepoint the face lacks, or the atlas being
/// full) so we don't re-attempt it every frame.
map: std.AutoHashMapUnmanaged(Key, ?Atlas.Placement),
cell_w: u32,
cell_h: u32,
ascent: u32,
/// The alpha atlas changed since the last GL upload; the caller re-uploads and
/// clears this via `takeDirty`.
dirty: bool,
/// The color atlas changed since the last GL upload (`takeColorDirty`).
color_dirty: bool,

/// Open `path` at `px` pixels and prepare an empty `atlas_size`-square atlas.
/// A missing/unreadable face is not fatal: the cache keeps working with a null
/// face (blank glyphs) and default metrics, matching the non-freetype build.
/// Only errors on out-of-memory (atlas / library).
pub fn init(alloc: std.mem.Allocator, path: [:0]const u8, px: u32, atlas_size: u32) !GlyphCache {
    var atlas = try Atlas.init(alloc, atlas_size);
    errdefer atlas.deinit(alloc);
    var color_atlas = try Atlas.initBpp(alloc, atlas_size, 4);
    errdefer color_atlas.deinit(alloc);
    var lib = try font.Library.init();
    errdefer lib.deinit();

    // Defaults used when the face can't be opened.
    var cell_w: u32 = @max(1, px / 2);
    var cell_h: u32 = @max(1, px);
    var ascent: u32 = @max(1, (px * 3) / 4);
    var face: ?font.Face = null;
    if (font.Face.init(lib, path, px)) |f| {
        face = f;
        const m = f.metrics();
        cell_w = m.cell_width;
        cell_h = m.cell_height;
        ascent = m.ascent;
    } else |err| {
        log.warn("font face '{s}' unavailable ({s}); rendering blank glyphs", .{ path, @errorName(err) });
    }

    return .{
        .alloc = alloc,
        .lib = lib,
        .face = face,
        .px = px,
        .fallbacks = .empty,
        .atlas = atlas,
        .color_atlas = color_atlas,
        .map = .empty,
        .cell_w = cell_w,
        .cell_h = cell_h,
        .ascent = ascent,
        .dirty = false,
        .color_dirty = false,
    };
}

/// Append a fallback face opened from `path` at the cache's pixel size (#75). A
/// missing/unreadable path is skipped with a warning (best-effort — a terminal
/// should still run if a fallback font isn't installed). Call after `init`,
/// before rendering; fallbacks are tried in the order added.
pub fn addFallback(self: *GlyphCache, path: [:0]const u8) void {
    if (font.Face.init(self.lib, path, self.px)) |f| {
        self.fallbacks.append(self.alloc, f) catch {
            var ff = f;
            ff.deinit();
        };
    } else |err| {
        log.warn("fallback font '{s}' unavailable ({s}); skipping", .{ path, @errorName(err) });
    }
}

pub fn deinit(self: *GlyphCache) void {
    self.map.deinit(self.alloc);
    if (self.face) |*f| f.deinit();
    for (self.fallbacks.items) |*f| f.deinit();
    self.fallbacks.deinit(self.alloc);
    self.lib.deinit();
    self.atlas.deinit(self.alloc);
    self.color_atlas.deinit(self.alloc);
    self.* = undefined;
}

/// The atlas placement for `cp` in the given synthetic style, rasterizing and
/// packing it on first sight. A null result means "draw no glyph" (blank/space,
/// a missing glyph, or the atlas being full). Packing a new glyph marks the
/// atlas dirty.
pub fn get(self: *GlyphCache, cp: u21, bold: bool, italic: bool) ?Atlas.Placement {
    const key: Key = .{ .id = cp, .by_index = false, .bold = bold, .italic = italic };
    if (self.map.get(key)) |cached| return cached;
    // Secure the map slot BEFORE packing, so a glyph we rasterize can always be
    // cached. Otherwise an out-of-memory `put` would drop the entry and the next
    // frame would re-rasterize the same key into a *fresh* atlas region —
    // leaking atlas space and re-uploading every frame. On OOM here we touch
    // neither the atlas nor the map and just draw blank this frame (cheap retry
    // next frame).
    self.map.ensureUnusedCapacity(self.alloc, 1) catch return null;
    const placed = self.rasterizeAndPack(key);
    self.map.putAssumeCapacity(key, placed);
    if (placed) |p| {
        if (p.color) self.color_dirty = true else self.dirty = true;
    }
    return placed;
}

/// Whether `cp` defaults to emoji (color) presentation, so a color-capable
/// fallback should be preferred even if an earlier monochrome face also carries
/// the glyph (#78). Approximates the Unicode Emoji_Presentation property with the
/// astral emoji/pictograph planes — virtually all emoji-presentation by default.
/// Text-presentation BMP symbols (dingbats / misc-symbols without VS16) keep the
/// normal monochrome order; full VS15/VS16 selector handling is future work.
fn wantsEmoji(cp: u21) bool {
    return cp >= 0x1F000 and cp <= 0x1FAFF;
}

/// The face to draw `cp` from: the primary if it has the glyph, else the first
/// fallback that does (#75), else null (draw nothing — blank, not the .notdef
/// box). For emoji-presentation codepoints a color-capable fallback is preferred
/// over a monochrome face that merely also has the glyph, so emoji render in
/// color rather than as a monochrome symbol-font glyph (#78).
fn faceFor(self: *GlyphCache, cp: u21) ?*font.Face {
    if (wantsEmoji(cp)) {
        for (self.fallbacks.items) |*f| {
            if (f.hasColor() and f.glyphIndex(cp) != null) return f;
        }
    }
    if (self.face) |*f| {
        if (f.glyphIndex(cp) != null) return f;
    }
    for (self.fallbacks.items) |*f| {
        if (f.glyphIndex(cp) != null) return f;
    }
    return null;
}

fn rasterizeAndPack(self: *GlyphCache, key: Key) ?Atlas.Placement {
    // This is the codepoint path; `key.id` is a Unicode codepoint (never a glyph
    // index — those go through `rasterizeIndexAndPack`).
    const cp: u21 = @intCast(key.id);
    // Built-in sprite glyphs (block elements, braille) are drawn procedurally so
    // they are crisp and present regardless of the font (#76), filling the whole
    // cell. Tried before the font face; style (bold/italic) doesn't apply.
    if (sprite.rasterize(self.alloc, cp, self.cell_w, self.cell_h) catch null) |pixels| {
        defer self.alloc.free(pixels);
        const region = self.atlas.reserve(self.cell_w, self.cell_h) catch return null;
        self.atlas.set(region, pixels);
        // bearing_y = ascent so the cell-sized sprite sits flush at the cell top
        // (buildQuads draws at cell_y + ascent - bearing_y); no horizontal bearing.
        return .{ .region = region, .bearing_x = 0, .bearing_y = @intCast(self.ascent) };
    }

    const face = self.faceFor(cp) orelse return null;

    // Color glyphs (emoji) from a color-capable face are packed into the RGBA
    // color atlas, filling the cell and drawn untinted (#78). Only attempted for
    // color faces, so normal text pays nothing.
    if (face.hasColor()) {
        if (face.rasterizeColor(self.alloc, cp, self.cell_w, self.cell_h) catch null) |cg_const| {
            var cg = cg_const;
            defer cg.deinit(self.alloc);
            const region = self.color_atlas.reserve(cg.width, cg.height) catch return null;
            self.color_atlas.set(region, cg.pixels);
            return .{ .region = region, .bearing_x = 0, .bearing_y = @intCast(self.ascent), .color = true };
        }
    }

    var g = face.rasterize(self.alloc, cp, .{ .bold = key.bold, .italic = key.italic }) catch return null;
    defer g.deinit(self.alloc);
    // A zero-area bitmap (space, control) has no quad.
    if (g.width == 0 or g.height == 0) return null;
    const region = self.atlas.reserve(g.width, g.height) catch return null;
    self.atlas.set(region, g.pixels);
    return .{ .region = region, .bearing_x = g.bearing_x, .bearing_y = g.bearing_y };
}

/// The atlas placement for a shaped glyph index (#79), rasterizing and packing
/// it on first sight. Distinct from `get`: the input is a FreeType glyph index
/// from `Shaper.shape`, not a codepoint, so it is rendered via the PRIMARY face
/// by index (`rasterizeIndex`) into the ALPHA atlas. Sprites and color glyphs do
/// NOT take this path — the renderer only shapes runs with no sprite cells and
/// fully covered by the primary face, so shaped glyphs are always plain alpha
/// outlines. A null result means "draw nothing" (no primary face, or a zero-area
/// bitmap). Packing marks the alpha atlas dirty.
pub fn getByIndex(self: *GlyphCache, glyph_index: u32, bold: bool, italic: bool) ?Atlas.Placement {
    const key: Key = .{ .id = glyph_index, .by_index = true, .bold = bold, .italic = italic };
    if (self.map.get(key)) |cached| return cached;
    self.map.ensureUnusedCapacity(self.alloc, 1) catch return null;
    const placed = self.rasterizeIndexAndPack(key);
    self.map.putAssumeCapacity(key, placed);
    if (placed != null) self.dirty = true;
    return placed;
}

fn rasterizeIndexAndPack(self: *GlyphCache, key: Key) ?Atlas.Placement {
    const face = if (self.face) |*f| f else return null;
    var g = face.rasterizeIndex(self.alloc, key.id, .{ .bold = key.bold, .italic = key.italic }) catch return null;
    defer g.deinit(self.alloc);
    // A zero-area bitmap (e.g. a space glyph in a ligature run) has no quad.
    if (g.width == 0 or g.height == 0) return null;
    const region = self.atlas.reserve(g.width, g.height) catch return null;
    self.atlas.set(region, g.pixels);
    return .{ .region = region, .bearing_x = g.bearing_x, .bearing_y = g.bearing_y };
}

/// Whether the alpha atlas changed since the last call, clearing the flag. The
/// caller re-uploads the glyph texture (`Renderer.setAtlas`) when true.
pub fn takeDirty(self: *GlyphCache) bool {
    const d = self.dirty;
    self.dirty = false;
    return d;
}

/// Whether the color (emoji) atlas changed since the last call, clearing the
/// flag. The caller re-uploads it (`Renderer.setColorAtlas`) when true (#78).
pub fn takeColorDirty(self: *GlyphCache) bool {
    const d = self.color_dirty;
    self.color_dirty = false;
    return d;
}

const test_font = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf";

test "glyphcache: rasterizes ASCII + non-ASCII on demand and caches" {
    std.fs.accessAbsolute(test_font, .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var cache = try GlyphCache.init(alloc, test_font, 16, 256);
    defer cache.deinit();

    try std.testing.expect(cache.cell_w > 0 and cache.cell_h > 0);

    // ASCII 'A' packs and dirties the atlas.
    const a = cache.get('A', false, false) orelse return error.NoGlyph;
    try std.testing.expect(a.region.width > 0 and a.region.height > 0);
    try std.testing.expect(cache.takeDirty()); // was dirtied
    try std.testing.expect(!cache.takeDirty()); // and cleared

    // Same codepoint returns the cached placement without re-dirtying.
    const a2 = cache.get('A', false, false) orelse return error.NoGlyph;
    try std.testing.expectEqual(a.region.x, a2.region.x);
    try std.testing.expect(!cache.takeDirty());

    // Non-ASCII the face supports: U+2500 BOX DRAWINGS LIGHT HORIZONTAL and
    // U+00E9 LATIN SMALL LETTER E WITH ACUTE both rasterize (the whole point).
    try std.testing.expect(cache.get(0x2500, false, false) != null);
    try std.testing.expect(cache.get(0x00E9, false, false) != null);
    try std.testing.expect(cache.takeDirty());
}

test "glyphcache: regular/bold/italic are distinct, cached entries" {
    std.fs.accessAbsolute(test_font, .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var cache = try GlyphCache.init(alloc, test_font, 32, 512);
    defer cache.deinit();

    const reg = cache.get('H', false, false) orelse return error.NoGlyph;
    const bold = cache.get('H', true, false) orelse return error.NoGlyph;
    const ital = cache.get('H', false, true) orelse return error.NoGlyph;

    // Each style packs its own atlas region, so the cache keys them apart.
    try std.testing.expect(bold.region.x != reg.region.x or bold.region.y != reg.region.y);
    try std.testing.expect(ital.region.x != reg.region.x or ital.region.y != reg.region.y);
    try std.testing.expect(bold.region.x != ital.region.x or bold.region.y != ital.region.y);

    // A repeat styled lookup hits the cache (same region, no re-pack/dirty).
    _ = cache.takeDirty();
    const bold2 = cache.get('H', true, false) orelse return error.NoGlyph;
    try std.testing.expectEqual(bold.region.x, bold2.region.x);
    try std.testing.expectEqual(bold.region.y, bold2.region.y);
    try std.testing.expect(!cache.takeDirty());
}

test "glyphcache: blank glyphs and atlas-full cache a null without crashing" {
    std.fs.accessAbsolute(test_font, .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var cache = try GlyphCache.init(alloc, test_font, 16, 256);
    defer cache.deinit();

    // A space has a zero-area bitmap -> null, cached, no dirty.
    try std.testing.expect(cache.get(' ', false, false) == null);
    try std.testing.expect(!cache.takeDirty());
    // Cached: still null on the second call.
    try std.testing.expect(cache.get(' ', false, false) == null);
}

test "glyphcache: a missing face is not fatal; every lookup misses" {
    const alloc = std.testing.allocator;
    var cache = try GlyphCache.init(alloc, "Z:\\does\\not\\exist.ttf", 16, 64);
    defer cache.deinit();
    try std.testing.expect(cache.face == null);
    try std.testing.expect(cache.get('A', false, false) == null);
    try std.testing.expect(!cache.takeDirty());
    // Default metrics are still positive so the grid math is well-defined.
    try std.testing.expect(cache.cell_w > 0 and cache.cell_h > 0);
}

test "glyphcache: a codepoint the face lacks draws nothing (no .notdef box)" {
    std.fs.accessAbsolute(test_font, .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var cache = try GlyphCache.init(alloc, test_font, 16, 256);
    defer cache.deinit();
    // DejaVuSansMono has no CJK; U+4E00 (一) must render as blank, not a box.
    try std.testing.expect(cache.get(0x4E00, false, false) == null);
    try std.testing.expect(!cache.takeDirty());
}

const cjk_fallback = "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc";

test "glyphcache: a fallback face renders a glyph the primary lacks (#75)" {
    std.fs.accessAbsolute(test_font, .{}) catch return error.SkipZigTest;
    std.fs.accessAbsolute(cjk_fallback, .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var cache = try GlyphCache.init(alloc, test_font, 24, 512);
    defer cache.deinit();

    // Fallbacks are added right after init, before any glyph is cached (adding
    // one later would not revisit a codepoint already cached as "draw nothing").
    cache.addFallback(cjk_fallback);

    // U+4E00 (一), which the primary DejaVu lacks, now packs a real glyph from
    // the CJK fallback instead of drawing blank.
    const placed = cache.get(0x4E00, false, false) orelse return error.NoFallbackGlyph;
    try std.testing.expect(placed.region.width > 0 and placed.region.height > 0);
    try std.testing.expect(cache.takeDirty());

    // ASCII still comes from the primary face; a codepoint NEITHER face has
    // still draws nothing (no fallback can fill it).
    try std.testing.expect(cache.get('A', false, false) != null);
    try std.testing.expect(cache.get(0x10FFFF, false, false) == null);
}

test "glyphcache: sprite glyphs are drawn procedurally, cell-sized, font-independent (#76)" {
    std.fs.accessAbsolute(test_font, .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var cache = try GlyphCache.init(alloc, test_font, 24, 512);
    defer cache.deinit();

    // U+2588 FULL BLOCK is a sprite: it packs a full cell-sized region (the
    // procedural path reserves cell_w x cell_h), not a font-glyph-sized one, and
    // sits flush at the cell top (bearing_y == ascent, no horizontal bearing).
    const block = cache.get(0x2588, false, false) orelse return error.NoSprite;
    try std.testing.expectEqual(cache.cell_w, block.region.width);
    try std.testing.expectEqual(cache.cell_h, block.region.height);
    try std.testing.expectEqual(@as(i32, 0), block.bearing_x);
    try std.testing.expectEqual(@as(i32, @intCast(cache.ascent)), block.bearing_y);

    // A braille pattern is likewise a sprite, cell-sized.
    const br = cache.get(0x28FF, false, false) orelse return error.NoBraille;
    try std.testing.expectEqual(cache.cell_w, br.region.width);
}

const emoji_font = "/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf";

test "glyphcache: a color-emoji fallback packs into the color atlas (#78)" {
    std.fs.accessAbsolute(test_font, .{}) catch return error.SkipZigTest;
    std.fs.accessAbsolute(emoji_font, .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var cache = try GlyphCache.init(alloc, test_font, 24, 512);
    defer cache.deinit();
    cache.addFallback(emoji_font);

    // U+1F600 (😀): the primary lacks it; the color fallback packs a cell-sized
    // region into the COLOR atlas, flagged color=true, dirtying the color atlas.
    const e = cache.get(0x1F600, false, false) orelse return error.NoEmoji;
    try std.testing.expect(e.color);
    try std.testing.expectEqual(cache.cell_w, e.region.width);
    try std.testing.expectEqual(cache.cell_h, e.region.height);
    try std.testing.expect(cache.takeColorDirty()); // color atlas dirtied
    try std.testing.expect(!cache.takeColorDirty()); // and cleared
    try std.testing.expect(!cache.takeDirty()); // the alpha atlas was untouched

    // A plain ASCII glyph still goes to the alpha atlas (not color).
    const a = cache.get('A', false, false) orelse return error.NoA;
    try std.testing.expect(!a.color);
    try std.testing.expect(cache.takeDirty());
    try std.testing.expect(!cache.takeColorDirty());
}

test "glyphcache: getByIndex packs a shaped glyph keyed distinctly from codepoints (#79)" {
    std.fs.accessAbsolute(test_font, .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var cache = try GlyphCache.init(alloc, test_font, 24, 512);
    defer cache.deinit();
    const face = &cache.face.?;

    // The glyph index for 'A'. getByIndex packs it into the alpha atlas.
    const idx = face.glyphIndex('A') orelse return error.NoIndex;
    const by_idx = cache.getByIndex(idx, false, false) orelse return error.NoGlyph;
    try std.testing.expect(by_idx.region.width > 0 and by_idx.region.height > 0);
    try std.testing.expect(!by_idx.color); // alpha atlas, not color
    try std.testing.expect(cache.takeDirty());

    // A second call hits the cache: same region, no re-dirty.
    const by_idx2 = cache.getByIndex(idx, false, false) orelse return error.NoGlyph;
    try std.testing.expectEqual(by_idx.region.x, by_idx2.region.x);
    try std.testing.expectEqual(by_idx.region.y, by_idx2.region.y);
    try std.testing.expect(!cache.takeDirty());

    // The index key is distinct from the codepoint key even when the numeric
    // value collides: get(idx-as-codepoint) packs its OWN region, untouched by
    // the by-index entry above.
    const cp_same_num = cache.get(@intCast(idx), false, false);
    if (cp_same_num) |p| {
        try std.testing.expect(p.region.x != by_idx.region.x or p.region.y != by_idx.region.y);
    }

    // A missing-face cache returns null from getByIndex (no primary face).
    var blank = try GlyphCache.init(alloc, "Z:\\nope.ttf", 16, 64);
    defer blank.deinit();
    try std.testing.expect(blank.face == null);
    try std.testing.expect(blank.getByIndex(1, false, false) == null);
}

test "glyphcache: sprites render even when the primary font is missing" {
    const alloc = std.testing.allocator;
    var cache = try GlyphCache.init(alloc, "Z:\\does\\not\\exist.ttf", 24, 512);
    defer cache.deinit();
    try std.testing.expect(cache.face == null);
    // Letters draw nothing (no face), but a sprite is procedural -> still packs.
    try std.testing.expect(cache.get('A', false, false) == null);
    try std.testing.expect(cache.get(0x2588, false, false) != null);
}
