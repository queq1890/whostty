//! whostty engine: child-process environment for a spawned pane (#137, epic E0).
//!
//! Stability: experimental (ADR 0010) — promoted once whomux drives the shape.
//!
//! For apps and shells to emit the sequences whomux relies on (OSC 133 prompt
//! marks, correct key encodings) each spawned pane needs a correct `TERM`, a
//! discoverable terminfo entry, and the shell-integration environment variables.
//! This module computes — platform-free — the env entries to inject at spawn, so
//! whomux gets the same environment whostty's own apprt does without
//! reimplementing it. The platform-bound spawn (ConPTY) applies them; see
//! `src/pty.zig`.
//!
//! The terminfo *entry* ships in `src/terminfo/` and the dir is passed in via
//! `Options.terminfo_dir`; the shell-integration *scripts* are out of scope here
//! (this module only produces the env that activates them — the env contract).

const std = @import("std");

/// The engine's `TERM`. whostty emits ghostty-compatible sequences, so it
/// advertises ghostty's terminfo name; apps resolve it from the bundled terminfo
/// (via `TERMINFO`) or a system copy.
pub const term = "xterm-ghostty";

/// The `TERM` to advertise when the `xterm-ghostty` terminfo can't be resolved
/// (no compiled entry next to the exe, no system copy). It is in every terminfo
/// database, so apps always resolve it — shipping it is strictly safer than an
/// unresolvable `xterm-ghostty` (which breaks curses apps). The host selects it
/// via `Options.term` when it could not find a compiled entry to point
/// `TERMINFO` at; see the apprt's terminfo resolution (#152).
pub const fallback_term = "xterm-256color";

/// The `TERM_PROGRAM` advertised to the child process. By convention each
/// terminal reports its own name (apps read it for telemetry and feature hints);
/// whostty reports `whostty`. A host embedding the engine (e.g. whomux) can
/// override it via `Options.term_program`.
pub const program = "whostty";

/// One environment variable to inject. `key` and `value` are owned by the
/// allocator passed to `compute` (released by `free`).
pub const Entry = struct {
    key: []const u8,
    value: []const u8,
};

/// Which shell-integration features are active, mirrored into
/// `GHOSTTY_SHELL_FEATURES`. A minimal, engine-owned subset (decoupled from the
/// full config flags) — the host maps its config onto this.
pub const Features = struct {
    cursor: bool = true,
    sudo: bool = false,
    title: bool = true,
};

pub const Options = struct {
    /// The `TERM` to advertise. Defaults to the engine's `xterm-ghostty`. The
    /// host overrides it with `fallback_term` when no compiled `xterm-ghostty`
    /// terminfo is resolvable, so apps never receive an unresolvable `TERM`
    /// (#152). When set to the fallback, leave `terminfo_dir` null.
    term: []const u8 = term,
    /// The `TERM_PROGRAM` to advertise. Defaults to the engine's `program`
    /// (`whostty`); a host embedding the engine can override it.
    term_program: []const u8 = program,
    /// Absolute path to the bundled terminfo dir (the compiled entries). When
    /// null, `TERMINFO` is left unset and apps fall back to the system terminfo
    /// database.
    terminfo_dir: ?[]const u8 = null,
    /// When true, inject the shell-integration variables (the `GHOSTTY_*`
    /// contract the integration scripts read). When false, only the base
    /// terminal variables (`TERM` / `COLORTERM` / `TERMINFO`) are injected.
    shell_integration: bool = true,
    features: Features = .{},
};

/// Compute the child-process environment entries to inject at pane spawn, owned
/// by `alloc` (release with `free`). Always sets `TERM` (to `opts.term`),
/// `COLORTERM` and `TERM_PROGRAM`; sets `TERMINFO` when a dir is given; and, when
/// shell integration is enabled, sets `GHOSTTY_SHELL_INTEGRATION` plus the
/// comma-joined `GHOSTTY_SHELL_FEATURES`.
pub fn compute(alloc: std.mem.Allocator, opts: Options) ![]Entry {
    var list: std.ArrayListUnmanaged(Entry) = .empty;
    errdefer freeList(alloc, &list);

    try put(alloc, &list, "TERM", opts.term);
    try put(alloc, &list, "COLORTERM", "truecolor");
    try put(alloc, &list, "TERM_PROGRAM", opts.term_program);
    if (opts.terminfo_dir) |dir| try put(alloc, &list, "TERMINFO", dir);

    if (opts.shell_integration) {
        try put(alloc, &list, "GHOSTTY_SHELL_INTEGRATION", "1");
        const feats = try formatFeatures(alloc, opts.features);
        defer alloc.free(feats);
        try put(alloc, &list, "GHOSTTY_SHELL_FEATURES", feats);
    }

    return list.toOwnedSlice(alloc);
}

/// Release an entry slice returned by `compute` (each key/value plus the slice).
pub fn free(alloc: std.mem.Allocator, entries: []Entry) void {
    for (entries) |e| {
        alloc.free(e.key);
        alloc.free(e.value);
    }
    alloc.free(entries);
}

fn put(
    alloc: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(Entry),
    key: []const u8,
    value: []const u8,
) !void {
    const k = try alloc.dupe(u8, key);
    errdefer alloc.free(k);
    const v = try alloc.dupe(u8, value);
    errdefer alloc.free(v);
    try list.append(alloc, .{ .key = k, .value = v });
}

fn freeList(alloc: std.mem.Allocator, list: *std.ArrayListUnmanaged(Entry)) void {
    for (list.items) |e| {
        alloc.free(e.key);
        alloc.free(e.value);
    }
    list.deinit(alloc);
}

/// Build the comma-joined feature list (e.g. "cursor,title"). Stable order so the
/// value is deterministic for tests + caching.
fn formatFeatures(alloc: std.mem.Allocator, f: Features) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);
    if (f.cursor) try append(alloc, &buf, "cursor");
    if (f.sudo) try append(alloc, &buf, "sudo");
    if (f.title) try append(alloc, &buf, "title");
    return buf.toOwnedSlice(alloc);
}

fn append(alloc: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), name: []const u8) !void {
    if (buf.items.len > 0) try buf.append(alloc, ',');
    try buf.appendSlice(alloc, name);
}

/// Find an entry's value by key (test/consumer helper).
pub fn get(entries: []const Entry, key: []const u8) ?[]const u8 {
    for (entries) |e| if (std.mem.eql(u8, e.key, key)) return e.value;
    return null;
}

test "env: base entries set TERM, COLORTERM and TERMINFO" {
    const alloc = std.testing.allocator;
    const entries = try compute(alloc, .{ .terminfo_dir = "C:/whostty/terminfo" });
    defer free(alloc, entries);

    try std.testing.expectEqualStrings("xterm-ghostty", get(entries, "TERM").?);
    try std.testing.expectEqualStrings("truecolor", get(entries, "COLORTERM").?);
    try std.testing.expectEqualStrings("whostty", get(entries, "TERM_PROGRAM").?);
    try std.testing.expectEqualStrings("C:/whostty/terminfo", get(entries, "TERMINFO").?);
}

test "env: a host can override TERM_PROGRAM (the engine is reusable)" {
    const alloc = std.testing.allocator;
    const entries = try compute(alloc, .{ .term_program = "whomux" });
    defer free(alloc, entries);
    try std.testing.expectEqualStrings("whomux", get(entries, "TERM_PROGRAM").?);
}

test "env: shell-integration vars are injected with the active features" {
    const alloc = std.testing.allocator;
    const entries = try compute(alloc, .{ .features = .{ .cursor = true, .sudo = true, .title = false } });
    defer free(alloc, entries);

    try std.testing.expectEqualStrings("1", get(entries, "GHOSTTY_SHELL_INTEGRATION").?);
    try std.testing.expectEqualStrings("cursor,sudo", get(entries, "GHOSTTY_SHELL_FEATURES").?);
}

test "env: the host can advertise the fallback TERM when no terminfo resolves" {
    const alloc = std.testing.allocator;
    // No bundled terminfo found -> host passes the fallback TERM and no dir, so
    // apps resolve a TERM that is always in the system database (#152).
    const entries = try compute(alloc, .{ .term = fallback_term });
    defer free(alloc, entries);

    try std.testing.expectEqualStrings("xterm-256color", get(entries, "TERM").?);
    try std.testing.expect(get(entries, "TERMINFO") == null);
}

test "env: shell integration off injects no GHOSTTY_* vars but keeps TERM" {
    const alloc = std.testing.allocator;
    const entries = try compute(alloc, .{ .shell_integration = false });
    defer free(alloc, entries);

    try std.testing.expect(get(entries, "TERM") != null);
    try std.testing.expect(get(entries, "GHOSTTY_SHELL_INTEGRATION") == null);
    try std.testing.expect(get(entries, "GHOSTTY_SHELL_FEATURES") == null);
    // TERMINFO is unset when no dir is given.
    try std.testing.expect(get(entries, "TERMINFO") == null);
}
