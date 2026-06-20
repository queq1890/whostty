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
        if (c.FT_Set_Pixel_Sizes(face.handle, 0, px) != 0) return error.SetPixelSizeFailed;
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

    /// Rasterize a single Unicode codepoint to an 8-bit alpha bitmap.
    pub fn rasterize(self: Face, alloc: std.mem.Allocator, codepoint: u32) !Glyph {
        const idx = self.inner.getCharIndex(codepoint) orelse 0;
        try self.inner.loadGlyph(idx, .{ .render = true });

        const slot = self.inner.handle.*.glyph;
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
                const row_off: i64 = @as(i64, @intCast(y)) * pitch;
                const src_row: [*]const u8 = if (pitch >= 0)
                    src + @as(usize, @intCast(row_off))
                else
                    src + @as(usize, @intCast(@as(i64, @intCast((height - 1 - y))) * (-pitch)));
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
};

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

    var g = try face.rasterize(std.testing.allocator, 'A');
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
    var g = try face.rasterize(std.testing.allocator, ' ');
    defer g.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), g.width);
    try std.testing.expectEqual(@as(u32, 0), g.height);
    try std.testing.expectEqual(@as(usize, 0), g.pixels.len);
    try std.testing.expect(g.advance > 0);
}
