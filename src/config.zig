//! whostty: configuration file layer.
//!
//! Reference: ghostty `src/config/Config.zig` (the `Config`/`Color` shapes and
//! the `#RRGGBB` color grammar) plus `src/cli/args.zig` `LineIterator` (the
//! config file line format). Strategy: port. ghostty's config is enormous
//! (hundreds of options, CLI integration, conditionals, theming); whostty
//! ports the file format faithfully and a small, growing set of options that
//! the apprt/renderer actually consume today (colors, font, cursor). More
//! options are added lazily as the layers that need them land. See PORTING.md.
const std = @import("std");

/// An RGB color. Ported from ghostty `Config.Color` — the `#RRGGBB` grammar
/// (leading `#` optional, 3- or 6-digit hex) plus a small set of named colors.
/// Full X11 color names live in libghostty-vt (`x11_color`) and can be wired
/// in later; here we keep the common ANSI names so config stays dependency-free
/// and host-testable.
pub const Color = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,

    /// Parse a color from a name or a hex value.
    pub fn parse(input: []const u8) !Color {
        if (named.get(input)) |c| return c;
        return fromHex(input);
    }

    /// fromHex parses a color from a hex value such as #RRGGBB. The "#" is
    /// optional and a 3-digit short form (#RGB) is expanded. Faithful port of
    /// ghostty `Config.Color.fromHex`.
    pub fn fromHex(input: []const u8) !Color {
        // Trim the beginning '#' if it exists.
        const trimmed = if (input.len != 0 and input[0] == '#') input[1..] else input;
        if (trimmed.len != 6 and trimmed.len != 3) return error.InvalidValue;

        // Expand short hex values to full hex values.
        var expanded: [6]u8 = undefined;
        const rgb: []const u8 = if (trimmed.len == 3) blk: {
            expanded = .{
                trimmed[0], trimmed[0],
                trimmed[1], trimmed[1],
                trimmed[2], trimmed[2],
            };
            break :blk &expanded;
        } else trimmed;

        // Parse the colors two at a time.
        var result: Color = undefined;
        comptime var i: usize = 0;
        inline while (i < 6) : (i += 2) {
            const v: u8 =
                ((try std.fmt.charToDigit(rgb[i], 16)) * 16) +
                try std.fmt.charToDigit(rgb[i + 1], 16);
            @field(result, switch (i) {
                0 => "r",
                2 => "g",
                4 => "b",
                else => unreachable,
            }) = v;
        }
        return result;
    }

    /// The common ANSI color names. A small subset of X11 colors; full names
    /// are deferred to libghostty-vt's `x11_color` map.
    const named = std.StaticStringMap(Color).initComptime(.{
        .{ "black", Color{ .r = 0, .g = 0, .b = 0 } },
        .{ "red", Color{ .r = 255, .g = 0, .b = 0 } },
        .{ "green", Color{ .r = 0, .g = 128, .b = 0 } },
        .{ "yellow", Color{ .r = 255, .g = 255, .b = 0 } },
        .{ "blue", Color{ .r = 0, .g = 0, .b = 255 } },
        .{ "magenta", Color{ .r = 255, .g = 0, .b = 255 } },
        .{ "cyan", Color{ .r = 0, .g = 255, .b = 255 } },
        .{ "white", Color{ .r = 255, .g = 255, .b = 255 } },
    });
};

/// The shape the cursor is drawn as.
pub const CursorStyle = enum { block, bar, underline };

/// A parsed `key = value` pair from a config file line.
pub const KeyValue = struct {
    key: []const u8,
    /// The value, with surrounding whitespace and a single pair of wrapping
    /// double quotes removed. Empty for a bare `key` line (a flag).
    value: []const u8,
};

/// Iterates the `key = value` lines of a config file string. Faithful port of
/// the rules in ghostty's `cli/args.zig` `LineIterator`:
///   - lines are trimmed of surrounding whitespace (including CR);
///   - blank lines and lines whose first character is `#` are skipped;
///   - the line is split on the first `=` into a trimmed key and value;
///   - a value wrapped in a single pair of double quotes is unquoted;
///   - a line with no `=` yields the whole line as the key with an empty value.
pub const LineIterator = struct {
    text: []const u8,
    idx: usize = 0,

    const whitespace = " \t";

    pub fn init(text: []const u8) LineIterator {
        return .{ .text = text };
    }

    pub fn next(self: *LineIterator) ?KeyValue {
        while (self.idx < self.text.len) {
            // Slice off the next line and advance past the newline.
            const start = self.idx;
            const nl = std.mem.indexOfScalarPos(u8, self.text, start, '\n') orelse self.text.len;
            self.idx = if (nl < self.text.len) nl + 1 else self.text.len;

            const raw = self.text[start..nl];
            const line = std.mem.trim(u8, raw, whitespace ++ "\r");

            // Ignore blank lines and comments.
            if (line.len == 0 or line[0] == '#') continue;

            if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
                const key = std.mem.trim(u8, line[0..eq], whitespace);
                var value = std.mem.trim(u8, line[eq + 1 ..], whitespace);
                if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
                    value = value[1 .. value.len - 1];
                }
                return .{ .key = key, .value = value };
            }

            return .{ .key = line, .value = "" };
        }
        return null;
    }
};

/// The whostty configuration. Owns its string allocations via an arena.
pub const Config = struct {
    arena: std.heap.ArenaAllocator,

    font_family: ?[]const u8 = null,
    font_size: f32 = 12,
    background: Color = .{ .r = 0, .g = 0, .b = 0 },
    foreground: Color = .{ .r = 0xff, .g = 0xff, .b = 0xff },
    cursor_style: CursorStyle = .block,

    /// Per-index overrides of the 256-color palette. A `null` entry means
    /// "use libghostty-vt's default for this index". Set via repeated
    /// `palette = <index>=<color>` lines (ghostty syntax).
    palette: [256]?Color = .{null} ** 256,

    /// Non-fatal problems encountered while loading (unknown keys, bad values).
    /// Owned by the arena. Loading never fails on these; it collects and
    /// continues, matching ghostty's behavior.
    diagnostics: std.ArrayList([]const u8) = .empty,

    pub fn init(gpa: std.mem.Allocator) Config {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Parse a config from a string into a fresh Config.
    pub fn parse(gpa: std.mem.Allocator, text: []const u8) !Config {
        var self = init(gpa);
        errdefer self.deinit();
        try self.loadString(text);
        return self;
    }

    /// Apply the `key = value` lines of `text` on top of the current values.
    pub fn loadString(self: *Config, text: []const u8) !void {
        const alloc = self.arena.allocator();
        var iter: LineIterator = .init(text);
        while (iter.next()) |kv| {
            self.set(alloc, kv.key, kv.value) catch |err| {
                try self.diag(alloc, "{s}: invalid value \"{s}\" ({s})", .{
                    kv.key, kv.value, @errorName(err),
                });
            };
        }
    }

    fn set(self: *Config, alloc: std.mem.Allocator, key: []const u8, value: []const u8) !void {
        if (std.mem.eql(u8, key, "font-family")) {
            self.font_family = try alloc.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "font-size")) {
            self.font_size = try std.fmt.parseFloat(f32, value);
        } else if (std.mem.eql(u8, key, "background")) {
            self.background = try Color.parse(value);
        } else if (std.mem.eql(u8, key, "foreground")) {
            self.foreground = try Color.parse(value);
        } else if (std.mem.eql(u8, key, "cursor-style")) {
            self.cursor_style = std.meta.stringToEnum(CursorStyle, value) orelse
                return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "palette")) {
            const eq = std.mem.indexOfScalar(u8, value, '=') orelse return error.InvalidValue;
            const idx = try std.fmt.parseInt(u8, std.mem.trim(u8, value[0..eq], " \t"), 10);
            self.palette[idx] = try Color.parse(std.mem.trim(u8, value[eq + 1 ..], " \t"));
        } else {
            try self.diag(alloc, "unknown config key: {s}", .{key});
        }
    }

    fn diag(self: *Config, alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(alloc, fmt, args);
        try self.diagnostics.append(alloc, msg);
    }
};

test "config: Color.fromHex" {
    const testing = std.testing;
    try testing.expectEqual(Color{ .r = 0, .g = 0, .b = 0 }, try Color.fromHex("#000000"));
    try testing.expectEqual(Color{ .r = 10, .g = 11, .b = 12 }, try Color.fromHex("#0A0B0C"));
    try testing.expectEqual(Color{ .r = 10, .g = 11, .b = 12 }, try Color.fromHex("0A0B0C"));
    try testing.expectEqual(Color{ .r = 255, .g = 255, .b = 255 }, try Color.fromHex("FFFFFF"));
    try testing.expectEqual(Color{ .r = 255, .g = 255, .b = 255 }, try Color.fromHex("FFF"));
    try testing.expectEqual(Color{ .r = 51, .g = 68, .b = 85 }, try Color.fromHex("#345"));
    try testing.expectError(error.InvalidValue, Color.fromHex("12345"));
}

test "config: Color.parse named" {
    try std.testing.expectEqual(Color{ .r = 0, .g = 0, .b = 0 }, try Color.parse("black"));
    try std.testing.expectEqual(Color{ .r = 255, .g = 255, .b = 255 }, try Color.parse("white"));
}

test "config: LineIterator key/value rules" {
    const testing = std.testing;
    var iter: LineIterator = .init(
        \\A
        \\B=42
        \\C
        \\
        \\# A comment
        \\D
        \\
        \\  # An indented comment
        \\  E = value
        \\
        \\F =  "value "
    );
    try testing.expectEqualStrings("A", iter.next().?.key);

    const b = iter.next().?;
    try testing.expectEqualStrings("B", b.key);
    try testing.expectEqualStrings("42", b.value);

    try testing.expectEqualStrings("C", iter.next().?.key);

    const d = iter.next().?;
    try testing.expectEqualStrings("D", d.key);
    try testing.expectEqualStrings("", d.value);

    const e = iter.next().?;
    try testing.expectEqualStrings("E", e.key);
    try testing.expectEqualStrings("value", e.value);

    // Quoted values keep inner whitespace but drop the quotes.
    const f = iter.next().?;
    try testing.expectEqualStrings("F", f.key);
    try testing.expectEqualStrings("value ", f.value);

    try testing.expectEqual(@as(?KeyValue, null), iter.next());
}

test "config: LineIterator handles CRLF" {
    const testing = std.testing;
    var iter: LineIterator = .init("A\r\nB = C\r\n");
    try testing.expectEqualStrings("A", iter.next().?.key);
    const b = iter.next().?;
    try testing.expectEqualStrings("B", b.key);
    try testing.expectEqualStrings("C", b.value);
    try testing.expectEqual(@as(?KeyValue, null), iter.next());
}

test "config: parse sets fields" {
    const testing = std.testing;
    var cfg = try Config.parse(testing.allocator,
        \\# whostty config
        \\font-family = JetBrains Mono
        \\font-size = 14
        \\background = #101418
        \\foreground = white
        \\cursor-style = bar
    );
    defer cfg.deinit();

    try testing.expectEqualStrings("JetBrains Mono", cfg.font_family.?);
    try testing.expectEqual(@as(f32, 14), cfg.font_size);
    try testing.expectEqual(Color{ .r = 0x10, .g = 0x14, .b = 0x18 }, cfg.background);
    try testing.expectEqual(Color{ .r = 255, .g = 255, .b = 255 }, cfg.foreground);
    try testing.expectEqual(CursorStyle.bar, cfg.cursor_style);
    try testing.expectEqual(@as(usize, 0), cfg.diagnostics.items.len);
}

test "config: defaults survive an empty load" {
    const testing = std.testing;
    var cfg = try Config.parse(testing.allocator, "\n# just a comment\n");
    defer cfg.deinit();
    try testing.expectEqual(@as(f32, 12), cfg.font_size);
    try testing.expectEqual(Color{ .r = 0, .g = 0, .b = 0 }, cfg.background);
    try testing.expectEqual(Color{ .r = 0xff, .g = 0xff, .b = 0xff }, cfg.foreground);
    try testing.expectEqual(CursorStyle.block, cfg.cursor_style);
}

test "config: palette overrides accumulate by index" {
    const testing = std.testing;
    var cfg = try Config.parse(testing.allocator,
        \\palette = 0=#1d1f21
        \\palette = 1 = red
    );
    defer cfg.deinit();

    try testing.expectEqual(Color{ .r = 0x1d, .g = 0x1f, .b = 0x21 }, cfg.palette[0].?);
    try testing.expectEqual(Color{ .r = 255, .g = 0, .b = 0 }, cfg.palette[1].?);
    // Untouched indices stay null (fall back to the vt default).
    try testing.expectEqual(@as(?Color, null), cfg.palette[2]);
    try testing.expectEqual(@as(usize, 0), cfg.diagnostics.items.len);
}

test "config: out-of-range palette index is a diagnostic" {
    const testing = std.testing;
    var cfg = try Config.parse(testing.allocator, "palette = 999=#ffffff\n");
    defer cfg.deinit();
    try testing.expectEqual(@as(usize, 1), cfg.diagnostics.items.len);
}

test "config: unknown key and bad value become diagnostics, not failures" {
    const testing = std.testing;
    var cfg = try Config.parse(testing.allocator,
        \\nonexistent-key = 1
        \\font-size = not-a-number
    );
    defer cfg.deinit();

    // Bad font-size leaves the default in place.
    try testing.expectEqual(@as(f32, 12), cfg.font_size);
    try testing.expectEqual(@as(usize, 2), cfg.diagnostics.items.len);
}
