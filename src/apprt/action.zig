//! whostty: the formal apprt action contract (#86).
//!
//! Reference: ghostty `src/apprt/action.zig` (`Target` + `Action`). Strategy:
//! port a faithful SUBSET. Ghostty's `Action` is a `union(Key)` of ~64 one-way
//! messages tagged by a C-ABI `Key(c_int)` so it can cross the libghostty C
//! boundary (with `CValue`/`cval`). whostty is NOT a libghostty C boundary — its
//! apprt dispatches inline on the window thread — so this mirrors the SEMANTICS,
//! not the comptime-key/extern-union machinery: a plain runtime-tagged
//! `union(enum)` consumed by `App.performAction`.
//!
//! This module is platform-free (no Win32 / GL / FreeType types) so the action
//! grammar and the `binding.Action -> apprt.Action` mapping are host-testable.
//! The effects of each action (window state, scrolling, the clipboard, spawning
//! a window) live in the Win32 `App` and are verified on-device.
const std = @import("std");
const binding = @import("../input/Binding.zig");

/// The thing an action acts on. Mirrors ghostty's `apprt.Target` (`app` vs.
/// `surface: *CoreSurface`). whostty has no separate core-Surface layer, so the
/// surface payload is carried by the caller (the per-window `SurfaceCtx`) rather
/// than embedded here; `Action` stays a flat union and `performAction` receives
/// the surface context alongside it. App-scoped variants ignore that context.
pub const Target = enum { app, surface };

/// A one-way apprt action. A faithful subset of ghostty `apprt/action.zig`'s
/// `Action` union limited to what whostty implements today (single-window plus
/// multi-window/new-window, #86). Variant names and payloads match ghostty's
/// spelling where they overlap; `close_surface` is whostty's own spelling
/// (mirroring its `binding.Action.close_surface`) and maps to ghostty's
/// surface-close path (`rt_surface.close()`), not an apprt action there.
///
/// scroll/clipboard/close_surface are folded INTO this union (and handled in
/// `performAction`) even though ghostty handles them inside
/// `Surface.performBindingAction` rather than as apprt actions — an intentional,
/// faithful simplification given whostty's lack of a core-Surface mailbox.
pub const Action = union(enum) {
    // --- App-scoped (Target.app) ---
    /// Open a new top-level window (a fresh window thread, #86).
    new_window,
    /// Close every window, ending the app (#92).
    quit,
    /// Bring the Nth top-level window (1-based) to the foreground (#92).
    goto_window: u8,

    // --- Surface-scoped (Target.surface): the calling window ---
    /// Close the calling window and all its tabs/splits (#92). Distinct from
    /// `close_surface`, which closes only the focused pane.
    close_window,
    /// Bring the calling window to the foreground (#92).
    present_terminal,
    /// Pin / unpin the calling window always-on-top (#92).
    toggle_window_float_on_top,
    /// Hide / show the calling window (#92).
    toggle_visibility,
    /// Close the calling window. Breaks only that window's message loop; the
    /// process exits only when the LAST window closes.
    close_surface,
    /// Borderless windowed fullscreen on/off.
    toggle_fullscreen,
    /// Maximize/restore.
    toggle_maximize,
    /// Show/hide the titlebar + resize border.
    toggle_window_decorations,
    /// Scroll the viewport one page up/down.
    scroll_page_up,
    scroll_page_down,
    /// Jump to the top of scrollback / back to the live bottom.
    scroll_to_top,
    scroll_to_bottom,
    /// Copy the selection to / paste from the system clipboard.
    copy_to_clipboard,
    paste_from_clipboard,
    /// Select the entire scrollback + screen (#53).
    select_all,

    // --- Still stubbed: in-window subdivision (#87) ---
    // Mapped-but-logged. Payloads reuse `binding`'s enums so the mapping is total.
    new_split: binding.Direction,
    goto_split: binding.Direction,
    new_tab,
    next_tab,
    previous_tab,
    goto_tab: u8,

    /// Whether this action is app-scoped (acts on the whole app) or
    /// surface-scoped (acts on the calling window). Mirrors how ghostty routes
    /// each action to a `Target`.
    pub fn target(self: Action) Target {
        return switch (self) {
            .new_window, .quit, .goto_window => .app,
            else => .surface,
        };
    }
};

/// Translate a keybind grammar action (`input/Binding.zig`) into the apprt action
/// contract. Pure and platform-free so the whole binding->apprt layer is
/// host-testable in isolation. Every `binding.Action` maps to exactly one
/// `apprt.Action` (the tab/split ones map to their still-stubbed counterparts).
pub fn fromBinding(b: binding.Action) Action {
    return switch (b) {
        .new_window => .new_window,
        .close_surface => .close_surface,
        .toggle_fullscreen => .toggle_fullscreen,
        .toggle_maximize => .toggle_maximize,
        .toggle_window_decorations => .toggle_window_decorations,
        .scroll_page_up => .scroll_page_up,
        .scroll_page_down => .scroll_page_down,
        .scroll_to_top => .scroll_to_top,
        .scroll_to_bottom => .scroll_to_bottom,
        .copy_to_clipboard => .copy_to_clipboard,
        .paste_from_clipboard => .paste_from_clipboard,
        .select_all => .select_all,
        .new_split => |d| .{ .new_split = d },
        .goto_split => |d| .{ .goto_split = d },
        .new_tab => .new_tab,
        .next_tab => .next_tab,
        .previous_tab => .previous_tab,
        .goto_tab => |n| .{ .goto_tab = n },
        .quit => .quit,
        .close_window => .close_window,
        .goto_window => |n| .{ .goto_window = n },
        .present_terminal => .present_terminal,
        .toggle_window_float_on_top => .toggle_window_float_on_top,
        .toggle_visibility => .toggle_visibility,
    };
}

const testing = std.testing;

test "apprt.Action: binding maps to the matching apprt action" {
    try testing.expectEqual(Action.new_window, fromBinding(.new_window));
    try testing.expectEqual(Action.close_surface, fromBinding(.close_surface));
    try testing.expectEqual(Action.toggle_fullscreen, fromBinding(.toggle_fullscreen));
    try testing.expectEqual(Action.toggle_maximize, fromBinding(.toggle_maximize));
    try testing.expectEqual(Action.toggle_window_decorations, fromBinding(.toggle_window_decorations));
    try testing.expectEqual(Action.scroll_page_up, fromBinding(.scroll_page_up));
    try testing.expectEqual(Action.scroll_page_down, fromBinding(.scroll_page_down));
    try testing.expectEqual(Action.scroll_to_top, fromBinding(.scroll_to_top));
    try testing.expectEqual(Action.scroll_to_bottom, fromBinding(.scroll_to_bottom));
    try testing.expectEqual(Action.copy_to_clipboard, fromBinding(.copy_to_clipboard));
    try testing.expectEqual(Action.paste_from_clipboard, fromBinding(.paste_from_clipboard));
    try testing.expectEqual(Action.select_all, fromBinding(.select_all));
    // App-lifecycle + windowing actions (#92).
    try testing.expectEqual(Action.quit, fromBinding(.quit));
    try testing.expectEqual(Action.close_window, fromBinding(.close_window));
    try testing.expectEqual(Action{ .goto_window = 2 }, fromBinding(.{ .goto_window = 2 }));
    try testing.expectEqual(Action.present_terminal, fromBinding(.present_terminal));
    try testing.expectEqual(Action.toggle_window_float_on_top, fromBinding(.toggle_window_float_on_top));
    try testing.expectEqual(Action.toggle_visibility, fromBinding(.toggle_visibility));
}

test "apprt.Action: stubbed tab/split actions still map (payload-preserving)" {
    try testing.expectEqual(Action{ .new_split = .right }, fromBinding(.{ .new_split = .right }));
    try testing.expectEqual(Action{ .goto_split = .up }, fromBinding(.{ .goto_split = .up }));
    try testing.expectEqual(Action.new_tab, fromBinding(.new_tab));
    try testing.expectEqual(Action.next_tab, fromBinding(.next_tab));
    try testing.expectEqual(Action.previous_tab, fromBinding(.previous_tab));
    try testing.expectEqual(Action{ .goto_tab = 4 }, fromBinding(.{ .goto_tab = 4 }));
}

test "apprt.Action: only new_window is app-scoped" {
    const new_window: Action = .new_window;
    const close_surface: Action = .close_surface;
    const scroll_page_up: Action = .scroll_page_up;
    const copy: Action = .copy_to_clipboard;
    try testing.expectEqual(Target.app, new_window.target());
    try testing.expectEqual(Target.surface, close_surface.target());
    try testing.expectEqual(Target.surface, scroll_page_up.target());
    try testing.expectEqual(Target.surface, copy.target());
    try testing.expectEqual(Target.surface, (Action{ .new_split = .left }).target());
    // App-lifecycle (#92): quit + goto_window are app-scoped; the rest act on
    // the calling window (surface-scoped).
    try testing.expectEqual(Target.app, @as(Action, .quit).target());
    try testing.expectEqual(Target.app, (Action{ .goto_window = 1 }).target());
    try testing.expectEqual(Target.surface, @as(Action, .close_window).target());
    try testing.expectEqual(Target.surface, @as(Action, .present_terminal).target());
    try testing.expectEqual(Target.surface, @as(Action, .toggle_visibility).target());
}
