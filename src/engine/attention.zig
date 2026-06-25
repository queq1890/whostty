//! whostty engine: the attention side channel public API (#135, epic E0 #141).
//!
//! Stability: experimental (ADR 0010) — promoted once whomux drives the shape.
//!
//! Terminal "attention" events drive whomux's notification ring, taskbar flash,
//! OS toasts and progress UI. whostty captures BEL, OSC 9 / OSC 777 notifications
//! and OSC 9;4 progress on the reader thread into a side channel (ADR 0008); this
//! module is the typed, host-facing shape of those events plus the contract for
//! draining them. The engine reports the typed events ONLY — it performs no OS
//! surfacing (no toast, no taskbar flash): whomux owns the OS actions.
//!
//! Two ways to consume, matching each signal's nature (ADR 0008):
//!   * **Poll** — `Termio.takeBellCount` / `takeNotification` / `progress`. The
//!     host drains once per frame. Bell and notification are *edges*:
//!     take-and-clear (the bell count resets; the latest notification wins and an
//!     undrained one is overwritten). Progress is a *level*: a persistent getter
//!     the host mirrors, not an event consumed once.
//!   * **Callback** — register a `Sink` to react eagerly (e.g. wake a sleeping
//!     frame loop). The sink fires on the **reader thread**, under the `Termio`
//!     mutex, the instant the event is captured. It must not block or re-enter
//!     `Termio`; typically it just sets a flag / signals the UI thread, which
//!     then does the poll-drain and the OS surfacing.

const std = @import("std");

/// A desktop notification (OSC 9 / OSC 777). The OSC 9 form carries only a body
/// (the `title` is empty). The slices are borrowed for the duration of the call
/// that exposes them — a `Sink` callback, or the value held until the next take —
/// so a consumer that outlives that must dupe; `Termio.takeNotification` returns
/// an owned copy for exactly that reason.
pub const Notification = struct {
    title: []const u8,
    body: []const u8,
};

/// OSC 9;4 taskbar progress. A *level*, not an edge: it persists until the app
/// changes it, so the host mirrors it rather than consuming it once.
pub const Progress = struct {
    pub const State = enum {
        /// No progress bar — the idle / cleared default.
        remove,
        /// Determinate progress at `percent`.
        set,
        /// Error state (e.g. a red taskbar bar).
        @"error",
        /// Busy with no known percentage.
        indeterminate,
        /// Paused.
        pause,
    };

    state: State,
    /// 0..100, meaningful for `.set` (and optionally `.@"error"` / `.pause`);
    /// null when the app reported no percentage.
    percent: ?u8 = null,
};

/// A captured attention event delivered to a `Sink`. Bell is a bare edge;
/// notification and progress carry their typed payload (borrowed for the call).
pub const Event = union(enum) {
    bell,
    notification: Notification,
    progress: Progress,
};

/// An optional host callback for eager (push) delivery, the inverse of polling.
/// The host fills `ctx` (its own state) and `on_event`; the engine calls `notify`
/// when it captures an attention event. Fires on the **reader thread** under the
/// `Termio` mutex — keep it non-blocking (set a flag / signal the UI thread) and
/// do not re-enter `Termio` from inside it.
pub const Sink = struct {
    ctx: *anyopaque,
    on_event: *const fn (ctx: *anyopaque, event: Event) void,

    pub fn notify(self: Sink, event: Event) void {
        self.on_event(self.ctx, event);
    }
};

// --- Tests: a fake sink proves the callback contract is implementable and that
//     each event shape routes through with its payload. This stands in for
//     whomux's real attention consumer until it drives the shape (ADR 0010).

const FakeSink = struct {
    bells: u32 = 0,
    last_notification: ?Notification = null,
    last_progress: ?Progress = null,

    fn sink(self: *FakeSink) Sink {
        return .{ .ctx = self, .on_event = onEvent };
    }

    fn onEvent(ctx: *anyopaque, event: Event) void {
        const self: *FakeSink = @ptrCast(@alignCast(ctx));
        switch (event) {
            .bell => self.bells += 1,
            .notification => |n| self.last_notification = n,
            .progress => |p| self.last_progress = p,
        }
    }
};

test "attention: sink routes each event shape with its payload" {
    var fake: FakeSink = .{};
    const s = fake.sink();

    s.notify(.bell);
    s.notify(.bell);
    s.notify(.{ .notification = .{ .title = "build", .body = "done" } });
    s.notify(.{ .progress = .{ .state = .set, .percent = 42 } });

    try std.testing.expectEqual(@as(u32, 2), fake.bells);
    try std.testing.expectEqualStrings("build", fake.last_notification.?.title);
    try std.testing.expectEqualStrings("done", fake.last_notification.?.body);
    try std.testing.expectEqual(Progress.State.set, fake.last_progress.?.state);
    try std.testing.expectEqual(@as(?u8, 42), fake.last_progress.?.percent);
}

test "attention: progress is a level (remove is the idle default, percent optional)" {
    const idle: Progress = .{ .state = .remove };
    try std.testing.expectEqual(Progress.State.remove, idle.state);
    try std.testing.expectEqual(@as(?u8, null), idle.percent);

    const indeterminate: Progress = .{ .state = .indeterminate };
    try std.testing.expectEqual(@as(?u8, null), indeterminate.percent);
}
