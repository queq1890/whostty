//! whostty: font subsystem — Freetype glyph rasterization.
//!
//! Reference: ghostty `src/font/main.zig` (strategy: port — ghostty's font
//! stack is large (discovery, shaping, atlas, fallback); slice-0 keeps just
//! enough to rasterize monospace ASCII glyphs to 8-bit alpha bitmaps via
//! Freetype). Shaping (Harfbuzz) and DirectWrite discovery are later work.
//! See PORTING.md.
const std = @import("std");
const freetype = @import("freetype");

const c = freetype.c;

pub const Library = freetype.Library;

/// Byte pointer to row `r` of a FreeType bitmap. FreeType defines `pitch` as
/// "the offset to add to a bitmap pointer to go down one row" *in all cases*, so
/// row `r` is `buffer + r*pitch` for both a positive (top-down) and a negative
/// (bottom-up) pitch — a single signed formula, no sign branch (which would read
/// out of bounds for bottom-up bitmaps).
fn bitmapRow(buffer: [*]const u8, r: u32, pitch: i32) [*]const u8 {
    const off: isize = @as(isize, @intCast(r)) * @as(isize, pitch);
    return @ptrFromInt(@as(usize, @intFromPtr(buffer)) +% @as(usize, @bitCast(off)));
}

/// A rasterized glyph: an 8-bit alpha coverage bitmap plus placement metrics.
pub const Glyph = struct {
    /// Bitmap dimensions in pixels.
    width: u32,
    height: u32,
    /// Bearing: offset from the pen origin to the top-left of the bitmap.
    bearing_x: i32,
    bearing_y: i32,
    /// Horizontal advance in whole pixels.
    advance: u32,
    /// width*height bytes of coverage (0..255), owned by the caller.
    pixels: []u8,

    pub fn deinit(self: *Glyph, alloc: std.mem.Allocator) void {
        alloc.free(self.pixels);
        self.* = undefined;
    }
};

/// A rasterized color glyph (e.g. emoji): a straight-alpha RGBA bitmap already
/// scaled to the target cell. Separate from `Glyph` because it carries 4 bytes
/// per texel and is sampled directly (not tinted by the cell's foreground). #78.
pub const ColorGlyph = struct {
    width: u32,
    height: u32,
    /// RGBA, straight (non-premultiplied) alpha; `width*height*4` bytes.
    pixels: []u8,

    pub fn deinit(self: *ColorGlyph, alloc: std.mem.Allocator) void {
        alloc.free(self.pixels);
        self.* = undefined;
    }
};

/// Cell metrics for a monospace face at a given pixel size.
pub const Metrics = struct {
    cell_width: u32,
    cell_height: u32,
    /// Baseline offset from the top of the cell.
    ascent: u32,
};

pub const Face = struct {
    inner: freetype.Face,
    px: u32,

    pub fn init(lib: Library, path: [:0]const u8, px: u32) !Face {
        const face = try lib.initFace(path, 0);
        errdefer face.deinit();
        if (c.FT_Set_Pixel_Sizes(face.handle, 0, px) != 0) {
            // Bitmap-strike fonts (e.g. color-emoji like Noto Color Emoji) have
            // only fixed sizes, so setting an arbitrary pixel size fails; select
            // the first available strike instead. Color glyphs are downscaled to
            // the cell at rasterize time (#78).
            if (face.handle.*.num_fixed_sizes > 0 and c.FT_Select_Size(face.handle, 0) == 0) {
                return .{ .inner = face, .px = px };
            }
            return error.SetPixelSizeFailed;
        }
        return .{ .inner = face, .px = px };
    }

    pub fn deinit(self: *Face) void {
        self.inner.deinit();
        self.* = undefined;
    }

    /// Monospace cell metrics derived from the face's global size metrics.
    pub fn metrics(self: Face) Metrics {
        const size = self.inner.handle.*.size.*.metrics;
        // 26.6 fixed-point -> pixels.
        const advance: u32 = @intCast(@as(i64, @intCast(size.max_advance)) >> 6);
        const ascent: u32 = @intCast(@as(i64, @intCast(size.ascender)) >> 6);
        const height: u32 = @intCast(@as(i64, @intCast(size.height)) >> 6);
        return .{
            .cell_width = if (advance == 0) self.px / 2 else advance,
            .cell_height = if (height == 0) self.px else height,
            .ascent = ascent,
        };
    }

    /// The face's glyph index for `codepoint`, or null if the face has no glyph
    /// for it. Lets a caller draw nothing (blank) for unsupported codepoints
    /// instead of the `.notdef` box, pending per-codepoint fallback (#75).
    pub fn glyphIndex(self: Face, codepoint: u32) ?u32 {
        return self.inner.getCharIndex(codepoint);
    }

    /// Synthetic styling applied to a rasterized glyph when a dedicated styled
    /// face isn't available — whostty loads a single face, so bold/italic are
    /// synthesized by transforming the regular outline (matching ghostty's
    /// fallback). Per-style families (`font-family-bold` etc.) are deferred.
    pub const Style = struct {
        bold: bool = false,
        italic: bool = false,
    };

    /// Rasterize a single Unicode codepoint to an 8-bit alpha bitmap, optionally
    /// synthesizing bold (embolden the outline) and/or italic (shear the
    /// outline) before rendering.
    pub fn rasterize(self: Face, alloc: std.mem.Allocator, codepoint: u32, style: Style) !Glyph {
        const idx = self.inner.getCharIndex(codepoint) orelse 0;
        // Load the outline WITHOUT rendering so synthetic styling can transform
        // it; then render. (`render = true` would rasterize the plain glyph.)
        try self.inner.loadGlyph(idx, .{});

        const slot = self.inner.handle.*.glyph;
        // Only outline glyphs can be transformed; bitmap (color/emoji) faces are
        // rendered as-is. Apply italic shear before embolden so the slant uses
        // the original stroke weight.
        if ((style.italic or style.bold) and slot.*.format == c.FT_GLYPH_FORMAT_OUTLINE) {
            if (style.italic) {
                // 16.16 shear matrix: x' = x + 0.2*y -> ~11.3° rightward slant.
                var m: c.FT_Matrix = .{ .xx = 0x10000, .xy = 0x3333, .yx = 0, .yy = 0x10000 };
                c.FT_Outline_Transform(&slot.*.outline, &m);
            }
            if (style.bold) {
                // Embolden ~ px/24 px (26.6 units); proportional so it reads at
                // any size. Ignore the error: failure leaves the regular outline.
                const strength: c.FT_Pos = @divTrunc(@as(c.FT_Pos, @intCast(self.px)) * 64, 24);
                _ = c.FT_Outline_Embolden(&slot.*.outline, strength);
            }
        }
        try self.inner.renderGlyph(.normal);

        const bm = slot.*.bitmap;
        const width: u32 = bm.width;
        const height: u32 = bm.rows;

        const pixels = try alloc.alloc(u8, width * height);
        errdefer alloc.free(pixels);

        // An empty bitmap (e.g. the space glyph) has zero extent and a null
        // `buffer`; @ptrCast of null to a non-optional pointer would panic, so
        // skip the copy entirely and return the empty glyph.
        if (width != 0 and height != 0) {
            // Copy row by row honoring pitch (may be negative for bottom-up).
            const pitch: i32 = bm.pitch;
            const src: [*]const u8 = @ptrCast(bm.buffer);
            var y: u32 = 0;
            while (y < height) : (y += 1) {
                const src_row = bitmapRow(src, y, pitch);
                @memcpy(pixels[y * width ..][0..width], src_row[0..width]);
            }
        }

        return .{
            .width = width,
            .height = height,
            .bearing_x = slot.*.bitmap_left,
            .bearing_y = slot.*.bitmap_top,
            .advance = @intCast(@as(i64, @intCast(slot.*.advance.x)) >> 6),
            .pixels = pixels,
        };
    }

    /// Whether this face carries embedded color bitmaps (emoji strikes). Used to
    /// decide whether to attempt the color path before the alpha path (#78).
    pub fn hasColor(self: Face) bool {
        // FT_FACE_FLAG_COLOR = 1 << 14.
        return (self.inner.handle.*.face_flags & (1 << 14)) != 0;
    }

    /// Rasterize `codepoint` as a color glyph (BGRA emoji bitmap) scaled to fill
    /// a `cell_w` x `cell_h` cell, returned as straight-alpha RGBA, or null if the
    /// face has no color glyph for it. The emoji's native bitmap strike is
    /// nearest-neighbor scaled to the cell (aspect not preserved — a slice; true
    /// wide-cell emoji sizing rides with wide-char support). #78.
    pub fn rasterizeColor(self: Face, alloc: std.mem.Allocator, codepoint: u32, cell_w: u32, cell_h: u32) !?ColorGlyph {
        if (cell_w == 0 or cell_h == 0) return null;
        const idx = self.inner.getCharIndex(codepoint) orelse return null;
        // Render to a BGRA bitmap: this covers both embedded-bitmap color fonts
        // (CBDT, e.g. Noto Color Emoji — needs Freetype built with PNG) and
        // layered-vector color fonts (COLR/CPAL, e.g. Segoe UI Emoji, which
        // Freetype composites into a bitmap).
        self.inner.loadGlyph(idx, .{ .color = true, .render = true }) catch return null;

        const slot = self.inner.handle.*.glyph;
        const bm = slot.*.bitmap;
        // Only true color (BGRA) bitmaps take this path; anything else (a normal
        // outline/alpha glyph) is left to `rasterize`.
        if (bm.pixel_mode != c.FT_PIXEL_MODE_BGRA) return null;
        const sw: u32 = bm.width;
        const sh: u32 = bm.rows;
        if (sw == 0 or sh == 0) return null;

        const out = try alloc.alloc(u8, cell_w * cell_h * 4);
        errdefer alloc.free(out);

        const src: [*]const u8 = @ptrCast(bm.buffer);
        const pitch: i32 = bm.pitch;
        var ty: u32 = 0;
        while (ty < cell_h) : (ty += 1) {
            const sy = ty * sh / cell_h; // nearest-neighbor
            const src_row = bitmapRow(src, sy, pitch);
            var tx: u32 = 0;
            while (tx < cell_w) : (tx += 1) {
                const sx = tx * sw / cell_w;
                const sp = src_row + sx * 4; // BGRA
                const b = sp[0];
                const g = sp[1];
                const r = sp[2];
                const a = sp[3];
                const o = (ty * cell_w + tx) * 4;
                // BGRA premultiplied -> RGBA straight (un-premultiply by alpha).
                if (a == 0) {
                    out[o + 0] = 0;
                    out[o + 1] = 0;
                    out[o + 2] = 0;
                    out[o + 3] = 0;
                } else {
                    out[o + 0] = unPremul(r, a);
                    out[o + 1] = unPremul(g, a);
                    out[o + 2] = unPremul(b, a);
                    out[o + 3] = a;
                }
            }
        }

        return .{ .width = cell_w, .height = cell_h, .pixels = out };
    }
};

/// Un-premultiply one channel: `c * 255 / a`, clamped to 255.
fn unPremul(ch: u8, a: u8) u8 {
    const v = (@as(u32, ch) * 255) / @as(u32, a);
    return @intCast(@min(v, 255));
}

test "font: rasterize an ASCII glyph to a non-empty bitmap" {
    // Host-only: uses a font present on the test machine.
    const path = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf";
    std.fs.accessAbsolute(path, .{}) catch return error.SkipZigTest;

    var lib = try Library.init();
    defer lib.deinit();

    var face = try Face.init(lib, path, 16);
    defer face.deinit();

    const m = face.metrics();
    try std.testing.expect(m.cell_width > 0);
    try std.testing.expect(m.cell_height > 0);

    var g = try face.rasterize(std.testing.allocator, 'A', .{});
    defer g.deinit(std.testing.allocator);

    try std.testing.expect(g.width > 0 and g.height > 0);
    try std.testing.expectEqual(g.width * g.height, g.pixels.len);
    // 'A' should have at least one inked pixel.
    var any: bool = false;
    for (g.pixels) |p| {
        if (p != 0) {
            any = true;
            break;
        }
    }
    try std.testing.expect(any);
}

test "font: space glyph has zero-area bitmap but positive advance" {
    const path = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf";
    std.fs.accessAbsolute(path, .{}) catch return error.SkipZigTest;

    var lib = try Library.init();
    defer lib.deinit();
    var face = try Face.init(lib, path, 16);
    defer face.deinit();

    // Regression: a space has an empty bitmap whose `buffer` is null.
    // rasterize must not @ptrCast that null pointer (which panics in safe
    // builds); it returns a zero-area glyph with no pixels.
    var g = try face.rasterize(std.testing.allocator, ' ', .{});
    defer g.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), g.width);
    try std.testing.expectEqual(@as(u32, 0), g.height);
    try std.testing.expectEqual(@as(usize, 0), g.pixels.len);
    try std.testing.expect(g.advance > 0);
}

fn inkSum(g: Glyph) u64 {
    var s: u64 = 0;
    for (g.pixels) |p| s += p;
    return s;
}

test "font: synthetic bold adds ink; italic shears the glyph" {
    const path = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf";
    std.fs.accessAbsolute(path, .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;

    var lib = try Library.init();
    defer lib.deinit();
    var face = try Face.init(lib, path, 32);
    defer face.deinit();

    var reg = try face.rasterize(alloc, 'H', .{});
    defer reg.deinit(alloc);
    var bold = try face.rasterize(alloc, 'H', .{ .bold = true });
    defer bold.deinit(alloc);
    var ital = try face.rasterize(alloc, 'H', .{ .italic = true });
    defer ital.deinit(alloc);

    // Embolden thickens strokes -> strictly more total coverage than regular.
    try std.testing.expect(inkSum(bold) > inkSum(reg));
    // Shearing leans the glyph: it widens it (top shifts right of the bottom).
    try std.testing.expect(ital.width > reg.width);
    // All three still produce a real (non-empty) bitmap.
    try std.testing.expect(reg.width > 0 and bold.width > 0 and ital.width > 0);
}

test "font: color emoji rasterizes to a cell-sized RGBA bitmap (#78)" {
    const path = "/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf";
    std.fs.accessAbsolute(path, .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;

    var lib = try Library.init();
    defer lib.deinit();
    // A bitmap-strike font: init must fall back to selecting a fixed strike.
    var face = try Face.init(lib, path, 24);
    defer face.deinit();
    try std.testing.expect(face.hasColor());

    // U+1F600 (😀) scales to the cell as straight-alpha RGBA.
    const cw: u32 = 20;
    const ch: u32 = 40;
    var cg = (try face.rasterizeColor(alloc, 0x1F600, cw, ch)) orelse return error.NoColorGlyph;
    defer cg.deinit(alloc);
    try std.testing.expectEqual(cw, cg.width);
    try std.testing.expectEqual(ch, cg.height);
    try std.testing.expectEqual(@as(usize, cw * ch * 4), cg.pixels.len);

    // It has actually-colored, opaque texels (not all transparent, and not pure
    // grey — emoji are colorful).
    var opaque_texels: u32 = 0;
    var colorful = false;
    var i: usize = 0;
    while (i < cg.pixels.len) : (i += 4) {
        const r = cg.pixels[i];
        const g = cg.pixels[i + 1];
        const b = cg.pixels[i + 2];
        const a = cg.pixels[i + 3];
        if (a > 200) opaque_texels += 1;
        if (a > 200 and (@max(r, @max(g, b)) - @min(r, @min(g, b))) > 40) colorful = true;
    }
    try std.testing.expect(opaque_texels > 0);
    try std.testing.expect(colorful);

    // A non-emoji codepoint returns null (no color glyph -> alpha path).
    try std.testing.expect((try face.rasterizeColor(alloc, 'A', cw, ch)) == null);
}
