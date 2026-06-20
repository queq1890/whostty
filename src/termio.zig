//! whostty: terminal IO — pumps PTY output bytes into libghostty-vt.
//!
//! Reference: ghostty `src/termio.zig` + `src/termio/` (strategy: port —
//! ghostty's termio is a much larger subsystem with a dedicated thread and
//! mailbox; slice-0 keeps just the byte-pump + terminal state, guarded by a
//! mutex so a reader thread can feed bytes while the renderer reads the grid).
//! See PORTING.md.
const std = @import("std");
const vt = @import("ghostty-vt");

/// Owns the VT parser stream and the terminal state. Heap-allocated so the
/// stream's handler can hold a stable pointer to `terminal`.
pub const Termio = struct {
    terminal: vt.Terminal,
    stream: vt.ReadonlyStream,
    /// Guards `terminal`: the reader thread mutates it via `process`, the
    /// renderer reads it. Lock with `lock`/`unlock` around grid access.
    mutex: std.Thread.Mutex,
    alloc: std.mem.Allocator,

    pub fn create(alloc: std.mem.Allocator, cols: u16, rows: u16, max_scrollback: usize) !*Termio {
        const self = try alloc.create(Termio);
        errdefer alloc.destroy(self);

        self.alloc = alloc;
        self.mutex = .{};
        self.terminal = try vt.Terminal.init(alloc, .{
            .cols = cols,
            .rows = rows,
            .max_scrollback = max_scrollback,
        });
        errdefer self.terminal.deinit(alloc);

        // The handler holds &self.terminal, which is stable because `self` is
        // heap-allocated and never moved.
        self.stream = vt.ReadonlyStream.initAlloc(alloc, .init(&self.terminal));
        return self;
    }

    pub fn destroy(self: *Termio) void {
        const alloc = self.alloc;
        self.stream.deinit();
        self.terminal.deinit(alloc);
        alloc.destroy(self);
    }

    /// Feed raw PTY output bytes (text + escape sequences) into the terminal,
    /// updating the grid. Thread-safe with respect to grid readers.
    pub fn process(self: *Termio, bytes: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.stream.nextSlice(bytes);
    }

    /// Resize the terminal grid. Thread-safe.
    pub fn resize(self: *Termio, cols: u16, rows: u16) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.terminal.resize(self.alloc, cols, rows);
    }

    /// Scroll the viewport into (negative) or back out of (positive) the
    /// scrollback history by `delta_rows`. The scrollback storage and clamping
    /// live in libghostty-vt's PageList. Thread-safe.
    pub fn scrollViewport(self: *Termio, delta_rows: isize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.terminal.screens.active.pages.scroll(.{ .delta_row = delta_rows });
    }

    /// Snap the viewport back to the active (bottom) area. Thread-safe.
    pub fn scrollToBottom(self: *Termio) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.terminal.screens.active.pages.scroll(.active);
    }

    /// Lock the terminal for reading the grid; pair with `unlock`.
    pub fn lock(self: *Termio) void {
        self.mutex.lock();
    }

    pub fn unlock(self: *Termio) void {
        self.mutex.unlock();
    }

    // --- Selection (mouse drag -> screen.selection) ------------------------
    // All locked internally; the selected region lives in the VT core. Pins are
    // tracked so they survive the reader thread's mutations / scroll / reflow.

    pub const Pin = vt.Pin;

    /// Pin a viewport cell and return a *tracked* pin (stable across mutation),
    /// or null. Pair every non-null result with `untrackPin`.
    pub fn pinViewportTracked(self: *Termio, x: u16, y: u16) ?*Pin {
        self.mutex.lock();
        defer self.mutex.unlock();
        const screen = self.terminal.screens.active;
        const p = screen.pages.pin(.{ .viewport = .{ .x = x, .y = y } }) orelse return null;
        return screen.pages.trackPin(p) catch null;
    }

    pub fn untrackPin(self: *Termio, p: *Pin) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.terminal.screens.active.pages.untrackPin(p);
    }

    /// Set the active selection to span from `anchor` to the given viewport cell.
    pub fn selectTo(self: *Termio, anchor: *Pin, x: u16, y: u16) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const screen = self.terminal.screens.active;
        const cur = screen.pages.pin(.{ .viewport = .{ .x = x, .y = y } }) orelse return;
        screen.select(vt.Selection.init(anchor.*, cur, false)) catch {};
    }

    pub fn clearSelection(self: *Termio) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.terminal.screens.active.clearSelection();
    }

    /// The current selection as UTF-8 (NUL-terminated), or null if none. Caller
    /// owns the returned slice.
    pub fn selectionStringAlloc(self: *Termio, alloc: std.mem.Allocator) !?[:0]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const screen = self.terminal.screens.active;
        const sel = screen.selection orelse return null;
        return try screen.selectionString(alloc, .{ .sel = sel, .trim = false });
    }

    /// Dump the active viewport as plain text (used by tests / debug).
    pub fn dumpAlloc(self: *Termio, alloc: std.mem.Allocator) ![]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.terminal.plainString(alloc);
    }
};

test "termio: plain text updates the grid" {
    const alloc = std.testing.allocator;
    const io = try Termio.create(alloc, 20, 3, 1 << 20);
    defer io.destroy();

    try io.process("hello");

    const dump = try io.dumpAlloc(alloc);
    defer alloc.free(dump);
    try std.testing.expect(std.mem.indexOf(u8, dump, "hello") != null);
}

test "termio: escape sequences move the cursor (overwrite)" {
    const alloc = std.testing.allocator;
    const io = try Termio.create(alloc, 20, 3, 1 << 20);
    defer io.destroy();

    // Print, then home the cursor and overwrite the first two cells.
    try io.process("XXXXX");
    try io.process("\x1b[1;1H"); // cursor to row 1, col 1
    try io.process("ab");

    const dump = try io.dumpAlloc(alloc);
    defer alloc.free(dump);
    const line = std.mem.trimRight(u8, dump, " \n");
    try std.testing.expect(std.mem.startsWith(u8, line, "abXXX"));
}

test "termio: selection over written cells yields the selected text" {
    const alloc = std.testing.allocator;
    const io = try Termio.create(alloc, 20, 3, 1 << 20);
    defer io.destroy();

    try io.process("hello world");

    // No selection initially.
    try std.testing.expect((try io.selectionStringAlloc(alloc)) == null);

    // Select viewport cells (0,0)..(4,0) -> "hello".
    const anchor = io.pinViewportTracked(0, 0) orelse return error.NoPin;
    defer io.untrackPin(anchor);
    io.selectTo(anchor, 4, 0);

    const text = (try io.selectionStringAlloc(alloc)) orelse return error.NoSelection;
    defer alloc.free(text);
    try std.testing.expectEqualStrings("hello", text);

    io.clearSelection();
    try std.testing.expect((try io.selectionStringAlloc(alloc)) == null);
}

test "termio: resize changes dimensions" {
    const alloc = std.testing.allocator;
    const io = try Termio.create(alloc, 20, 3, 1 << 20);
    defer io.destroy();

    try io.resize(40, 10);
    try std.testing.expectEqual(@as(usize, 40), io.terminal.cols);
    try std.testing.expectEqual(@as(usize, 10), io.terminal.rows);
}
