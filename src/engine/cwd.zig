//! whostty engine: the unified per-pane working-directory store (#134, epic E0).
//!
//! Stability: experimental (ADR 0010) — promoted once whomux drives the shape.
//!
//! Every consumer that needs a pane's working directory — the sidebar branch/cwd
//! display, new-pane cwd inheritance, session restore — must read ONE canonical
//! value. OSC 7 (the shell's `file://` URL) and OSC 133's reported directory both
//! write *this* store, so a consumer never reconciles two sources: there is
//! exactly one cwd path per surface.
//!
//! The store keeps the latest value with OSC 7's empty-url *reset* semantics
//! ("forget the pwd" — ghostty's behavior when the shell reports an empty url),
//! and owns its buffer. It is a plain value type with no synchronization of its
//! own; the owner (`Termio`) guards reads/writes with the same mutex that guards
//! the grid, so consumers see a consistent latest value (#134 scope, ADR 0008).

const std = @import("std");

/// A single per-surface working directory. Latest write wins; an empty update
/// *resets* the store to "unknown". Both the OSC 7 handler (raw `file://` URL)
/// and the OSC 133 prompt-mark handler (#136) call `set` on the same instance,
/// which is what makes the cwd a single canonical path rather than two stores.
pub const Cwd = struct {
    /// The latest reported path/URL, owned by `alloc`, or null when unknown
    /// (never reported, or reset by an empty OSC 7). The value is stored
    /// verbatim — whether it is a `file://` URL (OSC 7) or a plain path is up to
    /// the writer; consumers parse as needed.
    value: ?[]u8 = null,

    pub fn deinit(self: *Cwd, alloc: std.mem.Allocator) void {
        if (self.value) |v| alloc.free(v);
        self.* = undefined;
    }

    /// Set the cwd to `path`, duplicated into `alloc`. An empty `path` *resets*
    /// the store (clears it to null) — the OSC 7 "forget the pwd" case, made
    /// observable so a consumer can fall back to the spawn directory. The
    /// previous value is freed (latest write wins). Any source — OSC 7, OSC 133,
    /// or the host directly — routes through here so the path stays canonical.
    pub fn set(self: *Cwd, alloc: std.mem.Allocator, path: []const u8) !void {
        if (self.value) |old| {
            alloc.free(old);
            self.value = null;
        }
        if (path.len == 0) return;
        self.value = try alloc.dupe(u8, path);
    }

    /// The current cwd, or null if unknown/reset. The slice is borrowed from the
    /// store and valid only until the next `set`/`deinit`; a caller that needs to
    /// outlive that (e.g. crossing threads) should dupe it (see `Termio.cwdAlloc`).
    pub fn get(self: *const Cwd) ?[]const u8 {
        return self.value;
    }
};

test "cwd: set then get returns the path" {
    const alloc = std.testing.allocator;
    var c: Cwd = .{};
    defer c.deinit(alloc);

    try c.set(alloc, "file:///home/user/project");
    try std.testing.expectEqualStrings("file:///home/user/project", c.get().?);
}

test "cwd: empty set resets the store (forget the pwd)" {
    const alloc = std.testing.allocator;
    var c: Cwd = .{};
    defer c.deinit(alloc);

    try c.set(alloc, "file:///tmp");
    try std.testing.expect(c.get() != null);

    // An empty url is OSC 7's "the pwd is unknown" reset.
    try c.set(alloc, "");
    try std.testing.expect(c.get() == null);
}

test "cwd: latest write wins and frees the previous value" {
    const alloc = std.testing.allocator;
    var c: Cwd = .{};
    defer c.deinit(alloc);

    try c.set(alloc, "file:///first");
    try c.set(alloc, "file:///second");
    // If the previous value leaked, the testing allocator would flag it.
    try std.testing.expectEqualStrings("file:///second", c.get().?);
}

test "cwd: OSC 7 and OSC 133 sources write the same single field" {
    const alloc = std.testing.allocator;
    var c: Cwd = .{};
    defer c.deinit(alloc);

    // Simulate the OSC 7 source.
    try c.set(alloc, "file:///from/osc7");
    try std.testing.expectEqualStrings("file:///from/osc7", c.get().?);

    // Simulate the OSC 133 source writing the *same* store: the latest value is
    // indistinguishable from an OSC 7 update — there is exactly one cwd path.
    try c.set(alloc, "/from/osc133");
    try std.testing.expectEqualStrings("/from/osc133", c.get().?);
}
