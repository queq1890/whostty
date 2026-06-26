//! whostty: terminal IO — pumps PTY output bytes into libghostty-vt.
//!
//! Reference: ghostty `src/termio.zig` + `src/termio/` (strategy: port —
//! ghostty's termio is a much larger subsystem with a dedicated thread and
//! mailbox; slice-0 keeps just the byte-pump + terminal state, guarded by a
//! mutex so a reader thread can feed bytes while the renderer reads the grid).
//! See PORTING.md.
const std = @import("std");
const vt = @import("ghostty-vt");
const mouse = @import("engine/mouse.zig");
/// The unified per-pane cwd store (#134). OSC 7 and OSC 133 (#136) both write
/// this single canonical path so consumers never reconcile two sources.
const engine_cwd = @import("engine/cwd.zig");
/// The attention side channel public types (#135): typed bell / notification /
/// progress events + the host `Sink` callback.
const engine_attn = @import("engine/attention.zig");
/// OSC 133 semantic prompt marks (#136): per-pane semantic state + boundaries.
const engine_semantic = @import("engine/semantic.zig");
/// OSC 8 hyperlink ranges (#139): the host-facing `Range` type whostty resolves
/// from live cell hyperlink state.
const engine_hyperlink = @import("engine/hyperlink.zig");
/// Scrollback search results (#138): the host-facing `Match` + `Results` nav.
const engine_search = @import("engine/search.zig");

/// Module alias for use inside `ResponseHandler`, whose required `vt` method
/// name shadows the `vt` module import within the struct's scope.
const gvt = vt;

/// A desktop notification captured from OSC 9 / OSC 777, owned by `alloc`.
/// The app raises it out-of-band (a Windows toast / tray balloon); the OS
/// surfacing is tracked under the windows-host work (#43).
pub const Notification = struct {
    title: []u8,
    body: []u8,

    pub fn deinit(self: *Notification, alloc: std.mem.Allocator) void {
        alloc.free(self.title);
        alloc.free(self.body);
        self.* = undefined;
    }
};

/// Out-of-band terminal events the app consumes off the reply path — they don't
/// owe the pty a response, but the *app* (not the VT core) must act on them:
/// ring the bell, track the shell's working directory (OSC 7), raise desktop
/// notifications (OSC 9 / 777) and drive the taskbar progress bar (OSC 9;4).
/// `ReadonlyHandler` drops all of these (they have no terminal-modifying
/// effect), so `ResponseHandler` captures them here. Written on the reader
/// thread, drained on the UI thread; guarded by `Termio.mutex`.
const SideChannel = struct {
    /// Bells rung since the last drain. The app flashes the window once per
    /// drain regardless of count; the count just records that one happened.
    bell_count: u32 = 0,
    /// The unified working-directory store (#134): one canonical cwd fed by both
    /// OSC 7 (the raw `file://` URL) and OSC 133 (#136). An empty OSC 7 url
    /// clears it (ghostty's "forget the pwd" behavior). Owns its buffer.
    cwd: engine_cwd.Cwd = .{},
    /// Latest OSC 0/2 window title (UTF-8), owned by `alloc`; latest wins until
    /// drained. An empty title clears it (matching the cwd reset semantics).
    title: ?[]u8 = null,
    /// Latest desktop notification, owned; latest wins until drained.
    notification: ?Notification = null,
    /// Latest taskbar progress state (OSC 9;4). A *state*, not an event: it
    /// persists until the app changes it. `.remove` (no bar) is the idle default.
    progress: gvt.osc.Command.ProgressReport = .{ .state = .remove },
    /// Optional host callback (#135): when set, fired on the reader thread the
    /// instant an attention event (bell / notification / progress) is captured,
    /// so the host can react eagerly instead of waiting for the next poll. Set
    /// via `Termio.setAttentionSink`; guarded by `Termio.mutex` like the rest.
    attention_sink: ?engine_attn.Sink = null,
    /// OSC 133 semantic prompt marks (#136): the running semantic state, the last
    /// command's exit code, and the recorded command/prompt boundaries. Captured
    /// on the reader thread, read on the UI thread under `Termio.mutex`.
    semantic: engine_semantic.Marks = .{},

    fn deinit(self: *SideChannel, alloc: std.mem.Allocator) void {
        self.cwd.deinit(alloc);
        if (self.title) |t| alloc.free(t);
        if (self.notification) |*n| n.deinit(alloc);
        self.semantic.deinit(alloc);
        self.* = undefined;
    }
};

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
    /// Pending OSC 52 clipboard write (decoded, owned); points into `Termio`.
    /// The UI thread drains it because clipboard access needs the window.
    clipboard_write: *?[]u8,
    /// Out-of-band events (bell / cwd / notification / progress); points into
    /// `Termio`, drained on the UI thread.
    side: *SideChannel,
    alloc: std.mem.Allocator,

    fn init(
        terminal: *gvt.Terminal,
        response: *std.ArrayListUnmanaged(u8),
        clipboard_write: *?[]u8,
        side: *SideChannel,
        alloc: std.mem.Allocator,
    ) ResponseHandler {
        return .{
            .inner = gvt.ReadonlyHandler.init(terminal),
            .response = response,
            .clipboard_write = clipboard_write,
            .side = side,
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
            .clipboard_contents => self.clipboardContents(value),
            .kitty_keyboard_query => try self.queryKittyKeyboard(),

            // Out-of-band events the app consumes (not pty replies). The readonly
            // handler drops these, so we capture them into the side channel and
            // (if a sink is registered, #135) notify the host eagerly.
            .bell => self.bell(),
            .report_pwd => try self.reportPwd(value.url),
            .show_desktop_notification => try self.showNotification(value),
            .progress_report => self.captureProgress(value),
            .window_title => try self.setTitle(value.title),

            // OSC 133 semantic prompt marks (#136): capture the boundary for the
            // host-facing state machine, then delegate to the inner handler so
            // libghostty-vt still applies the per-row prompt flags + click state.
            .semantic_prompt => try self.semanticPrompt(value),

            // CSI 21t report-title and the CSI 22t/23t title stack are deferred.
            // The vt surfaces 21t muxed into `.size_report = .csi_21_t` (alongside
            // the pixel/cell size reports) and 22t/23t as bare `.title_push`/
            // `.title_pop` u16 index events carrying no title bytes — both require
            // whostty to own the title state and (for 21t) gate the reply behind
            // config, which ghostty itself leaves stubbed for the stack. They fall
            // through to the inner readonly handler (a no-op) for now.

            // ENQ falls through: ghostty's default `enquiry-response` is the
            // empty string, so replying with nothing (the readonly handler's
            // no-op) is the faithful default. xtversion / size-report replies
            // belong to later work.
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

    /// OSC 52 — clipboard set/get.
    ///
    /// - A **read** request (`data == "?"`) is **denied** for privacy: answering
    ///   it would let any program exfiltrate the clipboard.
    /// - A **write** decodes the base64 payload and queues the text for the UI
    ///   thread, which owns clipboard access; the latest write wins. An **empty**
    ///   payload decodes to an empty string, which is the spec's "clear the
    ///   clipboard" form (ghostty does the same). Bad base64 or OOM drops the
    ///   write (best-effort, never fatal).
    ///
    /// The write direction is currently **always allowed** — whostty has no
    /// clipboard-write access policy (allow/ask/deny) yet; both that and a config
    /// to permit reads are deferred (#50). The `kind` (clipboard selection) is
    /// ignored — we always use the standard clipboard, matching ghostty.
    fn clipboardContents(self: *ResponseHandler, cc: gvt.StreamAction.Value(.clipboard_contents)) void {
        if (cc.data.len == 1 and cc.data[0] == '?') return; // read denied
        const dec = std.base64.standard.Decoder;
        const n = dec.calcSizeForSlice(cc.data) catch return;
        const buf = self.alloc.alloc(u8, n) catch return;
        dec.decode(buf, cc.data) catch |err| switch (err) {
            // Non-canonical trailing bits: the decoded prefix is valid and fully
            // written, so keep it — matching ghostty, which accepts this because
            // some encoders emit it for otherwise-fine data.
            error.InvalidPadding => {},
            else => {
                self.alloc.free(buf);
                return;
            },
        };
        if (self.clipboard_write.*) |old| self.alloc.free(old);
        self.clipboard_write.* = buf;
    }

    /// Kitty keyboard query (`CSI ? u`) — report the active screen's current
    /// kitty keyboard flags as `CSI ? <flags> u`, so a probing app (e.g. nvim)
    /// learns the protocol is understood. Once an app pushes flags, key *output*
    /// is encoded in kitty CSI-u form by the Win32 layer (#82); this query just
    /// reports the live flag set.
    fn queryKittyKeyboard(self: *ResponseHandler) !void {
        const flags = self.inner.terminal.screens.active.kitty_keyboard.current().int();
        var buf: [32]u8 = undefined;
        try self.reply(try std.fmt.bufPrint(&buf, "\x1b[?{d}u", .{flags}));
    }

    /// OSC 7 — record the shell's reported working directory (the raw url) into
    /// the unified cwd store (#134). An empty url resets it (ghostty treats that
    /// as "the pwd is unknown"). OSC 133 (#136) writes the *same* store, so the
    /// cwd is one canonical path. The consumers (window title #89, new-window
    /// inheritance #87, whomux's sidebar) read it via `cwdAlloc`. The url slice
    /// is only valid during the call, so the store duplicates it.
    fn reportPwd(self: *ResponseHandler, url: []const u8) !void {
        try self.side.cwd.set(self.alloc, url);
    }

    /// OSC 0 / OSC 2 — capture the window title (UTF-8). The vt has already
    /// UTF-8-validated the bytes; the slice is valid only during the call, so it
    /// is duplicated into the side channel. An empty title clears it (matching
    /// the cwd reset semantics). The UI thread drains it via `takeTitle`.
    fn setTitle(self: *ResponseHandler, title: []const u8) !void {
        if (self.side.title) |old| {
            self.alloc.free(old);
            self.side.title = null;
        }
        if (title.len == 0) return;
        self.side.title = try self.alloc.dupe(u8, title);
    }

    /// BEL — record a bell edge and notify the host eagerly (#135). The count is
    /// drained take-and-clear by `takeBellCount`; the sink just learns one rang.
    fn bell(self: *ResponseHandler) void {
        self.side.bell_count +|= 1;
        if (self.side.attention_sink) |s| s.notify(.bell);
    }

    /// OSC 9;4 — record the latest taskbar progress *level* and notify the host
    /// (#135). Unlike the edges, the level persists (read via `progress`).
    fn captureProgress(self: *ResponseHandler, value: gvt.osc.Command.ProgressReport) void {
        self.side.progress = value;
        if (self.side.attention_sink) |s| s.notify(.{ .progress = engineProgress(value) });
    }

    /// OSC 9 / OSC 777 — capture a desktop notification (title may be empty for
    /// the OSC 9 form). Both fields are valid only during the call, so they are
    /// duplicated; the latest notification wins until the app drains it. The host
    /// sink (#135) is notified with the *borrowed* slices (valid for the call).
    fn showNotification(self: *ResponseHandler, n: gvt.StreamAction.Value(.show_desktop_notification)) !void {
        const title = try self.alloc.dupe(u8, n.title);
        errdefer self.alloc.free(title);
        const body = try self.alloc.dupe(u8, n.body);
        if (self.side.notification) |*old| old.deinit(self.alloc);
        self.side.notification = .{ .title = title, .body = body };
        if (self.side.attention_sink) |s| s.notify(.{ .notification = .{ .title = n.title, .body = n.body } });
    }

    /// OSC 133 — capture the semantic boundary for the host-facing state machine
    /// (#136): map the FinalTerm action, read the exit code for a command end,
    /// and tag it with the cursor's history-stable row. Then delegate to the
    /// inner handler so libghostty-vt still applies the per-row prompt flags and
    /// prompt/click state (this arm replaces the default fall-through).
    ///
    /// OSC 133 in libghostty-vt carries no cwd field, so there is nothing to
    /// route into the unified cwd store here; if a future cwd option appears it
    /// would call `self.side.cwd.set` — the same single store OSC 7 writes (#134).
    fn semanticPrompt(self: *ResponseHandler, cmd: gvt.StreamAction.Value(.semantic_prompt)) !void {
        const action: ?engine_semantic.Action = switch (cmd.action) {
            .fresh_line_new_prompt, .prompt_start => .prompt,
            .end_prompt_start_input, .end_prompt_start_input_terminate_eol => .input,
            .end_input_start_output => .command,
            .end_command => .end,
            // L (fresh line) and N (new command) are not boundaries we track.
            .fresh_line, .new_command => null,
        };
        if (action) |a| {
            const exit_code: ?i32 = if (a == .end) cmd.readOption(.exit_code) else null;
            try self.side.semantic.record(self.alloc, a, self.cursorAbsRow(), exit_code);
        }
        try self.inner.vt(.semantic_prompt, cmd);
    }

    /// The cursor's history-absolute row (rows from the top of scrollback), used
    /// to tag a semantic boundary so the host can scroll to it. Stable until
    /// scrollback is trimmed; 0 if the pin can't be mapped.
    fn cursorAbsRow(self: *ResponseHandler) u64 {
        const screen = self.inner.terminal.screens.active;
        const pt = screen.pages.pointFromPin(.screen, screen.cursor.page_pin.*) orelse return 0;
        return @intCast(pt.screen.y);
    }
};

/// Map libghostty-vt's progress report onto the engine's host-facing `Progress`,
/// decoupling whomux from the VT core's exact type (#135). The state enums share
/// the same five members; this switch keeps the boundary explicit.
fn engineProgress(p: gvt.osc.Command.ProgressReport) engine_attn.Progress {
    return .{
        .state = switch (p.state) {
            .remove => .remove,
            .set => .set,
            .@"error" => .@"error",
            .indeterminate => .indeterminate,
            .pause => .pause,
        },
        .percent = p.progress,
    };
}

/// Append a hyperlink range, duping the (borrowed) target URI into `alloc`. On
/// an append failure the freshly-duped URI is freed so nothing leaks (#139).
fn appendRange(
    alloc: std.mem.Allocator,
    ranges: *std.ArrayListUnmanaged(engine_hyperlink.Range),
    y: u16,
    x_start: u16,
    x_end: u16,
    uri: []const u8,
) !void {
    const dup = try alloc.dupe(u8, uri);
    ranges.append(alloc, .{ .y = y, .x_start = x_start, .x_end = x_end, .target = dup }) catch |e| {
        alloc.free(dup);
        return e;
    };
}

/// Append the physical row at row index `pin_y` of `page` (width `cols`) as UTF-8
/// to `buf` (#138). When `col_map` is non-null, also append — for every byte
/// written — the cell column that produced it, so a byte offset maps back to a
/// cell column for search. Wide-char tail spacers are skipped (the wide cell
/// already contributed its codepoint); empty cells become spaces so columns stay
/// aligned. `page` is a `*Page` from a pin's node.
fn appendRowBytes(
    alloc: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    col_map: ?*std.ArrayListUnmanaged(u16),
    page: anytype,
    pin_y: u16,
    cols: u16,
) !void {
    var x: u16 = 0;
    while (x < cols) : (x += 1) {
        const cell = page.getRowAndCell(x, pin_y).cell;
        if (cell.wide == .spacer_tail) continue; // second half of a wide char
        const cp: u21 = blk: {
            const c = cell.codepoint();
            break :blk if (c == 0) ' ' else c;
        };
        var utf8: [4]u8 = undefined;
        const len: usize = std.unicode.utf8Encode(cp, &utf8) catch enc: {
            utf8[0] = '?';
            break :enc 1;
        };
        try buf.appendSlice(alloc, utf8[0..len]);
        if (col_map) |cm| {
            var i: usize = 0;
            while (i < len) : (i += 1) try cm.append(alloc, x);
        }
    }
}

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
    /// Pending OSC 52 clipboard write (decoded text, owned by `alloc`), filled
    /// by the handler and drained by `takeClipboardWrite` on the UI thread.
    /// Latest write wins. Guarded by `mutex`.
    clipboard_write: ?[]u8,
    /// Out-of-band events (bell / OSC 7 cwd / OSC 9-777 notification / OSC 9;4
    /// progress) captured by the handler and drained on the UI thread. Guarded
    /// by `mutex`.
    side: SideChannel,
    /// Guards `terminal`: the reader thread mutates it via `process`, the
    /// renderer reads it. Lock with `lock`/`unlock` around grid access.
    mutex: std.Thread.Mutex,
    /// Bumped on every `process` (pty-output apply) so the UI thread can tell,
    /// without diffing the grid, that the screen may have changed and a redraw
    /// is needed — the basis of frame pacing (#72). Wraps harmlessly. Guarded by
    /// `mutex`. UI-initiated mutations (resize/scroll/selection) are already
    /// known to the UI thread (they ride its own events), so they don't bump it.
    dirty_gen: u64,
    alloc: std.mem.Allocator,

    /// Mouse-drag selection anchor: a tracked pin plus the exact screen it was
    /// created on. Binding the drag to that screen prevents building a
    /// cross-PageList selection if an app switches to the alternate screen
    /// (`\e[?1049h`) mid-drag.
    sel_anchor: ?*Pin = null,
    sel_anchor_screen: ?ActiveScreen = null,

    /// Scrollback search results (#138): filled by `searchStart` (a UI-thread
    /// scan over the screen rows), navigated by `searchNext`/`searchPrev`. Guarded
    /// by `mutex` since the scan reads the grid.
    search: engine_search.Results = .{},

    pub fn create(alloc: std.mem.Allocator, cols: u16, rows: u16, max_scrollback: usize) !*Termio {
        const self = try alloc.create(Termio);
        errdefer alloc.destroy(self);

        self.alloc = alloc;
        self.mutex = .{};
        self.response = .empty;
        self.clipboard_write = null;
        self.side = .{};
        self.dirty_gen = 0;
        self.sel_anchor = null;
        self.sel_anchor_screen = null;
        self.search = .{};
        self.terminal = try vt.Terminal.init(alloc, .{
            .cols = cols,
            .rows = rows,
            .max_scrollback = max_scrollback,
        });
        errdefer self.terminal.deinit(alloc);

        // The handler holds pointers into `self` (terminal, response,
        // clipboard_write, side), all stable because `self` is heap-allocated.
        self.stream = vt.Stream(ResponseHandler).initAlloc(
            alloc,
            ResponseHandler.init(&self.terminal, &self.response, &self.clipboard_write, &self.side, alloc),
        );
        return self;
    }

    pub fn destroy(self: *Termio) void {
        const alloc = self.alloc;
        self.stream.deinit();
        self.response.deinit(alloc);
        if (self.clipboard_write) |c| alloc.free(c);
        self.side.deinit(alloc);
        self.search.deinit(alloc);
        self.terminal.deinit(alloc);
        alloc.destroy(self);
    }

    /// Take the pending OSC 52 clipboard write, if any; ownership transfers to
    /// the caller (free with the same allocator). The caller writes it to the
    /// system clipboard (a UI-thread operation). Thread-safe.
    pub fn takeClipboardWrite(self: *Termio) ?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const c = self.clipboard_write;
        self.clipboard_write = null;
        return c;
    }

    /// Number of bells rung since the last call, then reset to 0. The app rings
    /// the bell (flashes the window) when this is non-zero. Thread-safe.
    pub fn takeBellCount(self: *Termio) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const n = self.side.bell_count;
        self.side.bell_count = 0;
        return n;
    }

    /// The pane's working directory — the single canonical value fed by OSC 7
    /// and OSC 133 (#134) — duplicated into `alloc` for the caller to own, or
    /// null if none has been reported or it was reset (the empty-url "forget the
    /// pwd" case, so whomux can fall back to the spawn directory). This is the
    /// per-Surface `cwd()` accessor; reads take the `Termio` mutex. Thread-safe.
    pub fn cwdAlloc(self: *Termio, alloc: std.mem.Allocator) !?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const c = self.side.cwd.get() orelse return null;
        return try alloc.dupe(u8, c);
    }

    /// Take the pending desktop notification (OSC 9 / 777), transferring
    /// ownership to the caller (free with `Notification.deinit`), or null if
    /// none is pending. Thread-safe.
    pub fn takeNotification(self: *Termio) ?Notification {
        self.mutex.lock();
        defer self.mutex.unlock();
        const n = self.side.notification;
        self.side.notification = null;
        return n;
    }

    /// Take the pending window title (OSC 0/2), transferring ownership to the
    /// caller (free with `alloc`), or null if none is pending. Drained on the UI
    /// thread to apply once per change. Thread-safe.
    pub fn takeTitle(self: *Termio) ?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const t = self.side.title;
        self.side.title = null;
        return t;
    }

    /// The current taskbar progress state (OSC 9;4). Unlike the other side
    /// channels this is a persistent *state* (not drained): the app reads it to
    /// drive the taskbar. Thread-safe.
    pub fn progressReport(self: *Termio) vt.osc.Command.ProgressReport {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.side.progress;
    }

    /// The current OSC 9;4 progress as the host-facing `engine.attention.Progress`
    /// (state + percent), decoupled from the VT core's type — this is the public
    /// per-Surface progress *level* getter (#135). Persistent (not drained), the
    /// `.remove` idle default until an app sets it. Thread-safe.
    pub fn progress(self: *Termio) engine_attn.Progress {
        self.mutex.lock();
        defer self.mutex.unlock();
        return engineProgress(self.side.progress);
    }

    /// Register (or clear, with null) the host attention `Sink` (#135). When set,
    /// it fires on the reader thread under `mutex` the instant a bell /
    /// notification / progress event is captured, so the host can react eagerly
    /// (e.g. wake a sleeping frame loop) rather than waiting for the next poll.
    /// The sink must not block or re-enter `Termio`. Thread-safe.
    pub fn setAttentionSink(self: *Termio, sink: ?engine_attn.Sink) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.side.attention_sink = sink;
    }

    /// The pane's current OSC 133 semantic state (#136): at-prompt (waiting for
    /// input), running, done, or unknown. whomux mirrors this for per-pane agent
    /// state. Thread-safe.
    pub fn semanticState(self: *Termio) engine_semantic.State {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.side.semantic.state();
    }

    /// The most recent command's exit code (the last OSC 133 `D`), or null if no
    /// command has finished yet. Thread-safe.
    pub fn lastExitCode(self: *Termio) ?i32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.side.semantic.last_exit_code;
    }

    /// A snapshot of the recorded OSC 133 command/prompt boundaries (#136),
    /// oldest first, duplicated into `alloc` for the caller to own (free the
    /// returned slice). Each carries its kind, the history-stable row it occurred
    /// at (for navigation), and — for a command end — the exit code. Thread-safe.
    pub fn commandBoundaries(self: *Termio, alloc: std.mem.Allocator) ![]engine_semantic.Mark {
        self.mutex.lock();
        defer self.mutex.unlock();
        return alloc.dupe(engine_semantic.Mark, self.side.semantic.boundaries());
    }

    /// The OSC 8 hyperlink target at viewport cell (x, y), duplicated into
    /// `alloc` for the caller to own, or null if that cell carries no hyperlink
    /// (#139). libghostty-vt has already attached the link to the cell; this
    /// resolves it to its URI. Thread-safe.
    pub fn hyperlinkAt(self: *Termio, alloc: std.mem.Allocator, x: u16, y: u16) !?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const screen = self.terminal.screens.active;
        const p = screen.pages.pin(.{ .viewport = .{ .x = x, .y = y } }) orelse return null;
        const page = &p.node.data;
        const rac = p.rowAndCell();
        if (!rac.cell.hyperlink) return null;
        const id = page.lookupHyperlink(rac.cell) orelse return null;
        const uri = page.hyperlink_set.get(page.memory, id).uri.slice(page.memory);
        return try alloc.dupe(u8, uri);
    }

    /// Enumerate the OSC 8 hyperlink ranges in the visible viewport (#139): each
    /// is a run of consecutive same-link cells on one row, with its target URI,
    /// so the host can underline + hit-test them (a multi-row link yields one
    /// range per row). The returned slice and each `target` are owned by `alloc`;
    /// free the whole result with `engine.hyperlink.freeRanges`. Thread-safe.
    pub fn hyperlinkRanges(self: *Termio, alloc: std.mem.Allocator) ![]engine_hyperlink.Range {
        self.mutex.lock();
        defer self.mutex.unlock();
        const screen = self.terminal.screens.active;
        const cols: u16 = @intCast(self.terminal.cols);
        const rows: u16 = @intCast(self.terminal.rows);

        var ranges: std.ArrayListUnmanaged(engine_hyperlink.Range) = .empty;
        errdefer {
            for (ranges.items) |r| alloc.free(r.target);
            ranges.deinit(alloc);
        }

        var y: u16 = 0;
        while (y < rows) : (y += 1) {
            const p = screen.pages.pin(.{ .viewport = .{ .x = 0, .y = y } }) orelse continue;
            const page = &p.node.data;

            // Walk the row left to right, grouping consecutive cells that share a
            // hyperlink id (page-local, so comparable within this single page row).
            var run_start: ?u16 = null;
            var run_uri: []const u8 = "";
            var run_id: ?usize = null;
            var x: u16 = 0;
            while (x < cols) : (x += 1) {
                const rac = page.getRowAndCell(x, p.y);
                var cur_id: ?usize = null;
                var cur_uri: []const u8 = "";
                if (rac.cell.hyperlink) {
                    if (page.lookupHyperlink(rac.cell)) |id| {
                        cur_id = @intCast(id);
                        cur_uri = page.hyperlink_set.get(page.memory, id).uri.slice(page.memory);
                    }
                }
                if (run_id != cur_id) {
                    if (run_start) |s| try appendRange(alloc, &ranges, y, s, x - 1, run_uri);
                    run_start = if (cur_id != null) x else null;
                    run_id = cur_id;
                    run_uri = cur_uri;
                }
            }
            if (run_start) |s| try appendRange(alloc, &ranges, y, s, cols - 1, run_uri);
        }
        return ranges.toOwnedSlice(alloc);
    }

    // --- Scrollback row access + search (#138) -----------------------------

    /// The text content of viewport row `y` (0 = top visible row), UTF-8 with
    /// trailing blanks trimmed, duplicated into `alloc` (caller owns), or null if
    /// `y` is out of range. whomux scans this for URLs and highlights. Thread-safe.
    pub fn rowText(self: *Termio, alloc: std.mem.Allocator, y: u16) !?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const pin = self.terminal.screens.active.pages.pin(.{ .viewport = .{ .x = 0, .y = y } }) orelse return null;
        return try self.rowTextFromPin(alloc, pin);
    }

    /// The text content of screen-absolute row `screen_y` (rows from the top of
    /// scrollback, history-inclusive) — the coordinate `Match` and semantic
    /// boundaries use, stable across viewport scrolls. Null if out of range.
    /// Thread-safe.
    pub fn rowTextScreen(self: *Termio, alloc: std.mem.Allocator, screen_y: u64) !?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const pin = self.terminal.screens.active.pages.pin(.{ .screen = .{ .x = 0, .y = @intCast(screen_y) } }) orelse return null;
        return try self.rowTextFromPin(alloc, pin);
    }

    fn rowTextFromPin(self: *Termio, alloc: std.mem.Allocator, pin: Pin) ![]u8 {
        const cols: u16 = @intCast(self.terminal.cols);
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(alloc);
        try appendRowBytes(alloc, &buf, null, &pin.node.data, pin.y, cols);
        const trimmed = std.mem.trimRight(u8, buf.items, " ");
        buf.shrinkRetainingCapacity(trimmed.len);
        return try buf.toOwnedSlice(alloc);
    }

    /// Start a scrollback search for `query` (#138): scan every screen row
    /// (scrollback history + active) for the needle and record each match as a
    /// screen-absolute `engine.search.Match`. Replaces any previous search and
    /// returns the match count; an empty query just clears it. Matches are
    /// navigated with `searchNext`/`searchPrev` and dropped with `searchClear`.
    /// Thread-safe.
    pub fn searchStart(self: *Termio, query: []const u8) !usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.search.clear();
        if (query.len == 0) return 0;

        const screen = self.terminal.screens.active;
        const cols: u16 = @intCast(self.terminal.cols);
        const total = screen.pages.scrollbar().total;

        var row_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer row_buf.deinit(self.alloc);
        var col_map: std.ArrayListUnmanaged(u16) = .empty;
        defer col_map.deinit(self.alloc);

        var sy: u64 = 0;
        while (sy < total) : (sy += 1) {
            const pin = screen.pages.pin(.{ .screen = .{ .x = 0, .y = @intCast(sy) } }) orelse continue;
            row_buf.clearRetainingCapacity();
            col_map.clearRetainingCapacity();
            try appendRowBytes(self.alloc, &row_buf, &col_map, &pin.node.data, pin.y, cols);

            // Record every non-overlapping occurrence of the needle in this row,
            // mapping the matched byte span back to its cell columns.
            var off: usize = 0;
            while (off + query.len <= row_buf.items.len) {
                const idx = std.mem.indexOf(u8, row_buf.items[off..], query) orelse break;
                const start_byte = off + idx;
                const end_byte = start_byte + query.len - 1;
                try self.search.append(self.alloc, .{
                    .start_x = col_map.items[start_byte],
                    .start_y = sy,
                    .end_x = col_map.items[end_byte],
                    .end_y = sy,
                });
                off = start_byte + query.len;
            }
        }
        return self.search.count();
    }

    /// The number of matches from the active search (#138). Thread-safe.
    pub fn searchCount(self: *Termio) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.search.count();
    }

    /// Advance to and return the next search match (wrapping), or null if there
    /// are none. The first call selects the first match (#138). Thread-safe.
    pub fn searchNext(self: *Termio) ?engine_search.Match {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.search.next();
    }

    /// Step to and return the previous search match (wrapping), or null if there
    /// are none. The first call selects the last match (#138). Thread-safe.
    pub fn searchPrev(self: *Termio) ?engine_search.Match {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.search.prev();
    }

    /// Clear the active search and its matches (#138). Thread-safe.
    pub fn searchClear(self: *Termio) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.search.clear();
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
        // Mark the screen potentially-changed so the UI thread redraws this
        // frame. `defer` so a mid-slice error (the reader then exits) still
        // reflects any bytes already applied.
        defer self.dirty_gen +%= 1;
        try self.stream.nextSlice(bytes);
    }

    /// The current dirty generation — the number of `process` calls so far.
    /// The UI thread redraws when this differs from the last frame's value
    /// (frame pacing, #72). Thread-safe.
    pub fn dirtyGen(self: *Termio) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.dirty_gen;
    }

    /// Whether a *blinking* cursor is currently shown (so the UI must keep
    /// redrawing at the blink cadence). False when unfocused, when the cursor is
    /// hidden (DECTCEM off), or when blink mode is off — in which case the UI can
    /// sleep until input/output instead of waking twice a second. Thread-safe.
    pub fn cursorBlinks(self: *Termio, focused: bool) bool {
        if (!focused) return false;
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.terminal.modes.get(.cursor_blinking) and
            self.terminal.modes.get(.cursor_visible);
    }

    /// The focused cursor's position in viewport cells (x = column, y = row), or
    /// null when it has scrolled out of view. Mirrors the mapping `buildQuads`
    /// uses to draw the cursor; used to pin the IME composition/candidate window
    /// to the caret (#88). Thread-safe.
    pub fn cursorViewport(self: *Termio) ?struct { x: u32, y: u32 } {
        self.mutex.lock();
        defer self.mutex.unlock();
        const screen = self.terminal.screens.active;
        const cpt = screen.pages.pointFromPin(.viewport, screen.cursor.page_pin.*) orelse return null;
        return .{ .x = cpt.viewport.x, .y = cpt.viewport.y };
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
    /// application mode (DECCKM), keypad mode, modify-other-keys, the alt-esc
    /// prefix, and the active screen's **kitty keyboard flags**. When an app has
    /// enabled the kitty keyboard protocol (`CSI > … u`), the returned
    /// `kitty_flags` are non-empty and the encoder produces kitty CSI-u key
    /// output instead of the legacy bytes (#82). The Win32 layer routes printable
    /// keys through the encoder only when these flags are non-empty, so legacy
    /// WM_CHAR typing is byte-identical when the protocol is off (the common
    /// case). Reading the flags requires the lock (the reader thread mutates
    /// `screens.active` as it parses), which `fromTerminal` reads under the lock
    /// held here. Thread-safe.
    pub fn keyEncodeOptions(self: *Termio) vt.input.KeyEncodeOptions {
        self.mutex.lock();
        defer self.mutex.unlock();
        return vt.input.KeyEncodeOptions.fromTerminal(&self.terminal);
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

    /// Scrollbar geometry from the VT viewport (libghostty-vt's authoritative
    /// computation): `total` scrollable rows, the viewport's `offset` from the
    /// top (rows above the first visible row), and the visible `len`. The
    /// renderer turns this into a thumb via `scroll.scrollbarThumb`. Thread-safe.
    pub const Scrollbar = struct { total: usize, offset: usize, len: usize };
    pub fn scrollbar(self: *Termio) Scrollbar {
        self.mutex.lock();
        defer self.mutex.unlock();
        const sb = self.terminal.screens.active.pages.scrollbar();
        return .{ .total = sb.total, .offset = sb.offset, .len = sb.len };
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
        button: ?mouse.Button,
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

test "termio: keyEncodeOptions reflects DECCKM and live kitty flags" {
    const alloc = std.testing.allocator;
    const io = try Termio.create(alloc, 20, 3, 1 << 20);
    defer io.destroy();

    // Default: cursor-key application mode off and kitty keyboard disabled, so
    // legacy encoding (raw WM_CHAR for printables) stays in effect.
    try std.testing.expect(!io.keyEncodeOptions().cursor_key_application);
    try std.testing.expectEqual(@as(u5, 0), io.keyEncodeOptions().kitty_flags.int());

    // App enables DECCKM (cursor keys) -> reflected in the encode options.
    try io.process("\x1b[?1h");
    try std.testing.expect(io.keyEncodeOptions().cursor_key_application);

    // App pushes kitty keyboard flags (`CSI > 1 u` = disambiguate): the terminal
    // records them AND they now flow through to the encode options, so key output
    // switches to kitty CSI-u form (#82). `>1u` sets just the disambiguate bit.
    try io.process("\x1b[>1u");
    try std.testing.expect(io.terminal.screens.active.kitty_keyboard.current().int() != 0);
    try std.testing.expectEqual(@as(u5, 1), io.keyEncodeOptions().kitty_flags.int());
    try std.testing.expect(io.keyEncodeOptions().kitty_flags.disambiguate);

    // Popping back to an empty stack returns to legacy (flags off).
    try io.process("\x1b[<u");
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

test "termio: OSC 52 write decodes base64 and queues it for the UI thread" {
    const alloc = std.testing.allocator;
    const io = try Termio.create(alloc, 20, 3, 1 << 20);
    defer io.destroy();

    // "aGVsbG8=" is base64 for "hello".
    try io.process("\x1b]52;c;aGVsbG8=\x07");
    const got = io.takeClipboardWrite() orelse return error.NoClipboardWrite;
    defer alloc.free(got);
    try std.testing.expectEqualStrings("hello", got);
    // Draining clears it.
    try std.testing.expect(io.takeClipboardWrite() == null);
}

test "termio: OSC 52 latest write wins" {
    const alloc = std.testing.allocator;
    const io = try Termio.create(alloc, 20, 3, 1 << 20);
    defer io.destroy();

    try io.process("\x1b]52;c;Zmlyc3Q=\x07"); // "first"
    try io.process("\x1b]52;c;c2Vjb25k\x07"); // "second"
    const got = io.takeClipboardWrite() orelse return error.NoClipboardWrite;
    defer alloc.free(got);
    try std.testing.expectEqualStrings("second", got);
}

test "termio: OSC 52 read is denied (no reply, no clipboard op)" {
    const alloc = std.testing.allocator;
    const io = try Termio.create(alloc, 20, 3, 1 << 20);
    defer io.destroy();

    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("", try replyTo(io, "\x1b]52;c;?\x07", &buf));
    try std.testing.expect(io.takeClipboardWrite() == null);
}

test "termio: OSC 52 invalid base64 is dropped" {
    const alloc = std.testing.allocator;
    const io = try Termio.create(alloc, 20, 3, 1 << 20);
    defer io.destroy();

    try io.process("\x1b]52;c;!!!notbase64!!!\x07");
    try std.testing.expect(io.takeClipboardWrite() == null);
}

test "termio: OSC 52 accepts non-canonical padding like ghostty" {
    const alloc = std.testing.allocator;
    const io = try Termio.create(alloc, 20, 3, 1 << 20);
    defer io.destroy();

    // "aa==" has non-canonical trailing bits (InvalidPadding) but a valid
    // leading byte (0x69 = 'i'); ghostty keeps it, so we do too.
    try io.process("\x1b]52;c;aa==\x07");
    const got = io.takeClipboardWrite() orelse return error.NoClipboardWrite;
    defer alloc.free(got);
    try std.testing.expectEqualStrings("i", got);
}

test "termio: OSC 52 empty payload clears the clipboard" {
    const alloc = std.testing.allocator;
    const io = try Termio.create(alloc, 20, 3, 1 << 20);
    defer io.destroy();

    // Empty (non-"?") payload is the spec's clear form: a zero-length write.
    try io.process("\x1b]52;c;\x07");
    const got = io.takeClipboardWrite() orelse return error.NoClipboardWrite;
    defer alloc.free(got);
    try std.testing.expectEqual(@as(usize, 0), got.len);
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

test "termio: kitty keyboard query reports the current flags (CSI ?u)" {
    const alloc = std.testing.allocator;
    const io = try Termio.create(alloc, 20, 3, 1 << 20);
    defer io.destroy();

    var buf: [64]u8 = undefined;
    // No flags pushed yet -> 0.
    try std.testing.expectEqualStrings("\x1b[?0u", try replyTo(io, "\x1b[?u", &buf));
    // App pushes flags 1 (disambiguate escape codes); the query now reports 1.
    try std.testing.expectEqualStrings("\x1b[?1u", try replyTo(io, "\x1b[>1u\x1b[?u", &buf));
}

test "termio: BEL increments the bell count, drained once" {
    const alloc = std.testing.allocator;
    const io = try Termio.create(alloc, 20, 3, 1 << 20);
    defer io.destroy();

    // Plain output rings no bell.
    try io.process("hi");
    try std.testing.expectEqual(@as(u32, 0), io.takeBellCount());

    // Two BELs -> count 2, then draining clears it.
    try io.process("\x07ab\x07");
    try std.testing.expectEqual(@as(u32, 2), io.takeBellCount());
    try std.testing.expectEqual(@as(u32, 0), io.takeBellCount());
}

test "termio: OSC 7 records and resets the working directory" {
    const alloc = std.testing.allocator;
    const io = try Termio.create(alloc, 20, 3, 1 << 20);
    defer io.destroy();

    // None reported yet.
    try std.testing.expect((try io.cwdAlloc(alloc)) == null);

    try io.process("\x1b]7;file://host/home/user\x1b\\");
    const cwd = (try io.cwdAlloc(alloc)) orelse return error.NoCwd;
    defer alloc.free(cwd);
    try std.testing.expectEqualStrings("file://host/home/user", cwd);

    // An empty OSC 7 forgets the pwd.
    try io.process("\x1b]7;\x1b\\");
    try std.testing.expect((try io.cwdAlloc(alloc)) == null);
}

test "termio: OSC 7 and the OSC 133 path write a single canonical cwd store (#134)" {
    const alloc = std.testing.allocator;
    const io = try Termio.create(alloc, 20, 3, 1 << 20);
    defer io.destroy();

    // OSC 7 writes the unified store.
    try io.process("\x1b]7;file://host/from/osc7\x1b\\");
    {
        const c = (try io.cwdAlloc(alloc)) orelse return error.NoCwd;
        defer alloc.free(c);
        try std.testing.expectEqualStrings("file://host/from/osc7", c);
    }

    // The OSC 133 prompt-mark path (#136) routes its reported directory into the
    // *same* `side.cwd` store rather than a second source — so the latest value
    // is indistinguishable from an OSC 7 update. Exercise that shared store
    // directly here (the OSC 133 capture is wired in #136) to assert there is
    // exactly one cwd field.
    io.mutex.lock();
    try io.side.cwd.set(alloc, "/from/osc133");
    io.mutex.unlock();
    {
        const c = (try io.cwdAlloc(alloc)) orelse return error.NoCwd;
        defer alloc.free(c);
        try std.testing.expectEqualStrings("/from/osc133", c);
    }
}

test "termio: OSC 0 / OSC 2 capture the window title, drained once, empty clears" {
    const alloc = std.testing.allocator;
    const io = try Termio.create(alloc, 20, 3, 1 << 20);
    defer io.destroy();

    // Plain output sets no title.
    try io.process("hi");
    try std.testing.expect(io.takeTitle() == null);

    // OSC 0 (icon + window title) sets it.
    try io.process("\x1b]0;Hello\x07");
    {
        const t = io.takeTitle() orelse return error.NoTitle;
        defer alloc.free(t);
        try std.testing.expectEqualStrings("Hello", t);
    }
    // Draining clears it.
    try std.testing.expect(io.takeTitle() == null);

    // OSC 2 (window title) sets it; a later title overwrites an undrained one.
    try io.process("\x1b]2;World\x07");
    try io.process("\x1b]2;Again\x07");
    {
        const t = io.takeTitle() orelse return error.NoTitle;
        defer alloc.free(t);
        try std.testing.expectEqualStrings("Again", t);
    }

    // An empty title clears it.
    try io.process("\x1b]2;Set\x07");
    try io.process("\x1b]2;\x07");
    try std.testing.expect(io.takeTitle() == null);
}

test "termio: OSC 9 / OSC 777 desktop notifications, latest wins" {
    const alloc = std.testing.allocator;
    const io = try Termio.create(alloc, 20, 3, 1 << 20);
    defer io.destroy();

    // OSC 9: body only, empty title.
    try io.process("\x1b]9;Build finished\x07");
    {
        var n = io.takeNotification() orelse return error.NoNotification;
        defer n.deinit(alloc);
        try std.testing.expectEqualStrings("", n.title);
        try std.testing.expectEqualStrings("Build finished", n.body);
    }
    // Draining clears it.
    try std.testing.expect(io.takeNotification() == null);

    // OSC 777: title + body, and a later one overwrites an undrained earlier one.
    try io.process("\x1b]777;notify;First;A\x07");
    try io.process("\x1b]777;notify;Second;B\x07");
    {
        var n = io.takeNotification() orelse return error.NoNotification;
        defer n.deinit(alloc);
        try std.testing.expectEqualStrings("Second", n.title);
        try std.testing.expectEqualStrings("B", n.body);
    }
}

test "termio: OSC 9;4 progress report is captured as persistent state" {
    const alloc = std.testing.allocator;
    const io = try Termio.create(alloc, 20, 3, 1 << 20);
    defer io.destroy();

    // Idle default: no bar.
    try std.testing.expectEqual(vt.osc.Command.ProgressReport.State.remove, io.progressReport().state);

    // Set 50%.
    try io.process("\x1b]9;4;1;50\x07");
    const p = io.progressReport();
    try std.testing.expectEqual(vt.osc.Command.ProgressReport.State.set, p.state);
    try std.testing.expectEqual(@as(?u8, 50), p.progress);

    // It persists (a state, not an event): a second read still reports it.
    try std.testing.expectEqual(vt.osc.Command.ProgressReport.State.set, io.progressReport().state);

    // Remove clears the bar.
    try io.process("\x1b]9;4;0;\x07");
    try std.testing.expectEqual(vt.osc.Command.ProgressReport.State.remove, io.progressReport().state);
}

test "termio: progress() exposes OSC 9;4 as the engine attention level (#135)" {
    const alloc = std.testing.allocator;
    const io = try Termio.create(alloc, 20, 3, 1 << 20);
    defer io.destroy();

    try std.testing.expectEqual(engine_attn.Progress.State.remove, io.progress().state);

    // Error state at 80%.
    try io.process("\x1b]9;4;2;80\x07");
    const p = io.progress();
    try std.testing.expectEqual(engine_attn.Progress.State.@"error", p.state);
    try std.testing.expectEqual(@as(?u8, 80), p.percent);
}

test "termio: attention sink fires eagerly for bell, notification and progress (#135)" {
    const alloc = std.testing.allocator;
    const io = try Termio.create(alloc, 20, 3, 1 << 20);
    defer io.destroy();

    const Captured = struct {
        bells: u32 = 0,
        notif_title: [64]u8 = undefined,
        notif_title_len: usize = 0,
        notif_body: [64]u8 = undefined,
        notif_body_len: usize = 0,
        progress_state: ?engine_attn.Progress.State = null,
        progress_percent: ?u8 = null,

        fn onEvent(ctx: *anyopaque, event: engine_attn.Event) void {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            switch (event) {
                .bell => c.bells += 1,
                .notification => |n| {
                    // Copy out: the slices are borrowed for this call only.
                    @memcpy(c.notif_title[0..n.title.len], n.title);
                    c.notif_title_len = n.title.len;
                    @memcpy(c.notif_body[0..n.body.len], n.body);
                    c.notif_body_len = n.body.len;
                },
                .progress => |p| {
                    c.progress_state = p.state;
                    c.progress_percent = p.percent;
                },
            }
        }
    };

    var cap: Captured = .{};
    io.setAttentionSink(.{ .ctx = &cap, .on_event = Captured.onEvent });

    // Bell edge.
    try io.process("\x07");
    try std.testing.expectEqual(@as(u32, 1), cap.bells);

    // OSC 777 notification (title + body), delivered eagerly with borrowed slices.
    try io.process("\x1b]777;notify;Build;passed\x07");
    try std.testing.expectEqualStrings("Build", cap.notif_title[0..cap.notif_title_len]);
    try std.testing.expectEqualStrings("passed", cap.notif_body[0..cap.notif_body_len]);

    // OSC 9;4 progress level.
    try io.process("\x1b]9;4;1;25\x07");
    try std.testing.expectEqual(engine_attn.Progress.State.set, cap.progress_state.?);
    try std.testing.expectEqual(@as(?u8, 25), cap.progress_percent);

    // Clearing the sink stops eager delivery; the poll API still works.
    io.setAttentionSink(null);
    try io.process("\x07");
    try std.testing.expectEqual(@as(u32, 1), cap.bells); // unchanged
    try std.testing.expectEqual(@as(u32, 2), io.takeBellCount()); // both bells counted
}

test "termio: OSC 133 A/B/C/D drives semantic state, exit code and boundaries (#136)" {
    const alloc = std.testing.allocator;
    const io = try Termio.create(alloc, 20, 5, 1 << 20);
    defer io.destroy();

    // No OSC 133 yet -> unknown.
    try std.testing.expectEqual(engine_semantic.State.unknown, io.semanticState());

    // A: new prompt -> at prompt.
    try io.process("\x1b]133;A\x07");
    try std.testing.expectEqual(engine_semantic.State.prompt, io.semanticState());

    // B: prompt end / input start -> still at prompt (waiting for the user).
    try io.process("\x1b]133;B\x07");
    try std.testing.expectEqual(engine_semantic.State.prompt, io.semanticState());

    // The user "types" a command and runs it.
    try io.process("ls\r\n");

    // C: command output start -> running.
    try io.process("\x1b]133;C\x07");
    try std.testing.expectEqual(engine_semantic.State.running, io.semanticState());

    // D;0: command end, exit 0 -> done with the captured status.
    try io.process("\x1b]133;D;0\x07");
    try std.testing.expectEqual(engine_semantic.State.done, io.semanticState());
    try std.testing.expectEqual(@as(?i32, 0), io.lastExitCode());

    // The boundaries are enumerable for navigation: A, B, C, D.
    const bounds = try io.commandBoundaries(alloc);
    defer alloc.free(bounds);
    try std.testing.expectEqual(@as(usize, 4), bounds.len);
    try std.testing.expectEqual(engine_semantic.Mark.Kind.prompt_start, bounds[0].kind);
    try std.testing.expectEqual(engine_semantic.Mark.Kind.input_start, bounds[1].kind);
    try std.testing.expectEqual(engine_semantic.Mark.Kind.command_start, bounds[2].kind);
    try std.testing.expectEqual(engine_semantic.Mark.Kind.command_end, bounds[3].kind);
    try std.testing.expectEqual(@as(?i32, 0), bounds[3].exit_code);

    // A failing command's non-zero status is captured too.
    try io.process("\x1b]133;A\x07\x1b]133;C\x07\x1b]133;D;127\x07");
    try std.testing.expectEqual(engine_semantic.State.done, io.semanticState());
    try std.testing.expectEqual(@as(?i32, 127), io.lastExitCode());
}

test "termio: the bundled shell-integration scripts' OSC 133 output is recorded (#152)" {
    const alloc = std.testing.allocator;
    const io = try Termio.create(alloc, 40, 5, 1 << 20);
    defer io.destroy();

    // The OSC 133 sequence the bundled bash script emits over one
    // prompt -> command -> prompt cycle (no pre-existing PROMPT_COMMAND),
    // verified on-device against a live bash (#152). The host test suite has no
    // shell, so this curated stream — not an in-process capture — stands in for
    // the script's output and pins the engine's parsing of it:
    //   precmd:  D;<exit> (skipped on the first prompt) then A
    //   PS1:     B at the end of the prompt
    //   preexec: C before the command runs
    // Running `echo hi` (exit 0) between two prompts produces:
    try io.process(
        "\x1b]133;A\x07" ++ // precmd: first prompt start (no preceding D)
            "user@host:~$ \x1b]133;B\x07" ++ // prompt text + PS1 B (input start)
            "echo hi\r\n" ++ // the typed command, echoed
            "\x1b]133;C\x07" ++ // preexec: command output start
            "hi\r\n" ++ // command output
            "\x1b]133;D;0\x07" ++ // precmd: command end, exit 0
            "\x1b]133;A\x07" ++ // precmd: next prompt start
            "user@host:~$ \x1b]133;B\x07", // prompt text + PS1 B
    );

    // The engine recorded every boundary the scripts emitted, in order.
    const bounds = try io.commandBoundaries(alloc);
    defer alloc.free(bounds);
    const K = engine_semantic.Mark.Kind;
    const expected = [_]K{ .prompt_start, .input_start, .command_start, .command_end, .prompt_start, .input_start };
    try std.testing.expectEqual(expected.len, bounds.len);
    for (expected, bounds) |want, got| try std.testing.expectEqual(want, got.kind);

    // The command's exit status rode in on D, and after the trailing A/B the pane
    // is back at a prompt waiting for input.
    try std.testing.expectEqual(@as(?i32, 0), bounds[3].exit_code);
    try std.testing.expectEqual(@as(?i32, 0), io.lastExitCode());
    try std.testing.expectEqual(engine_semantic.State.prompt, io.semanticState());
}

test "termio: OSC 8 hyperlink attaches a target to a cell run, enumerable (#139)" {
    const alloc = std.testing.allocator;
    const io = try Termio.create(alloc, 20, 3, 1 << 20);
    defer io.destroy();

    // Open OSC 8 with a URI, print a 4-cell run, close it, then print unlinked
    // text: cells 0..3 = "link", col 4 = space, then "later".
    try io.process("\x1b]8;;https://example.com\x1b\\link\x1b]8;;\x1b\\ later");

    // Cells within the run report the target.
    {
        const t = (try io.hyperlinkAt(alloc, 0, 0)) orelse return error.NoLink;
        defer alloc.free(t);
        try std.testing.expectEqualStrings("https://example.com", t);
    }
    {
        const t = (try io.hyperlinkAt(alloc, 3, 0)) orelse return error.NoLink;
        defer alloc.free(t);
        try std.testing.expectEqualStrings("https://example.com", t);
    }

    // A cell outside any hyperlink reports no target.
    try std.testing.expect((try io.hyperlinkAt(alloc, 6, 0)) == null);

    // Enumeration returns the single run [0..3] on row 0 with its target.
    const ranges = try io.hyperlinkRanges(alloc);
    defer engine_hyperlink.freeRanges(alloc, ranges);
    try std.testing.expectEqual(@as(usize, 1), ranges.len);
    try std.testing.expectEqual(@as(u16, 0), ranges[0].y);
    try std.testing.expectEqual(@as(u16, 0), ranges[0].x_start);
    try std.testing.expectEqual(@as(u16, 3), ranges[0].x_end);
    try std.testing.expectEqualStrings("https://example.com", ranges[0].target);
}

test "termio: scrollback row access + search navigation, stable across scroll (#138)" {
    const alloc = std.testing.allocator;
    const io = try Termio.create(alloc, 20, 3, 1 << 20); // 3 visible rows

    defer io.destroy();

    // Seed lines that scroll into history; "needle" appears on two of them.
    try io.process("alpha needle\r\n"); // -> scrollback row, "needle" at col 6
    try io.process("beta\r\n");
    try io.process("gamma needle end\r\n"); // "needle" at col 6
    try io.process("delta\r\n");
    try io.process("epsilon"); // current line (cursor row)

    // Row access: the bottom visible row is the current line.
    {
        const t = (try io.rowText(alloc, 2)) orelse return error.NoRow;
        defer alloc.free(t);
        try std.testing.expectEqualStrings("epsilon", t);
    }

    // Search finds both occurrences, recorded top-to-bottom.
    try std.testing.expectEqual(@as(usize, 2), try io.searchStart("needle"));
    try std.testing.expectEqual(@as(usize, 2), io.searchCount());

    // Forward navigation visits both then wraps; columns map to the cells.
    const m1 = io.searchNext().?;
    const m2 = io.searchNext().?;
    try std.testing.expect(m1.start_y < m2.start_y);
    try std.testing.expectEqual(@as(u16, 6), m1.start_x);
    try std.testing.expectEqual(@as(u16, 11), m1.end_x); // "needle" is 6 cells: 6..11
    const m1_again = io.searchNext().?; // wrapped
    try std.testing.expectEqual(m1.start_y, m1_again.start_y);

    // Backward navigation (from m1 wraps back to m2).
    try std.testing.expectEqual(m2.start_y, io.searchPrev().?.start_y);

    // The match's screen-absolute row is stable across a viewport scroll: the
    // row at its screen_y holds the same text before and after scrolling up.
    const before = (try io.rowTextScreen(alloc, m1.start_y)) orelse return error.NoRow;
    defer alloc.free(before);
    io.scrollViewport(-2); // scroll up into scrollback
    const after = (try io.rowTextScreen(alloc, m1.start_y)) orelse return error.NoRow;
    defer alloc.free(after);
    try std.testing.expectEqualStrings(before, after);
    try std.testing.expect(std.mem.indexOf(u8, after, "needle") != null);

    // Clearing drops the matches.
    io.searchClear();
    try std.testing.expectEqual(@as(usize, 0), io.searchCount());
    try std.testing.expect(io.searchNext() == null);
}

test "termio: scrollbar reflects scrollback growth and viewport position" {
    const alloc = std.testing.allocator;
    const io = try Termio.create(alloc, 20, 3, 1 << 20);
    defer io.destroy();

    // Fresh screen: the viewport is everything, so total == len and no offset.
    {
        const sb = io.scrollbar();
        try std.testing.expectEqual(@as(usize, 3), sb.len);
        try std.testing.expectEqual(sb.len, sb.total);
        try std.testing.expectEqual(@as(usize, 0), sb.offset);
    }

    // Print more lines than fit -> history accumulates, total exceeds the view.
    var i: usize = 0;
    while (i < 30) : (i += 1) try io.process("line\r\n");
    const grown = io.scrollbar();
    try std.testing.expect(grown.total > grown.len);
    // At the live bottom the thumb is at the end: offset == total - len.
    try std.testing.expectEqual(grown.total - grown.len, grown.offset);

    // Scrolling up into history moves the viewport (and the thumb) up.
    io.scrollViewport(-5);
    const scrolled = io.scrollbar();
    try std.testing.expect(scrolled.offset < grown.offset);
    // total/len are unchanged by scrolling the viewport.
    try std.testing.expectEqual(grown.total, scrolled.total);
    try std.testing.expectEqual(grown.len, scrolled.len);
}

test "termio: dirty generation bumps on output; cursorBlinks gates on focus/visibility/mode" {
    const alloc = std.testing.allocator;
    const io = try Termio.create(alloc, 20, 3, 1 << 20);
    defer io.destroy();

    // Each pty-output apply bumps the generation (the UI thread's redraw signal).
    const g0 = io.dirtyGen();
    try io.process("a");
    const g1 = io.dirtyGen();
    try std.testing.expect(g1 != g0);
    try io.process("b");
    try std.testing.expect(io.dirtyGen() != g1);

    // A blinking cursor style (DECSCUSR 1), visible + focused -> blinking, so the
    // UI must keep waking at the blink cadence.
    try io.process("\x1b[1 q");
    try std.testing.expect(io.cursorBlinks(true));
    // Unfocused never blinks (the cursor renders hollow/static).
    try std.testing.expect(!io.cursorBlinks(false));
    // Hiding the cursor (DECTCEM off) stops the blink wake even when focused.
    try io.process("\x1b[?25l");
    try std.testing.expect(!io.cursorBlinks(true));
    // A steady cursor style (DECSCUSR 2) doesn't blink either.
    try io.process("\x1b[?25h\x1b[2 q");
    try std.testing.expect(!io.cursorBlinks(true));
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
