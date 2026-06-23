//! whostty: configuration formatter (write-back).
//!
//! Adapted from ghostty `src/config/formatter.zig`. Emits a `Config` back out as
//! `key = value` lines that round-trip through the loader — the backbone of a
//! future `+show-config` / `+edit-config` (CLI surface deferred to #53). ghostty's
//! version also threads `help_strings` (doc comments) and a `changed`-only diff
//! against the default config; both depend on CLI/codegen infrastructure whostty
//! does not yet have, so they are omitted here. Everything else — the generic
//! per-type `formatEntry`, the `EntryFormatter` indirection used by field types
//! with custom formatting, and the whole-config `FileFormatter` — is faithful.
const formatter = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("Config.zig");

/// Returns a single entry formatter for the given field name and writer.
pub fn entryFormatter(
    name: []const u8,
    writer: *std.Io.Writer,
) EntryFormatter {
    return .{ .name = name, .writer = writer };
}

/// The entry formatter type for a given writer. Field types that need custom
/// formatting receive one of these and call back into `formatEntry` for each
/// primitive value, so the `name = ` prefix and newline are written uniformly.
pub const EntryFormatter = struct {
    name: []const u8,
    writer: *std.Io.Writer,

    pub fn formatEntry(
        self: @This(),
        comptime T: type,
        value: T,
    ) !void {
        return formatter.formatEntry(
            T,
            self.name,
            value,
            self.writer,
        );
    }
};

/// Convert a Zig field name to its config key form (underscores -> hyphens),
/// at comptime.
fn kebab(comptime name: []const u8) []const u8 {
    return comptime blk: {
        var buf: [name.len]u8 = undefined;
        for (name, 0..) |c, i| buf[i] = if (c == '_') '-' else c;
        const final = buf;
        break :blk &final;
    };
}

/// True if `T` is a container type that defines a `formatEntry` method. Guards
/// the `@hasDecl` call, which is only valid on container types (not optionals,
/// ints, etc.).
fn hasFormatEntry(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "formatEntry"),
        else => false,
    };
}

/// Format a single type with the given name and value.
pub fn formatEntry(
    comptime T: type,
    name: []const u8,
    value: T,
    writer: *std.Io.Writer,
) !void {
    switch (@typeInfo(T)) {
        .bool, .int => {
            try writer.print("{s} = {}\n", .{ name, value });
            return;
        },

        .float => {
            try writer.print("{s} = {d}\n", .{ name, value });
            return;
        },

        .@"enum" => {
            try writer.print("{s} = {t}\n", .{ name, value });
            return;
        },

        .void => {
            try writer.print("{s} = \n", .{name});
            return;
        },

        .optional => |info| {
            if (value) |inner| {
                try formatEntry(
                    info.child,
                    name,
                    inner,
                    writer,
                );
            } else {
                try writer.print("{s} = \n", .{name});
            }

            return;
        },

        .pointer => switch (T) {
            []const u8,
            [:0]const u8,
            => {
                try writer.print("{s} = {s}\n", .{ name, value });
                return;
            },

            else => {},
        },

        // Structs/unions of all types require a "formatEntry" method to be
        // defined which will be called to format the value. This is given the
        // formatter in use so that they can call BACK to our formatEntry to
        // write each primitive value.
        .@"struct" => |info| if (@hasDecl(T, "formatEntry")) {
            try value.formatEntry(entryFormatter(name, writer));
            return;
        } else switch (info.layout) {
            // Packed structs we special case: a comma-separated list of
            // `flag`/`no-flag`.
            .@"packed" => {
                try writer.print("{s} = ", .{name});
                inline for (info.fields, 0..) |field, i| {
                    if (i > 0) try writer.print(",", .{});
                    try writer.print("{s}{s}", .{
                        if (!@field(value, field.name)) "no-" else "",
                        field.name,
                    });
                }
                try writer.print("\n", .{});
                return;
            },

            else => {},
        },

        .@"union" => if (@hasDecl(T, "formatEntry")) {
            try value.formatEntry(entryFormatter(name, writer));
            return;
        },

        else => {},
    }

    // Compile error so that we can catch missing cases.
    @compileLog(T);
    @compileError("missing case for type");
}

/// FileFormatter is a formatter implementation that outputs the config in a
/// file-like format that round-trips through the loader.
pub const FileFormatter = struct {
    config: *const Config,

    /// Implements the std.fmt format interface.
    pub fn format(
        self: FileFormatter,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        @setEvalBranchQuota(20_000);

        inline for (@typeInfo(Config).@"struct".fields) |field| {
            // Internal bookkeeping fields and the collection fields handled
            // explicitly below are skipped by the generic pass.
            if (comptime !Config.isFormattable(field.name)) continue;
            formatField(field, self.config, writer) catch return error.WriteFailed;
        }

        // Collection fields whose element layout doesn't map to a single
        // `key = value` line: emit one line per element so they round-trip.
        self.config.formatCollections(writer) catch return error.WriteFailed;
    }
};

/// Emit one config field. Null optionals are omitted so the output re-parses
/// cleanly (the loader rejects an empty value for keys that require one).
fn formatField(
    comptime field: std.builtin.Type.StructField,
    config: *const Config,
    writer: *std.Io.Writer,
) !void {
    const value = @field(config, field.name);

    if (comptime @typeInfo(field.type) == .optional) {
        if (value == null) return;
    }

    // The config key is the field name with underscores as hyphens.
    const name = comptime kebab(field.name);

    if (comptime hasFormatEntry(field.type)) {
        try value.formatEntry(entryFormatter(name, writer));
    } else {
        try formatEntry(field.type, name, value, writer);
    }
}

test "formatEntry bool" {
    const testing = std.testing;

    {
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try formatEntry(bool, "a", true, &buf.writer);
        try testing.expectEqualStrings("a = true\n", buf.written());
    }

    {
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try formatEntry(bool, "a", false, &buf.writer);
        try testing.expectEqualStrings("a = false\n", buf.written());
    }
}

test "formatEntry int" {
    const testing = std.testing;
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try formatEntry(u8, "a", 123, &buf.writer);
    try testing.expectEqualStrings("a = 123\n", buf.written());
}

test "formatEntry float" {
    const testing = std.testing;
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try formatEntry(f64, "a", 0.7, &buf.writer);
    try testing.expectEqualStrings("a = 0.7\n", buf.written());
}

test "formatEntry enum" {
    const testing = std.testing;
    const Enum = enum { one, two, three };
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try formatEntry(Enum, "a", .two, &buf.writer);
    try testing.expectEqualStrings("a = two\n", buf.written());
}

test "formatEntry void" {
    const testing = std.testing;
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try formatEntry(void, "a", {}, &buf.writer);
    try testing.expectEqualStrings("a = \n", buf.written());
}

test "formatEntry optional" {
    const testing = std.testing;
    {
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try formatEntry(?bool, "a", null, &buf.writer);
        try testing.expectEqualStrings("a = \n", buf.written());
    }
    {
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try formatEntry(?bool, "a", false, &buf.writer);
        try testing.expectEqualStrings("a = false\n", buf.written());
    }
}

test "formatEntry string" {
    const testing = std.testing;
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try formatEntry([]const u8, "a", "hello", &buf.writer);
    try testing.expectEqualStrings("a = hello\n", buf.written());
}

test "formatEntry packed struct" {
    const testing = std.testing;
    const Value = packed struct {
        one: bool = true,
        two: bool = false,
    };
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try formatEntry(Value, "a", .{}, &buf.writer);
    try testing.expectEqualStrings("a = one,no-two\n", buf.written());
}

test "FileFormatter: a real config round-trips through the loader" {
    const testing = std.testing;
    const src =
        \\font-family = JetBrains Mono
        \\font-size = 13
        \\background = #101418
        \\foreground = #c0c0c0
        \\cursor-style = bar
        \\window-decoration = none
        \\confirm-close-surface = always
        \\background-opacity = 0.8
        \\command = pwsh -NoLogo
        \\freetype-load-flags = no-hinting,monochrome
        \\palette = 1=#ff0000
        \\font-feature = ss01=2
        \\env = FOO=bar
    ;

    var cfg = try Config.parse(testing.allocator, src);
    defer cfg.deinit();
    try testing.expectEqual(@as(usize, 0), cfg.diagnostics.items.len);

    // Format it out, then re-parse the formatted output.
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    const ff: FileFormatter = .{ .config = &cfg };
    try ff.format(&buf.writer);

    var cfg2 = try Config.parse(testing.allocator, buf.written());
    defer cfg2.deinit();
    try testing.expectEqual(@as(usize, 0), cfg2.diagnostics.items.len);

    // The values survive the round-trip.
    try testing.expectEqualStrings("JetBrains Mono", cfg2.font_family.?);
    try testing.expectEqual(@as(f32, 13), cfg2.font_size);
    try testing.expectEqual(Config.Color{ .r = 0x10, .g = 0x14, .b = 0x18 }, cfg2.background);
    try testing.expectEqual(Config.Color{ .r = 0xc0, .g = 0xc0, .b = 0xc0 }, cfg2.foreground);
    try testing.expectEqual(Config.CursorStyle.bar, cfg2.cursor_style);
    try testing.expectEqual(Config.WindowDecoration.none, cfg2.window_decoration);
    try testing.expectEqual(Config.ConfirmCloseSurface.always, cfg2.confirm_close_surface);
    try testing.expectApproxEqAbs(@as(f32, 0.8), cfg2.background_opacity, 0.0001);
    try testing.expect(cfg2.command.? == .shell);
    try testing.expectEqualStrings("pwsh -NoLogo", cfg2.command.?.shell);
    try testing.expect(!cfg2.freetype_load_flags.hinting);
    try testing.expect(cfg2.freetype_load_flags.monochrome);
    try testing.expectEqual(Config.Color{ .r = 0xff, .g = 0, .b = 0 }, cfg2.palette[1].?);
    try testing.expectEqual(@as(usize, 1), cfg2.font_features.items.len);
    try testing.expectEqual(@as(usize, 1), cfg2.env.items.len);
    try testing.expectEqualStrings("FOO", cfg2.env.items[0].key);
}
