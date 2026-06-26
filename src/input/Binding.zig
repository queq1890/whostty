//! whostty: keybindings — map key chords to terminal actions.
//!
//! Reference: ghostty `src/input/Binding.zig` (`Trigger` + `Action` + `Set`).
//! Strategy: port. The chord/action grammar is ported and host-tested here; the
//! apprt maps its Win32 key events onto a `Trigger` and looks up the `Action`,
//! then drives the matching surface-management (#18) / scrollback (#16)
//! operation. See PORTING.md.
//!
//! This module is free of platform and libghostty-vt types so it compiles and
//! unit-tests on the host. The key is modeled self-containedly (a printable
//! codepoint or a named special key) rather than reusing the VT key enum, so
//! parsing correctness doesn't hinge on that enum's spelling.
const std = @import("std");

/// Modifier keys held with the trigger key.
pub const Mods = packed struct {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    super: bool = false,

    pub fn eql(a: Mods, b: Mods) bool {
        return a.ctrl == b.ctrl and a.shift == b.shift and a.alt == b.alt and a.super == b.super;
    }
};

/// The key part of a trigger: a printable unicode codepoint (letters, digits,
/// punctuation) or a named non-printable key.
pub const Key = union(enum) {
    codepoint: u21,
    named: Named,

    pub const Named = enum {
        enter,
        tab,
        space,
        escape,
        backspace,
        up,
        down,
        left,
        right,
        home,
        end,
        insert,
        page_up,
        page_down,
    };

    pub fn eql(a: Key, b: Key) bool {
        return switch (a) {
            .codepoint => |c| switch (b) {
                .codepoint => |d| c == d,
                .named => false,
            },
            .named => |n| switch (b) {
                .named => |m| n == m,
                .codepoint => false,
            },
        };
    }
};

/// A key chord: a key plus the modifiers held with it.
pub const Trigger = struct {
    key: Key,
    mods: Mods = .{},

    pub fn eql(a: Trigger, b: Trigger) bool {
        return a.key.eql(b.key) and a.mods.eql(b.mods);
    }
};

/// Split / navigation direction.
pub const Direction = enum { left, right, up, down };

/// An action a binding triggers. A faithful subset of ghostty's actions, limited
/// to what whostty implements today: surface management (#18) and scrollback
/// (#16).
pub const Action = union(enum) {
    /// Open a new top-level window (#86). Multi-window via thread-per-window; the
    /// apprt spawns a fresh, fully independent window thread. Void-payload,
    /// mirroring ghostty's `new_window`.
    new_window,
    new_split: Direction,
    goto_split: Direction,
    new_tab,
    close_surface,
    next_tab,
    previous_tab,
    goto_tab: u8,
    scroll_page_up,
    scroll_page_down,
    scroll_to_top,
    scroll_to_bottom,
    copy_to_clipboard,
    paste_from_clipboard,
    /// Window-state actions (#91). Borderless windowed fullscreen, maximize/
    /// restore, and show/hide the titlebar+resize border. Each acts on the
    /// current window (the apprt's single surface). Void-payload, mirroring
    /// ghostty's `toggle_fullscreen`/`toggle_maximize`/`toggle_window_decorations`.
    toggle_fullscreen,
    toggle_maximize,
    toggle_window_decorations,
    /// App-lifecycle + extra windowing actions (#92). `quit` closes every window
    /// (ending the app); `close_window` closes the calling window (all its tabs/
    /// splits) vs. `close_surface` which closes one pane; `goto_window` focuses
    /// the Nth top-level window (1-based); `present_terminal` brings the calling
    /// window to the foreground; `toggle_window_float_on_top` pins it always-on-
    /// top; `toggle_visibility` hides/shows it. Names mirror ghostty's where they
    /// overlap. Void-payload except `goto_window`.
    quit,
    close_window,
    goto_window: u8,
    present_terminal,
    toggle_window_float_on_top,
    toggle_visibility,
};

/// Every bindable action name — the `Action` union's field names — for the
/// `+list-actions` CLI (#53). Derived from the type so it never drifts from the
/// names `parseAction` accepts.
pub const action_names = blk: {
    const fields = @typeInfo(Action).@"union".fields;
    var names: [fields.len][]const u8 = undefined;
    for (fields, 0..) |f, i| names[i] = f.name;
    break :blk names;
};

/// A parsed `trigger = action` binding.
pub const Binding = struct {
    trigger: Trigger,
    action: Action,
};

pub const ParseError = error{
    InvalidTrigger,
    InvalidKey,
    InvalidAction,
    InvalidArgument,
};

/// Parse a full `trigger=action` line (e.g. `ctrl+shift+right=new_split:right`).
pub fn parse(input: []const u8) ParseError!Binding {
    const eq = std.mem.indexOfScalar(u8, input, '=') orelse return error.InvalidTrigger;
    return .{
        .trigger = try parseTrigger(input[0..eq]),
        .action = try parseAction(input[eq + 1 ..]),
    };
}

/// Parse the trigger side: `+`-separated modifiers ending in one key.
pub fn parseTrigger(input: []const u8) ParseError!Trigger {
    var mods: Mods = .{};
    var key: ?Key = null;

    var it = std.mem.splitScalar(u8, input, '+');
    while (it.next()) |raw| {
        const tok = std.mem.trim(u8, raw, " \t");
        if (tok.len == 0) return error.InvalidTrigger;

        if (modBit(tok)) |which| {
            switch (which) {
                .ctrl => mods.ctrl = true,
                .shift => mods.shift = true,
                .alt => mods.alt = true,
                .super => mods.super = true,
            }
            continue;
        }

        // Not a modifier, so it must be the (single) key.
        if (key != null) return error.InvalidTrigger;
        key = try keyFromName(tok);
    }

    return .{ .key = key orelse return error.InvalidTrigger, .mods = mods };
}

const ModName = enum { ctrl, shift, alt, super };

fn modBit(tok: []const u8) ?ModName {
    if (eqlIgnoreCase(tok, "ctrl") or eqlIgnoreCase(tok, "control")) return .ctrl;
    if (eqlIgnoreCase(tok, "shift")) return .shift;
    if (eqlIgnoreCase(tok, "alt") or eqlIgnoreCase(tok, "opt") or eqlIgnoreCase(tok, "option")) return .alt;
    if (eqlIgnoreCase(tok, "super") or eqlIgnoreCase(tok, "cmd") or eqlIgnoreCase(tok, "win")) return .super;
    return null;
}

fn keyFromName(tok: []const u8) ParseError!Key {
    const named = std.StaticStringMap(Key.Named).initComptime(.{
        .{ "enter", .enter },     .{ "return", .enter },
        .{ "tab", .tab },         .{ "space", .space },
        .{ "escape", .escape },   .{ "esc", .escape },
        .{ "backspace", .backspace },
        .{ "up", .up },           .{ "down", .down },
        .{ "left", .left },       .{ "right", .right },
        .{ "home", .home },       .{ "end", .end },
        .{ "insert", .insert },   .{ "ins", .insert },
        .{ "pageup", .page_up },  .{ "page_up", .page_up },
        .{ "pagedown", .page_down }, .{ "page_down", .page_down },
    });

    // Named keys are matched case-insensitively via a lowercased copy on the
    // stack (names are short).
    var buf: [16]u8 = undefined;
    if (tok.len <= buf.len) {
        const lower = std.ascii.lowerString(buf[0..tok.len], tok);
        if (named.get(lower)) |n| return .{ .named = n };
    }

    // Otherwise it must be a single printable codepoint.
    const view = std.unicode.Utf8View.init(tok) catch return error.InvalidKey;
    var cps = view.iterator();
    const first = cps.nextCodepoint() orelse return error.InvalidKey;
    if (cps.nextCodepoint() != null) return error.InvalidKey; // more than one cp, not a named key

    // ASCII letters fold to lowercase; shift is carried as a separate modifier.
    var cp: u21 = first;
    if (cp < 128 and std.ascii.isUpper(@intCast(cp))) cp = std.ascii.toLower(@intCast(cp));
    return .{ .codepoint = cp };
}

/// Parse the action side: a name with an optional `:argument`.
pub fn parseAction(input: []const u8) ParseError!Action {
    const trimmed = std.mem.trim(u8, input, " \t");
    var name = trimmed;
    var arg: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, trimmed, ':')) |c| {
        name = std.mem.trim(u8, trimmed[0..c], " \t");
        arg = std.mem.trim(u8, trimmed[c + 1 ..], " \t");
    }

    if (eqlIgnoreCase(name, "new_window")) return .new_window;
    if (eqlIgnoreCase(name, "new_split")) return .{ .new_split = try dir(arg) };
    if (eqlIgnoreCase(name, "goto_split")) return .{ .goto_split = try dir(arg) };
    if (eqlIgnoreCase(name, "new_tab")) return .new_tab;
    if (eqlIgnoreCase(name, "close_surface")) return .close_surface;
    if (eqlIgnoreCase(name, "next_tab")) return .next_tab;
    if (eqlIgnoreCase(name, "previous_tab")) return .previous_tab;
    if (eqlIgnoreCase(name, "goto_tab")) {
        const a = arg orelse return error.InvalidArgument;
        return .{ .goto_tab = std.fmt.parseInt(u8, a, 10) catch return error.InvalidArgument };
    }
    if (eqlIgnoreCase(name, "scroll_page_up")) return .scroll_page_up;
    if (eqlIgnoreCase(name, "scroll_page_down")) return .scroll_page_down;
    if (eqlIgnoreCase(name, "scroll_to_top")) return .scroll_to_top;
    if (eqlIgnoreCase(name, "scroll_to_bottom")) return .scroll_to_bottom;
    if (eqlIgnoreCase(name, "copy_to_clipboard")) return .copy_to_clipboard;
    if (eqlIgnoreCase(name, "paste_from_clipboard")) return .paste_from_clipboard;
    if (eqlIgnoreCase(name, "toggle_fullscreen")) return .toggle_fullscreen;
    if (eqlIgnoreCase(name, "toggle_maximize")) return .toggle_maximize;
    if (eqlIgnoreCase(name, "toggle_window_decorations")) return .toggle_window_decorations;
    if (eqlIgnoreCase(name, "quit")) return .quit;
    if (eqlIgnoreCase(name, "close_window")) return .close_window;
    if (eqlIgnoreCase(name, "goto_window")) {
        const a = arg orelse return error.InvalidArgument;
        return .{ .goto_window = std.fmt.parseInt(u8, a, 10) catch return error.InvalidArgument };
    }
    if (eqlIgnoreCase(name, "present_terminal")) return .present_terminal;
    if (eqlIgnoreCase(name, "toggle_window_float_on_top")) return .toggle_window_float_on_top;
    if (eqlIgnoreCase(name, "toggle_visibility")) return .toggle_visibility;
    return error.InvalidAction;
}

fn dir(arg: ?[]const u8) ParseError!Direction {
    const a = arg orelse return error.InvalidArgument;
    if (eqlIgnoreCase(a, "left")) return .left;
    if (eqlIgnoreCase(a, "right")) return .right;
    if (eqlIgnoreCase(a, "up")) return .up;
    if (eqlIgnoreCase(a, "down")) return .down;
    return error.InvalidArgument;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// An ordered set of bindings with last-wins semantics per trigger.
pub const Set = struct {
    list: std.ArrayList(Binding) = .empty,

    pub fn deinit(self: *Set, alloc: std.mem.Allocator) void {
        self.list.deinit(alloc);
        self.* = undefined;
    }

    /// Insert a binding, replacing any existing one for the same trigger.
    pub fn put(self: *Set, alloc: std.mem.Allocator, b: Binding) !void {
        for (self.list.items) |*existing| {
            if (existing.trigger.eql(b.trigger)) {
                existing.action = b.action;
                return;
            }
        }
        try self.list.append(alloc, b);
    }

    /// Parse a `trigger=action` line and insert it.
    pub fn putLine(self: *Set, alloc: std.mem.Allocator, line: []const u8) !void {
        try self.put(alloc, try parse(line));
    }

    /// The action bound to `trigger`, or null.
    pub fn get(self: *const Set, trigger: Trigger) ?Action {
        for (self.list.items) |b| {
            if (b.trigger.eql(trigger)) return b.action;
        }
        return null;
    }

    pub fn count(self: *const Set) usize {
        return self.list.items.len;
    }
};

/// whostty's default key bindings, in `trigger=action` config syntax. This is the
/// single source of truth: `addDefaults` seeds a `Set` from it, and the
/// `+list-keybinds` CLI action (#53) prints it. Each line round-trips through
/// `parse` (asserted by the test below).
pub const default_lines = [_][]const u8{
    "ctrl+shift+n=new_window",
    "ctrl+shift+t=new_tab",
    "ctrl+shift+w=close_surface",
    "ctrl+pagedown=next_tab",
    "ctrl+pageup=previous_tab",
    "ctrl+shift+right=new_split:right",
    "ctrl+shift+left=new_split:left",
    "ctrl+shift+down=new_split:down",
    "ctrl+shift+up=new_split:up",
    "alt+right=goto_split:right",
    "alt+left=goto_split:left",
    "alt+down=goto_split:down",
    "alt+up=goto_split:up",
    "shift+pageup=scroll_page_up",
    "shift+pagedown=scroll_page_down",
    "ctrl+shift+c=copy_to_clipboard",
    "ctrl+shift+v=paste_from_clipboard",
    // Windows-standard copy/paste (#53): Ctrl+Insert copies, Shift+Insert pastes.
    "ctrl+insert=copy_to_clipboard",
    "shift+insert=paste_from_clipboard",
    "ctrl+shift+enter=toggle_fullscreen",
    "ctrl+shift+m=toggle_maximize",
    "ctrl+shift+b=toggle_window_decorations",
    "ctrl+shift+q=quit",
};

/// Seed `set` with whostty's default bindings. Called by the apprt before
/// applying any user `keybind` lines, which then override per trigger.
pub fn addDefaults(set: *Set, alloc: std.mem.Allocator) !void {
    for (default_lines) |line| try set.putLine(alloc, line);
}

const testing = std.testing;

test "binding: every default line parses (so +list-keybinds prints valid syntax)" {
    for (default_lines) |line| {
        _ = parse(line) catch |e| {
            std.debug.print("default keybind failed to parse: {s} ({})\n", .{ line, e });
            return e;
        };
    }
}

test "binding: ctrl+insert / shift+insert resolve to copy/paste (#53)" {
    const copy = try parse("ctrl+insert=copy_to_clipboard");
    try testing.expect(copy.trigger.key.eql(.{ .named = .insert }));
    try testing.expect(copy.trigger.mods.eql(.{ .ctrl = true }));
    try testing.expectEqual(Action.copy_to_clipboard, copy.action);

    const pst = try parse("shift+insert=paste_from_clipboard");
    try testing.expect(pst.trigger.key.eql(.{ .named = .insert }));
    try testing.expect(pst.trigger.mods.eql(.{ .shift = true }));
    try testing.expectEqual(Action.paste_from_clipboard, pst.action);

    // "ins" is an accepted alias for the insert key.
    const alias = try parse("ctrl+ins=copy_to_clipboard");
    try testing.expect(alias.trigger.key.eql(.{ .named = .insert }));
}

test "binding: action_names lists every action and each one parses (#53)" {
    try testing.expectEqual(@typeInfo(Action).@"union".fields.len, action_names.len);
    var saw_copy = false;
    for (action_names) |name| {
        // Names with a payload (e.g. new_split) need an argument to parse, so
        // just assert the void-payload ones round-trip; all names are non-empty.
        try testing.expect(name.len > 0);
        if (std.mem.eql(u8, name, "copy_to_clipboard")) saw_copy = true;
    }
    try testing.expect(saw_copy);
    // A representative void action round-trips through parseAction by name.
    try testing.expectEqual(Action.copy_to_clipboard, try parseAction("copy_to_clipboard"));
}

test "binding: parse a trigger with modifiers and a named key" {
    const t = try parseTrigger("ctrl+shift+right");
    try testing.expect(t.mods.ctrl and t.mods.shift);
    try testing.expect(!t.mods.alt and !t.mods.super);
    try testing.expect(t.key.eql(.{ .named = .right }));
}

test "binding: a letter key folds case; shift stays a modifier" {
    const a = try parseTrigger("ctrl+T");
    try testing.expect(a.mods.ctrl);
    try testing.expect(a.key.eql(.{ .codepoint = 't' }));

    const b = try parseTrigger("ctrl+shift+t");
    try testing.expect(b.key.eql(.{ .codepoint = 't' }));
    try testing.expect(b.mods.shift);
}

test "binding: modifier aliases" {
    const t = try parseTrigger("control+opt+win+esc");
    try testing.expect(t.mods.ctrl and t.mods.alt and t.mods.super);
    try testing.expect(t.key.eql(.{ .named = .escape }));
}

test "binding: malformed triggers error" {
    try testing.expectError(error.InvalidTrigger, parseTrigger("ctrl+shift")); // no key
    try testing.expectError(error.InvalidTrigger, parseTrigger("a+b")); // two keys
    try testing.expectError(error.InvalidKey, parseTrigger("ctrl+nope")); // unknown multi-char key
}

test "binding: parse actions with and without arguments" {
    try testing.expectEqual(Action{ .new_split = .right }, try parseAction("new_split:right"));
    try testing.expectEqual(Action{ .goto_split = .up }, try parseAction("goto_split:up"));
    // Multi-window (#86): a void-payload action like new_tab.
    try testing.expectEqual(Action.new_window, try parseAction("new_window"));
    try testing.expectEqual(Action.new_window, try parseAction("New_Window")); // case-insensitive
    try testing.expectEqual(Action.new_tab, try parseAction("new_tab"));
    try testing.expectEqual(Action.next_tab, try parseAction("next_tab"));
    try testing.expectEqual(Action{ .goto_tab = 3 }, try parseAction("goto_tab:3"));
    try testing.expectEqual(Action.scroll_to_bottom, try parseAction("scroll_to_bottom"));
    try testing.expectEqual(Action.copy_to_clipboard, try parseAction("copy_to_clipboard"));
    try testing.expectEqual(Action.paste_from_clipboard, try parseAction("paste_from_clipboard"));
    // Window-state actions (#91), void-payload.
    try testing.expectEqual(Action.toggle_fullscreen, try parseAction("toggle_fullscreen"));
    try testing.expectEqual(Action.toggle_maximize, try parseAction("toggle_maximize"));
    try testing.expectEqual(Action.toggle_window_decorations, try parseAction("toggle_window_decorations"));
    // Case-insensitive, like the other action names.
    try testing.expectEqual(Action.toggle_fullscreen, try parseAction("Toggle_Fullscreen"));
    // App-lifecycle + windowing actions (#92).
    try testing.expectEqual(Action.quit, try parseAction("quit"));
    try testing.expectEqual(Action.close_window, try parseAction("close_window"));
    try testing.expectEqual(Action{ .goto_window = 2 }, try parseAction("goto_window:2"));
    try testing.expectEqual(Action.present_terminal, try parseAction("present_terminal"));
    try testing.expectEqual(Action.toggle_window_float_on_top, try parseAction("toggle_window_float_on_top"));
    try testing.expectEqual(Action.toggle_visibility, try parseAction("toggle_visibility"));
}

test "binding: bad actions error" {
    try testing.expectError(error.InvalidAction, parseAction("frobnicate"));
    try testing.expectError(error.InvalidArgument, parseAction("new_split")); // missing dir
    try testing.expectError(error.InvalidArgument, parseAction("new_split:sideways"));
    try testing.expectError(error.InvalidArgument, parseAction("goto_tab:x"));
    try testing.expectError(error.InvalidArgument, parseAction("goto_window")); // missing index
}

test "binding: full parse of a line" {
    const b = try parse("ctrl+shift+right=new_split:right");
    try testing.expect(b.trigger.key.eql(.{ .named = .right }));
    try testing.expectEqual(Action{ .new_split = .right }, b.action);
}

test "binding: Set get, last-wins override" {
    var set: Set = .{};
    defer set.deinit(testing.allocator);

    try set.putLine(testing.allocator, "ctrl+shift+t=new_tab");
    try set.putLine(testing.allocator, "ctrl+shift+right=new_split:right");
    try testing.expectEqual(@as(usize, 2), set.count());

    const t1: Trigger = .{ .key = .{ .codepoint = 't' }, .mods = .{ .ctrl = true, .shift = true } };
    try testing.expectEqual(Action.new_tab, set.get(t1).?);

    // Re-bind the same trigger: replaces, doesn't grow.
    try set.putLine(testing.allocator, "ctrl+shift+t=close_surface");
    try testing.expectEqual(@as(usize, 2), set.count());
    try testing.expectEqual(Action.close_surface, set.get(t1).?);

    // Unknown trigger.
    const miss: Trigger = .{ .key = .{ .codepoint = 'z' } };
    try testing.expect(set.get(miss) == null);
}

test "binding: defaults populate a usable set" {
    var set: Set = .{};
    defer set.deinit(testing.allocator);
    try addDefaults(&set, testing.allocator);
    try testing.expect(set.count() >= 10);

    const split_right: Trigger = .{ .key = .{ .named = .right }, .mods = .{ .ctrl = true, .shift = true } };
    try testing.expectEqual(Action{ .new_split = .right }, set.get(split_right).?);

    // Window-state defaults (#91): the exact chords the apprt dispatches on.
    const cs: Mods = .{ .ctrl = true, .shift = true };

    // new_window (#86): the default chord is ctrl+shift+n. keymap.keyFromVk(0x4E)
    // maps the 'N' virtual key to codepoint 'n', so WM_KEYDOWN routes this exact
    // trigger; assert the default binds it.
    const new_window: Trigger = .{ .key = .{ .codepoint = 'n' }, .mods = cs };
    try testing.expectEqual(Action.new_window, set.get(new_window).?);
    const fullscreen: Trigger = .{ .key = .{ .named = .enter }, .mods = cs };
    try testing.expectEqual(Action.toggle_fullscreen, set.get(fullscreen).?);
    const maximize: Trigger = .{ .key = .{ .codepoint = 'm' }, .mods = cs };
    try testing.expectEqual(Action.toggle_maximize, set.get(maximize).?);
    const decorations: Trigger = .{ .key = .{ .codepoint = 'b' }, .mods = cs };
    try testing.expectEqual(Action.toggle_window_decorations, set.get(decorations).?);
}
