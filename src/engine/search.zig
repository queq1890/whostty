//! whostty engine: scrollback search results + navigation (#138, epic E0 #141).
//!
//! Stability: experimental (ADR 0010) — promoted once whomux drives the shape.
//!
//! whomux's search UI, URL detection and match highlighting need to read
//! scrollback row contents and run searches over history. The reading of live
//! rows + the scan live on `Termio` (they need the VT core); this module is the
//! pure host-facing shape of the *results*: a `Match` (a cell-coordinate range in
//! screen-absolute coordinates, so it stays valid across viewport scrolls) and a
//! `Results` container with forward/backward navigation. Search-UI concerns (the
//! input box, highlight colors) stay whomux-side.

const std = @import("std");

/// A single search match as a screen-absolute cell range. `*_y` are rows from the
/// top of scrollback (history-inclusive), so the coordinates stay valid as the
/// viewport scrolls — the host maps them to viewport cells with the current
/// scroll offset. Columns are inclusive. A within-row match has `start_y == end_y`.
pub const Match = struct {
    start_x: u16,
    start_y: u64,
    end_x: u16,
    end_y: u64,
};

/// The accumulated matches for a search plus a navigation cursor. A pure
/// container: the owner (`Termio`) fills it by scanning rows and reads it for
/// next/prev. `next`/`prev` wrap around and move the cursor. Not thread-safe; the
/// owner guards it with the grid mutex.
pub const Results = struct {
    matches: std.ArrayListUnmanaged(Match) = .empty,
    /// The currently-selected match index, or null before the first navigation.
    cursor: ?usize = null,

    pub fn deinit(self: *Results, alloc: std.mem.Allocator) void {
        self.matches.deinit(alloc);
        self.* = undefined;
    }

    /// Drop all matches and reset the cursor (keeps the backing capacity for the
    /// next search).
    pub fn clear(self: *Results) void {
        self.matches.clearRetainingCapacity();
        self.cursor = null;
    }

    pub fn append(self: *Results, alloc: std.mem.Allocator, m: Match) !void {
        try self.matches.append(alloc, m);
    }

    pub fn count(self: *const Results) usize {
        return self.matches.items.len;
    }

    /// The currently-selected match, or null if there are none / none selected yet.
    pub fn current(self: *const Results) ?Match {
        const c = self.cursor orelse return null;
        if (c >= self.matches.items.len) return null;
        return self.matches.items[c];
    }

    /// Advance to and return the next match (wrapping). The first call selects the
    /// first match. Null only when there are no matches.
    pub fn next(self: *Results) ?Match {
        const n = self.matches.items.len;
        if (n == 0) return null;
        const i = if (self.cursor) |c| (c + 1) % n else 0;
        self.cursor = i;
        return self.matches.items[i];
    }

    /// Step to and return the previous match (wrapping). The first call selects
    /// the last match. Null only when there are no matches.
    pub fn prev(self: *Results) ?Match {
        const n = self.matches.items.len;
        if (n == 0) return null;
        const i = if (self.cursor) |c| (c + n - 1) % n else n - 1;
        self.cursor = i;
        return self.matches.items[i];
    }
};

test "search: next/prev navigate and wrap around the matches" {
    const alloc = std.testing.allocator;
    var r: Results = .{};
    defer r.deinit(alloc);

    try r.append(alloc, .{ .start_x = 0, .start_y = 1, .end_x = 2, .end_y = 1 });
    try r.append(alloc, .{ .start_x = 5, .start_y = 3, .end_x = 7, .end_y = 3 });
    try std.testing.expectEqual(@as(usize, 2), r.count());

    // First next() selects the first match; then the second; then wraps.
    try std.testing.expectEqual(@as(u64, 1), r.next().?.start_y);
    try std.testing.expectEqual(@as(u64, 3), r.next().?.start_y);
    try std.testing.expectEqual(@as(u64, 1), r.next().?.start_y); // wrapped

    // prev() steps backward and wraps.
    try std.testing.expectEqual(@as(u64, 3), r.prev().?.start_y); // wrap back to last
    try std.testing.expectEqual(@as(u64, 1), r.prev().?.start_y);
}

test "search: clear drops matches and resets the cursor" {
    const alloc = std.testing.allocator;
    var r: Results = .{};
    defer r.deinit(alloc);

    try r.append(alloc, .{ .start_x = 0, .start_y = 0, .end_x = 1, .end_y = 0 });
    _ = r.next();
    r.clear();
    try std.testing.expectEqual(@as(usize, 0), r.count());
    try std.testing.expect(r.current() == null);
    try std.testing.expect(r.next() == null);
}

test "search: prev on a fresh result selects the last match" {
    const alloc = std.testing.allocator;
    var r: Results = .{};
    defer r.deinit(alloc);
    try r.append(alloc, .{ .start_x = 0, .start_y = 0, .end_x = 0, .end_y = 0 });
    try r.append(alloc, .{ .start_x = 0, .start_y = 9, .end_x = 0, .end_y = 9 });
    try std.testing.expectEqual(@as(u64, 9), r.prev().?.start_y);
}
