//! whostty: mouse-wheel scroll accumulation.
//!
//! Reference: ghostty handles scroll in `src/Surface.zig` (scrollback uses the
//! VT core's viewport, which whostty delegates to libghostty-vt). This module
//! is the small, host-testable piece: turning raw OS wheel deltas into whole
//! row steps to feed the VT viewport. The viewport storage itself lives in
//! libghostty-vt (`PageList.scroll`). See PORTING.md.
const std = @import("std");

/// Accumulates raw wheel deltas and yields whole-row scroll amounts. Windows
/// reports wheel movement in multiples of `notch` (WHEEL_DELTA); high-res
/// touchpads report smaller deltas, so sub-notch movement is carried over.
pub const WheelAccumulator = struct {
    /// Raw wheel delta not yet converted to whole rows.
    acc: i32 = 0,
    /// Rows scrolled per wheel notch.
    lines_per_notch: i32 = 3,

    /// One wheel notch in raw units (Win32 `WHEEL_DELTA`).
    pub const notch: i32 = 120;

    /// Feed a raw wheel delta and get the VT `delta_row` to apply. Windows
    /// reports a positive delta when the wheel rolls away from the user, which
    /// scrolls up into history; the VT viewport uses a negative `delta_row` for
    /// up, so the sign is flipped here. Returns 0 until at least one whole notch
    /// has accumulated.
    pub fn feed(self: *WheelAccumulator, raw: i32) isize {
        self.acc += raw;
        const notches = @divTrunc(self.acc, notch);
        self.acc -= notches * notch;
        return -@as(isize, notches * self.lines_per_notch);
    }
};

/// Scrollbar thumb geometry, in track-pixel units measured from the track top.
pub const Thumb = struct {
    offset: f32,
    size: f32,
};

/// Compute the scrollbar thumb over a track of `track` pixels.
///   - `total_rows`: scrollback history + the visible viewport.
///   - `viewport_rows`: rows currently on screen.
///   - `rows_above`: rows of history above the viewport's first visible row
///     (0 = scrolled to the oldest line; max = at the live bottom).
/// When everything fits, the thumb fills the track. The thumb has a 1px floor so
/// it stays grabbable in deep scrollback.
pub fn scrollbarThumb(total_rows: usize, viewport_rows: usize, rows_above: usize, track: f32) Thumb {
    if (total_rows <= viewport_rows or total_rows == 0) return .{ .offset = 0, .size = track };

    const total_f: f32 = @floatFromInt(total_rows);
    const view_f: f32 = @floatFromInt(viewport_rows);
    const size = @max(track * (view_f / total_f), 1);

    const max_above = total_rows - viewport_rows;
    const above = @min(rows_above, max_above);
    const frac: f32 = @as(f32, @floatFromInt(above)) / @as(f32, @floatFromInt(max_above));
    return .{ .offset = (track - size) * frac, .size = size };
}

test "scroll: scrollbarThumb fills the track when everything fits" {
    const t = scrollbarThumb(20, 24, 0, 200);
    try std.testing.expectEqual(@as(f32, 0), t.offset);
    try std.testing.expectEqual(@as(f32, 200), t.size);
}

test "scroll: scrollbarThumb sizes and positions by scroll fraction" {
    // 25 of 100 rows visible over a 400px track -> 100px thumb, 300px of travel.
    const top = scrollbarThumb(100, 25, 0, 400);
    try std.testing.expectEqual(@as(f32, 100), top.size);
    try std.testing.expectEqual(@as(f32, 0), top.offset); // oldest line: thumb at top

    const bottom = scrollbarThumb(100, 25, 75, 400);
    try std.testing.expectEqual(@as(f32, 300), bottom.offset); // live bottom: thumb at end

    // rows_above clamps to the maximum.
    const clamped = scrollbarThumb(100, 25, 999, 400);
    try std.testing.expectEqual(@as(f32, 300), clamped.offset);
}

/// Rows to move the viewport for a page scroll, given the number of visible
/// rows. One row of overlap is kept so the boundary line stays on screen, as
/// most terminals do. Always at least 1. The caller applies the sign (negative
/// for up, matching the VT viewport's `delta_row`).
pub fn pageRows(visible_rows: usize) usize {
    return if (visible_rows > 1) visible_rows - 1 else 1;
}

test "scroll: pageRows keeps one row of overlap" {
    try std.testing.expectEqual(@as(usize, 23), pageRows(24));
    try std.testing.expectEqual(@as(usize, 1), pageRows(1));
    try std.testing.expectEqual(@as(usize, 1), pageRows(0));
}

test "scroll: one notch up yields negative delta_row" {
    var w: WheelAccumulator = .{};
    try std.testing.expectEqual(@as(isize, -3), w.feed(WheelAccumulator.notch));
    try std.testing.expectEqual(@as(i32, 0), w.acc);
}

test "scroll: sub-notch deltas accumulate then fire" {
    var w: WheelAccumulator = .{};
    try std.testing.expectEqual(@as(isize, 0), w.feed(60));
    try std.testing.expectEqual(@as(i32, 60), w.acc);
    try std.testing.expectEqual(@as(isize, -3), w.feed(60));
    try std.testing.expectEqual(@as(i32, 0), w.acc);
}

test "scroll: wheel down scrolls back toward the bottom" {
    var w: WheelAccumulator = .{};
    try std.testing.expectEqual(@as(isize, 3), w.feed(-WheelAccumulator.notch));
}

test "scroll: multiple notches scale by lines_per_notch" {
    var w: WheelAccumulator = .{ .lines_per_notch = 5 };
    try std.testing.expectEqual(@as(isize, -10), w.feed(2 * WheelAccumulator.notch));
}
