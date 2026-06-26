//! whostty entrypoint.
//!
//! Bootstrap/slice-0 stage. On Windows it drives the ConPTY pty layer; on other
//! hosts (used for cross-compiling checks and host-side unit tests) it falls
//! back to a libghostty-vt wiring demo. The full Win32 apprt + renderer are
//! tracked as slice-0 work (see the repo issues and PORTING.md).
const std = @import("std");
const builtin = @import("builtin");
const vt = @import("ghostty-vt");
const cli = @import("cli.zig");
const w = @import("os/windows.zig");
const theme = @import("config/theme.zig");
const config = @import("config.zig");
const discovery = @import("font/discovery.zig");
const binding = @import("input/Binding.zig");

// Canonical version lives in build.zig.zon (`.version`); keep this literal in
// lockstep with it and the git release tag when bumping.
const version_string = "whostty 0.0.1 (ghostty v1.3.1, libghostty-vt)";

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // argsAlloc returns [][:0]u8; re-view it as []const []const u8 for the parser.
    const argv = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, argv);
    const args = try alloc.alloc([]const u8, argv.len);
    defer alloc.free(args);
    for (argv, 0..) |a, i| args[i] = a;

    var opts = try cli.parse(alloc, args[1..]);
    defer opts.deinit();

    switch (opts.action) {
        .help => return cliPrint(help_text),
        .version => return cliPrint(version_string ++ "\n"),
        .list_fonts => return listFontsAction(alloc),
        .list_themes => return listThemesAction(alloc),
        .list_keybinds => return listKeybindsAction(alloc),
        .list_actions => return listActionsAction(alloc),
        .show_config => return showConfigAction(alloc, opts.config_text),
        .validate_config => return validateConfigAction(alloc, opts.config_text),
        .run => {},
    }

    if (comptime builtin.os.tag == .windows) {
        return @import("apprt/win32/App.zig").run(alloc, opts);
    }
    return runVtDemo();
}

const help_text =
    \\Usage: whostty [options] [-e command [args...]]
    \\
    \\Launch the whostty terminal.
    \\
    \\Options:
    \\  -e <command...>    Run <command> instead of the default shell.
    \\  --<key>=<value>    Set a config option (same keys as the config file,
    \\                     e.g. --font-size=14 --background=#101010). May also
    \\                     be written as --<key> <value>.
    \\  --help, -h         Show this help.
    \\  --version, -V      Show the version.
    \\
    \\Actions:
    \\  +list-fonts        List the discoverable system font families.
    \\  +list-themes       List the available themes.
    \\  +list-keybinds     List the default key bindings.
    \\  +list-actions      List the bindable keybind actions.
    \\  +show-config       Print the effective config in config-file syntax.
    \\  +validate-config   Load the config and report diagnostics (exit 1 if any).
    \\  +version           Show the version.
    \\
    \\Config file: %APPDATA%\whostty\config.whostty (legacy: %APPDATA%\whostty\config)
    \\
;

/// `+list-themes`: print the built-in theme catalog (sorted) plus where to add
/// custom themes. Output goes to the launching console via `cliPrint`.
fn listThemesAction(alloc: std.mem.Allocator) void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const sorted = alloc.dupe([]const u8, theme.builtin.keys()) catch return;
    defer alloc.free(sorted);
    std.mem.sort([]const u8, sorted, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    out.appendSlice(alloc, "Built-in themes:\n") catch return;
    for (sorted) |name| {
        out.appendSlice(alloc, "  ") catch return;
        out.appendSlice(alloc, name) catch return;
        out.append(alloc, '\n') catch return;
    }
    out.appendSlice(alloc, "\nAdd your own under %APPDATA%\\whostty\\themes\\ or <exe dir>\\themes\\.\n") catch return;
    cliPrint(out.items);
}

/// `+list-keybinds`: print the default key bindings in `trigger=action` config
/// syntax (copy-pasteable into the config file).
fn listKeybindsAction(alloc: std.mem.Allocator) void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    for (binding.default_lines) |line| {
        out.appendSlice(alloc, line) catch return;
        out.append(alloc, '\n') catch return;
    }
    cliPrint(out.items);
}

/// `+validate-config`: load the config the same way `+show-config` does and report
/// any diagnostics the loader collected (unknown keys, bad values, …). Prints
/// "Configuration valid." and exits 0 when clean, or the diagnostics and exits 1
/// when not — so scripts and CI can gate on a config's validity.
fn validateConfigAction(alloc: std.mem.Allocator, override_text: []const u8) void {
    var cfg = config.Config.init(alloc);
    defer cfg.deinit();
    const dark = if (comptime builtin.os.tag == .windows) w.isSystemDarkMode() else false;
    const state: config.ConditionalState = .{ .theme = if (dark) .dark else .light };
    config.loadDefaultFiles(&cfg, alloc, state) catch {};
    if (override_text.len > 0) cfg.loadString(override_text) catch {};

    if (cfg.diagnostics.items.len == 0) {
        cliPrint("Configuration valid.\n");
        return;
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    for (cfg.diagnostics.items) |msg| {
        out.appendSlice(alloc, msg) catch break;
        out.append(alloc, '\n') catch break;
    }
    cliPrint(out.items);
    std.process.exit(1);
}

/// `+show-config`: load the user's config (file + theme + `config-file` includes,
/// then the `--key value` CLI overrides) and print the effective settings in
/// config-file syntax, which round-trips back through the loader.
fn showConfigAction(alloc: std.mem.Allocator, override_text: []const u8) void {
    var cfg = config.Config.init(alloc);
    defer cfg.deinit();
    const dark = if (comptime builtin.os.tag == .windows) w.isSystemDarkMode() else false;
    const state: config.ConditionalState = .{ .theme = if (dark) .dark else .light };
    config.loadDefaultFiles(&cfg, alloc, state) catch {};
    if (override_text.len > 0) cfg.loadString(override_text) catch {};

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    const ff: config.FileFormatter = .{ .config = &cfg };
    ff.format(&buf.writer) catch return;
    cliPrint(buf.written());
}

/// `+list-actions`: print the bindable keybind action names (one per line), so a
/// user can discover what the right side of a `keybind = trigger=action` may be.
fn listActionsAction(alloc: std.mem.Allocator) void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    for (binding.action_names) |name| {
        out.appendSlice(alloc, name) catch return;
        out.append(alloc, '\n') catch return;
    }
    cliPrint(out.items);
}

/// `+list-fonts`: print the discoverable system font families (one per line).
fn listFontsAction(alloc: std.mem.Allocator) void {
    const families = discovery.listFamilies(alloc) catch {
        cliPrint("Unable to list fonts: the DirectWrite system font collection is unavailable.\n");
        return;
    };
    defer {
        for (families) |f| alloc.free(f);
        alloc.free(families);
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    for (families) |f| {
        out.appendSlice(alloc, f) catch return;
        out.append(alloc, '\n') catch return;
    }
    cliPrint(out.items);
}

/// Print CLI output. whostty is a GUI-subsystem app on Windows (so the spawned
/// shell can't grab its console), which means it has no console of its own; we
/// attach to the launching shell's console and write there. Elsewhere, normal
/// stdout.
fn cliPrint(bytes: []const u8) void {
    if (comptime builtin.os.tag == .windows) {
        _ = w.AttachConsole(w.ATTACH_PARENT_PROCESS);
        const h = w.GetStdHandle(w.STD_OUTPUT_HANDLE);
        var written: w.DWORD = 0;
        _ = w.WriteFile(h, bytes.ptr, @intCast(bytes.len), &written, null);
    } else {
        var buf: [128]u8 = undefined;
        var stdout = std.fs.File.stdout().writer(&buf);
        stdout.interface.writeAll(bytes) catch {};
        stdout.interface.flush() catch {};
    }
}

/// Non-Windows host: prove the libghostty-vt wiring by feeding bytes and
/// reading the grid back.
fn runVtDemo() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var term = try vt.Terminal.init(alloc, .{ .cols = 80, .rows = 24 });
    defer term.deinit(alloc);

    try term.printString("whostty: libghostty-vt is wired up.");

    const dump = try term.plainString(alloc);
    defer alloc.free(dump);

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buf);
    const out = &stdout.interface;
    try out.print("{s}\n", .{std.mem.trimRight(u8, dump, " \n")});
    try out.flush();
}

test {
    // Pull in host-testable slice-0 modules' tests.
    _ = @import("termio.zig");
    _ = @import("terminfo.zig");
    _ = @import("pty.zig");
    _ = @import("input.zig");
    _ = @import("font/Atlas.zig");
    _ = @import("renderer/OpenGL.zig");
    _ = @import("renderer/decoration.zig");
    _ = @import("font/sprite.zig");
    _ = @import("renderer.zig");
    _ = @import("Surface.zig");
    _ = @import("config.zig");
    _ = @import("engine/engine.zig"); // grid + SplitTree/TabList + mouse + scroll + frame
    _ = @import("font/discovery.zig");
    _ = @import("font/shaper.zig");
    _ = @import("input/Binding.zig");
    _ = @import("apprt/action.zig");
    _ = @import("apprt/win32/keymap.zig");
    _ = @import("os/windows.zig");
    _ = @import("cli.zig");
    if (@import("build_options").freetype) _ = @import("font/main.zig");
    if (@import("build_options").freetype) _ = @import("font/GlyphCache.zig");
}

test "vt: feed bytes and read back grid state" {
    const alloc = std.testing.allocator;

    var term = try vt.Terminal.init(alloc, .{ .cols = 20, .rows = 3 });
    defer term.deinit(alloc);

    try term.printString("hello");

    const dump = try term.plainString(alloc);
    defer alloc.free(dump);

    try std.testing.expect(std.mem.indexOf(u8, dump, "hello") != null);
}
