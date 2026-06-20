//! whostty: terminal IO — pumps PTY output bytes into libghostty-vt.
//!
//! Reference: ghostty `src/termio.zig` + `src/termio/` (strategy: port —
//! ghostty's termio is a much larger subsystem with a dedicated thread and
//! mailbox; slice-0 keeps just the byte-pump + terminal state, guarded by a
//! mutex so a reader thread can feed bytes while the renderer reads the grid).
//! See PORTING.md.
const std = @import("std");
const vt = @import("ghostty-vt");
const mouse = @import("mouse.zig");

/// Module alias for use inside `ResponseHandler`, whose required `vt` method
/// name shadows the `vt` module import within the struct's scope.
const gvt = vt;

/// The stream handler. libghostty-vt's `ReadonlyStream` applies every
/// state-modifying action to the terminal but deliberately drops the queries
/// that require a reply (DSR / DA / DECRQM / ENQ) — it is meant for replay
/// tooling that has no pty to answer to. We wrap that readonly handler and add
/// only the reverse path: replies are appended to `response`, which the app
/// drains and writes back to the pty. State-modifying actions are delegated to
/// the inner handler unchanged, so none of that logic is duplicated here.
///
/// Reference: ghostty `src/termio/stream_handler.zig`
/// (`deviceAttributes`/`deviceStatusReport`/`requestMode`). See ADR 0006.
const ResponseHandler = struct {
    /// Applies state-modifying actions to the terminal (the upstream handler).
    inner: gvt.ReadonlyHandler,
    /// Pending reply bytes owed to the pty; points into the owning `Termio`.
    response: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,

    fn init(
        terminal: *gvt.Terminal,
        response: *std.ArrayListUnmanaged(u8),
        alloc: std.mem.Allocator,
    ) ResponseHandler {
        return .{
            .inner = gvt.ReadonlyHandler.init(terminal),
            .response = response,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *ResponseHandler) void {
        self.inner.deinit();
    }

    /// Stream action dispatch. Query actions that owe a reply are handled here;
    /// every other action is delegated to the readonly handler unchanged.
    pub fn vt(
        self: *ResponseHandler,
        comptime action: gvt.StreamAction.Tag,
        value: gvt.StreamAction.Value(action),
    ) !void {
        switch (action) {
            .device_attributes => try self.deviceAttributes(value),
            .device_status => try self.deviceStatus(value),
            .request_mode => try self.requestMode(value.mode),
            .request_mode_unknown => try self.requestModeUnknown(value),
            .color_operation => try self.colorOperation(value),

            // ENQ falls through: ghostty's default `enquiry-response` is the
            // empty string, so replying with nothing (the readonly handler's
            // no-op) is the faithful default. xtversion / size-report /
            // kitty-keyboard-query replies belong to later sub-issues (#82).
            else => try self.inner.vt(action, value),
        }
    }

    fn reply(self: *ResponseHandler, bytes: []const u8) !void {
        try self.response.appendSlice(self.alloc, bytes);
    }

    /// DA — CSI c / CSI > c. We quack as a VT220 like ghostty, but omit the
    /// `52` clipboard flag from the primary reply: OSC 52 write-back isn't
    /// wired yet (#85), and advertising it would invite queries we can't
    /// answer. The `52` is added when OSC 52 lands.
    fn deviceAttributes(self: *ResponseHandler, req: gvt.DeviceAttributeReq) !void {
        switch (req) {
            // 62 = VT220 (level 2 conformance); 22 = color text.
            .primary => try self.reply("\x1b[?62;22c"),
            .secondary => try self.reply("\x1b[>1;10;0c"),
            else => {}, // tertiary: unimplemented, matching ghostty
        }
    }

    /// DSR — CSI 5n / CSI 6n. The cursor-position report honors origin mode,
    /// reporting cursor coordinates relative to the scrolling region.
    fn deviceStatus(self: *ResponseHandler, ds: gvt.StreamAction.Value(.device_status)) !void {
        switch (ds.request) {
            .operating_status => try self.reply("\x1b[0n"),
            .cursor_position => {
                const t = self.inner.terminal;
                const cur = t.screens.active.cursor;
                const origin = t.modes.get(.origin);
                const x = if (origin) cur.x -| t.scrolling_region.left else cur.x;
                const y = if (origin) cur.y -| t.scrolling_region.top else cur.y;
                var buf: [32]u8 = undefined;
                try self.reply(try std.fmt.bufPrint(&buf, "\x1b[{d};{d}R", .{ y + 1, x + 1 }));
            },
            // Light/dark reporting needs an OS appearance signal whostty does
            // not track yet; deferred with the OSC color work (#83).
            .color_scheme => {},
        }
    }

    /// DECRQM for a mode libghostty-vt recognizes — CSI ? Pd $ p / CSI Pd $ p.
    /// Reply code 1 = set, 2 = reset. DEC private modes carry the `?` prefix.
    fn requestMode(self: *ResponseHandler, mode: gvt.Mode) !void {
        const tag: gvt.modes.ModeTag = @bitCast(@intFromEnum(mode));
        const code: u8 = if (self.inner.terminal.modes.get(mode)) 1 else 2;
        var buf: [32]u8 = undefined;
        try self.reply(try std.fmt.bufPrint(&buf, "\x1b[{s}{d};{d}$y", .{
            if (tag.ansi) "" else "?",
            tag.value,
            code,
        }));
    }

    /// DECRQM for an unrecognized mode. Reply code 0 = mode not recognized.
    fn requestModeUnknown(self: *ResponseHandler, raw: gvt.StreamAction.Value(.request_mode_unknown)) !void {
        var buf: [32]u8 = undefined;
        try self.reply(try std.fmt.bufPrint(&buf, "\x1b[{s}{d};0$y", .{
            if (raw.ansi) "" else "?",
            raw.mode,
        }));
    }

    /// OSC 4 / 10 / 11 / 12 (and friends) color operations. Set/reset are state
    /// changes the readonly handler already applies, so we delegate the whole
    /// operation to it first; then we answer any `?` queries from the resulting
    /// color state. Colors come from `terminal.colors`, which `Termio.seedColors`
    /// primes with the configured defaults, so a query before any runtime change
    /// reports the configured color (not an empty/garbage value).
    ///
    /// Replies use the 16-bit `rgb:RRRR/GGGG/BBBB` form (ghostty's default
    /// `osc-color-report-format`), echoing the request's ST/BEL terminator.
    ///
    /// Sets are applied (via the delegate) before any query is reported, so a
    /// query reports the post-set color. This matches ghostty for the realistic
    /// `set; query` order and diverges only for a nonsensical same-target
    /// `query; set` in a single OSC, which no querying tool emits.
    fn colorOperation(self: *ResponseHandler, value: gvt.StreamAction.Value(.color_operation)) !void {
        try self.inner.vt(.color_operation, value);

        const term = self.inner.terminal;
        var it = value.requests.constIterator(0);
        while (it.next()) |req| {
            const target = switch (req.*) {
                .query => |t| t,
                else => continue,
            };
            const c = switch (target) {
                .palette => |i| term.colors.palette.current[i],
                .dynamic => |d| switch (d) {
                    .foreground => term.colors.foreground.get() orelse continue,
                    .background => term.colors.background.get() orelse continue,
                    .cursor => term.colors.cursor.get() orelse
                        term.colors.foreground.get() orelse continue,
                    // pointer / tektronix / highlight colors aren't tracked yet.
                    else => continue,
                },
                .special => continue,
            };
            // 8-bit channels scaled to 16-bit (x257), matching xterm's report.
            const r: u16 = @as(u16, c.r) * 257;
            const g: u16 = @as(u16, c.g) * 257;
            const b: u16 = @as(u16, c.b) * 257;
            const term_str = value.terminator.string();
            var buf: [64]u8 = undefined;
            const body = switch (target) {
                .palette => |i| try std.fmt.bufPrint(&buf, "\x1b]4;{d};rgb:{x:0>4}/{x:0>4}/{x:0>4}{s}", .{ i, r, g, b, term_str }),
                .dynamic => |d| try std.fmt.bufPrint(&buf, "\x1b]{d};rgb:{x:0>4}/{x:0>4}/{x:0>4}{s}", .{ @intFromEnum(d), r, g, b, term_str }),
                .special => continue,
            };
            try self.reply(body);
        }
    }
};

/// Owns the VT parser stream and the terminal state. Heap-allocated so the
/// stream's handler can hold a stable pointer to `terminal`.
pub const Termio = struct {
    pub const Pin = vt.Pin;
    /// The type of `terminal.screens.active` (`*Screen`), derived without relying
    /// on libghostty-vt re-exporting the Screen type.
    const ActiveScreen = @FieldType(@FieldType(vt.Terminal, "screens"), "active");

    terminal: vt.Terminal,
    stream: vt.Stream(ResponseHandler),
    /// Reply bytes the terminal owes the pty (DSR/DA/DECRQM), filled by the
    /// handler during `process` and drained by `takeResponse`. Guarded by
    /// `mutex` since `process` (reader thread) and `takeResponse` (UI thread)
    /// touch it from different threads.
    response: std.ArrayListUnmanaged(u8),
    /// Guards `terminal`: the reader thread mutates it via `process`, the
    /// renderer reads it. Lock with `lock`/`unlock` around grid access.
    mutex: std.Thread.Mutex,
    alloc: std.mem.Allocator,

    /// Mouse-drag selection anchor: a tracked pin plus the exact screen it was
    /// created on. Binding the drag to that screen prevents building a
    /// cross-PageList selection if an app switches to the alternate screen
    /// (`\e[?1049h`) mid-drag.
    sel_anchor: ?*Pin = null,
    sel_anchor_screen: ?ActiveScreen = null,

    pub fn create(alloc: std.mem.Allocator, cols: u16, rows: u16, max_scrollback: usize) !*Termio {
        const self = try alloc.create(Termio);
        errdefer alloc.destroy(self);

        self.alloc = alloc;
        self.mutex = .{};
        self.response = .empty;
        self.sel_anchor = null;
        self.sel_anchor_screen = null;
        self.terminal = try vt.Terminal.init(alloc, .{
            .cols = cols,
            .rows = rows,
            .max_scrollback = max_scrollback,
        });
        errdefer self.terminal.deinit(alloc);

        // The handler holds &self.terminal and &self.response, both stable
        // because `self` is heap-allocated and never moved.
        self.stream = vt.Stream(ResponseHandler).initAlloc(
            alloc,
            ResponseHandler.init(&self.terminal, &self.response, alloc),
        );
        return self;
    }

    pub fn destroy(self: *Termio) void {
        const alloc = self.alloc;
        self.stream.deinit();
        self.response.deinit(alloc);
        self.terminal.deinit(alloc);
        alloc.destroy(self);
    }

    /// Move pending VT replies (DSR/DA/DECRQM) into `buf`, returning the number
    /// of bytes written; the caller writes them to the pty. If the queue
    /// exceeds `buf`, the remainder stays queued for the next call (drain in a
    /// loop). Thread-safe with respect to `process`.
    pub fn takeResponse(self: *Termio, buf: []u8) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        const n = @min(buf.len, self.response.items.len);
        if (n == 0) return 0;
        @memcpy(buf[0..n], self.response.items[0..n]);
        if (n == self.response.items.len) {
            self.response.clearRetainingCapacity();
        } else {
            std.mem.copyForwards(u8, self.response.items, self.response.items[n..]);
            self.response.shrinkRetainingCapacity(self.response.items.len - n);
        }
        return n;
    }

    /// Feed raw PTY output bytes (text + escape sequences) into the terminal,
    /// updating the grid. Thread-safe with respect to grid readers.
    pub fn process(self: *Termio, bytes: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.stream.nextSlice(bytes);
    }

    /// Seed the terminal's dynamic colors with the configured defaults so that
    /// OSC color queries report the configured color (until an app overrides it)
    /// and the renderer can treat `terminal.colors` as the single source of
    /// truth (OSC 10/11/4 then take visible effect). Call once before the reader
    /// thread starts; not synchronized.
    pub fn seedColors(
        self: *Termio,
        fg: vt.color.RGB,
        bg: vt.color.RGB,
        cursor: ?vt.color.RGB,
        palette: *const vt.color.Palette,
    ) void {
        self.terminal.colors.foreground = .init(fg);
        self.terminal.colors.background = .init(bg);
        // Cursor color is optional: if the user configured one it becomes the
        // default, which OSC 12 can then override; otherwise it stays unset and
        // the cursor derives its color from the cell. Either way the query reply
        // and the rendered cursor read the same `terminal.colors.cursor`.
        if (cursor) |c| self.terminal.colors.cursor = .init(c);
        self.terminal.colors.palette = .init(palette.*);
    }

    /// The effective default background — the OSC 11 override if an app set one,
    /// else `fallback` (the configured background). Used for the framebuffer
    /// clear color. Thread-safe.
    pub fn backgroundColor(self: *Termio, fallback: vt.color.RGB) vt.color.RGB {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.terminal.colors.background.get() orelse fallback;
    }

    /// The focus report to send the pty for a focus change, or null if the app
    /// hasn't enabled focus reporting (DEC mode 1004). `CSI I` = focus in,
    /// `CSI O` = focus out. Thread-safe; the returned slice is a static literal.
    ///
    /// Reports the change only. ghostty additionally emits the current focus
    /// state the instant mode 1004 is enabled; that on-enable report needs the
    /// window focus state (which lives in the app layer) and is deferred.
    pub fn focusReport(self: *Termio, focused: bool) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.terminal.modes.get(.focus_event)) return null;
        return if (focused) "\x1b[I" else "\x1b[O";
    }

    /// Key-encoding options derived from the current terminal state: cursor-key
    /// application mode (DECCKM), keypad mode, modify-other-keys, and the
    /// alt-esc prefix. Kitty keyboard output is forced **off**: the Win32 layer
    /// still emits raw UTF-8 for printable keys via WM_CHAR, so routing special
    /// keys through the kitty encoder would be inconsistent. Full kitty output
    /// and the `CSI ? u` reply are deferred (#82). Thread-safe.
    pub fn keyEncodeOptions(self: *Termio) vt.input.KeyEncodeOptions {
        self.mutex.lock();
        defer self.mutex.unlock();
        var opts = vt.input.KeyEncodeOptions.fromTerminal(&self.terminal);
        opts.kitty_flags = .disabled;
        return opts;
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
    // All locked internally; the selected region lives in the VT core. The drag
    // anchor is a tracked pin (survives the reader thread's mutation / scroll /
    // reflow) bound to the screen it was created on.

    /// Begin a drag selection anchored at the given viewport cell.
    pub fn selectStart(self: *Termio, x: u16, y: u16) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.releaseAnchorLocked();
        const screen = self.terminal.screens.active;
        screen.clearSelection();
        const p = screen.pages.pin(.{ .viewport = .{ .x = x, .y = y } }) orelse return;
        self.sel_anchor = screen.pages.trackPin(p) catch return;
        self.sel_anchor_screen = screen;
    }

    /// Extend the active drag selection to the given viewport cell.
    pub fn selectExtend(self: *Termio, x: u16, y: u16) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const anchor = self.sel_anchor orelse return;
        const screen = self.sel_anchor_screen orelse return;
        // If the active screen changed since the drag started (alternate-screen
        // switch), the anchor belongs to a different PageList — don't cross pools.
        if (screen != self.terminal.screens.active) return;
        const cur = screen.pages.pin(.{ .viewport = .{ .x = x, .y = y } }) orelse return;
        screen.select(vt.Selection.init(anchor.*, cur, false)) catch {};
    }

    /// End the drag (the selection stays set, owning its own tracked pins). The
    /// anchor is untracked on the screen it was created on.
    pub fn selectEnd(self: *Termio) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.releaseAnchorLocked();
    }

    fn releaseAnchorLocked(self: *Termio) void {
        if (self.sel_anchor) |a| {
            // Only untrack if the anchor's screen is still the active one. If the
            // app switched away from (or, via RIS, *freed*) that screen, the pin
            // was freed with it — dereferencing the stored pointer would be a
            // use-after-free. Just drop the fields in that case.
            if (self.sel_anchor_screen) |s| {
                if (s == self.terminal.screens.active) s.pages.untrackPin(a);
            }
            self.sel_anchor = null;
            self.sel_anchor_screen = null;
        }
    }

    pub fn clearSelection(self: *Termio) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.terminal.screens.active.clearSelection();
    }

    /// Encode a mouse event as a VT report into `buf` if the terminal currently
    /// requests mouse tracking, else null. Reads the mode/format under the lock.
    /// The MouseEvents/MouseFormat enums share integer values with mouse.zig's.
    pub fn encodeMouseReport(
        self: *Termio,
        buf: []u8,
        col: u16,
        row: u16,
        button: mouse.Button,
        action: mouse.Action,
        mods: mouse.Mods,
    ) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const ev: mouse.Event = @enumFromInt(@intFromEnum(self.terminal.flags.mouse_event));
        if (ev == .none) return null;
        const fmt: mouse.Format = @enumFromInt(@intFromEnum(self.terminal.flags.mouse_format));
        return mouse.encode(buf, ev, fmt, button, action, mods, col, row);
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

    // Drag-select viewport cells (0,0)..(4,0) -> "hello".
    io.selectStart(0, 0);
    io.selectExtend(4, 0);

    const text = (try io.selectionStringAlloc(alloc)) orelse return error.NoSelection;
    defer alloc.free(text);
    try std.testing.expectEqualStrings("hello", text);

    io.selectEnd();
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

// --- VT response write-back (DSR/DA/DECRQM) -----------------------------------

/// Feed `bytes`, then return the queued reply as a slice of `buf`.
fn replyTo(io: *Termio, bytes: []const u8, buf: []u8) ![]const u8 {
    try io.process(bytes);
    return buf[0..io.takeResponse(buf)];
}

test "termio: no reply for plain output" {
    const alloc = std.testing.allocator;
    const io = try Termio.create(alloc, 20, 3, 1 << 20);
    defer io.destroy();

    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("", try replyTo(io, "hello", &buf));
}

test "termio: DSR operating status reports OK" {
    const alloc = std.testing.allocator;
    const io = try Termio.create(alloc, 20, 3, 1 << 20);
    defer io.destroy();

    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[0n", try replyTo(io, "\x1b[5n", &buf));
}

test "termio: DSR cursor position report is 1-based row;col" {
    const alloc = std.testing.allocator;
    const io = try Termio.create(alloc, 20, 5, 1 << 20);
    defer io.destroy();

    var buf: [64]u8 = undefined;
    // Move to row 3, col 5 (1-based), then query position.
    try std.testing.expectEqualStrings("\x1b[3;5R", try replyTo(io, "\x1b[3;5H\x1b[6n", &buf));
}

test "termio: primary device attributes quack as VT220" {
    const alloc = std.testing.allocator;
    const io = try Termio.create(alloc, 20, 3, 1 << 20);
    defer io.destroy();

    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[?62;22c", try replyTo(io, "\x1b[c", &buf));
}

test "termio: secondary device attributes" {
    const alloc = std.testing.allocator;
    const io = try Termio.create(alloc, 20, 3, 1 << 20);
    defer io.destroy();

    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[>1;10;0c", try replyTo(io, "\x1b[>c", &buf));
}

test "termio: DECRQM reports a known mode's state" {
    const alloc = std.testing.allocator;
    const io = try Termio.create(alloc, 20, 3, 1 << 20);
    defer io.destroy();

    var buf: [64]u8 = undefined;
    // Wraparound (DEC private mode 7) is on by default -> set (1).
    try std.testing.expectEqualStrings("\x1b[?7;1$y", try replyTo(io, "\x1b[?7$p", &buf));
    // Disable it, then re-query -> reset (2).
    try std.testing.expectEqualStrings("\x1b[?7;2$y", try replyTo(io, "\x1b[?7l\x1b[?7$p", &buf));
}

test "termio: DECRQM reports an unknown mode as not recognized" {
    const alloc = std.testing.allocator;
    const io = try Termio.create(alloc, 20, 3, 1 << 20);
    defer io.destroy();

    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[?9999;0$y", try replyTo(io, "\x1b[?9999$p", &buf));
}

test "termio: keyEncodeOptions reflects DECCKM and forces kitty output off" {
    const alloc = std.testing.allocator;
    const io = try Termio.create(alloc, 20, 3, 1 << 20);
    defer io.destroy();

    // Default: cursor-key application mode off.
    try std.testing.expect(!io.keyEncodeOptions().cursor_key_application);

    // App enables DECCKM (cursor keys) -> reflected in the encode options.
    try io.process("\x1b[?1h");
    try std.testing.expect(io.keyEncodeOptions().cursor_key_application);

    // App pushes kitty keyboard flags: the terminal records them...
    try io.process("\x1b[>1u");
    try std.testing.expect(io.terminal.screens.active.kitty_keyboard.current().int() != 0);
    // ...but key-encode options force kitty output off (the WM_CHAR text path is
    // still legacy; full kitty output is deferred).
    try std.testing.expectEqual(@as(u5, 0), io.keyEncodeOptions().kitty_flags.int());
}

test "termio: OSC 11 set then query reports the background (16-bit)" {
    const alloc = std.testing.allocator;
    const io = try Termio.create(alloc, 20, 3, 1 << 20);
    defer io.destroy();

    var buf: [128]u8 = undefined;
    // Setting a color produces no reply.
    try std.testing.expectEqualStrings("", try replyTo(io, "\x1b]11;rgb:ff/00/00\x07", &buf));
    // Querying reports it scaled to 16-bit, echoing the BEL terminator.
    try std.testing.expectEqualStrings(
        "\x1b]11;rgb:ffff/0000/0000\x07",
        try replyTo(io, "\x1b]11;?\x07", &buf),
    );
}

test "termio: OSC 4 palette set then query reports the color, ST terminator" {
    const alloc = std.testing.allocator;
    const io = try Termio.create(alloc, 20, 3, 1 << 20);
    defer io.destroy();

    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", try replyTo(io, "\x1b]4;5;rgb:12/34/56\x07", &buf));
    // ST-terminated query -> ST-terminated reply.
    try std.testing.expectEqualStrings(
        "\x1b]4;5;rgb:1212/3434/5656\x1b\\",
        try replyTo(io, "\x1b]4;5;?\x1b\\", &buf),
    );
}

test "termio: OSC 10 query reports the seeded foreground default" {
    const alloc = std.testing.allocator;
    const io = try Termio.create(alloc, 20, 3, 1 << 20);
    defer io.destroy();

    // No app override yet: the reply is the configured (seeded) foreground.
    io.seedColors(.{ .r = 0xab, .g = 0xcd, .b = 0xef }, .{ .r = 0, .g = 0, .b = 0 }, null, &vt.color.default);
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "\x1b]10;rgb:abab/cdcd/efef\x07",
        try replyTo(io, "\x1b]10;?\x07", &buf),
    );
}

test "termio: seeded background is overridden by OSC 11 and read back" {
    const alloc = std.testing.allocator;
    const io = try Termio.create(alloc, 20, 3, 1 << 20);
    defer io.destroy();

    io.seedColors(.{ .r = 0x10, .g = 0x20, .b = 0x30 }, .{ .r = 0x01, .g = 0x02, .b = 0x03 }, null, &vt.color.default);
    // backgroundColor returns the seeded default until an app overrides it.
    try std.testing.expectEqual(vt.color.RGB{ .r = 0x01, .g = 0x02, .b = 0x03 }, io.backgroundColor(.{ .r = 0, .g = 0, .b = 0 }));
    try io.process("\x1b]11;rgb:aa/bb/cc\x07");
    try std.testing.expectEqual(vt.color.RGB{ .r = 0xaa, .g = 0xbb, .b = 0xcc }, io.backgroundColor(.{ .r = 0, .g = 0, .b = 0 }));
}

test "termio: OSC 12 cursor query reports seed then OSC override" {
    const alloc = std.testing.allocator;
    const io = try Termio.create(alloc, 20, 3, 1 << 20);
    defer io.destroy();

    // Seed a configured cursor color: the query reports it (and the renderer,
    // which reads the same terminal.colors.cursor, would paint it).
    io.seedColors(.{ .r = 0, .g = 0, .b = 0 }, .{ .r = 0, .g = 0, .b = 0 }, .{ .r = 0x11, .g = 0x22, .b = 0x33 }, &vt.color.default);
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "\x1b]12;rgb:1111/2222/3333\x07",
        try replyTo(io, "\x1b]12;?\x07", &buf),
    );
    // OSC 12 set overrides the seed and is read back.
    try io.process("\x1b]12;rgb:ee/dd/cc\x07");
    try std.testing.expectEqualStrings(
        "\x1b]12;rgb:eeee/dddd/cccc\x07",
        try replyTo(io, "\x1b]12;?\x07", &buf),
    );
}

test "termio: focus reporting follows DEC mode 1004" {
    const alloc = std.testing.allocator;
    const io = try Termio.create(alloc, 20, 3, 1 << 20);
    defer io.destroy();

    // Off by default: no report.
    try std.testing.expect(io.focusReport(true) == null);
    try std.testing.expect(io.focusReport(false) == null);

    // App enables focus reporting -> CSI I on focus in, CSI O on focus out.
    try io.process("\x1b[?1004h");
    try std.testing.expectEqualStrings("\x1b[I", io.focusReport(true).?);
    try std.testing.expectEqualStrings("\x1b[O", io.focusReport(false).?);

    // Disabling stops the reports.
    try io.process("\x1b[?1004l");
    try std.testing.expect(io.focusReport(true) == null);
}

test "termio: takeResponse drains and clears the queue" {
    const alloc = std.testing.allocator;
    const io = try Termio.create(alloc, 20, 3, 1 << 20);
    defer io.destroy();

    try io.process("\x1b[5n");
    var buf: [64]u8 = undefined;
    try std.testing.expect(io.takeResponse(&buf) > 0);
    // Second drain on the now-empty queue yields nothing.
    try std.testing.expectEqual(@as(usize, 0), io.takeResponse(&buf));
}
