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
