//! whostty: the bundled terminfo entry for TERM=xterm-ghostty (#137, epic E0).
//!
//! Apps running in a whostty pane need a discoverable terminfo entry for the
//! injected `TERM` (see `engine/env.zig`). whostty ships the source here, under
//! `src/` (covered by `build.zig.zon`'s `.paths`), so packaging can compile it
//! with `tic` into the `TERMINFO` directory whostty points the child at. The
//! source is also embedded so the installer always has it without a separate
//! data path.
//!
//! Living outside the platform-free engine module (which cannot reach `src/`
//! data files) keeps the engine boundary clean; the engine only computes the env
//! that references this entry.

const std = @import("std");

/// The terminfo *source* for xterm-ghostty (the `tic` input). Embedded so it is
/// always available to the installer / packaging step.
pub const source = @embedFile("terminfo/xterm-ghostty.terminfo");

/// The primary `TERM` name this entry defines — kept in sync with
/// `engine.env.term`.
pub const term = "xterm-ghostty";

test "terminfo: the bundled xterm-ghostty source ships and names the TERM" {
    // Ships via build.zig.zon `.paths` ("src") and is embedded, so packaging can
    // always find + compile it.
    try std.testing.expect(source.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, source, term) != null);
    // Carries the direct-color extension whostty supports.
    try std.testing.expect(std.mem.indexOf(u8, source, "Tc,") != null);
    // Builds on the universally-available xterm-256color base.
    try std.testing.expect(std.mem.indexOf(u8, source, "use=xterm-256color") != null);
}
