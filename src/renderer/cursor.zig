//! whostty: cursor rendering — decides which cursor style to draw and emits the
//! quads for it.
//!
//! Reference: ghostty `src/renderer/cursor.zig` (strategy: port). `resolveStyle`
//! is a faithful port of ghostty's `style()` priority system; whostty has no
//! `terminal.RenderState`, so the caller (`App.buildQuads`) reads the cursor
//! position / DECTCEM (mode 25) / blink (mode 12) / focus off libghostty-vt and
//! passes them in via `State`. The shape geometry (block / hollow block / bar /
//! underline) emits the renderer's `SolidRect` quads. The block cursor's
//! inverted text glyph is re-drawn by the caller, which owns glyph lookup.
//!
//! Omitted vs ghostty: the `lock` style (password-input detection is not wired)
//! and custom cursor sprites. See PORTING.md.
const std = @import("std");
const gl = @import("OpenGL.zig");

/// Cursor styles a renderer must be able to draw. A superset of the terminal
/// cursor styles: `block_hollow` is the outline shown when the window is not
/// focused. Mirrors ghostty's `renderer.cursor.Style`.
pub const Style = enum { block, block_hollow, bar, underline };

/// The terminal's requested cursor style. Mirrors libghostty-vt's
/// `terminal.CursorStyle`, kept local so this module has no vt dependency and
/// stays host-testable.
pub const TermStyle = enum { block, bar, underline, block_hollow };

/// Inputs that decide cursor visibility/style, flattened from what ghostty reads
/// off its `RenderState`. `App.buildQuads` fills these from libghostty-vt.
pub const State = struct {
    /// The cursor position lies within the visible viewport. False when the user
    /// has scrolled the cursor up into scrollback — then no cursor is drawn.
    in_viewport: bool,
    /// IME pre-edit in progress: always show a block, even if mode 25 hid it,
    /// because it is important editing state. Not wired yet (IME is #68).
    preedit: bool = false,
    /// DECTCEM (mode 25): the terminal wants the cursor visible.
    visible: bool,
    /// The window currently has keyboard focus.
    focused: bool,
    /// Mode 12: the cursor is configured to blink.
    blinking: bool,
    /// The current blink phase is "on" (cursor shown this tick).
    blink_visible: bool,
    /// The terminal's requested visual style (DECSCUSR / config default).
    term_style: TermStyle,
};

/// Returns the cursor style to render, or null if no cursor should be drawn.
///
/// Faithful port of ghostty `renderer/cursor.zig` `style()`: the order of the
/// conditionals below is a deliberate priority system — keep it identical.
pub fn resolveStyle(s: State) ?Style {
    // The cursor must be visible in the viewport to be rendered.
    if (!s.in_viewport) return null;

    // In preedit we always show the block cursor, even if mode 25 hid it.
    if (s.preedit) return .block;

    // If the cursor is explicitly hidden by terminal mode, don't render.
    if (!s.visible) return null;

    // If we're not focused, the cursor is always shown as a hollow box.
    if (!s.focused) return .block_hollow;

    // If the cursor is blinking and we're in the off phase, don't render.
    if (s.blinking and !s.blink_visible) return null;

    // Otherwise, whatever style the terminal wants.
    return switch (s.term_style) {
        .bar => .bar,
        .block => .block,
        .underline => .underline,
        .block_hollow => .block_hollow,
    };
}

/// The cell rectangle (window pixels) the cursor occupies, plus the line
/// thickness used for the bar width and the underline / hollow border.
pub const Geometry = struct {
    px: i32,
    py: i32,
    cell_w: u32,
    cell_h: u32,
    /// Bar width and underline / hollow-border thickness, in pixels (clamped to
    /// at least 1).
    thickness: u32,
};

/// Append the solid rect(s) that draw `style` for the cell at `geo`, filled with
/// `color` at opacity `alpha`. Only the shape is drawn here; the block cursor's
/// inverted text glyph is re-emitted by the caller. Pure; host-testable.
pub fn shapeQuads(
    out: *std.ArrayList(gl.Quad),
    alloc: std.mem.Allocator,
    style: Style,
    geo: Geometry,
    color: [3]f32,
    alpha: f32,
) !void {
    const t: u32 = @max(1, geo.thickness);
    const w = geo.cell_w;
    const h = geo.cell_h;
    const x = geo.px;
    const y = geo.py;
    const r = color[0];
    const g = color[1];
    const b = color[2];

    switch (style) {
        // Full-cell fill.
        .block => try out.append(alloc, .{ .solid = .{
            .px = x, .py = y, .w = w, .h = h, .r = r, .g = g, .b = b, .a = alpha,
        } }),

        // Vertical bar at the left edge.
        .bar => try out.append(alloc, .{ .solid = .{
            .px = x, .py = y, .w = t, .h = h, .r = r, .g = g, .b = b, .a = alpha,
        } }),

        // Horizontal bar at the bottom edge.
        .underline => try out.append(alloc, .{ .solid = .{
            .px = x,
            .py = y + @as(i32, @intCast(h -| t)),
            .w = w,
            .h = t,
            .r = r,
            .g = g,
            .b = b,
            .a = alpha,
        } }),

        // Outline: four borders. Corners overlap (same color), which is fine
        // and avoids clamping the side heights for tiny cells.
        .block_hollow => {
            const right_x = x + @as(i32, @intCast(w -| t));
            const bottom_y = y + @as(i32, @intCast(h -| t));
            // top
            try out.append(alloc, .{ .solid = .{ .px = x, .py = y, .w = w, .h = t, .r = r, .g = g, .b = b, .a = alpha } });
            // bottom
            try out.append(alloc, .{ .solid = .{ .px = x, .py = bottom_y, .w = w, .h = t, .r = r, .g = g, .b = b, .a = alpha } });
            // left
            try out.append(alloc, .{ .solid = .{ .px = x, .py = y, .w = t, .h = h, .r = r, .g = g, .b = b, .a = alpha } });
            // right
            try out.append(alloc, .{ .solid = .{ .px = right_x, .py = y, .w = t, .h = h, .r = r, .g = g, .b = b, .a = alpha } });
        },
    }
}

// --- resolveStyle: ported from ghostty renderer/cursor.zig style() tests -----

test "cursor: default uses the configured style; unfocused is hollow; blink-off hides" {
    // bar style, blinking on.
    const base: State = .{ .in_viewport = true, .visible = true, .focused = true, .blinking = true, .blink_visible = true, .term_style = .bar };
    try std.testing.expectEqual(Style.bar, resolveStyle(base).?);
    // Unfocused -> hollow regardless of blink phase.
    try std.testing.expectEqual(Style.block_hollow, resolveStyle(.{ .in_viewport = true, .visible = true, .focused = false, .blinking = true, .blink_visible = true, .term_style = .bar }).?);
    try std.testing.expectEqual(Style.block_hollow, resolveStyle(.{ .in_viewport = true, .visible = true, .focused = false, .blinking = true, .blink_visible = false, .term_style = .bar }).?);
    // Focused, blinking, off phase -> nothing.
    try std.testing.expect(resolveStyle(.{ .in_viewport = true, .visible = true, .focused = true, .blinking = true, .blink_visible = false, .term_style = .bar }) == null);
}

test "cursor: blinking disabled always shows when focused" {
    const on: State = .{ .in_viewport = true, .visible = true, .focused = true, .blinking = false, .blink_visible = true, .term_style = .bar };
    const off: State = .{ .in_viewport = true, .visible = true, .focused = true, .blinking = false, .blink_visible = false, .term_style = .bar };
    try std.testing.expectEqual(Style.bar, resolveStyle(on).?);
    try std.testing.expectEqual(Style.bar, resolveStyle(off).?);
}

test "cursor: mode 25 off hides the cursor in every focus/blink combination" {
    for ([_]bool{ true, false }) |focused| {
        for ([_]bool{ true, false }) |blink| {
            try std.testing.expect(resolveStyle(.{ .in_viewport = true, .visible = false, .focused = focused, .blinking = true, .blink_visible = blink, .term_style = .bar }) == null);
        }
    }
}

test "cursor: preedit forces a block; out-of-viewport hides everything" {
    // Preedit beats mode 25 / blink, but only when in the viewport.
    try std.testing.expectEqual(Style.block, resolveStyle(.{ .in_viewport = true, .preedit = true, .visible = false, .focused = false, .blinking = true, .blink_visible = false, .term_style = .underline }).?);
    // Scrolled out of the viewport: nothing, even with preedit.
    try std.testing.expect(resolveStyle(.{ .in_viewport = false, .preedit = true, .visible = true, .focused = true, .blinking = false, .blink_visible = true, .term_style = .block }) == null);
}

test "cursor: terminal underline/block styles pass through" {
    const mk = struct {
        fn s(ts: TermStyle) State {
            return .{ .in_viewport = true, .visible = true, .focused = true, .blinking = false, .blink_visible = true, .term_style = ts };
        }
    };
    try std.testing.expectEqual(Style.block, resolveStyle(mk.s(.block)).?);
    try std.testing.expectEqual(Style.underline, resolveStyle(mk.s(.underline)).?);
}

// --- shapeQuads geometry -----------------------------------------------------

test "cursor: block fills the whole cell with the given alpha" {
    const alloc = std.testing.allocator;
    var q: std.ArrayList(gl.Quad) = .empty;
    defer q.deinit(alloc);
    try shapeQuads(&q, alloc, .block, .{ .px = 16, .py = 32, .cell_w = 8, .cell_h = 16, .thickness = 2 }, .{ 1, 0, 0 }, 0.75);
    try std.testing.expectEqual(@as(usize, 1), q.items.len);
    const s = q.items[0].solid;
    try std.testing.expectEqual(@as(i32, 16), s.px);
    try std.testing.expectEqual(@as(i32, 32), s.py);
    try std.testing.expectEqual(@as(u32, 8), s.w);
    try std.testing.expectEqual(@as(u32, 16), s.h);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), s.a, 0.0001);
}

test "cursor: bar is a left-edge vertical stripe of width = thickness" {
    const alloc = std.testing.allocator;
    var q: std.ArrayList(gl.Quad) = .empty;
    defer q.deinit(alloc);
    try shapeQuads(&q, alloc, .bar, .{ .px = 0, .py = 0, .cell_w = 8, .cell_h = 16, .thickness = 2 }, .{ 1, 1, 1 }, 1);
    try std.testing.expectEqual(@as(usize, 1), q.items.len);
    const s = q.items[0].solid;
    try std.testing.expectEqual(@as(u32, 2), s.w);
    try std.testing.expectEqual(@as(u32, 16), s.h);
    try std.testing.expectEqual(@as(i32, 0), s.px);
}

test "cursor: underline sits at the bottom of the cell" {
    const alloc = std.testing.allocator;
    var q: std.ArrayList(gl.Quad) = .empty;
    defer q.deinit(alloc);
    try shapeQuads(&q, alloc, .underline, .{ .px = 0, .py = 0, .cell_w = 8, .cell_h = 16, .thickness = 2 }, .{ 1, 1, 1 }, 1);
    try std.testing.expectEqual(@as(usize, 1), q.items.len);
    const s = q.items[0].solid;
    try std.testing.expectEqual(@as(u32, 8), s.w);
    try std.testing.expectEqual(@as(u32, 2), s.h);
    try std.testing.expectEqual(@as(i32, 14), s.py); // 16 - 2
}

test "cursor: hollow draws four border rects" {
    const alloc = std.testing.allocator;
    var q: std.ArrayList(gl.Quad) = .empty;
    defer q.deinit(alloc);
    try shapeQuads(&q, alloc, .block_hollow, .{ .px = 0, .py = 0, .cell_w = 8, .cell_h = 16, .thickness = 2 }, .{ 1, 1, 1 }, 1);
    try std.testing.expectEqual(@as(usize, 4), q.items.len);
    // The right border starts at cell_w - thickness.
    const right = q.items[3].solid;
    try std.testing.expectEqual(@as(i32, 6), right.px); // 8 - 2
    try std.testing.expectEqual(@as(u32, 2), right.w);
    try std.testing.expectEqual(@as(u32, 16), right.h);
}
