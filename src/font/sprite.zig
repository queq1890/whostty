//! whostty: built-in sprite glyphs (#76) — block elements and braille rendered
//! procedurally into a cell-sized alpha bitmap, so they are crisp and present
//! regardless of the font (many monospace fonts lack or misalign them).
//!
//! Reference: ghostty `src/font/sprite/` (`Box.zig`, `Canvas.zig`; strategy:
//! port a slice). This first cut covers block elements (U+2580–259F: halves,
//! eighths, quadrants, shades) and braille (U+2800–28FF). Box-drawing line
//! glyphs (U+2500–257F) are a follow-up. `GlyphCache` calls `rasterize` before
//! consulting the font face. See PORTING.md.
const std = @import("std");

/// Whether `cp` is a sprite codepoint this module rasterizes (so the cache draws
/// it procedurally instead of from the font). Box-drawing codepoints we don't
/// model (some mixed-weight / partial variants) report false and fall through to
/// the font.
pub fn isSprite(cp: u21) bool {
    return switch (cp) {
        0x2500...0x257F => boxSegments(cp) != null, // box-drawing (handled subset)
        0x2580...0x259F => true, // block elements
        0x2800...0x28FF => true, // braille patterns
        else => false,
    };
}

/// Rasterize `cp` into a freshly allocated `w*h` 8-bit alpha bitmap (row-major,
/// 0 = transparent, 255 = opaque), or null if `cp` isn't a handled sprite. The
/// caller owns the returned slice. The bitmap fills the whole cell; the cache
/// places it with the cell's full extent.
pub fn rasterize(alloc: std.mem.Allocator, cp: u21, w: u32, h: u32) std.mem.Allocator.Error!?[]u8 {
    if (!isSprite(cp) or w == 0 or h == 0) return null;
    const pixels = try alloc.alloc(u8, w * h);
    @memset(pixels, 0);
    errdefer alloc.free(pixels);
    const c: Canvas = .{ .px = pixels, .w = w, .h = h };
    switch (cp) {
        0x2500...0x257F => boxDrawing(c, cp),
        0x2580...0x259F => blockElement(c, cp),
        0x2800...0x28FF => braille(c, cp),
        else => unreachable,
    }
    return pixels;
}

/// A cell-sized alpha bitmap with clamped rectangle fills (so fraction math that
/// rounds a hair past the edge never writes out of bounds).
const Canvas = struct {
    px: []u8,
    w: u32,
    h: u32,

    /// Fill [x0,x1) x [y0,y1) (clamped to the cell) with `val`.
    fn fill(self: Canvas, x0: u32, y0: u32, x1: u32, y1: u32, val: u8) void {
        const xa = @min(x0, self.w);
        const xb = @min(x1, self.w);
        const ya = @min(y0, self.h);
        const yb = @min(y1, self.h);
        var y = ya;
        while (y < yb) : (y += 1) {
            var x = xa;
            const row = y * self.w;
            while (x < xb) : (x += 1) self.px[row + x] = val;
        }
    }

    /// Like `fill` but with signed coordinates clamped to the cell (negatives →
    /// 0). Used by box-drawing, whose strokes are centered ± an offset and can
    /// compute a negative left/top edge on a narrow cell.
    fn fillI(self: Canvas, x0: i32, y0: i32, x1: i32, y1: i32, val: u8) void {
        const w: i32 = @intCast(self.w);
        const h: i32 = @intCast(self.h);
        self.fill(
            @intCast(std.math.clamp(x0, 0, w)),
            @intCast(std.math.clamp(y0, 0, h)),
            @intCast(std.math.clamp(x1, 0, w)),
            @intCast(std.math.clamp(y1, 0, h)),
            val,
        );
    }

    fn all(self: Canvas, val: u8) void {
        @memset(self.px, val);
    }
};

fn blockElement(c: Canvas, cp: u21) void {
    const w = c.w;
    const h = c.h;
    switch (cp) {
        0x2580 => c.fill(0, 0, w, h / 2, 255), // upper half
        // Lower n/8 blocks (U+2581 1/8 .. U+2588 full): fill the bottom n eighths.
        0x2581...0x2588 => {
            const n = cp - 0x2580; // 1..8
            const top = h - @as(u32, @intCast(@as(u64, h) * n / 8));
            c.fill(0, top, w, h, 255);
        },
        // Left blocks (U+2589 7/8 .. U+258F 1/8): fill the left (8-m)/8 columns.
        0x2589...0x258F => {
            const m = cp - 0x2588; // 1..7
            const right = @as(u32, @intCast(@as(u64, w) * (8 - m) / 8));
            c.fill(0, 0, right, h, 255);
        },
        0x2590 => c.fill(w / 2, 0, w, h, 255), // right half
        0x2591 => c.all(64), // light shade (~25%)
        0x2592 => c.all(128), // medium shade (~50%)
        0x2593 => c.all(191), // dark shade (~75%)
        0x2594 => c.fill(0, 0, w, h / 8, 255), // upper one eighth
        0x2595 => c.fill(w - w / 8, 0, w, h, 255), // right one eighth
        // Quadrants (U+2596..259F): a bitmask of the four cell quarters.
        0x2596...0x259F => {
            const mask = quadrant_mask[cp - 0x2596];
            const mx = w / 2;
            const my = h / 2;
            if (mask & 0b0001 != 0) c.fill(0, 0, mx, my, 255); // upper-left
            if (mask & 0b0010 != 0) c.fill(mx, 0, w, my, 255); // upper-right
            if (mask & 0b0100 != 0) c.fill(0, my, mx, h, 255); // lower-left
            if (mask & 0b1000 != 0) c.fill(mx, my, w, h, 255); // lower-right
        },
        else => {},
    }
}

/// Quadrant masks for U+2596..U+259F (bit0 UL, bit1 UR, bit2 LL, bit3 LR).
const quadrant_mask = [_]u4{
    0b0100, // 2596 lower left
    0b1000, // 2597 lower right
    0b0001, // 2598 upper left
    0b1101, // 2599 UL+LL+LR
    0b1001, // 259A UL+LR
    0b0111, // 259B UL+UR+LL
    0b1011, // 259C UL+UR+LR
    0b0010, // 259D upper right
    0b0110, // 259E UR+LL
    0b1110, // 259F UR+LL+LR
};

/// Braille (U+2800..U+28FF): the low byte sets dots in a 2-column, 4-row grid.
/// Unicode dot numbering (1-8) maps to bits 0-7; layout:
///   1 4      bit0 bit3
///   2 5      bit1 bit4
///   3 6      bit2 bit5
///   7 8      bit6 bit7
fn braille(c: Canvas, cp: u21) void {
    const pattern: u8 = @intCast(cp - 0x2800);
    // (bit, col, row) for each of the 8 dots.
    const dots = [8][3]u8{
        .{ 0, 0, 0 }, .{ 1, 0, 1 }, .{ 2, 0, 2 }, .{ 6, 0, 3 },
        .{ 3, 1, 0 }, .{ 4, 1, 1 }, .{ 5, 1, 2 }, .{ 7, 1, 3 },
    };
    const cw = c.w / 2; // dot-cell width  (2 columns)
    const ch = c.h / 4; // dot-cell height (4 rows)
    if (cw == 0 or ch == 0) return;
    // Inset each dot within its cell so dots read as dots, not a solid fill.
    const mx = @max(1, cw / 5);
    const my = @max(1, ch / 5);
    for (dots) |d| {
        if (pattern & (@as(u8, 1) << @intCast(d[0])) == 0) continue;
        const x0 = d[1] * cw;
        const y0 = d[2] * ch;
        c.fill(x0 + mx, y0 + my, x0 + cw - mx, y0 + ch - my, 255);
    }
}

/// Box-drawing segment weights for `cp`: [up, down, left, right], each
/// 0 none / 1 light / 2 heavy / 3 double, or null if we don't model it (it then
/// falls through to the font). Covers the pure light / heavy / double lines,
/// corners, tees and crosses, plus the dashed variants (approximated as their
/// solid line of the same weight). Mixed-weight and partial-line variants are
/// left to the font.
fn boxSegments(cp: u21) ?[4]u2 {
    return switch (cp) {
        // Horizontals & verticals (dashed -> solid of the same weight).
        0x2500, 0x2504, 0x2508 => .{ 0, 0, 1, 1 }, // light horizontal
        0x2501, 0x2505, 0x2509 => .{ 0, 0, 2, 2 }, // heavy horizontal
        0x2502, 0x2506, 0x250A => .{ 1, 1, 0, 0 }, // light vertical
        0x2503, 0x2507, 0x250B => .{ 2, 2, 0, 0 }, // heavy vertical
        // Light corners (down/up + right/left).
        0x250C => .{ 0, 1, 0, 1 },
        0x2510 => .{ 0, 1, 1, 0 },
        0x2514 => .{ 1, 0, 0, 1 },
        0x2518 => .{ 1, 0, 1, 0 },
        // Heavy corners.
        0x250F => .{ 0, 2, 0, 2 },
        0x2513 => .{ 0, 2, 2, 0 },
        0x2517 => .{ 2, 0, 0, 2 },
        0x251B => .{ 2, 0, 2, 0 },
        // Light tees.
        0x251C => .{ 1, 1, 0, 1 },
        0x2524 => .{ 1, 1, 1, 0 },
        0x252C => .{ 0, 1, 1, 1 },
        0x2534 => .{ 1, 0, 1, 1 },
        // Heavy tees.
        0x2523 => .{ 2, 2, 0, 2 },
        0x252B => .{ 2, 2, 2, 0 },
        0x2533 => .{ 0, 2, 2, 2 },
        0x253B => .{ 2, 0, 2, 2 },
        // Crosses.
        0x253C => .{ 1, 1, 1, 1 },
        0x254B => .{ 2, 2, 2, 2 },
        // Double lines.
        0x2550 => .{ 0, 0, 3, 3 },
        0x2551 => .{ 3, 3, 0, 0 },
        // Double corners.
        0x2554 => .{ 0, 3, 0, 3 },
        0x2557 => .{ 0, 3, 3, 0 },
        0x255A => .{ 3, 0, 0, 3 },
        0x255D => .{ 3, 0, 3, 0 },
        // Double tees.
        0x2560 => .{ 3, 3, 0, 3 },
        0x2563 => .{ 3, 3, 3, 0 },
        0x2566 => .{ 0, 3, 3, 3 },
        0x2569 => .{ 3, 0, 3, 3 },
        // Double cross.
        0x256C => .{ 3, 3, 3, 3 },
        else => null,
    };
}

const Dir = enum { up, down, left, right };

fn boxDrawing(c: Canvas, cp: u21) void {
    const segs = boxSegments(cp) orelse return;
    const w: i32 = @intCast(c.w);
    const h: i32 = @intCast(c.h);
    const cx = @divFloor(w, 2);
    const cy = @divFloor(h, 2);
    // Light stroke thickness; heavy is ~double, double is two light strokes.
    const t: i32 = @max(1, @divFloor(@min(w, h), 8));

    inline for (.{ Dir.up, Dir.down, Dir.left, Dir.right }, 0..) |dir, i| {
        const wt = segs[i];
        if (wt != 0) {
            if (wt == 3) {
                // Double: two light strokes straddling the center line.
                stroke(c, dir, cx, cy, t, -t);
                stroke(c, dir, cx, cy, t, t);
            } else {
                stroke(c, dir, cx, cy, if (wt == 2) 2 * t else t, 0);
            }
        }
    }
}

/// Draw one half-segment from the cell center toward `dir`'s edge: a band of
/// width `th` (perpendicular to the run), shifted `off` perpendicular (for the
/// two strokes of a double line). Each band extends `th/2` past the center so
/// the junction box where segments meet is filled.
fn stroke(c: Canvas, comptime dir: Dir, cx: i32, cy: i32, th: i32, off: i32) void {
    const w: i32 = @intCast(c.w);
    const h: i32 = @intCast(c.h);
    const hh = @divFloor(th, 2);
    switch (dir) {
        .up => c.fillI(cx + off - hh, 0, cx + off - hh + th, cy + hh, 255),
        .down => c.fillI(cx + off - hh, cy - hh, cx + off - hh + th, h, 255),
        .left => c.fillI(0, cy + off - hh, cx + hh, cy + off - hh + th, 255),
        .right => c.fillI(cx - hh, cy + off - hh, w, cy + off - hh + th, 255),
    }
}

const testing = std.testing;

fn sumAlpha(px: []const u8) u64 {
    var s: u64 = 0;
    for (px) |p| s += p;
    return s;
}

test "sprite: isSprite covers blocks + braille + handled box chars, not letters" {
    try testing.expect(isSprite(0x2588)); // full block
    try testing.expect(isSprite(0x2580)); // upper half
    try testing.expect(isSprite(0x28FF)); // braille
    try testing.expect(isSprite(0x2500)); // light horizontal box-drawing
    try testing.expect(!isSprite('A'));
    try testing.expect(!isSprite(0x251E)); // mixed-weight box char — not modeled
}

test "sprite: non-sprite codepoints return null" {
    try testing.expect((try rasterize(testing.allocator, 'A', 10, 20)) == null);
    try testing.expect((try rasterize(testing.allocator, 0x251E, 10, 20)) == null);
}

test "sprite: full block fills the whole cell; upper/lower halves split it" {
    const alloc = testing.allocator;
    const w: u32 = 10;
    const h: u32 = 20;

    const full = (try rasterize(alloc, 0x2588, w, h)).?;
    defer alloc.free(full);
    for (full) |p| try testing.expectEqual(@as(u8, 255), p);

    // Upper half: top rows lit, bottom rows blank.
    const upper = (try rasterize(alloc, 0x2580, w, h)).?;
    defer alloc.free(upper);
    try testing.expectEqual(@as(u8, 255), upper[0]); // top-left
    try testing.expectEqual(@as(u8, 0), upper[(h - 1) * w]); // bottom-left

    // Lower half (U+2584): bottom rows lit, top rows blank.
    const lower = (try rasterize(alloc, 0x2584, w, h)).?;
    defer alloc.free(lower);
    try testing.expectEqual(@as(u8, 0), lower[0]);
    try testing.expectEqual(@as(u8, 255), lower[(h - 1) * w]);
    // The two halves together cover the full block.
    try testing.expectEqual(sumAlpha(full), sumAlpha(upper) + sumAlpha(lower));
}

test "sprite: left/right halves split columns; shades are partial" {
    const alloc = testing.allocator;
    const w: u32 = 10;
    const h: u32 = 20;

    const left = (try rasterize(alloc, 0x258C, w, h)).?;
    defer alloc.free(left);
    try testing.expectEqual(@as(u8, 255), left[0]); // left column
    try testing.expectEqual(@as(u8, 0), left[w - 1]); // right column

    const right = (try rasterize(alloc, 0x2590, w, h)).?;
    defer alloc.free(right);
    try testing.expectEqual(@as(u8, 0), right[0]);
    try testing.expectEqual(@as(u8, 255), right[w - 1]);

    // Shades fill everything but at reduced alpha (light < medium < dark < full).
    const light = (try rasterize(alloc, 0x2591, w, h)).?;
    defer alloc.free(light);
    const dark = (try rasterize(alloc, 0x2593, w, h)).?;
    defer alloc.free(dark);
    try testing.expect(sumAlpha(light) > 0);
    try testing.expect(sumAlpha(dark) > sumAlpha(light));
    try testing.expect(sumAlpha(dark) < @as(u64, 255) * w * h);
}

test "sprite: a quadrant lights only its quarter" {
    const alloc = testing.allocator;
    const w: u32 = 10;
    const h: u32 = 20;
    // U+2598 QUADRANT UPPER LEFT.
    const ul = (try rasterize(alloc, 0x2598, w, h)).?;
    defer alloc.free(ul);
    try testing.expectEqual(@as(u8, 255), ul[0]); // top-left set
    try testing.expectEqual(@as(u8, 0), ul[w - 1]); // top-right clear
    try testing.expectEqual(@as(u8, 0), ul[(h - 1) * w]); // bottom-left clear
}

test "sprite: box-drawing only models a subset; the rest falls to the font" {
    try testing.expect(isSprite(0x2500)); // light horizontal — handled
    try testing.expect(isSprite(0x253C)); // light cross — handled
    try testing.expect(isSprite(0x2550)); // double horizontal — handled
    try testing.expect(!isSprite(0x251E)); // mixed-weight tee — not modeled
    try testing.expect((try rasterize(testing.allocator, 0x251E, 12, 24)) == null);
}

test "sprite: light horizontal/vertical lines lie on the center axes" {
    const alloc = testing.allocator;
    const w: u32 = 12;
    const h: u32 = 24;
    const cx = w / 2;
    const cy = h / 2;

    const horiz = (try rasterize(alloc, 0x2500, w, h)).?;
    defer alloc.free(horiz);
    try testing.expect(horiz[cy * w + 0] == 255); // left edge, center row: lit
    try testing.expect(horiz[cy * w + (w - 1)] == 255); // right edge, center row: lit
    try testing.expect(horiz[0] == 0); // top-left corner: blank (no vertical)

    const vert = (try rasterize(alloc, 0x2502, w, h)).?;
    defer alloc.free(vert);
    try testing.expect(vert[0 * w + cx] == 255); // top edge, center col: lit
    try testing.expect(vert[(h - 1) * w + cx] == 255); // bottom edge, center col: lit
    try testing.expect(vert[cy * w + 0] == 0); // center row, left edge: blank
}

test "sprite: a corner draws only its two arms" {
    const alloc = testing.allocator;
    const w: u32 = 12;
    const h: u32 = 24;
    const cx = w / 2;
    const cy = h / 2;
    // U+250C ┌ : down + right arms only (no up, no left).
    const dr = (try rasterize(alloc, 0x250C, w, h)).?;
    defer alloc.free(dr);
    try testing.expect(dr[(h - 1) * w + cx] == 255); // down arm reaches bottom
    try testing.expect(dr[cy * w + (w - 1)] == 255); // right arm reaches right edge
    try testing.expect(dr[0 * w + cx] == 0); // no up arm at the top
    try testing.expect(dr[cy * w + 0] == 0); // no left arm at the left edge
}

test "sprite: heavy lines have more ink than light; double has two strokes" {
    const alloc = testing.allocator;
    const w: u32 = 16;
    const h: u32 = 32;

    const light = (try rasterize(alloc, 0x2500, w, h)).?;
    defer alloc.free(light);
    const heavy = (try rasterize(alloc, 0x2501, w, h)).?;
    defer alloc.free(heavy);
    try testing.expect(sumAlpha(heavy) > sumAlpha(light));

    // Double horizontal (U+2550): two separated bands -> the center row between
    // them is blank while rows just above and below it are lit.
    const dbl = (try rasterize(alloc, 0x2550, w, h)).?;
    defer alloc.free(dbl);
    const cy = h / 2;
    var lit_above = false;
    var lit_below = false;
    for (0..w) |x| {
        if (dbl[(cy - 2) * w + x] == 255) lit_above = true;
        if (dbl[(cy + 2) * w + x] == 255) lit_below = true;
    }
    try testing.expect(lit_above and lit_below);
}

test "sprite: braille lights more dots as bits set; blank pattern is empty" {
    const alloc = testing.allocator;
    const w: u32 = 12;
    const h: u32 = 20;

    // U+2800: no dots -> blank.
    const blank = (try rasterize(alloc, 0x2800, w, h)).?;
    defer alloc.free(blank);
    try testing.expectEqual(@as(u64, 0), sumAlpha(blank));

    // U+2801: dot 1 (top-left) only -> some ink in the top-left dot cell.
    const one = (try rasterize(alloc, 0x2801, w, h)).?;
    defer alloc.free(one);
    try testing.expect(sumAlpha(one) > 0);

    // U+28FF: all 8 dots -> strictly more ink than a single dot.
    const all8 = (try rasterize(alloc, 0x28FF, w, h)).?;
    defer alloc.free(all8);
    try testing.expect(sumAlpha(all8) > sumAlpha(one));
}
