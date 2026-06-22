//! whostty: config path expansion.
//!
//! Adapted from ghostty `src/config/path.zig`. Expands `~` (home) and `%VAR%`
//! environment references and resolves relative paths against a base directory
//! (the including config file's directory). ghostty's `path.zig` is Linux/macOS
//! focused (`~/` only, no `%VAR%`); the Windows form here uses `USERPROFILE` for
//! `~` and supports `%VAR%` so `config-file = %APPDATA%\whostty\extra.conf`
//! resolves. Pure where possible: the core expansion takes an injectable getenv
//! so it is host-testable.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// A getenv function. Returns null for an undefined variable.
pub const GetEnvFn = *const fn (name: []const u8) ?[]const u8;

/// Expand a leading `~` (to `USERPROFILE`/`HOME`) and any `%VAR%` references in
/// `input`, using `getenv` for lookups. An undefined `%VAR%` expands to empty.
/// The result is always freshly allocated and owned by the caller.
pub fn expandEnvWith(alloc: Allocator, input: []const u8, getenv: GetEnvFn) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var rest = input;

    // Leading "~" or "~/" / "~\" -> home directory.
    if (rest.len >= 1 and rest[0] == '~' and
        (rest.len == 1 or rest[1] == '/' or rest[1] == '\\'))
    {
        const home = getenv("USERPROFILE") orelse getenv("HOME") orelse "";
        try out.appendSlice(alloc, home);
        rest = rest[1..];
    }

    // Expand %VAR% references anywhere in the remainder.
    var i: usize = 0;
    while (i < rest.len) {
        const c = rest[i];
        if (c == '%') {
            if (std.mem.indexOfScalarPos(u8, rest, i + 1, '%')) |end| {
                const name = rest[i + 1 .. end];
                // "%%" is a literal percent.
                if (name.len == 0) {
                    try out.append(alloc, '%');
                } else if (getenv(name)) |val| {
                    try out.appendSlice(alloc, val);
                }
                i = end + 1;
                continue;
            }
        }
        try out.append(alloc, c);
        i += 1;
    }

    return out.toOwnedSlice(alloc);
}

/// Convenience wrapper over `expandEnvWith` using the process environment.
pub fn expandEnv(alloc: Allocator, input: []const u8) ![]u8 {
    return expandEnvWith(alloc, input, processGetEnv);
}

/// Resolve `input` (which may contain `~`/`%VAR%`) to a canonical absolute path.
/// An absolute expanded path resets the base; otherwise it is resolved against
/// `base_dir` (which must be absolute). `.`/`..` segments are collapsed so the
/// result is stable for use as a cycle-guard key. The result is owned by the
/// caller.
pub fn resolve(alloc: Allocator, base_dir: []const u8, input: []const u8) ![]u8 {
    const expanded = try expandEnv(alloc, input);
    defer alloc.free(expanded);
    // std.fs.path.resolve collapses `.`/`..` and lets an absolute component
    // override the base — exactly the realpath-like normalization we want.
    return std.fs.path.resolve(alloc, &.{ base_dir, expanded });
}

/// True if `input` parses as an optional path (leading `?`). Returns the path
/// without the marker.
pub fn parseOptional(input: []const u8) struct { optional: bool, path: []const u8 } {
    if (input.len > 0 and input[0] == '?') {
        return .{ .optional = true, .path = input[1..] };
    }
    return .{ .optional = false, .path = input };
}

/// getenv backed by the process environment. A small thread-local scratch
/// buffer holds one variable's value at a time: it is reset before every lookup
/// (safe because `expandEnvWith` copies the returned value into the caller's
/// allocator immediately, before the next lookup), so it never accumulates.
threadlocal var env_buf: [32768]u8 = undefined;
threadlocal var env_fba: ?std.heap.FixedBufferAllocator = null;

fn processGetEnv(name: []const u8) ?[]const u8 {
    if (env_fba == null) env_fba = std.heap.FixedBufferAllocator.init(&env_buf);
    env_fba.?.reset();
    const a = env_fba.?.allocator();
    return std.process.getEnvVarOwned(a, name) catch null;
}

test "expandEnvWith: tilde to home" {
    const G = struct {
        fn get(name: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, name, "USERPROFILE")) return "C:\\Users\\me";
            return null;
        }
    };
    const out = try expandEnvWith(std.testing.allocator, "~\\foo", G.get);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("C:\\Users\\me\\foo", out);
}

test "expandEnvWith: percent variable" {
    const G = struct {
        fn get(name: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, name, "APPDATA")) return "C:\\Users\\me\\AppData\\Roaming";
            return null;
        }
    };
    const out = try expandEnvWith(std.testing.allocator, "%APPDATA%\\whostty\\x.conf", G.get);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("C:\\Users\\me\\AppData\\Roaming\\whostty\\x.conf", out);
}

test "expandEnvWith: undefined variable expands empty; %% is literal" {
    const G = struct {
        fn get(_: []const u8) ?[]const u8 {
            return null;
        }
    };
    const a = std.testing.allocator;
    {
        const out = try expandEnvWith(a, "x%NOPE%y", G.get);
        defer a.free(out);
        try std.testing.expectEqualStrings("xy", out);
    }
    {
        const out = try expandEnvWith(a, "100%%", G.get);
        defer a.free(out);
        try std.testing.expectEqualStrings("100%", out);
    }
}

test "expandEnvWith: no expansion needed" {
    const G = struct {
        fn get(_: []const u8) ?[]const u8 {
            return null;
        }
    };
    const out = try expandEnvWith(std.testing.allocator, "plain\\path.conf", G.get);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("plain\\path.conf", out);
}

test "parseOptional" {
    const a = parseOptional("?foo");
    try std.testing.expect(a.optional);
    try std.testing.expectEqualStrings("foo", a.path);
    const b = parseOptional("bar");
    try std.testing.expect(!b.optional);
    try std.testing.expectEqualStrings("bar", b.path);
}
