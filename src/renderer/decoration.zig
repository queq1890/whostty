//! whostty: underline decoration sprites (#80).
//!
//! Reference: ghostty `src/font/sprite/underline.zig` (strategy: port a slice —
//! ghostty rasterizes decorations into the sprite atlas; whostty draws them as
//! solid rectangles in the cell pipeline, which needs no atlas and reads the
//! same). The bring-up renderer drew every underline style as one solid line;
//! this distinguishes single / double / dotted / dashed / curly. Strikethrough
//! and overline stay single lines (they have no SGR style variants). The
//! geometry is pure so it is host-testable; the caller (buildQuads) turns each
//! `Rect` into a colored quad. See PORTING.md.
const std = @import("std");

/// The underline styles SGR distinguishes (mirrors libghostty-vt's
/// `sgr.Attribute.Underline` tags; the caller maps from `style.flags.underline`
/// so this module stays dependency-free).
pub const Underline = enum { none, single, double, dotted, dashed, curly };

/// A solid rectangle in cell-local pixels (relative to the cell's top-left).
pub const Rect = struct { x: i32, y: i32, w: u32, h: u32 };

/// Append the rectangles that draw `style` along an underline whose top is at
/// `baseline` pixels below the cell top, across a `cell_w`-wide cell, with stroke
/// thickness `t` (>=1). `.none` appends nothing. Reuses `out`'s capacity; the
/// caller clears it between cells.
pub fn underlineRects(
    out: *std.ArrayList(Rect),
    alloc: std.mem.Allocator,
    style: Underline,
    cell_w: u32,
    baseline: i32,
    t: u32,
) !void {
    const th = @max(1, t);
    switch (style) {
        .none => {},
        .single => try out.append(alloc, .{ .x = 0, .y = baseline, .w = cell_w, .h = th }),
        .double => {
            // Two strokes separated by one stroke of gap. The second sits below
            // the first; at small cell sizes it may touch the cell's lower edge,
            // which is cosmetic (ghostty clamps similarly).
            try out.append(alloc, .{ .x = 0, .y = baseline, .w = cell_w, .h = th });
            try out.append(alloc, .{ .x = 0, .y = baseline + @as(i32, @intCast(2 * th)), .w = cell_w, .h = th });
        },
        .dotted => {
            // Dots one unit wide separated by one unit of gap.
            const unit = th;
            const step = 2 * unit;
            var x: u32 = 0;
            while (x + unit <= cell_w) : (x += step) {
                try out.append(alloc, .{ .x = @intCast(x), .y = baseline, .w = unit, .h = th });
            }
        },
        .dashed => {
            // Longer dashes (about a quarter cell) with a half-dash gap.
            const dash = @max(2 * th, cell_w / 4);
            const gap = @max(th, dash / 2);
            const step = dash + gap;
            var x: u32 = 0;
            while (x < cell_w) : (x += step) {
                const w = @min(dash, cell_w - x);
                try out.append(alloc, .{ .x = @intCast(x), .y = baseline, .w = w, .h = th });
            }
        },
        .curly => {
            // Approximate a sine with short segments whose y oscillates around
            // `baseline`, giving the squiggle spell-checkers use. Amplitude and
            // period scale with the stroke so it reads at any size.
            const amp: f32 = @floatFromInt(@max(1, th));
            const period: f32 = @floatFromInt(@max(4, cell_w / 2));
            const seg: u32 = @max(1, th);
            var x: u32 = 0;
            while (x < cell_w) : (x += seg) {
                const phase = (@as(f32, @floatFromInt(x)) / period) * (2.0 * std.math.pi);
                const dy: i32 = @intFromFloat(@round(amp * @sin(phase)));
                const w = @min(seg, cell_w - x);
                out.append(alloc, .{ .x = @intCast(x), .y = baseline + dy, .w = w, .h = th }) catch |e| return e;
            }
        },
    }
}

const testing = std.testing;

test "decoration: single is one full-width stroke; none is empty" {
    var out: std.ArrayList(Rect) = .empty;
    defer out.deinit(testing.allocator);

    try underlineRects(&out, testing.allocator, .none, 10, 14, 1);
    try testing.expectEqual(@as(usize, 0), out.items.len);

    try underlineRects(&out, testing.allocator, .single, 10, 14, 1);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(Rect{ .x = 0, .y = 14, .w = 10, .h = 1 }, out.items[0]);
}

test "decoration: double is two strokes at different y, same span" {
    var out: std.ArrayList(Rect) = .empty;
    defer out.deinit(testing.allocator);
    try underlineRects(&out, testing.allocator, .double, 10, 14, 1);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqual(@as(i32, 14), out.items[0].y);
    try testing.expect(out.items[1].y > out.items[0].y);
    try testing.expectEqual(out.items[0].w, out.items[1].w);
}

test "decoration: dotted leaves gaps (covered width < cell width)" {
    var out: std.ArrayList(Rect) = .empty;
    defer out.deinit(testing.allocator);
    try underlineRects(&out, testing.allocator, .dotted, 20, 14, 1);
    try testing.expect(out.items.len > 1);
    var covered: u32 = 0;
    for (out.items) |r| {
        covered += r.w;
        try testing.expectEqual(@as(i32, 14), r.y); // all on the baseline
    }
    try testing.expect(covered < 20); // gaps mean it doesn't fill the cell
}

test "decoration: dashed segments are longer/fewer than dotted" {
    const alloc = testing.allocator;
    var dotted: std.ArrayList(Rect) = .empty;
    defer dotted.deinit(alloc);
    var dashed: std.ArrayList(Rect) = .empty;
    defer dashed.deinit(alloc);
    try underlineRects(&dotted, alloc, .dotted, 40, 14, 1);
    try underlineRects(&dashed, alloc, .dashed, 40, 14, 1);
    try testing.expect(dashed.items.len < dotted.items.len);
    try testing.expect(dashed.items[0].w > dotted.items[0].w);
}

test "decoration: curly oscillates around the baseline" {
    var out: std.ArrayList(Rect) = .empty;
    defer out.deinit(testing.allocator);
    try underlineRects(&out, testing.allocator, .curly, 40, 14, 1);
    try testing.expect(out.items.len > 2);
    var min_y: i32 = 1 << 20;
    var max_y: i32 = -(1 << 20);
    for (out.items) |r| {
        min_y = @min(min_y, r.y);
        max_y = @max(max_y, r.y);
    }
    // A real squiggle spans more than one row (above and below the baseline).
    try testing.expect(max_y > min_y);
    try testing.expect(min_y < 14 and max_y > 14);
}
