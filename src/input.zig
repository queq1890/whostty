//! whostty: app-side input handling — translate Win32 key events into the
//! terminal byte sequences to write back to the pty.
//!
//! Reference: ghostty `src/input.zig` + apprt key handling (strategy: port).
//! The actual encoding is delegated to libghostty-vt (`input.encodeKey`); this
//! module only maps Win32 virtual-key codes / modifier state into a
//! `vt.input.KeyEvent`. See PORTING.md.
const std = @import("std");
const vt = @import("ghostty-vt");

pub const KeyEvent = vt.input.KeyEvent;
pub const Key = vt.input.Key;
pub const Mods = vt.input.KeyMods;
pub const Options = vt.input.KeyEncodeOptions;

/// Win32 virtual-key codes we map for slice-0.
pub const vk = struct {
    pub const back: u32 = 0x08;
    pub const tab: u32 = 0x09;
    pub const enter: u32 = 0x0D;
    pub const escape: u32 = 0x1B;
    pub const left: u32 = 0x25;
    pub const up: u32 = 0x26;
    pub const right: u32 = 0x27;
    pub const down: u32 = 0x28;
};

/// Map a Win32 virtual-key code to a libghostty-vt `Key`. Returns
/// `.unidentified` for keys whose text comes from WM_CHAR instead.
pub fn keyFromVk(code: u32) Key {
    return switch (code) {
        vk.back => .backspace,
        vk.tab => .tab,
        vk.enter => .enter,
        vk.escape => .escape,
        vk.left => .arrow_left,
        vk.up => .arrow_up,
        vk.right => .arrow_right,
        vk.down => .arrow_down,
        else => .unidentified,
    };
}

/// Build modifiers from individual key states (as read from GetKeyState).
pub fn mods(shift: bool, ctrl: bool, alt: bool) Mods {
    return .{ .shift = shift, .ctrl = ctrl, .alt = alt };
}

/// Encode a key event into terminal bytes, writing into `buf`. Returns the
/// written slice (may be empty if the event produces no bytes).
pub fn encode(buf: []u8, event: KeyEvent, opts: Options) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    try vt.input.encodeKey(&writer, event, opts);
    return writer.buffered();
}

test "input: Enter encodes to CR" {
    var buf: [8]u8 = undefined;
    const out = try encode(&buf, .{ .key = .enter }, .{});
    try std.testing.expectEqualStrings("\r", out);
}

test "input: printable text passes through" {
    var buf: [8]u8 = undefined;
    const out = try encode(&buf, .{ .utf8 = "a", .unshifted_codepoint = 'a' }, .{});
    try std.testing.expectEqualStrings("a", out);
}

test "input: backspace and tab" {
    var buf: [8]u8 = undefined;
    const bs = try encode(&buf, .{ .key = .backspace }, .{});
    try std.testing.expect(bs.len >= 1);

    var buf2: [8]u8 = undefined;
    const tab = try encode(&buf2, .{ .key = .tab }, .{});
    try std.testing.expectEqualStrings("\t", tab);
}

test "input: vk mapping" {
    try std.testing.expectEqual(Key.enter, keyFromVk(vk.enter));
    try std.testing.expectEqual(Key.arrow_up, keyFromVk(vk.up));
    try std.testing.expectEqual(Key.unidentified, keyFromVk('A'));
}

test "input: arrow key produces an escape sequence" {
    var buf: [16]u8 = undefined;
    const out = try encode(&buf, .{ .key = .arrow_up }, .{});
    try std.testing.expect(out.len >= 2 and out[0] == 0x1b);
}
