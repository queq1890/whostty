//! whostty engine: OSC 133 semantic prompt marks (#136, epic E0 #141).
//!
//! Stability: experimental (ADR 0010) — promoted once whomux drives the shape.
//!
//! OSC 133 (`A`/`B`/`C`/`D`) marks the prompt, the command-input region, the
//! command-output start and the command end (with its exit status). whomux uses
//! these to infer per-pane agent state (waiting for input vs. running vs.
//! finished) and to power command-boundary navigation. libghostty-vt already
//! applies the per-row prompt flags as the stream is parsed; this module is the
//! pure host-facing *summary*: the current semantic `State`, the last command's
//! exit code, and an enumerable list of command/prompt boundaries (each with the
//! scrollback row it occurred at, for navigation).
//!
//! It is a pure state machine over the four FinalTerm actions, so it is fully
//! host-testable with synthetic A/B/C/D inputs. The platform-bound `Termio`
//! feeds it from captured OSC 133 events (mapping the VT action, reading the exit
//! code, and capturing the cursor's history-stable row) — see `src/termio.zig`.

const std = @import("std");

/// The four semantic boundaries whomux cares about, mapped from OSC 133's
/// FinalTerm actions. `L` (fresh line) and `N` (new command) carry no boundary
/// and are ignored by the tracker.
pub const Action = enum {
    /// `A` / `P` — a new prompt begins (the shell is about to prompt).
    prompt,
    /// `B` / `I` — the prompt ends and user command input begins.
    input,
    /// `C` — input ends and the command's output begins (it is now running).
    command,
    /// `D` — the command ends, carrying its exit status.
    end,
};

/// The pane's current semantic state, the thing whomux mirrors to show "waiting
/// for input" vs "running" vs "finished" per pane.
pub const State = enum {
    /// No OSC 133 seen yet — semantic state is unknown.
    unknown,
    /// At a prompt: the shell is waiting for the user to enter a command
    /// (between `A`/`B` and the next `C`).
    prompt,
    /// A command is running — its output is being produced (between `C` and `D`).
    running,
    /// The last command finished (`D`); `Marks.last_exit_code` holds its status.
    /// The pane is idle until the next prompt.
    done,
};

/// One recorded boundary: its kind, the scrollback row it occurred at (a
/// history-stable absolute row so a consumer can scroll to it), and — for a
/// command end — the command's exit code.
pub const Mark = struct {
    pub const Kind = enum {
        prompt_start,
        input_start,
        command_start,
        command_end,
    };

    kind: Kind,
    /// History-absolute row (rows from the top of scrollback) at the boundary.
    /// The caller defines the coordinate; `Termio` uses libghostty-vt's `.screen`
    /// point so it stays valid until scrollback is trimmed.
    row: u64,
    /// Exit code, present only on a `command_end` mark (`D` with `err=`/exit code).
    exit_code: ?i32 = null,
};

/// Tracks the running semantic state plus the list of boundaries seen so far.
/// Not thread-safe by itself; the owner (`Termio`) guards it with the grid mutex.
pub const Marks = struct {
    list: std.ArrayListUnmanaged(Mark) = .empty,
    current: State = .unknown,
    /// The most recent command's exit code (from the last `D`), or null if no
    /// command has finished yet.
    last_exit_code: ?i32 = null,

    pub fn deinit(self: *Marks, alloc: std.mem.Allocator) void {
        self.list.deinit(alloc);
        self.* = undefined;
    }

    /// Record a boundary `action` at `row` (and `exit_code` for `.end`), advancing
    /// the state machine. `prompt`/`input` mean the shell is at a prompt waiting
    /// for the user; `command` means a command is running; `end` means it finished.
    pub fn record(
        self: *Marks,
        alloc: std.mem.Allocator,
        action: Action,
        row: u64,
        exit_code: ?i32,
    ) !void {
        const kind: Mark.Kind = switch (action) {
            .prompt => .prompt_start,
            .input => .input_start,
            .command => .command_start,
            .end => .command_end,
        };
        self.current = switch (action) {
            .prompt, .input => .prompt,
            .command => .running,
            .end => .done,
        };
        if (action == .end) self.last_exit_code = exit_code;
        try self.list.append(alloc, .{
            .kind = kind,
            .row = row,
            .exit_code = if (action == .end) exit_code else null,
        });
    }

    /// The current semantic state (at-prompt / running / done / unknown).
    pub fn state(self: *const Marks) State {
        return self.current;
    }

    /// The boundaries seen so far, oldest first. Borrowed from the tracker; valid
    /// until the next `record`/`deinit`/`clear` (a thread-safe `Termio` accessor
    /// returns an owned copy).
    pub fn boundaries(self: *const Marks) []const Mark {
        return self.list.items;
    }

    /// Drop all recorded boundaries and reset to `unknown` (e.g. on a hard reset).
    pub fn clear(self: *Marks) void {
        self.list.clearRetainingCapacity();
        self.current = .unknown;
        self.last_exit_code = null;
    }
};

test "semantic: A/B/C/D drives the state machine and records boundaries" {
    const alloc = std.testing.allocator;
    var m: Marks = .{};
    defer m.deinit(alloc);

    try std.testing.expectEqual(State.unknown, m.state());

    // A: prompt start -> at prompt.
    try m.record(alloc, .prompt, 10, null);
    try std.testing.expectEqual(State.prompt, m.state());

    // B: input start -> still at prompt (user typing).
    try m.record(alloc, .input, 10, null);
    try std.testing.expectEqual(State.prompt, m.state());

    // C: command output start -> running.
    try m.record(alloc, .command, 11, null);
    try std.testing.expectEqual(State.running, m.state());

    // D: command end with exit code 0 -> done.
    try m.record(alloc, .end, 14, 0);
    try std.testing.expectEqual(State.done, m.state());
    try std.testing.expectEqual(@as(?i32, 0), m.last_exit_code);

    const b = m.boundaries();
    try std.testing.expectEqual(@as(usize, 4), b.len);
    try std.testing.expectEqual(Mark.Kind.prompt_start, b[0].kind);
    try std.testing.expectEqual(@as(u64, 10), b[0].row);
    try std.testing.expectEqual(Mark.Kind.input_start, b[1].kind);
    try std.testing.expectEqual(Mark.Kind.command_start, b[2].kind);
    try std.testing.expectEqual(Mark.Kind.command_end, b[3].kind);
    try std.testing.expectEqual(@as(?i32, 0), b[3].exit_code);
    // Only the command_end carries an exit code.
    try std.testing.expectEqual(@as(?i32, null), b[2].exit_code);
}

test "semantic: a failing command records its non-zero exit status" {
    const alloc = std.testing.allocator;
    var m: Marks = .{};
    defer m.deinit(alloc);

    try m.record(alloc, .prompt, 0, null);
    try m.record(alloc, .command, 1, null);
    try m.record(alloc, .end, 3, 127); // e.g. command-not-found
    try std.testing.expectEqual(State.done, m.state());
    try std.testing.expectEqual(@as(?i32, 127), m.last_exit_code);
    try std.testing.expectEqual(@as(?i32, 127), m.boundaries()[2].exit_code);
}

test "semantic: a second prompt after done returns to the prompt state" {
    const alloc = std.testing.allocator;
    var m: Marks = .{};
    defer m.deinit(alloc);

    try m.record(alloc, .prompt, 0, null);
    try m.record(alloc, .command, 1, null);
    try m.record(alloc, .end, 2, 0);
    // Next prompt: back to waiting for input. last_exit_code persists until the
    // next command ends.
    try m.record(alloc, .prompt, 3, null);
    try std.testing.expectEqual(State.prompt, m.state());
    try std.testing.expectEqual(@as(?i32, 0), m.last_exit_code);
    try std.testing.expectEqual(@as(usize, 4), m.boundaries().len);
}

test "semantic: clear resets state and drops boundaries" {
    const alloc = std.testing.allocator;
    var m: Marks = .{};
    defer m.deinit(alloc);

    try m.record(alloc, .prompt, 0, null);
    try m.record(alloc, .end, 1, 0);
    m.clear();
    try std.testing.expectEqual(State.unknown, m.state());
    try std.testing.expectEqual(@as(?i32, null), m.last_exit_code);
    try std.testing.expectEqual(@as(usize, 0), m.boundaries().len);
}
