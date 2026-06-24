//! whostty: frame pacing — decide when to redraw so the UI thread renders on
//! change and sleeps while idle (#72), instead of rebuilding + drawing + swapping
//! every loop iteration (which pins a CPU/GPU core even with no output).
//!
//! Reference: ghostty paces frames in the renderer thread with vsync + a
//! dirty/damage check (`src/renderer/`). whostty's slice keeps the decision
//! pure and host-testable here; the Win32 wait (`MsgWaitForMultipleObjects`) and
//! the reader-thread wake (`PostMessage`) live in the apprt. See PORTING.md.
const std = @import("std");

/// A snapshot of the inputs that affect the rendered frame but are not discrete
/// UI events: the terminal's dirty generation (bumped whenever the reader thread
/// applies pty output), the *effective* cursor-blink phase (only flips when a
/// blinking cursor is actually shown), and window focus (drives the hollow
/// cursor). Compared frame-to-frame to decide whether a redraw is needed.
pub const FrameState = struct {
    gen: u64 = 0,
    blink: bool = true,
    focused: bool = true,
};

/// True when the frame must be redrawn: a render-affecting UI event happened
/// (key / mouse / resize / scroll / selection) or any sampled state changed since
/// the last drawn frame.
pub fn needsRedraw(prev: FrameState, cur: FrameState, ui_event: bool) bool {
    return ui_event or
        prev.gen != cur.gen or
        prev.blink != cur.blink or
        prev.focused != cur.focused;
}

/// How long to sleep (milliseconds) when no redraw is needed, before waking to
/// re-check. When a cursor is blinking we wake exactly at the next blink toggle
/// so the blink stays crisp; otherwise we wake at `idle_cap_ms` purely as a
/// safety net (the reader thread also wakes the UI immediately on new output via
/// a posted message, and OS input wakes it too, so this cap is a fallback). The
/// result is clamped to at least 1ms so a zero never turns the wait into a spin.
pub fn idleWaitMs(blinking: bool, blink_elapsed_ns: u64, blink_interval_ns: u64, idle_cap_ms: u32) u32 {
    if (!blinking or blink_interval_ns == 0) return idle_cap_ms;
    const into = blink_elapsed_ns % blink_interval_ns;
    const remaining_ms: u64 = (blink_interval_ns - into) / std.time.ns_per_ms;
    return @intCast(std.math.clamp(remaining_ms, 1, idle_cap_ms));
}

test "frame: needsRedraw fires on event or any state change, else not" {
    const base: FrameState = .{ .gen = 5, .blink = true, .focused = true };

    // Identical state, no event -> no redraw (the whole point: idle is cheap).
    try std.testing.expect(!needsRedraw(base, base, false));
    // A UI event always forces a redraw.
    try std.testing.expect(needsRedraw(base, base, true));
    // Each piece of state, on its own, forces a redraw.
    try std.testing.expect(needsRedraw(base, .{ .gen = 6, .blink = true, .focused = true }, false));
    try std.testing.expect(needsRedraw(base, .{ .gen = 5, .blink = false, .focused = true }, false));
    try std.testing.expect(needsRedraw(base, .{ .gen = 5, .blink = true, .focused = false }, false));
}

test "frame: idleWaitMs wakes at the next blink toggle, capped" {
    const interval: u64 = 600 * std.time.ns_per_ms;

    // Not blinking -> just the idle cap (no periodic wake needed).
    try std.testing.expectEqual(@as(u32, 1000), idleWaitMs(false, 0, interval, 1000));

    // Blinking, just toggled (elapsed multiple of interval) -> wait a full
    // interval (under the cap, so not clamped).
    try std.testing.expectEqual(@as(u32, 600), idleWaitMs(true, 2 * interval, interval, 1000));

    // Blinking, partway through -> wait only the remainder.
    const part = 2 * interval + 450 * std.time.ns_per_ms; // 450ms into the phase
    try std.testing.expectEqual(@as(u32, 150), idleWaitMs(true, part, interval, 1000));

    // Remainder larger than the cap clamps down to the cap.
    try std.testing.expectEqual(@as(u32, 100), idleWaitMs(true, 2 * interval, interval, 100));

    // A zero interval can't divide; fall back to the cap rather than crash.
    try std.testing.expectEqual(@as(u32, 1000), idleWaitMs(true, 123, 0, 1000));
}

test "frame: idleWaitMs never returns zero (no spin) when nearly toggled" {
    const interval: u64 = 600 * std.time.ns_per_ms;
    // 1ns before the toggle: remainder rounds to 0ms but is clamped up to 1ms.
    try std.testing.expectEqual(@as(u32, 1), idleWaitMs(true, interval - 1, interval, 1000));
}
