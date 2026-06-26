//! whostty: command-line argument parsing for launching the terminal.
//!
//! Reference: ghostty `src/cli/` (strategy: port — a faithful first cut). ghostty
//! accepts config keys as `--key=value` / `--key value` flags (same grammar as
//! the config file), `-e <command…>` to run a program instead of the default
//! shell, and `--help` / `--version`. whostty mirrors that subset here; the rich
//! `+action` subcommands (`+list-fonts`, …) are a follow-up (#53).
//!
//! The parser is pure (no platform / no vt types) so it is host-tested. It turns
//! `--key value` flags into `key = value` lines that the apprt applies on top of
//! the file config via `Config.loadString`, keeping CLI and file config in sync.
const std = @import("std");

pub const Action = enum {
    run,
    help,
    version,
    /// `+list-fonts` — print the discoverable system font families.
    list_fonts,
    /// `+list-themes` — print the available themes (built-in catalog).
    list_themes,
    /// `+list-keybinds` — print the default key bindings.
    list_keybinds,
    /// `+list-actions` — print the bindable keybind action names.
    list_actions,
    /// `+show-config` — print the effective config in config-file syntax.
    show_config,
    /// `+validate-config` — load the config and report any diagnostics.
    validate_config,
    /// `+list-colors` — print the recognized named colors with their hex values.
    list_colors,
};

pub const Options = struct {
    action: Action = .run,
    /// The command to run instead of the default shell (`-e prog args…`),
    /// joined into one command line, or null. Owned by this struct.
    command: ?[]const u8 = null,
    /// Accumulated `key = value\n` config-override lines (from `--key value`
    /// flags), or "". Owned by this struct.
    config_text: []const u8 = "",

    alloc: std.mem.Allocator,

    pub fn deinit(self: *Options) void {
        if (self.command) |c| self.alloc.free(c);
        if (self.config_text.len > 0) self.alloc.free(self.config_text);
        self.* = undefined;
    }
};

pub const Error = error{OutOfMemory};

/// Parse argv (excluding argv[0]).
pub fn parse(alloc: std.mem.Allocator, args: []const []const u8) Error!Options {
    var command: ?[]const u8 = null;
    var config: std.ArrayList(u8) = .empty;
    errdefer config.deinit(alloc);

    var action: Action = .run;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        // `-e`/`--` : everything after is the command to run.
        if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--")) {
            const rest = args[i + 1 ..];
            if (rest.len > 0) command = try join(alloc, rest);
            break;
        }

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            action = .help;
            continue;
        }
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            action = .version;
            continue;
        }

        // `+name` action subcommands (ghostty-style): `whostty +list-fonts`, etc.
        // An unrecognized action falls back to showing help.
        if (arg.len > 1 and arg[0] == '+') {
            const name = arg[1..];
            action = if (std.mem.eql(u8, name, "version"))
                .version
            else if (std.mem.eql(u8, name, "help"))
                .help
            else if (std.mem.eql(u8, name, "list-fonts"))
                .list_fonts
            else if (std.mem.eql(u8, name, "list-themes"))
                .list_themes
            else if (std.mem.eql(u8, name, "list-keybinds"))
                .list_keybinds
            else if (std.mem.eql(u8, name, "list-actions"))
                .list_actions
            else if (std.mem.eql(u8, name, "show-config"))
                .show_config
            else if (std.mem.eql(u8, name, "validate-config"))
                .validate_config
            else if (std.mem.eql(u8, name, "list-colors"))
                .list_colors
            else
                .help;
            continue;
        }

        // `--key=value` or `--key value` config overrides.
        if (std.mem.startsWith(u8, arg, "--") and arg.len > 2) {
            const body = arg[2..];
            var key: []const u8 = body;
            var value: []const u8 = "true"; // bare `--flag` means true
            if (std.mem.indexOfScalar(u8, body, '=')) |eq| {
                key = body[0..eq];
                value = body[eq + 1 ..];
            } else if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) {
                value = args[i + 1];
                i += 1;
            }
            if (key.len == 0) continue;
            try config.appendSlice(alloc, key);
            try config.appendSlice(alloc, " = ");
            try config.appendSlice(alloc, value);
            try config.append(alloc, '\n');
            continue;
        }

        // Bare positional args are ignored for now (no positional grammar yet).
    }

    return .{
        .action = action,
        .command = command,
        .config_text = if (config.items.len > 0) try config.toOwnedSlice(alloc) else "",
        .alloc = alloc,
    };
}

/// Join argv slices into a single space-separated command line.
fn join(alloc: std.mem.Allocator, parts: []const []const u8) Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    for (parts, 0..) |p, idx| {
        if (idx > 0) try buf.append(alloc, ' ');
        try buf.appendSlice(alloc, p);
    }
    return buf.toOwnedSlice(alloc);
}

const testing = std.testing;

test "cli: no args -> run with defaults" {
    var o = try parse(testing.allocator, &.{});
    defer o.deinit();
    try testing.expectEqual(Action.run, o.action);
    try testing.expect(o.command == null);
    try testing.expectEqualStrings("", o.config_text);
}

test "cli: --help / --version" {
    var h = try parse(testing.allocator, &.{"--help"});
    defer h.deinit();
    try testing.expectEqual(Action.help, h.action);

    var v = try parse(testing.allocator, &.{ "-V", "--font-size=10" });
    defer v.deinit();
    try testing.expectEqual(Action.version, v.action);
}

test "cli: +action subcommands select the action" {
    inline for (.{
        .{ "+list-fonts", Action.list_fonts },
        .{ "+list-themes", Action.list_themes },
        .{ "+list-keybinds", Action.list_keybinds },
        .{ "+list-actions", Action.list_actions },
        .{ "+show-config", Action.show_config },
        .{ "+validate-config", Action.validate_config },
        .{ "+list-colors", Action.list_colors },
        .{ "+version", Action.version },
        .{ "+help", Action.help },
    }) |c| {
        var o = try parse(testing.allocator, &.{c[0]});
        defer o.deinit();
        try testing.expectEqual(c[1], o.action);
    }
    // An unknown +action falls back to help rather than launching.
    var u = try parse(testing.allocator, &.{"+nope"});
    defer u.deinit();
    try testing.expectEqual(Action.help, u.action);
}

test "cli: -e joins the command line" {
    var o = try parse(testing.allocator, &.{ "--font-size=14", "-e", "pwsh", "-NoLogo" });
    defer o.deinit();
    try testing.expectEqualStrings("pwsh -NoLogo", o.command.?);
    // The flag before -e still became a config override.
    try testing.expectEqualStrings("font-size = 14\n", o.config_text);
}

test "cli: --key=value and --key value both become config lines" {
    var o = try parse(testing.allocator, &.{ "--font-size=14", "--background", "#101010" });
    defer o.deinit();
    try testing.expectEqualStrings("font-size = 14\nbackground = #101010\n", o.config_text);
}

test "cli: bare --flag is true" {
    var o = try parse(testing.allocator, &.{"--bold-is-bright"});
    defer o.deinit();
    try testing.expectEqualStrings("bold-is-bright = true\n", o.config_text);
}

test "cli: a flag followed by another flag does not consume it as a value" {
    var o = try parse(testing.allocator, &.{ "--bold-is-bright", "--font-size=9" });
    defer o.deinit();
    try testing.expectEqualStrings("bold-is-bright = true\nfont-size = 9\n", o.config_text);
}
