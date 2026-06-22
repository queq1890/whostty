//! whostty: config file loading (Windows paths, recursive includes, themes).
//!
//! Adapted from ghostty `src/config/file_load.zig` (the preferred/legacy default
//! path probing and the constrained `open`). ghostty resolves the XDG/macOS
//! Application Support locations; whostty resolves the Windows location
//! (`%APPDATA%\whostty\config.whostty`, with the pre-1.0 `config` as the legacy
//! fallback). This file also drives the IO that `Config.loadString` deliberately
//! defers: applying a `theme` as a base layer (so the user's own config wins) and
//! resolving `config-file` includes recursively (with a cycle guard).
const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("Config.zig");
const theme = @import("theme.zig");
const path = @import("path.zig");
const conditional = @import("conditional.zig");

const log = std.log.scoped(.config);

/// Maximum config file size and include recursion depth.
const max_file_size = 1 << 20;
const max_include_depth = 16;

const OpenFileError = error{
    FileNotFound,
    FileIsEmpty,
    FileOpenFailed,
    NotAFile,
};

/// Opens the file at the given absolute path and returns it if it exists and is
/// a non-empty regular file. Faithful port of ghostty's `open`.
pub fn open(p: []const u8) OpenFileError!std.fs.File {
    std.debug.assert(std.fs.path.isAbsolute(p));

    var file = std.fs.openFileAbsolute(p, .{}) catch |err| switch (err) {
        error.FileNotFound => return OpenFileError.FileNotFound,
        else => {
            log.warn("unexpected file open error path={s} err={}", .{ p, err });
            return OpenFileError.FileOpenFailed;
        },
    };
    errdefer file.close();

    const stat = file.stat() catch return OpenFileError.FileOpenFailed;
    switch (stat.kind) {
        .file => {},
        else => return OpenFileError.NotAFile,
    }
    if (stat.size == 0) return OpenFileError.FileIsEmpty;

    return file;
}

/// The preferred default config path, `%APPDATA%\whostty\config.whostty`, with
/// the legacy `%APPDATA%\whostty\config` used if it exists and the new one does
/// not. The returned value is owned by the caller (allocate with an arena).
pub fn preferredDefaultFilePath(alloc: Allocator) ![]u8 {
    const appdata = std.process.getEnvVarOwned(alloc, "APPDATA") catch
        return error.NoAppData;

    const new_path = try std.fs.path.join(alloc, &.{ appdata, "whostty", "config.whostty" });
    if (open(new_path)) |f| {
        f.close();
        return new_path;
    } else |_| {}

    const legacy = try std.fs.path.join(alloc, &.{ appdata, "whostty", "config" });
    if (open(legacy)) |f| {
        f.close();
        return legacy;
    } else |_| {}

    // Neither exists: return the new (preferred) path so callers can report it.
    return new_path;
}

/// Load the default config file (if present) into `cfg`, resolving its theme and
/// includes. Missing/empty default file is not an error.
pub fn loadDefaultFiles(cfg: *Config, gpa: Allocator, state: conditional.State) !void {
    const p = preferredDefaultFilePath(cfg.allocator()) catch return;
    const f = open(p) catch return; // missing/empty/not-a-file -> nothing to load
    f.close();
    try loadFile(cfg, gpa, p, state);
}

/// Load the config file at `file_path` (absolute) into `cfg`: apply its `theme`
/// as a base layer, then the file itself (so the file wins over the theme), then
/// its `config-file` includes recursively.
pub fn loadFile(cfg: *Config, gpa: Allocator, file_path: []const u8, state: conditional.State) !void {
    const arena = cfg.allocator();
    const data = std.fs.cwd().readFileAlloc(arena, file_path, max_file_size) catch |err| {
        try diag(cfg, "failed to read config file {s}: {s}", .{ file_path, @errorName(err) });
        return;
    };

    try applyThemeBase(cfg, arena, data, state);

    const start = cfg.config_files.items.len;
    try cfg.loadString(data);

    var visited = std.StringHashMap(void).init(gpa);
    defer visited.deinit();
    const dir = std.fs.path.dirname(file_path) orelse ".";
    // Seed the root file's canonical path so a `config-file` pointing back at it
    // (directly or via a cycle) is caught instead of re-applied.
    if (path.resolve(arena, dir, std.fs.path.basename(file_path))) |root_key| {
        visited.put(root_key, {}) catch {};
    } else |_| {}
    try processBlock(cfg, arena, dir, state, start, &visited, 0);
}

/// Resolve the `config-file` includes already recorded on `cfg` (e.g. from a
/// prior `loadString`), relative to `base_dir`, recursively.
pub fn loadRecursiveFiles(cfg: *Config, gpa: Allocator, base_dir: []const u8, state: conditional.State) !void {
    var visited = std.StringHashMap(void).init(gpa);
    defer visited.deinit();
    try processBlock(cfg, cfg.allocator(), base_dir, state, 0, &visited, 0);
}

/// Process the `config_files` entries in `[start, len)` (a single file's block)
/// relative to `base_dir`, recursing into each.
fn processBlock(
    cfg: *Config,
    arena: Allocator,
    base_dir: []const u8,
    state: conditional.State,
    start: usize,
    visited: *std.StringHashMap(void),
    depth: usize,
) Allocator.Error!void {
    const end = cfg.config_files.items.len;
    var i = start;
    while (i < end) : (i += 1) {
        const entry = cfg.config_files.items[i];
        const po = path.parseOptional(entry);
        const resolved = path.resolve(arena, base_dir, po.path) catch |err| {
            try diag(cfg, "failed to resolve config-file {s}: {s}", .{ po.path, @errorName(err) });
            continue;
        };
        try processInclude(cfg, arena, resolved, po.optional, state, visited, depth);
    }
}

fn processInclude(
    cfg: *Config,
    arena: Allocator,
    resolved_path: []const u8,
    optional: bool,
    state: conditional.State,
    visited: *std.StringHashMap(void),
    depth: usize,
) Allocator.Error!void {
    if (depth >= max_include_depth) {
        try diag(cfg, "config-file include depth exceeded at {s}", .{resolved_path});
        return;
    }
    // Cycle guard (best effort, by resolved path string).
    if (visited.contains(resolved_path)) return;
    try visited.put(resolved_path, {});

    const data = std.fs.cwd().readFileAlloc(arena, resolved_path, max_file_size) catch |err| {
        if (!optional) {
            try diag(cfg, "failed to read included config file {s}: {s}", .{ resolved_path, @errorName(err) });
        }
        return;
    };

    const start = cfg.config_files.items.len;
    try cfg.loadString(data);
    const dir = std.fs.path.dirname(resolved_path) orelse ".";
    try processBlock(cfg, arena, dir, state, start, visited, depth + 1);
}

/// If `data` sets a `theme`, load that theme's config as a base layer. The
/// caller applies `data` afterwards so the user's own keys win over the theme.
fn applyThemeBase(cfg: *Config, arena: Allocator, data: []const u8, state: conditional.State) !void {
    const name = peekTheme(arena, data, state) orelse return;
    const text = (theme.content(arena, name) catch null) orelse {
        try diag(cfg, "theme \"{s}\" not found", .{name});
        return;
    };
    try cfg.loadString(text);
}

/// Scan `data` for the last `theme` directive and return the theme name for the
/// current OS appearance, if any. Does not mutate `cfg`.
fn peekTheme(arena: Allocator, data: []const u8, state: conditional.State) ?[]const u8 {
    var it = Config.LineIterator.init(data);
    var result: ?[]const u8 = null;
    while (it.next()) |kv| {
        if (!std.mem.eql(u8, kv.key, "theme")) continue;
        const spec = Config.ThemeSpec.parse(arena, kv.value) catch continue;
        if (spec.forState(state.theme)) |n| result = n;
    }
    return result;
}

fn diag(cfg: *Config, comptime fmt: []const u8, args: anytype) !void {
    const a = cfg.allocator();
    const msg = try std.fmt.allocPrint(a, fmt, args);
    try cfg.diagnostics.append(a, msg);
}

// =========================================================================
// Tests
// =========================================================================

test "file_load: include applies and base file wins where it sets" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "main.conf", .data = "font-size = 20\nconfig-file = inc.conf\nbackground = #abcdef\n" });
    try tmp.dir.writeFile(.{ .sub_path = "inc.conf", .data = "background = #123456\nforeground = #fedcba\n" });

    const base = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base);
    const main_path = try std.fs.path.join(testing.allocator, &.{ base, "main.conf" });
    defer testing.allocator.free(main_path);

    var cfg = Config.init(testing.allocator);
    defer cfg.deinit();
    try loadFile(&cfg, testing.allocator, main_path, .{});

    try testing.expectEqual(@as(f32, 20), cfg.font_size);
    // The include is processed after the base file, so it overrides background.
    try testing.expectEqual(Config.Color{ .r = 0x12, .g = 0x34, .b = 0x56 }, cfg.background);
    try testing.expectEqual(Config.Color{ .r = 0xfe, .g = 0xdc, .b = 0xba }, cfg.foreground);
    try testing.expectEqual(@as(usize, 0), cfg.diagnostics.items.len);
}

test "file_load: theme is a base layer; user file overrides it" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // rose-pine sets background = #191724; the user overrides foreground only.
    try tmp.dir.writeFile(.{ .sub_path = "main.conf", .data = "theme = rose-pine\nforeground = #ffffff\n" });

    const base = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base);
    const main_path = try std.fs.path.join(testing.allocator, &.{ base, "main.conf" });
    defer testing.allocator.free(main_path);

    var cfg = Config.init(testing.allocator);
    defer cfg.deinit();
    try loadFile(&cfg, testing.allocator, main_path, .{});

    // Theme background survives (user didn't set it).
    try testing.expectEqual(Config.Color{ .r = 0x19, .g = 0x17, .b = 0x24 }, cfg.background);
    // User foreground wins over the theme's.
    try testing.expectEqual(Config.Color{ .r = 0xff, .g = 0xff, .b = 0xff }, cfg.foreground);
    try testing.expectEqual(@as(usize, 0), cfg.diagnostics.items.len);
}

test "file_load: conditional theme picks by OS appearance state" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "main.conf", .data = "theme = light:rose-pine-dawn,dark:rose-pine\n" });

    const base = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base);
    const main_path = try std.fs.path.join(testing.allocator, &.{ base, "main.conf" });
    defer testing.allocator.free(main_path);

    {
        var cfg = Config.init(testing.allocator);
        defer cfg.deinit();
        try loadFile(&cfg, testing.allocator, main_path, .{ .theme = .dark });
        try testing.expectEqual(Config.Color{ .r = 0x19, .g = 0x17, .b = 0x24 }, cfg.background);
    }
    {
        var cfg = Config.init(testing.allocator);
        defer cfg.deinit();
        try loadFile(&cfg, testing.allocator, main_path, .{ .theme = .light });
        try testing.expectEqual(Config.Color{ .r = 0xfa, .g = 0xf4, .b = 0xed }, cfg.background);
    }
}

test "file_load: include cycle terminates" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "a.conf", .data = "font-size = 9\nconfig-file = b.conf\n" });
    try tmp.dir.writeFile(.{ .sub_path = "b.conf", .data = "background = #010203\nconfig-file = a.conf\n" });

    const base = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base);
    const a_path = try std.fs.path.join(testing.allocator, &.{ base, "a.conf" });
    defer testing.allocator.free(a_path);

    var cfg = Config.init(testing.allocator);
    defer cfg.deinit();
    // Must not infinite-loop / stack-overflow.
    try loadFile(&cfg, testing.allocator, a_path, .{});
    try testing.expectEqual(@as(f32, 9), cfg.font_size);
    try testing.expectEqual(Config.Color{ .r = 0x01, .g = 0x02, .b = 0x03 }, cfg.background);
}

test "file_load: relative self-include is caught (canonical cycle guard)" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // A relative self-reference would, without path canonicalization, dodge the
    // cycle guard (each level appends a distinct `.\` segment) and re-apply the
    // file up to the depth limit, duplicating repeatable keys.
    try tmp.dir.writeFile(.{ .sub_path = "x.conf", .data = "font-size = 7\nenv = A=b\nconfig-file = ./x.conf\n" });

    const base = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base);
    const x_path = try std.fs.path.join(testing.allocator, &.{ base, "x.conf" });
    defer testing.allocator.free(x_path);

    var cfg = Config.init(testing.allocator);
    defer cfg.deinit();
    try loadFile(&cfg, testing.allocator, x_path, .{});

    try testing.expectEqual(@as(f32, 7), cfg.font_size);
    // Applied exactly once: no duplicate env entries, no spurious diagnostics.
    try testing.expectEqual(@as(usize, 1), cfg.env.items.len);
    try testing.expectEqual(@as(usize, 0), cfg.diagnostics.items.len);
}

test "file_load: missing required include is a diagnostic; optional is silent" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "main.conf", .data = "config-file = nope.conf\nconfig-file = ?maybe.conf\n" });

    const base = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base);
    const main_path = try std.fs.path.join(testing.allocator, &.{ base, "main.conf" });
    defer testing.allocator.free(main_path);

    var cfg = Config.init(testing.allocator);
    defer cfg.deinit();
    try loadFile(&cfg, testing.allocator, main_path, .{});
    // Exactly one diagnostic (the required missing include); optional is silent.
    try testing.expectEqual(@as(usize, 1), cfg.diagnostics.items.len);
}
