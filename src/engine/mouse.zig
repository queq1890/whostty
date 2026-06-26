//! whostty: mouse-event VT report encoding.
//!
//! Reference: ghostty `src/Surface.zig` `mouseReport` (strategy: port). The VT
//! mouse encoding is NOT exposed by libghostty-vt's public surface (unlike key
//! and paste encoding), so whostty implements it here. Pure (no platform / no
//! vt types) so it is host-testable; the apprt reads the terminal's mouse mode
//! / format from `terminal.flags` and feeds the integer-equivalent enums in.
//!
//! First cut: the two dominant formats — legacy X10 (`CSI M`) and SGR 1006
//! (`CSI < … M/m`) — for button press/release and wheel, with modifiers. Motion
//! reporting (button/any modes) and the utf8 / urxvt / sgr_pixels formats are
//! deliberately not encoded yet (return null = "don't report"). See PORTING.md.
const std = @import("std");

/// Which mouse-tracking mode the terminal requested. Integer values match
/// libghostty-vt's `MouseEvents` (none=0 … any=4).
pub const Event = enum(u3) { none = 0, x10 = 1, normal = 2, button = 3, any = 4 };

/// The encoding format. Integer values match libghostty-vt's `MouseFormat`.
pub const Format = enum(u3) { x10 = 0, utf8 = 1, sgr = 2, urxvt = 3, sgr_pixels = 4 };

pub const Button = enum { left, middle, right, wheel_up, wheel_down };
pub const Action = enum { press, release, motion };
pub const Mods = struct { shift: bool = false, alt: bool = false, ctrl: bool = false };

/// Encode a mouse event into `buf`. `col`/`row` are 0-based viewport cells.
/// Returns the bytes to write to the pty, or null if this event must not be
/// reported under the given mode/format (or the format isn't supported yet).
pub fn encode(
    buf: []u8,
    mode: Event,
    format: Format,
    button: ?Button,
    action: Action,
    mods: Mods,
    col: u16,
    row: u16,
) ?[]const u8 {
    // Gate by tracking mode (mirrors ghostty's mouseReport switch).
    switch (mode) {
        .none => return null,
        // X10 reports only left/middle/right *presses*, no modifiers.
        .x10 => if (action != .press or !isClick(button)) return null,
        // Normal reports presses/releases/wheel but not motion.
        .normal => if (action == .motion) return null,
        // Button (1002): motion is reported only while a button is held.
        .button => if (button == null) return null,
        // Any (1003): reports all motion, including no-button hover motion
        // (encoded with the dedicated "no button" code, 3).
        .any => {},
    }

    const sgr = format == .sgr or format == .sgr_pixels;

    var acc: u8 = 0;
    if (button == null) {
        acc = 3; // motion with no button
    } else if (action == .release and !sgr) {
        // Legacy formats can't say which button was released, so it's always 3.
        // SGR keeps the real button and distinguishes press/release via M vs m.
        acc = 3;
    } else {
        acc = switch (button.?) {
            .left => 0,
            .middle => 1,
            .right => 2,
            .wheel_up => 64,
            .wheel_down => 65,
        };
    }

    // X10 carries no modifiers.
    if (mode != .x10) {
        if (mods.shift) acc += 4;
        if (mods.alt) acc += 8;
        if (mods.ctrl) acc += 16;
    }
    if (action == .motion) acc += 32;

    switch (format) {
        .x10 => {
            // 1-based, offset by 32; the protocol can't encode past 223.
            if (col > 222 or row > 222) return null;
            if (buf.len < 6) return null;
            buf[0] = 0x1b;
            buf[1] = '[';
            buf[2] = 'M';
            buf[3] = 32 +% acc;
            buf[4] = @intCast(32 + @as(u32, col) + 1);
            buf[5] = @intCast(32 + @as(u32, row) + 1);
            return buf[0..6];
        },
        .sgr => {
            const final: u8 = if (action == .release) 'm' else 'M';
            return std.fmt.bufPrint(buf, "\x1b[<{d};{d};{d}{c}", .{
                acc, @as(u32, col) + 1, @as(u32, row) + 1, final,
            }) catch null;
        },
        // utf8 / urxvt / sgr_pixels: not encoded yet.
        else => return null,
    }
}

fn isClick(button: ?Button) bool {
    return if (button) |b| (b == .left or b == .middle or b == .right) else false;
}

const testing = std.testing;

test "mouse: disabled mode reports nothing" {
    var buf: [32]u8 = undefined;
    try testing.expect(encode(&buf, .none, .sgr, .left, .press, .{}, 0, 0) == null);
}

test "mouse: SGR press/release keeps the button and uses M/m" {
    var buf: [32]u8 = undefined;
    // left press at viewport (0,0) -> 1-based (1,1).
    try testing.expectEqualStrings("\x1b[<0;1;1M", encode(&buf, .normal, .sgr, .left, .press, .{}, 0, 0).?);
    // right release at (9,4) -> (10,5); SGR keeps button 2 + 'm'.
    try testing.expectEqualStrings("\x1b[<2;10;5m", encode(&buf, .normal, .sgr, .right, .release, .{}, 9, 4).?);
}

test "mouse: SGR modifiers add to the button code" {
    var buf: [32]u8 = undefined;
    // ctrl(16)+shift(4) + left(0) = 20.
    try testing.expectEqualStrings("\x1b[<20;1;1M", encode(&buf, .normal, .sgr, .left, .press, .{ .ctrl = true, .shift = true }, 0, 0).?);
}

test "mouse: SGR wheel up/down use codes 64/65" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("\x1b[<64;3;2M", encode(&buf, .normal, .sgr, .wheel_up, .press, .{}, 2, 1).?);
    try testing.expectEqualStrings("\x1b[<65;3;2M", encode(&buf, .normal, .sgr, .wheel_down, .press, .{}, 2, 1).?);
}

test "mouse: X10 format offsets coords by 32; release is button 3" {
    var buf: [32]u8 = undefined;
    // left press at (0,0): bytes ESC [ M, 32+0, 32+1, 32+1.
    const out = encode(&buf, .normal, .x10, .left, .press, .{}, 0, 0).?;
    try testing.expectEqualSlices(u8, &.{ 0x1b, '[', 'M', 32, 33, 33 }, out);
    // release in a legacy format is always button 3 (32+3).
    const rel = encode(&buf, .normal, .x10, .left, .release, .{}, 0, 0).?;
    try testing.expectEqual(@as(u8, 32 + 3), rel[3]);
}

test "mouse: modifiers gate on tracking mode, not format" {
    var buf: [32]u8 = undefined;
    // X10 *mode* carries no modifiers even with the X10 format: acc stays 0.
    const x10mode = encode(&buf, .x10, .x10, .left, .press, .{ .ctrl = true }, 0, 0).?;
    try testing.expectEqual(@as(u8, 32 + 0), x10mode[3]);
    // normal mode with the X10 format does apply ctrl(16): 32+16.
    const normal = encode(&buf, .normal, .x10, .left, .press, .{ .ctrl = true }, 0, 0).?;
    try testing.expectEqual(@as(u8, 32 + 16), normal[3]);
}

test "mouse: X10 mode reports only clicks, no wheel, no release" {
    var buf: [32]u8 = undefined;
    try testing.expect(encode(&buf, .x10, .x10, .left, .release, .{}, 0, 0) == null);
    try testing.expect(encode(&buf, .x10, .x10, .wheel_up, .press, .{}, 0, 0) == null);
    try testing.expect(encode(&buf, .x10, .x10, .left, .press, .{}, 0, 0) != null);
}

test "mouse: normal mode drops motion" {
    var buf: [32]u8 = undefined;
    try testing.expect(encode(&buf, .normal, .sgr, .left, .motion, .{}, 0, 0) == null);
}

test "mouse: button/any modes report held-button drag motion with the +32 bit" {
    var buf: [32]u8 = undefined;
    // Button mode (1002), left held, motion to viewport (5,2) -> 1-based (6,3):
    // acc = left(0) + motion(32) = 32, press-style final 'M'.
    try testing.expectEqualStrings("\x1b[<32;6;3M", encode(&buf, .button, .sgr, .left, .motion, .{}, 5, 2).?);
    // Any mode (1003) reports it too; ctrl(16) + left(0) + motion(32) = 48.
    try testing.expectEqualStrings("\x1b[<48;6;3M", encode(&buf, .any, .sgr, .left, .motion, .{ .ctrl = true }, 5, 2).?);
    // X10 mode never reports motion.
    try testing.expect(encode(&buf, .x10, .sgr, .left, .motion, .{}, 5, 2) == null);
}

test "mouse: any mode reports no-button (hover) motion; button mode does not" {
    var buf: [32]u8 = undefined;
    // Any mode (1003): no-button motion uses the "no button" code 3, + motion(32)
    // = 35, at viewport (5,2) -> 1-based (6,3).
    try testing.expectEqualStrings("\x1b[<35;6;3M", encode(&buf, .any, .sgr, null, .motion, .{}, 5, 2).?);
    // Button mode (1002) only reports motion while a button is held, so no-button
    // motion is dropped.
    try testing.expect(encode(&buf, .button, .sgr, null, .motion, .{}, 5, 2) == null);
}

test "mouse: X10 format rejects coordinates past 223" {
    var buf: [32]u8 = undefined;
    try testing.expect(encode(&buf, .normal, .x10, .left, .press, .{}, 300, 0) == null);
}
