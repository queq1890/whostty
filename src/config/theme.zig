//! whostty: theme resolution.
//!
//! Adapted from ghostty `src/config/theme.zig`. A theme is just a config file
//! (a set of `key = value` lines, typically colors + palette) loaded as a base
//! layer beneath the user's own config. ghostty ships a large iTerm2-derived
//! theme catalog as a *resources* directory; whostty embeds a small built-in
//! catalog via `@embedFile` (so it always works with no external assets) and
//! also searches a user themes directory (`%APPDATA%\whostty\themes`) and the
//! executable's `themes/` resources directory. `theme = light:X dark:Y` drives
//! OS-appearance switching via `conditional.State` (see Config.ThemeSpec).
const std = @import("std");
const Allocator = std.mem.Allocator;
const path = @import("path.zig");

/// The embedded built-in theme catalog. Each value is a complete config snippet.
pub const builtin = std.StaticStringMap([]const u8).initComptime(.{
    .{ "rose-pine", @embedFile("themes/rose-pine") },
    .{ "rose-pine-dawn", @embedFile("themes/rose-pine-dawn") },
    .{ "builtin-dark", @embedFile("themes/builtin-dark") },
    .{ "builtin-light", @embedFile("themes/builtin-light") },
});

/// Location of possible themes. The order matters: it defines search priority
/// (built-ins are checked before either of these). Faithful to ghostty's
/// `Location` (minus macOS Application Support).
pub const Location = enum {
    user, // user themes dir (%APPDATA%\whostty\themes)
    resources, // executable-relative resources dir (<exe dir>\themes)

    /// Returns the directory for this location, or null if it can't be
    /// determined. Allocated in `arena`.
    pub fn dir(self: Location, arena: Allocator) !?[]const u8 {
        return switch (self) {
            .user => path.expandEnv(arena, "%APPDATA%\\whostty\\themes") catch null,
            .resources => res: {
                const exe_dir = std.fs.selfExeDirPathAlloc(arena) catch break :res null;
                break :res try std.fs.path.join(arena, &.{ exe_dir, "themes" });
            },
        };
    }
};

/// Return the config text for the named theme, or null if it cannot be found.
/// Built-in themes are returned directly (static, do not free); themes found on
/// disk are read into `arena`. `arena` should be an arena allocator.
pub fn content(arena: Allocator, name: []const u8) !?[]const u8 {
    // Built-in catalog first.
    if (builtin.get(name)) |c| return c;

    // A theme name may not contain path separators (it must resolve within a
    // themes directory). Absolute/relative theme paths are not supported here.
    const base = std.fs.path.basename(name);
    if (!std.mem.eql(u8, name, base)) return null;

    inline for (.{ Location.user, Location.resources }) |loc| {
        if (try loc.dir(arena)) |d| {
            const p = try std.fs.path.join(arena, &.{ d, name });
            if (std.fs.cwd().readFileAlloc(arena, p, 1 << 20)) |data| {
                return data;
            } else |err| switch (err) {
                error.FileNotFound => {},
                else => return null,
            }
        }
    }

    return null;
}

test "theme: built-in catalog resolves" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const rp = (try content(a, "rose-pine")).?;
    try std.testing.expect(std.mem.indexOf(u8, rp, "background = #191724") != null);

    const dawn = (try content(a, "rose-pine-dawn")).?;
    try std.testing.expect(std.mem.indexOf(u8, dawn, "background = #faf4ed") != null);
}

test "theme: unknown name returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(?[]const u8, null), try content(arena.allocator(), "nonexistent-xyz"));
}

test "theme: names with separators are rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(?[]const u8, null), try content(arena.allocator(), "evil/../escape"));
}
