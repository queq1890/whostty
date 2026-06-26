//! whostty: Win32 virtual-key -> binding key mapping.
//!
//! Pure integer→`binding.Key` translation, kept separate from the Windows-only
//! apprt code so it compiles and unit-tests on the host. The apprt builds a
//! `binding.Trigger` from this plus the modifier state and looks it up in the
//! keybinding set. See PORTING.md.
const std = @import("std");
const binding = @import("../../input/Binding.zig");

/// Map a Win32 virtual-key code to a binding key, or null for keys that can't
/// start a chord we recognize (handled as normal input instead). VK letter and
/// digit codes equal their ASCII uppercase/digit values; letters fold to
/// lowercase since shift is carried as a separate modifier.
pub fn keyFromVk(vk: u32) ?binding.Key {
    return switch (vk) {
        0x25 => .{ .named = .left },
        0x26 => .{ .named = .up },
        0x27 => .{ .named = .right },
        0x28 => .{ .named = .down },
        0x21 => .{ .named = .page_up },
        0x22 => .{ .named = .page_down },
        0x24 => .{ .named = .home },
        0x23 => .{ .named = .end },
        0x2D => .{ .named = .insert }, // VK_INSERT — ctrl/shift+insert copy/paste (#53)
        0x0D => .{ .named = .enter },
        0x09 => .{ .named = .tab },
        0x1B => .{ .named = .escape },
        0x08 => .{ .named = .backspace },
        0x20 => .{ .named = .space },
        '0'...'9' => .{ .codepoint = @intCast(vk) },
        'A'...'Z' => .{ .codepoint = @intCast(vk + 32) },
        else => null,
    };
}

const testing = std.testing;

test "keymap: named keys" {
    try testing.expect(keyFromVk(0x27).?.eql(.{ .named = .right }));
    try testing.expect(keyFromVk(0x21).?.eql(.{ .named = .page_up }));
    try testing.expect(keyFromVk(0x1B).?.eql(.{ .named = .escape }));
    try testing.expect(keyFromVk(0x2D).?.eql(.{ .named = .insert })); // VK_INSERT (#53)
}

test "keymap: letters fold to lowercase, digits pass through" {
    try testing.expect(keyFromVk('T').?.eql(.{ .codepoint = 't' })); // 0x54
    try testing.expect(keyFromVk('A').?.eql(.{ .codepoint = 'a' }));
    try testing.expect(keyFromVk('Z').?.eql(.{ .codepoint = 'z' }));
    try testing.expect(keyFromVk('5').?.eql(.{ .codepoint = '5' }));
}

test "keymap: unknown vk is null" {
    try testing.expect(keyFromVk(0x2C) == null); // PrintScreen
    try testing.expect(keyFromVk(0x70) == null); // F1
}
