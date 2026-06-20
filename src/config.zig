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
const shaper = @import("font/shaper.zig");
const binding = @import("input/Binding.zig");

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

/// Which renderer backend draws the terminal. `opengl` (WGL) is the bring-up
/// path and the default; `direct3d` is the long-term native Windows target
/// (#15) and is selected here but not yet implemented — see `src/renderer.zig`.
pub const RendererBackend = enum { opengl, direct3d };

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
    renderer: RendererBackend = .opengl,

    /// Optional color overrides. `null` means "derive from fg/bg" (the renderer
    /// picks a sensible default — e.g. the cursor uses the foreground).
    cursor_color: ?Color = null,
    /// The color of the text under a block cursor. `null` derives it from the
    /// cell (the cell's background, i.e. the glyph is inverted).
    cursor_text: ?Color = null,
    /// Cursor opacity (0..1). 1 is fully opaque; lower lets the cell show
    /// through the cursor. Ported from ghostty's `cursor-opacity`.
    cursor_opacity: f32 = 1,
    selection_background: ?Color = null,
    selection_foreground: ?Color = null,

    /// Render bold text with the bright (8–15) palette color, as many terminals
    /// do. Ported from ghostty's `bold-is-bright`.
    bold_is_bright: bool = false,

    /// Minimum WCAG contrast ratio between a glyph and its background. When the
    /// resolved foreground falls below this against its cell background, the
    /// glyph is forced to black or white (whichever contrasts more). `1` (the
    /// default) disables the adjustment. Clamped to ghostty's 1..21 range.
    minimum_contrast: f32 = 1,

    /// Opacity applied to faint/dim (SGR 2) text. Ported from ghostty's
    /// `faint-opacity`; clamped to 0..1.
    faint_opacity: f32 = 0.5,

    /// Maximum scrollback retained, in bytes (ghostty's `scrollback-limit`).
    /// Defaults to 10 MB. The VT core (libghostty-vt) enforces the limit.
    scrollback_limit: usize = 10_000_000,

    /// Per-index overrides of the 256-color palette. A `null` entry means
    /// "use libghostty-vt's default for this index". Set via repeated
    /// `palette = <index>=<color>` lines (ghostty syntax).
    palette: [256]?Color = .{null} ** 256,

    /// OpenType font features to apply during shaping (#13). Accumulated from
    /// repeated `font-feature = <tag>` lines (e.g. `-liga`, `ss01=2`). Owned by
    /// the arena.
    font_features: std.ArrayList(shaper.Feature) = .empty,

    /// User keybindings (#18/#16), from repeated `keybind = <trigger>=<action>`
    /// lines. The apprt seeds defaults first, then these override per trigger.
    /// Owned by the arena.
    keybinds: binding.Set = .{},

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
        } else if (std.mem.eql(u8, key, "renderer")) {
            self.renderer = std.meta.stringToEnum(RendererBackend, value) orelse
                return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "palette")) {
            const eq = std.mem.indexOfScalar(u8, value, '=') orelse return error.InvalidValue;
            const idx = try std.fmt.parseInt(u8, std.mem.trim(u8, value[0..eq], " \t"), 10);
            self.palette[idx] = try Color.parse(std.mem.trim(u8, value[eq + 1 ..], " \t"));
        } else if (std.mem.eql(u8, key, "font-feature")) {
            try self.font_features.append(alloc, try shaper.Feature.parse(value));
        } else if (std.mem.eql(u8, key, "keybind")) {
            try self.keybinds.putLine(alloc, value);
        } else if (std.mem.eql(u8, key, "cursor-color")) {
            self.cursor_color = try Color.parse(value);
        } else if (std.mem.eql(u8, key, "cursor-text")) {
            self.cursor_text = try Color.parse(value);
        } else if (std.mem.eql(u8, key, "cursor-opacity")) {
            const o = try std.fmt.parseFloat(f32, value);
            self.cursor_opacity = std.math.clamp(o, 0, 1);
        } else if (std.mem.eql(u8, key, "selection-background")) {
            self.selection_background = try Color.parse(value);
        } else if (std.mem.eql(u8, key, "selection-foreground")) {
            self.selection_foreground = try Color.parse(value);
        } else if (std.mem.eql(u8, key, "bold-is-bright")) {
            self.bold_is_bright = try parseBool(value);
        } else if (std.mem.eql(u8, key, "minimum-contrast")) {
            self.minimum_contrast = std.math.clamp(try std.fmt.parseFloat(f32, value), 1, 21);
        } else if (std.mem.eql(u8, key, "faint-opacity")) {
            self.faint_opacity = std.math.clamp(try std.fmt.parseFloat(f32, value), 0, 1);
        } else if (std.mem.eql(u8, key, "scrollback-limit")) {
            self.scrollback_limit = try std.fmt.parseInt(usize, value, 10);
        } else {
            try self.diag(alloc, "unknown config key: {s}", .{key});
        }
    }

    fn diag(self: *Config, alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(alloc, fmt, args);
        try self.diagnostics.append(alloc, msg);
    }
};

/// Parse a boolean config value. A bare key (empty value) is `true` — the flag
/// form, matching ghostty — as are `true`/`yes`/`1`; `false`/`no`/`0` are
/// `false`. Anything else is an error.
fn parseBool(value: []const u8) !bool {
    if (value.len == 0) return true;
    if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "yes") or std.mem.eql(u8, value, "1"))
        return true;
    if (std.mem.eql(u8, value, "false") or std.mem.eql(u8, value, "no") or std.mem.eql(u8, value, "0"))
        return false;
    return error.InvalidValue;
}

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

test "config: optional color overrides and bold-is-bright" {
    const testing = std.testing;
    var cfg = try Config.parse(testing.allocator,
        \\cursor-color = #ff8800
        \\selection-background = #222244
        \\selection-foreground = white
        \\bold-is-bright = true
    );
    defer cfg.deinit();

    try testing.expectEqual(Color{ .r = 0xff, .g = 0x88, .b = 0x00 }, cfg.cursor_color.?);
    try testing.expectEqual(Color{ .r = 0x22, .g = 0x22, .b = 0x44 }, cfg.selection_background.?);
    try testing.expectEqual(Color{ .r = 0xff, .g = 0xff, .b = 0xff }, cfg.selection_foreground.?);
    try testing.expect(cfg.bold_is_bright);
    try testing.expectEqual(@as(usize, 0), cfg.diagnostics.items.len);
}

test "config: cursor-text and cursor-opacity parse; opacity clamps to 0..1" {
    const testing = std.testing;
    var cfg = try Config.parse(testing.allocator,
        \\cursor-text = #101010
        \\cursor-opacity = 0.6
    );
    defer cfg.deinit();
    try testing.expectEqual(Color{ .r = 0x10, .g = 0x10, .b = 0x10 }, cfg.cursor_text.?);
    try testing.expectApproxEqAbs(@as(f32, 0.6), cfg.cursor_opacity, 0.0001);
    try testing.expectEqual(@as(usize, 0), cfg.diagnostics.items.len);

    // Out-of-range opacity is clamped, not rejected.
    var hi = try Config.parse(testing.allocator, "cursor-opacity = 1.5\n");
    defer hi.deinit();
    try testing.expectApproxEqAbs(@as(f32, 1.0), hi.cursor_opacity, 0.0001);

    // Defaults: opaque, derive-from-cell text.
    var def = try Config.parse(testing.allocator, "\n");
    defer def.deinit();
    try testing.expectApproxEqAbs(@as(f32, 1.0), def.cursor_opacity, 0.0001);
    try testing.expect(def.cursor_text == null);
}

test "config: minimum-contrast and faint-opacity parse and clamp" {
    const testing = std.testing;
    var cfg = try Config.parse(testing.allocator,
        \\minimum-contrast = 4.5
        \\faint-opacity = 0.3
    );
    defer cfg.deinit();
    try testing.expectApproxEqAbs(@as(f32, 4.5), cfg.minimum_contrast, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.3), cfg.faint_opacity, 0.0001);
    try testing.expectEqual(@as(usize, 0), cfg.diagnostics.items.len);

    // minimum-contrast clamps to 1..21, faint-opacity to 0..1.
    var lo = try Config.parse(testing.allocator, "minimum-contrast = 0.2\n");
    defer lo.deinit();
    try testing.expectApproxEqAbs(@as(f32, 1.0), lo.minimum_contrast, 0.0001);
    var hi = try Config.parse(testing.allocator, "minimum-contrast = 99\n");
    defer hi.deinit();
    try testing.expectApproxEqAbs(@as(f32, 21.0), hi.minimum_contrast, 0.0001);
    var fo = try Config.parse(testing.allocator, "faint-opacity = 2\n");
    defer fo.deinit();
    try testing.expectApproxEqAbs(@as(f32, 1.0), fo.faint_opacity, 0.0001);

    // Defaults.
    var def = try Config.parse(testing.allocator, "\n");
    defer def.deinit();
    try testing.expectApproxEqAbs(@as(f32, 1.0), def.minimum_contrast, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), def.faint_opacity, 0.0001);
}

test "config: scrollback-limit parses; default otherwise" {
    const testing = std.testing;
    var cfg = try Config.parse(testing.allocator, "scrollback-limit = 5000000\n");
    defer cfg.deinit();
    try testing.expectEqual(@as(usize, 5_000_000), cfg.scrollback_limit);

    var def = try Config.parse(testing.allocator, "\n");
    defer def.deinit();
    try testing.expectEqual(@as(usize, 10_000_000), def.scrollback_limit);
}

test "config: color overrides default to null; bool flag form is true" {
    const testing = std.testing;
    var cfg = try Config.parse(testing.allocator, "bold-is-bright\n");
    defer cfg.deinit();
    try testing.expect(cfg.cursor_color == null);
    try testing.expect(cfg.selection_background == null);
    try testing.expect(cfg.bold_is_bright); // bare flag => true
}

test "config: parseBool forms and errors" {
    const testing = std.testing;
    try testing.expect(try parseBool(""));
    try testing.expect(try parseBool("yes"));
    try testing.expect(!try parseBool("false"));
    try testing.expect(!try parseBool("0"));
    try testing.expectError(error.InvalidValue, parseBool("maybe"));
}

test "config: renderer backend selection" {
    const testing = std.testing;
    var cfg = try Config.parse(testing.allocator, "renderer = direct3d\n");
    defer cfg.deinit();
    try testing.expectEqual(RendererBackend.direct3d, cfg.renderer);
    try testing.expectEqual(@as(usize, 0), cfg.diagnostics.items.len);

    // Default is opengl; a bad value is a diagnostic and leaves the default.
    var bad = try Config.parse(testing.allocator, "renderer = vulkan\n");
    defer bad.deinit();
    try testing.expectEqual(RendererBackend.opengl, bad.renderer);
    try testing.expectEqual(@as(usize, 1), bad.diagnostics.items.len);
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

test "config: font-feature accumulates parsed features" {
    const testing = std.testing;
    var cfg = try Config.parse(testing.allocator,
        \\font-feature = -liga
        \\font-feature = ss01=2
    );
    defer cfg.deinit();

    try testing.expectEqual(@as(usize, 2), cfg.font_features.items.len);
    try testing.expectEqualSlices(u8, "liga", &cfg.font_features.items[0].tag);
    try testing.expectEqual(@as(u32, 0), cfg.font_features.items[0].value);
    try testing.expectEqualSlices(u8, "ss01", &cfg.font_features.items[1].tag);
    try testing.expectEqual(@as(u32, 2), cfg.font_features.items[1].value);
    try testing.expectEqual(@as(usize, 0), cfg.diagnostics.items.len);
}

test "config: a bad font-feature is a diagnostic, not a failure" {
    const testing = std.testing;
    var cfg = try Config.parse(testing.allocator, "font-feature = waytoolong\n");
    defer cfg.deinit();
    try testing.expectEqual(@as(usize, 0), cfg.font_features.items.len);
    try testing.expectEqual(@as(usize, 1), cfg.diagnostics.items.len);
}

test "config: keybind lines populate the binding set" {
    const testing = std.testing;
    var cfg = try Config.parse(testing.allocator,
        \\keybind = ctrl+shift+t=new_tab
        \\keybind = ctrl+shift+right=new_split:right
    );
    defer cfg.deinit();

    try testing.expectEqual(@as(usize, 2), cfg.keybinds.count());
    const t: binding.Trigger = .{ .key = .{ .codepoint = 't' }, .mods = .{ .ctrl = true, .shift = true } };
    try testing.expectEqual(binding.Action.new_tab, cfg.keybinds.get(t).?);
    try testing.expectEqual(@as(usize, 0), cfg.diagnostics.items.len);
}

test "config: a bad keybind is a diagnostic, not a failure" {
    const testing = std.testing;
    var cfg = try Config.parse(testing.allocator, "keybind = ctrl+shift+t=frobnicate\n");
    defer cfg.deinit();
    try testing.expectEqual(@as(usize, 0), cfg.keybinds.count());
    try testing.expectEqual(@as(usize, 1), cfg.diagnostics.items.len);
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
