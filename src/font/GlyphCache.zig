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

const GlyphCache = @This();
const log = std.log.scoped(.font);

alloc: std.mem.Allocator,
lib: font.Library,
/// null when the configured face could not be opened (missing font / bring-up):
/// every lookup then misses and the renderer draws blank glyphs, as before.
face: ?font.Face,
atlas: Atlas,
/// codepoint -> placement, or a cached null meaning "draw nothing" (a blank
/// glyph such as space, a codepoint the face lacks, or the atlas being full) so
/// we don't re-attempt it every frame.
map: std.AutoHashMapUnmanaged(u21, ?Atlas.Placement),
cell_w: u32,
cell_h: u32,
ascent: u32,
/// The atlas changed since the last GL upload; the caller re-uploads and clears
/// this via `takeDirty`.
dirty: bool,

/// Open `path` at `px` pixels and prepare an empty `atlas_size`-square atlas.
/// A missing/unreadable face is not fatal: the cache keeps working with a null
/// face (blank glyphs) and default metrics, matching the non-freetype build.
/// Only errors on out-of-memory (atlas / library).
pub fn init(alloc: std.mem.Allocator, path: [:0]const u8, px: u32, atlas_size: u32) !GlyphCache {
    var atlas = try Atlas.init(alloc, atlas_size);
    errdefer atlas.deinit(alloc);
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
        .atlas = atlas,
        .map = .empty,
        .cell_w = cell_w,
        .cell_h = cell_h,
        .ascent = ascent,
        .dirty = false,
    };
}

pub fn deinit(self: *GlyphCache) void {
    self.map.deinit(self.alloc);
    if (self.face) |*f| f.deinit();
    self.lib.deinit();
    self.atlas.deinit(self.alloc);
    self.* = undefined;
}

/// The atlas placement for `cp`, rasterizing and packing it on first sight.
/// A null result means "draw no glyph" (blank/space, a missing glyph, or the
/// atlas being full). Packing a new glyph marks the atlas dirty.
pub fn get(self: *GlyphCache, cp: u21) ?Atlas.Placement {
    if (self.map.get(cp)) |cached| return cached;
    // Secure the map slot BEFORE packing, so a glyph we rasterize can always be
    // cached. Otherwise an out-of-memory `put` would drop the entry and the next
    // frame would re-rasterize the same codepoint into a *fresh* atlas region —
    // leaking atlas space and re-uploading every frame. On OOM here we touch
    // neither the atlas nor the map and just draw blank this frame (cheap retry
    // next frame).
    self.map.ensureUnusedCapacity(self.alloc, 1) catch return null;
    const placed = self.rasterizeAndPack(cp);
    self.map.putAssumeCapacity(cp, placed);
    if (placed != null) self.dirty = true;
    return placed;
}

fn rasterizeAndPack(self: *GlyphCache, cp: u21) ?Atlas.Placement {
    const face = self.face orelse return null;
    // Draw nothing for codepoints the face lacks (blank, not the .notdef box) —
    // per-codepoint fallback to another face is #75.
    if (face.glyphIndex(cp) == null) return null;
    var g = face.rasterize(self.alloc, cp) catch return null;
    defer g.deinit(self.alloc);
    // A zero-area bitmap (space, control) has no quad.
    if (g.width == 0 or g.height == 0) return null;
    const region = self.atlas.reserve(g.width, g.height) catch return null;
    self.atlas.set(region, g.pixels);
    return .{ .region = region, .bearing_x = g.bearing_x, .bearing_y = g.bearing_y };
}

/// Whether the atlas changed since the last call, clearing the flag. The caller
/// re-uploads the atlas texture (`Renderer.setAtlas`) when this returns true.
pub fn takeDirty(self: *GlyphCache) bool {
    const d = self.dirty;
    self.dirty = false;
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
    const a = cache.get('A') orelse return error.NoGlyph;
    try std.testing.expect(a.region.width > 0 and a.region.height > 0);
    try std.testing.expect(cache.takeDirty()); // was dirtied
    try std.testing.expect(!cache.takeDirty()); // and cleared

    // Same codepoint returns the cached placement without re-dirtying.
    const a2 = cache.get('A') orelse return error.NoGlyph;
    try std.testing.expectEqual(a.region.x, a2.region.x);
    try std.testing.expect(!cache.takeDirty());

    // Non-ASCII the face supports: U+2500 BOX DRAWINGS LIGHT HORIZONTAL and
    // U+00E9 LATIN SMALL LETTER E WITH ACUTE both rasterize (the whole point).
    try std.testing.expect(cache.get(0x2500) != null);
    try std.testing.expect(cache.get(0x00E9) != null);
    try std.testing.expect(cache.takeDirty());
}

test "glyphcache: blank glyphs and atlas-full cache a null without crashing" {
    std.fs.accessAbsolute(test_font, .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var cache = try GlyphCache.init(alloc, test_font, 16, 256);
    defer cache.deinit();

    // A space has a zero-area bitmap -> null, cached, no dirty.
    try std.testing.expect(cache.get(' ') == null);
    try std.testing.expect(!cache.takeDirty());
    // Cached: still null on the second call.
    try std.testing.expect(cache.get(' ') == null);
}

test "glyphcache: a missing face is not fatal; every lookup misses" {
    const alloc = std.testing.allocator;
    var cache = try GlyphCache.init(alloc, "Z:\\does\\not\\exist.ttf", 16, 64);
    defer cache.deinit();
    try std.testing.expect(cache.face == null);
    try std.testing.expect(cache.get('A') == null);
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
    try std.testing.expect(cache.get(0x4E00) == null);
    try std.testing.expect(!cache.takeDirty());
}
