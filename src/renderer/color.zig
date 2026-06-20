//! whostty: renderer color math — WCAG contrast and the minimum-contrast
//! foreground adjustment.
//!
//! Reference: ghostty `src/terminal/color.zig` (`luminance` / `contrast`) and
//! `src/renderer/shaders/glsl/common.glsl` (`contrasted_color`) (strategy:
//! port). Backend-agnostic and GL-free: it operates on normalized `[3]f32`
//! colors (0..1), the form the renderer already uses, so it stays host-testable
//! and keeps the renderer free of a libghostty-vt dependency. See PORTING.md.
const std = @import("std");

/// Single-channel relative luminance per the W3C WCAG 2.0 formula. The input is
/// already normalized (0..1), so unlike ghostty's `componentLuminance` (which
/// divides a u8 by 255) we use it directly.
fn componentLuminance(c: f32) f32 {
    if (c <= 0.03928) return c / 12.92;
    return std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
}

/// Relative luminance (0 = black, 1 = white). W3C WCAG 2.0.
/// https://www.w3.org/TR/WCAG20/#relativeluminancedef
pub fn luminance(c: [3]f32) f32 {
    return 0.2126 * componentLuminance(c[0]) +
        0.7152 * componentLuminance(c[1]) +
        0.0722 * componentLuminance(c[2]);
}

/// WCAG contrast ratio between two colors (1..21). Symmetric in its arguments.
pub fn contrast(a: [3]f32, b: [3]f32) f32 {
    const la = luminance(a);
    const lb = luminance(b);
    const hi = @max(la, lb);
    const lo = @min(la, lb);
    return (hi + 0.05) / (lo + 0.05);
}

/// If `fg` does not reach `min_ratio` contrast against `bg`, return whichever of
/// black/white contrasts more with `bg`; otherwise return `fg` unchanged.
/// Faithful port of ghostty's GLSL `contrasted_color`. A `min_ratio` of 1 (the
/// config default) can never trip the threshold, so this is a no-op then.
pub fn contrastedColor(fg: [3]f32, bg: [3]f32, min_ratio: f32) [3]f32 {
    if (contrast(fg, bg) >= min_ratio) return fg;
    const white = [3]f32{ 1, 1, 1 };
    const black = [3]f32{ 0, 0, 0 };
    return if (contrast(white, bg) > contrast(black, bg)) white else black;
}

test "color: contrast extremes match WCAG (white/black = 21, equal = 1)" {
    try std.testing.expectApproxEqAbs(@as(f32, 21.0), contrast(.{ 1, 1, 1 }, .{ 0, 0, 0 }), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), contrast(.{ 0.5, 0.5, 0.5 }, .{ 0.5, 0.5, 0.5 }), 0.0001);
    // Symmetric.
    try std.testing.expectApproxEqAbs(
        contrast(.{ 0.2, 0.4, 0.6 }, .{ 0.9, 0.1, 0.3 }),
        contrast(.{ 0.9, 0.1, 0.3 }, .{ 0.2, 0.4, 0.6 }),
        0.0001,
    );
}

test "color: luminance ordering (white brightest, black darkest)" {
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), luminance(.{ 1, 1, 1 }), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), luminance(.{ 0, 0, 0 }), 0.0001);
    try std.testing.expect(luminance(.{ 0, 1, 0 }) > luminance(.{ 0, 0, 1 })); // green > blue
}

test "color: minimum-contrast forces black/white only when below the ratio" {
    // A mid-grey fg on a mid-grey bg has ~1.0 contrast; ratio 4.5 forces a flip.
    const fg = [3]f32{ 0.45, 0.45, 0.45 };
    const bg = [3]f32{ 0.5, 0.5, 0.5 };
    const out = contrastedColor(fg, bg, 4.5);
    // bg is light-ish, so black contrasts more -> expect black.
    try std.testing.expectEqual([3]f32{ 0, 0, 0 }, out);

    // On a dark bg, white wins.
    const out_dark = contrastedColor(.{ 0.2, 0.2, 0.2 }, .{ 0.1, 0.1, 0.1 }, 4.5);
    try std.testing.expectEqual([3]f32{ 1, 1, 1 }, out_dark);
}

test "color: ratio 1 is a no-op (default disables the adjustment)" {
    const fg = [3]f32{ 0.3, 0.6, 0.9 };
    try std.testing.expectEqual(fg, contrastedColor(fg, .{ 0.31, 0.61, 0.91 }, 1));
}

test "color: already-contrasting foreground is left unchanged" {
    const fg = [3]f32{ 1, 1, 1 };
    const bg = [3]f32{ 0, 0, 0 };
    try std.testing.expectEqual(fg, contrastedColor(fg, bg, 4.5));
}
