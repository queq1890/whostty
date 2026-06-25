//! whostty: the configuration struct and value parsing.
//!
//! Reference: ghostty `src/config/Config.zig` (the `Config` field surface, the
//! `Color`/`#RRGGBB` grammar, the value types) plus ghostty `src/cli/args.zig`
//! `LineIterator` (the config file line format). Strategy: port.
//!
//! ghostty's Config is enormous (100+ fields, a typed CLI, doc-comment codegen).
//! whostty ports the *system* faithfully — the file format, value types
//! (`Command`, `Color`, metric modifiers, packed-flag sets), `config-file`
//! includes, `theme`/conditional resolution, and the formatter (write-back) — and
//! a broad, growing field surface. Runtime behavior for many keys is delegated to
//! the layer that owns it (rendering #65/#66, windowing #68, search #94, shell
//! integration #55, VT side-channels #67); this layer only parses, stores,
//! validates and formats them. See PORTING.md and the #49 epic.
//!
//! `loadString` is pure (no IO): `config-file` and `theme` directives are
//! *recorded* into fields, and the IO-driven include/theme resolution lives in
//! `file_load.zig`/`theme.zig` so the parser stays host-testable.
const Config = @This();

const std = @import("std");
const shaper = @import("../font/shaper.zig");
const binding = @import("../input/Binding.zig");
const conditional = @import("conditional.zig");
const command_pkg = @import("command.zig");

pub const Command = command_pkg.Command;
pub const ConditionalState = conditional.State;

// =========================================================================
// Value types
// =========================================================================

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

    pub fn formatEntry(self: Color, formatter: anytype) !void {
        var buf: [7]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "#{x:0>2}{x:0>2}{x:0>2}", .{
            self.r, self.g, self.b,
        }) catch return error.OutOfMemory;
        try formatter.formatEntry([]const u8, s);
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

/// How a window is decorated by the OS. Faithful to ghostty's `window-decoration`
/// (runtime application is apprt-side, #68).
pub const WindowDecoration = enum { auto, client, server, none };

/// `window-theme`: the titlebar/appearance theme. Faithful to ghostty.
pub const WindowTheme = enum { auto, system, light, dark, ghostty };

/// Whether/when to confirm closing a surface with a running process.
/// Faithful to ghostty's `confirm-close-surface` (false/true/always).
pub const ConfirmCloseSurface = enum { false, true, always };

/// `copy-on-select` behavior. Faithful to ghostty.
pub const CopyOnSelect = enum { false, true, clipboard };

/// Clipboard read/write access policy. Faithful to ghostty's
/// `clipboard-read` / `clipboard-write` (`ClipboardAccess`).
pub const ClipboardAccess = enum { ask, allow, deny };

/// How shift interacts with mouse capture. Faithful to ghostty's
/// `mouse-shift-capture`.
pub const MouseShiftCapture = enum { false, true, always, never };

/// `grapheme-width-method`. Faithful to ghostty.
pub const GraphemeWidthMethod = enum { legacy, unicode };

/// `window-save-state`. Faithful to ghostty.
pub const WindowSaveState = enum { default, never, always };

/// `custom-shader-animation`. Faithful to ghostty.
pub const CustomShaderAnimation = enum { false, true, always };

/// The fill mode for a background image. Faithful to ghostty's
/// `background-image-fit`.
pub const BackgroundImageFit = enum { contain, cover, stretch, none };

/// Where to position a background image. Faithful to ghostty's
/// `background-image-position`.
pub const BackgroundImagePosition = enum {
    @"top-left",
    @"top-center",
    @"top-right",
    @"center-left",
    @"center-center",
    @"center-right",
    @"bottom-left",
    @"bottom-center",
    @"bottom-right",
    center,
};

/// FreeType load flags. A packed struct of bools, formatted as a comma list
/// (`hinting,no-force-autohint,…`). Faithful to ghostty's `FreetypeLoadFlags`.
pub const FreetypeLoadFlags = packed struct {
    hinting: bool = true,
    @"force-autohint": bool = false,
    monochrome: bool = false,
    autohint: bool = true,
};

/// Shell integration injection mode. Faithful to ghostty's `ShellIntegration`.
pub const ShellIntegration = enum { none, detect, bash, elvish, fish, zsh };

/// Which shell-integration features are enabled. Packed flags. Faithful to
/// ghostty's `ShellIntegrationFeatures`.
pub const ShellIntegrationFeatures = packed struct {
    cursor: bool = true,
    sudo: bool = false,
    title: bool = true,
};

/// A font metric modifier: an absolute pixel adjustment or a percentage of the
/// computed metric. Faithful in spirit to ghostty's `Metrics.Modifier`
/// (`adjust-*` keys). Rendering application is font-engine side (#66).
pub const MetricModifier = union(enum) {
    /// A signed absolute number of pixels.
    absolute: i32,
    /// A signed percentage of the base metric, stored as the integer percent
    /// (e.g. `10%` -> 10, `-5%` -> -5).
    percent: i32,

    pub fn parse(input: []const u8) !MetricModifier {
        const v = std.mem.trim(u8, input, " \t");
        if (v.len == 0) return error.ValueRequired;
        if (v[v.len - 1] == '%') {
            return .{ .percent = try std.fmt.parseInt(i32, v[0 .. v.len - 1], 10) };
        }
        return .{ .absolute = try std.fmt.parseInt(i32, v, 10) };
    }

    pub fn formatEntry(self: MetricModifier, formatter: anytype) !void {
        switch (self) {
            .absolute => |v| try formatter.formatEntry(i32, v),
            .percent => |v| {
                var buf: [16]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}%", .{v}) catch
                    return error.OutOfMemory;
                try formatter.formatEntry([]const u8, s);
            },
        }
    }
};

/// A single OpenType font variation axis setting (`font-variation`, e.g.
/// `wght=600`). Repeatable. Faithful in spirit to ghostty's
/// `RepeatableFontVariation`.
pub const FontVariation = struct {
    tag: [4]u8,
    value: f64,

    pub fn parse(input: []const u8) !FontVariation {
        const eq_idx = std.mem.indexOfScalar(u8, input, '=') orelse
            return error.InvalidValue;
        const tag_s = std.mem.trim(u8, input[0..eq_idx], " \t");
        if (tag_s.len != 4) return error.InvalidValue;
        var tag: [4]u8 = undefined;
        @memcpy(&tag, tag_s[0..4]);
        const value = try std.fmt.parseFloat(f64, std.mem.trim(u8, input[eq_idx + 1 ..], " \t"));
        return .{ .tag = tag, .value = value };
    }
};

/// An environment variable override (`env = KEY=VALUE`). Repeatable. Faithful in
/// spirit to ghostty's `RepeatableStringMap` for the `env` key.
pub const EnvEntry = struct {
    key: []const u8,
    value: []const u8,
};

/// `theme`: either a single theme name (applied for both light & dark) or a
/// conditional `light:NAME dark:NAME` pair. Faithful in spirit to ghostty's
/// `theme` key, which drives OS-appearance switching via `conditional.State`.
pub const ThemeSpec = struct {
    light: ?[]const u8 = null,
    dark: ?[]const u8 = null,

    /// Parse the value of a `theme = …` line. Either a single theme name
    /// (applied for both appearances) or ghostty's conditional comma form
    /// `light:NAME,dark:NAME` (order-independent; both required). Theme names
    /// may contain spaces — only the simple form or the comma form is split, so
    /// `theme = light:Rose Pine Dawn,dark:Rose Pine` works.
    pub fn parse(alloc: std.mem.Allocator, value: []const u8) !ThemeSpec {
        const trimmed = std.mem.trim(u8, value, " \t");
        if (trimmed.len == 0) return error.ValueRequired;

        // Conditional form: a comma-separated list, or a single light:/dark:
        // token. Each part is `key:value`; both light and dark are required.
        if (std.mem.indexOfScalar(u8, trimmed, ',') != null or
            std.mem.startsWith(u8, trimmed, "light:") or
            std.mem.startsWith(u8, trimmed, "dark:"))
        {
            var spec: ThemeSpec = .{};
            var it = std.mem.splitScalar(u8, trimmed, ',');
            while (it.next()) |part_raw| {
                const part = std.mem.trim(u8, part_raw, " \t");
                const colon = std.mem.indexOfScalar(u8, part, ':') orelse
                    return error.InvalidValue;
                const k = std.mem.trim(u8, part[0..colon], " \t");
                const v = std.mem.trim(u8, part[colon + 1 ..], " \t");
                if (std.mem.eql(u8, k, "light")) {
                    spec.light = try alloc.dupe(u8, v);
                } else if (std.mem.eql(u8, k, "dark")) {
                    spec.dark = try alloc.dupe(u8, v);
                } else {
                    return error.InvalidValue;
                }
            }
            if (spec.light == null or spec.dark == null) return error.InvalidValue;
            return spec;
        }

        const name = try alloc.dupe(u8, trimmed);
        return .{ .light = name, .dark = name };
    }

    /// The theme name to use for the given OS appearance, if any.
    pub fn forState(self: ThemeSpec, theme: ConditionalState.Theme) ?[]const u8 {
        return switch (theme) {
            .light => self.light,
            .dark => self.dark,
        };
    }

    pub fn formatEntry(self: ThemeSpec, formatter: anytype) !void {
        // Unset -> emit nothing (an empty `theme = ` would be rejected on
        // re-parse, which requires a value).
        if (self.light == null and self.dark == null) return;
        // Same name for both -> the simple form.
        if (self.light != null and self.dark != null and
            std.mem.eql(u8, self.light.?, self.dark.?))
        {
            try formatter.formatEntry([]const u8, self.light.?);
            return;
        }
        // Conditional form, comma-separated to match ghostty (so names with
        // spaces round-trip).
        var buf: [512]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        var first = true;
        if (self.light) |l| {
            w.print("light:{s}", .{l}) catch return error.OutOfMemory;
            first = false;
        }
        if (self.dark) |d| {
            if (!first) w.writeByte(',') catch return error.OutOfMemory;
            w.print("dark:{s}", .{d}) catch return error.OutOfMemory;
        }
        try formatter.formatEntry([]const u8, w.buffered());
    }
};

// =========================================================================
// Config file line format
// =========================================================================

/// A parsed `key = value` pair from a config file line.
pub const KeyValue = struct {
    key: []const u8,
    /// The value, with surrounding whitespace and a single pair of wrapping
    /// double quotes removed. Empty for a bare `key` line (a flag).
    value: []const u8,
};

/// Iterates the `key = value` lines of a config file string. Faithful port of
/// the rules in ghostty's `cli/args.zig` `LineIterator`.
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

            if (std.mem.indexOfScalar(u8, line, '=')) |eq_idx| {
                const key = std.mem.trim(u8, line[0..eq_idx], whitespace);
                var value = std.mem.trim(u8, line[eq_idx + 1 ..], whitespace);
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

// =========================================================================
// The configuration
// =========================================================================

arena: std.heap.ArenaAllocator,

// --- Fonts ---
font_family: ?[]const u8 = null,
font_family_bold: ?[]const u8 = null,
font_family_italic: ?[]const u8 = null,
font_family_bold_italic: ?[]const u8 = null,
font_size: f32 = 12,
font_thicken: bool = false,
font_thicken_strength: u8 = 255,
grapheme_width_method: GraphemeWidthMethod = .unicode,
freetype_load_flags: FreetypeLoadFlags = .{},
adjust_cell_width: ?MetricModifier = null,
adjust_cell_height: ?MetricModifier = null,
adjust_font_baseline: ?MetricModifier = null,
adjust_underline_position: ?MetricModifier = null,
adjust_cursor_thickness: ?MetricModifier = null,

// --- Colors / appearance ---
background: Color = .{ .r = 0, .g = 0, .b = 0 },
foreground: Color = .{ .r = 0xff, .g = 0xff, .b = 0xff },
background_opacity: f32 = 1,
background_blur: bool = false,
cursor_style: CursorStyle = .block,
cursor_style_blink: ?bool = null,
cursor_color: ?Color = null,
cursor_text: ?Color = null,
cursor_opacity: f32 = 1,
selection_background: ?Color = null,
selection_foreground: ?Color = null,
selection_clear_on_typing: bool = true,
selection_clear_on_copy: bool = true,
/// Codepoints treated as part of a "word" for double-click word selection
/// (ghostty's `selection-word-chars`). Stored raw here; the boundary logic is
/// the selection layer's (#51).
selection_word_chars: ?[]const u8 = null,
bold_is_bright: bool = false,
minimum_contrast: f32 = 1,
faint_opacity: f32 = 0.5,

// --- Theme ---
theme: ThemeSpec = .{},
window_theme: WindowTheme = .auto,

// --- Renderer / shaders ---
renderer: RendererBackend = .opengl,
custom_shader: ?[]const u8 = null,
custom_shader_animation: CustomShaderAnimation = .true,

// --- Background image ---
background_image: ?[]const u8 = null,
background_image_fit: BackgroundImageFit = .contain,
background_image_position: BackgroundImagePosition = .center,
background_image_opacity: f32 = 1,

// --- Window / geometry ---
window_padding_x: u16 = 0,
window_padding_y: u16 = 0,
window_padding_balance: bool = false,
window_width: u32 = 0,
window_height: u32 = 0,
window_decoration: WindowDecoration = .auto,
window_save_state: WindowSaveState = .default,
fullscreen: bool = false,
maximize: bool = false,
title: ?[]const u8 = null,

// --- Splits ---
unfocused_split_opacity: f32 = 0.7,
split_divider_color: ?Color = null,

// --- Behavior ---
confirm_close_surface: ConfirmCloseSurface = .true,
copy_on_select: CopyOnSelect = .false,
clipboard_read: ClipboardAccess = .ask,
clipboard_write: ClipboardAccess = .allow,
clipboard_paste_protection: bool = true,
mouse_hide_while_typing: bool = false,
mouse_shift_capture: MouseShiftCapture = .true,
focus_follows_mouse: bool = false,
scrollback_limit: usize = 10_000_000,
/// Route a second launch into the already-running instance (#93): when set,
/// starting whostty while it's already running opens a new window in the
/// existing process instead of spawning a separate one. Default off, so the
/// normal one-process-per-launch behavior is unchanged. Ported from ghostty's
/// single-instance behavior (`gtk-single-instance`).
single_instance: bool = false,

// --- Command / shell / environment ---
command: ?Command = null,
working_directory: ?[]const u8 = null,
shell_integration: ShellIntegration = .detect,
shell_integration_features: ShellIntegrationFeatures = .{},

// --- Collections (formatted explicitly; not part of the generic pass) ---
/// Per-index overrides of the 256-color palette. A `null` entry means
/// "use libghostty-vt's default for this index". Set via repeated
/// `palette = <index>=<color>` lines (ghostty syntax).
palette: [256]?Color = .{null} ** 256,
/// OpenType font features applied during shaping (#13), from repeated
/// `font-feature = <tag>` lines (e.g. `-liga`, `ss01=2`). Owned by the arena.
font_features: std.ArrayList(shaper.Feature) = .empty,
/// OpenType variation axes, from repeated `font-variation = <tag>=<value>`.
font_variations: std.ArrayList(FontVariation) = .empty,
/// Environment overrides, from repeated `env = KEY=VALUE`.
env: std.ArrayList(EnvEntry) = .empty,
/// User keybindings (#18/#16), from repeated `keybind = <trigger>=<action>`.
keybinds: binding.Set = .{},
/// `config-file` include directives (recorded here during the pure parse;
/// resolved by `file_load.zig`). A leading `?` marks an optional include.
config_files: std.ArrayList([]const u8) = .empty,

// --- Internal bookkeeping (never formatted) ---
/// Non-fatal problems encountered while loading (unknown keys, bad values).
/// Owned by the arena. Loading never fails on these; it collects and continues,
/// matching ghostty's behavior.
diagnostics: std.ArrayList([]const u8) = .empty,

/// Keys whostty's parser does not recognize, preserved as key/value pairs (owned
/// by the arena) rather than dropped (#140). A downstream consumer (whomux)
/// overlays its own config keys on top of whostty's format: it reads these to
/// pick up its keys without forking the parser. An unrecognized key is still
/// recorded in `diagnostics` (so a genuine typo is visible), but the value is
/// retained here so the consumer can use it.
unknown_keys: std.ArrayList(Unknown) = .empty,

/// An unrecognized `key = value` pair, surfaced to a downstream consumer.
pub const Unknown = struct {
    key: []const u8,
    value: []const u8,
};

// =========================================================================
// Lifecycle + parsing
// =========================================================================

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

/// Apply the `key = value` lines of `text` on top of the current values. Pure:
/// `config-file`/`theme` directives are recorded into fields, not resolved.
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
    // Fonts
    if (eq(key, "font-family")) {
        self.font_family = try alloc.dupe(u8, value);
    } else if (eq(key, "font-family-bold")) {
        self.font_family_bold = try alloc.dupe(u8, value);
    } else if (eq(key, "font-family-italic")) {
        self.font_family_italic = try alloc.dupe(u8, value);
    } else if (eq(key, "font-family-bold-italic")) {
        self.font_family_bold_italic = try alloc.dupe(u8, value);
    } else if (eq(key, "font-size")) {
        self.font_size = try std.fmt.parseFloat(f32, value);
    } else if (eq(key, "font-thicken")) {
        self.font_thicken = try parseBool(value);
    } else if (eq(key, "font-thicken-strength")) {
        self.font_thicken_strength = try std.fmt.parseInt(u8, value, 10);
    } else if (eq(key, "grapheme-width-method")) {
        self.grapheme_width_method = try parseEnum(GraphemeWidthMethod, value);
    } else if (eq(key, "freetype-load-flags")) {
        self.freetype_load_flags = try parsePackedFlags(FreetypeLoadFlags, value);
    } else if (eq(key, "adjust-cell-width")) {
        self.adjust_cell_width = try MetricModifier.parse(value);
    } else if (eq(key, "adjust-cell-height")) {
        self.adjust_cell_height = try MetricModifier.parse(value);
    } else if (eq(key, "adjust-font-baseline")) {
        self.adjust_font_baseline = try MetricModifier.parse(value);
    } else if (eq(key, "adjust-underline-position")) {
        self.adjust_underline_position = try MetricModifier.parse(value);
    } else if (eq(key, "adjust-cursor-thickness")) {
        self.adjust_cursor_thickness = try MetricModifier.parse(value);
    } else if (eq(key, "font-feature")) {
        try self.font_features.append(alloc, try shaper.Feature.parse(value));
    } else if (eq(key, "font-variation")) {
        try self.font_variations.append(alloc, try FontVariation.parse(value));

        // Colors / appearance
    } else if (eq(key, "background")) {
        self.background = try Color.parse(value);
    } else if (eq(key, "foreground")) {
        self.foreground = try Color.parse(value);
    } else if (eq(key, "background-opacity")) {
        self.background_opacity = std.math.clamp(try std.fmt.parseFloat(f32, value), 0, 1);
    } else if (eq(key, "background-blur")) {
        self.background_blur = try parseBool(value);
    } else if (eq(key, "cursor-style")) {
        self.cursor_style = try parseEnum(CursorStyle, value);
    } else if (eq(key, "cursor-style-blink")) {
        self.cursor_style_blink = try parseBool(value);
    } else if (eq(key, "cursor-color")) {
        self.cursor_color = try Color.parse(value);
    } else if (eq(key, "cursor-text")) {
        self.cursor_text = try Color.parse(value);
    } else if (eq(key, "cursor-opacity")) {
        self.cursor_opacity = std.math.clamp(try std.fmt.parseFloat(f32, value), 0, 1);
    } else if (eq(key, "selection-background")) {
        self.selection_background = try Color.parse(value);
    } else if (eq(key, "selection-foreground")) {
        self.selection_foreground = try Color.parse(value);
    } else if (eq(key, "selection-clear-on-typing")) {
        self.selection_clear_on_typing = try parseBool(value);
    } else if (eq(key, "selection-clear-on-copy")) {
        self.selection_clear_on_copy = try parseBool(value);
    } else if (eq(key, "selection-word-chars")) {
        self.selection_word_chars = try alloc.dupe(u8, value);
    } else if (eq(key, "bold-is-bright")) {
        self.bold_is_bright = try parseBool(value);
    } else if (eq(key, "minimum-contrast")) {
        self.minimum_contrast = std.math.clamp(try std.fmt.parseFloat(f32, value), 1, 21);
    } else if (eq(key, "faint-opacity")) {
        self.faint_opacity = std.math.clamp(try std.fmt.parseFloat(f32, value), 0, 1);
    } else if (eq(key, "palette")) {
        const e = std.mem.indexOfScalar(u8, value, '=') orelse return error.InvalidValue;
        const idx = try std.fmt.parseInt(u8, std.mem.trim(u8, value[0..e], " \t"), 10);
        self.palette[idx] = try Color.parse(std.mem.trim(u8, value[e + 1 ..], " \t"));

        // Theme
    } else if (eq(key, "theme")) {
        self.theme = try ThemeSpec.parse(alloc, value);
    } else if (eq(key, "window-theme")) {
        self.window_theme = try parseEnum(WindowTheme, value);

        // Renderer / shaders
    } else if (eq(key, "renderer")) {
        self.renderer = try parseEnum(RendererBackend, value);
    } else if (eq(key, "custom-shader")) {
        self.custom_shader = try alloc.dupe(u8, value);
    } else if (eq(key, "custom-shader-animation")) {
        self.custom_shader_animation = try parseEnum(CustomShaderAnimation, value);

        // Background image
    } else if (eq(key, "background-image")) {
        self.background_image = try alloc.dupe(u8, value);
    } else if (eq(key, "background-image-fit")) {
        self.background_image_fit = try parseEnum(BackgroundImageFit, value);
    } else if (eq(key, "background-image-position")) {
        self.background_image_position = try parseEnum(BackgroundImagePosition, value);
    } else if (eq(key, "background-image-opacity")) {
        self.background_image_opacity = std.math.clamp(try std.fmt.parseFloat(f32, value), 0, 1);

        // Window / geometry
    } else if (eq(key, "window-padding-x")) {
        self.window_padding_x = try std.fmt.parseInt(u16, value, 10);
    } else if (eq(key, "window-padding-y")) {
        self.window_padding_y = try std.fmt.parseInt(u16, value, 10);
    } else if (eq(key, "window-padding-balance")) {
        self.window_padding_balance = try parseBool(value);
    } else if (eq(key, "window-width")) {
        self.window_width = try std.fmt.parseInt(u32, value, 10);
    } else if (eq(key, "window-height")) {
        self.window_height = try std.fmt.parseInt(u32, value, 10);
    } else if (eq(key, "window-decoration")) {
        self.window_decoration = try parseEnum(WindowDecoration, value);
    } else if (eq(key, "window-save-state")) {
        self.window_save_state = try parseEnum(WindowSaveState, value);
    } else if (eq(key, "fullscreen")) {
        self.fullscreen = try parseBool(value);
    } else if (eq(key, "maximize")) {
        self.maximize = try parseBool(value);
    } else if (eq(key, "title")) {
        self.title = try alloc.dupe(u8, value);

        // Splits
    } else if (eq(key, "unfocused-split-opacity")) {
        // ghostty floors this at 0.15 (a fully-transparent unfocused split is
        // not allowed).
        self.unfocused_split_opacity = std.math.clamp(try std.fmt.parseFloat(f32, value), 0.15, 1);
    } else if (eq(key, "split-divider-color")) {
        self.split_divider_color = try Color.parse(value);

        // Behavior
    } else if (eq(key, "confirm-close-surface")) {
        self.confirm_close_surface = try parseEnum(ConfirmCloseSurface, value);
    } else if (eq(key, "copy-on-select")) {
        self.copy_on_select = try parseEnum(CopyOnSelect, value);
    } else if (eq(key, "clipboard-read")) {
        self.clipboard_read = try parseEnum(ClipboardAccess, value);
    } else if (eq(key, "clipboard-write")) {
        self.clipboard_write = try parseEnum(ClipboardAccess, value);
    } else if (eq(key, "clipboard-paste-protection")) {
        self.clipboard_paste_protection = try parseBool(value);
    } else if (eq(key, "mouse-hide-while-typing")) {
        self.mouse_hide_while_typing = try parseBool(value);
    } else if (eq(key, "mouse-shift-capture")) {
        self.mouse_shift_capture = try parseEnum(MouseShiftCapture, value);
    } else if (eq(key, "focus-follows-mouse")) {
        self.focus_follows_mouse = try parseBool(value);
    } else if (eq(key, "scrollback-limit")) {
        self.scrollback_limit = try std.fmt.parseInt(usize, value, 10);
    } else if (eq(key, "single-instance")) {
        self.single_instance = try parseBool(value);

        // Command / shell / environment
    } else if (eq(key, "command")) {
        var cmd: Command = undefined;
        try cmd.parseCLI(alloc, value);
        self.command = cmd;
    } else if (eq(key, "working-directory")) {
        self.working_directory = try alloc.dupe(u8, value);
    } else if (eq(key, "shell-integration")) {
        self.shell_integration = try parseEnum(ShellIntegration, value);
    } else if (eq(key, "shell-integration-features")) {
        self.shell_integration_features = try parsePackedFlags(ShellIntegrationFeatures, value);
    } else if (eq(key, "env")) {
        try self.env.append(alloc, try parseEnvEntry(alloc, value));

        // Keybindings
    } else if (eq(key, "keybind")) {
        try self.keybinds.putLine(alloc, value);

        // Includes (recorded; resolved by file_load.zig)
    } else if (eq(key, "config-file")) {
        if (value.len == 0) return error.ValueRequired;
        try self.config_files.append(alloc, try alloc.dupe(u8, value));
    } else {
        // Unrecognized by whostty: record the diagnostic (typo visibility) AND
        // preserve the key/value so a downstream consumer (whomux) can overlay
        // its own keys instead of seeing them dropped (#140).
        try self.diag(alloc, "unknown config key: {s}", .{key});
        try self.unknown_keys.append(alloc, .{
            .key = try alloc.dupe(u8, key),
            .value = try alloc.dupe(u8, value),
        });
    }
}

fn diag(self: *Config, alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const msg = try std.fmt.allocPrint(alloc, fmt, args);
    try self.diagnostics.append(alloc, msg);
}

/// The value of an unrecognized `key` (latest wins), or null — a convenience
/// over scanning `unknown_keys` for a downstream consumer reading its own
/// overlaid keys (#140). The returned slice is owned by the config arena.
pub fn unknownValue(self: *const Config, key: []const u8) ?[]const u8 {
    var i: usize = self.unknown_keys.items.len;
    while (i > 0) {
        i -= 1;
        if (eq(self.unknown_keys.items[i].key, key)) return self.unknown_keys.items[i].value;
    }
    return null;
}

/// The arena allocator for ad-hoc config-owned allocations (used by the IO
/// layers in file_load.zig / theme.zig).
pub fn allocator(self: *Config) std.mem.Allocator {
    return self.arena.allocator();
}

// =========================================================================
// Formatter support
// =========================================================================

/// Whether a field participates in the generic `FileFormatter` pass. Internal
/// bookkeeping and collection fields (emitted explicitly by `formatCollections`)
/// are excluded.
pub fn isFormattable(comptime name: []const u8) bool {
    const excluded = [_][]const u8{
        "arena",           "diagnostics", "palette",  "font_features",
        "font_variations", "env",         "keybinds", "config_files",
        "unknown_keys",
    };
    inline for (excluded) |x| if (comptime eq(name, x)) return false;
    return true;
}

/// Emit the collection fields one line per element so they round-trip. Keybinds
/// are not yet formatted (reverse trigger/action mapping is a follow-up).
pub fn formatCollections(self: *const Config, writer: *std.Io.Writer) !void {
    // palette = <i>=#rrggbb
    for (self.palette, 0..) |maybe, i| {
        if (maybe) |c| {
            try writer.print("palette = {d}=#{x:0>2}{x:0>2}{x:0>2}\n", .{ i, c.r, c.g, c.b });
        }
    }
    // font-feature = <tag>=<value>
    for (self.font_features.items) |f| {
        try writer.print("font-feature = {s}={d}\n", .{ f.tag[0..], f.value });
    }
    // font-variation = <tag>=<value>
    for (self.font_variations.items) |v| {
        try writer.print("font-variation = {s}={d}\n", .{ v.tag[0..], v.value });
    }
    // env = KEY=VALUE
    for (self.env.items) |e| {
        try writer.print("env = {s}={s}\n", .{ e.key, e.value });
    }
    // config-file = path
    for (self.config_files.items) |p| {
        try writer.print("config-file = {s}\n", .{p});
    }
}

// =========================================================================
// Value-parsing helpers
// =========================================================================

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn parseEnum(comptime T: type, value: []const u8) !T {
    return std.meta.stringToEnum(T, value) orelse error.InvalidValue;
}

fn parseEnvEntry(alloc: std.mem.Allocator, value: []const u8) !EnvEntry {
    const e = std.mem.indexOfScalar(u8, value, '=') orelse return error.InvalidValue;
    const k = std.mem.trim(u8, value[0..e], " \t");
    if (k.len == 0) return error.InvalidValue;
    return .{
        .key = try alloc.dupe(u8, k),
        .value = try alloc.dupe(u8, std.mem.trim(u8, value[e + 1 ..], " \t")),
    };
}

/// Parse a comma-separated list of `flag` / `no-flag` tokens into a packed
/// struct of bools, starting from its defaults. Faithful to ghostty's packed
/// flag parsing. Unknown flags are an error.
fn parsePackedFlags(comptime T: type, value: []const u8) !T {
    var result: T = .{};

    // Whole-value bool form (faithful to ghostty): `true`/`false` (and the
    // other bool spellings) toggles *every* flag at once. Only a non-empty
    // value that parses as a bool takes this path; flag-name tokens fall
    // through to the per-flag parser below.
    if (value.len > 0) {
        if (parseBool(value)) |b| {
            inline for (@typeInfo(T).@"struct".fields) |field| {
                @field(result, field.name) = b;
            }
            return result;
        } else |_| {}
    }

    var it = std.mem.tokenizeAny(u8, value, ", ");
    while (it.next()) |tok_raw| {
        const tok = std.mem.trim(u8, tok_raw, " \t");
        if (tok.len == 0) continue;
        const on = !std.mem.startsWith(u8, tok, "no-");
        const name = if (on) tok else tok["no-".len..];
        var matched = false;
        inline for (@typeInfo(T).@"struct".fields) |field| {
            if (eq(field.name, name)) {
                @field(result, field.name) = on;
                matched = true;
            }
        }
        if (!matched) return error.InvalidValue;
    }
    return result;
}

/// Parse a boolean config value. A bare key (empty value) is `true` — the flag
/// form, matching ghostty — as are `true`/`yes`/`1`; `false`/`no`/`0` are
/// `false`. Anything else is an error.
pub fn parseBool(value: []const u8) !bool {
    if (value.len == 0) return true;
    if (eq(value, "true") or eq(value, "yes") or eq(value, "1")) return true;
    if (eq(value, "false") or eq(value, "no") or eq(value, "0")) return false;
    return error.InvalidValue;
}

// =========================================================================
// Tests
// =========================================================================

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

test "config: window padding parses x/y/balance; defaults to zero/off" {
    const testing = std.testing;
    var cfg = try Config.parse(testing.allocator,
        \\window-padding-x = 12
        \\window-padding-y = 8
        \\window-padding-balance = true
    );
    defer cfg.deinit();
    try testing.expectEqual(@as(u16, 12), cfg.window_padding_x);
    try testing.expectEqual(@as(u16, 8), cfg.window_padding_y);
    try testing.expect(cfg.window_padding_balance);

    var def = try Config.parse(testing.allocator, "\n");
    defer def.deinit();
    try testing.expectEqual(@as(u16, 0), def.window_padding_x);
    try testing.expectEqual(@as(u16, 0), def.window_padding_y);
    try testing.expect(!def.window_padding_balance);
}

test "config: single-instance parses; defaults off" {
    const testing = std.testing;
    var cfg = try Config.parse(testing.allocator, "single-instance = true\n");
    defer cfg.deinit();
    try testing.expect(cfg.single_instance);

    var def = try Config.parse(testing.allocator, "\n");
    defer def.deinit();
    try testing.expect(!def.single_instance);
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

    try testing.expectEqual(@as(f32, 12), cfg.font_size);
    try testing.expectEqual(@as(usize, 2), cfg.diagnostics.items.len);
}

test "config: unknown keys are surfaced to the consumer, not just diagnosed (#140)" {
    const testing = std.testing;
    var cfg = try Config.parse(testing.allocator,
        \\whomux-sidebar-width = 32
        \\font-size = 14
    );
    defer cfg.deinit();

    // The recognized key is resolved normally.
    try testing.expectEqual(@as(f32, 14), cfg.font_size);
    // The whomux-specific (unknown-to-whostty) key is preserved with its value
    // for the downstream consumer rather than discarded.
    try testing.expectEqualStrings("32", cfg.unknownValue("whomux-sidebar-width").?);
    try testing.expect(cfg.unknownValue("not-present") == null);
    try testing.expectEqual(@as(usize, 1), cfg.unknown_keys.items.len);
    // It is also still a (non-fatal) diagnostic so a genuine typo stays visible.
    try testing.expectEqual(@as(usize, 1), cfg.diagnostics.items.len);
}

test "config: parse resolves color and font values (#140)" {
    const testing = std.testing;
    var cfg = try Config.parse(testing.allocator,
        \\background = 1a1b26
        \\foreground = #c0caf5
        \\font-family = JetBrains Mono
        \\font-size = 13.5
        \\font-feature = -liga
    );
    defer cfg.deinit();

    try testing.expectEqual(@as(usize, 0), cfg.diagnostics.items.len);
    // Resolved colors whomux uses to seed the engine (ADR 0007).
    try testing.expectEqual(@as(u8, 0x1a), cfg.background.r);
    try testing.expectEqual(@as(u8, 0x1b), cfg.background.g);
    try testing.expectEqual(@as(u8, 0x26), cfg.background.b);
    try testing.expectEqual(@as(u8, 0xc0), cfg.foreground.r);
    try testing.expectEqual(@as(u8, 0xca), cfg.foreground.g);
    try testing.expectEqual(@as(u8, 0xf5), cfg.foreground.b);
    // Resolved font values whomux uses for cell sizing.
    try testing.expectEqualStrings("JetBrains Mono", cfg.font_family.?);
    try testing.expectEqual(@as(f32, 13.5), cfg.font_size);
    try testing.expectEqual(@as(usize, 1), cfg.font_features.items.len);
}

test "config: new font tuning keys parse" {
    const testing = std.testing;
    var cfg = try Config.parse(testing.allocator,
        \\font-family-bold = Cascadia Bold
        \\font-thicken = true
        \\font-thicken-strength = 128
        \\grapheme-width-method = legacy
        \\adjust-cell-height = 10%
        \\adjust-cursor-thickness = 2
        \\font-variation = wght=600
        \\freetype-load-flags = no-hinting,monochrome
    );
    defer cfg.deinit();
    try testing.expectEqualStrings("Cascadia Bold", cfg.font_family_bold.?);
    try testing.expect(cfg.font_thicken);
    try testing.expectEqual(@as(u8, 128), cfg.font_thicken_strength);
    try testing.expectEqual(GraphemeWidthMethod.legacy, cfg.grapheme_width_method);
    try testing.expectEqual(MetricModifier{ .percent = 10 }, cfg.adjust_cell_height.?);
    try testing.expectEqual(MetricModifier{ .absolute = 2 }, cfg.adjust_cursor_thickness.?);
    try testing.expectEqual(@as(usize, 1), cfg.font_variations.items.len);
    try testing.expectEqualSlices(u8, "wght", &cfg.font_variations.items[0].tag);
    try testing.expect(!cfg.freetype_load_flags.hinting);
    try testing.expect(cfg.freetype_load_flags.monochrome);
    try testing.expect(cfg.freetype_load_flags.autohint); // untouched default
    try testing.expectEqual(@as(usize, 0), cfg.diagnostics.items.len);
}

test "config: window + behavior + command keys parse" {
    const testing = std.testing;
    var cfg = try Config.parse(testing.allocator,
        \\window-decoration = none
        \\window-save-state = always
        \\fullscreen = true
        \\confirm-close-surface = always
        \\copy-on-select = clipboard
        \\clipboard-read = allow
        \\mouse-shift-capture = never
        \\command = pwsh -NoLogo
        \\working-directory = C:\src
        \\shell-integration = none
        \\shell-integration-features = no-cursor,sudo
        \\env = FOO=bar
        \\env = BAZ=qux
    );
    defer cfg.deinit();
    try testing.expectEqual(WindowDecoration.none, cfg.window_decoration);
    try testing.expectEqual(WindowSaveState.always, cfg.window_save_state);
    try testing.expect(cfg.fullscreen);
    try testing.expectEqual(ConfirmCloseSurface.always, cfg.confirm_close_surface);
    try testing.expectEqual(CopyOnSelect.clipboard, cfg.copy_on_select);
    try testing.expectEqual(ClipboardAccess.allow, cfg.clipboard_read);
    try testing.expectEqual(MouseShiftCapture.never, cfg.mouse_shift_capture);
    try testing.expect(cfg.command.? == .shell);
    try testing.expectEqualStrings("pwsh -NoLogo", cfg.command.?.shell);
    try testing.expectEqualStrings("C:\\src", cfg.working_directory.?);
    try testing.expectEqual(ShellIntegration.none, cfg.shell_integration);
    try testing.expect(!cfg.shell_integration_features.cursor);
    try testing.expect(cfg.shell_integration_features.sudo);
    try testing.expectEqual(@as(usize, 2), cfg.env.items.len);
    try testing.expectEqualStrings("FOO", cfg.env.items[0].key);
    try testing.expectEqualStrings("bar", cfg.env.items[0].value);
    try testing.expectEqual(@as(usize, 0), cfg.diagnostics.items.len);
}

test "config: packed flags accept the whole-value bool form" {
    const testing = std.testing;
    var off = try Config.parse(testing.allocator, "freetype-load-flags = false\n");
    defer off.deinit();
    try testing.expect(!off.freetype_load_flags.hinting);
    try testing.expect(!off.freetype_load_flags.autohint);
    try testing.expect(!off.freetype_load_flags.monochrome);
    try testing.expectEqual(@as(usize, 0), off.diagnostics.items.len);

    var on = try Config.parse(testing.allocator, "shell-integration-features = true\n");
    defer on.deinit();
    try testing.expect(on.shell_integration_features.cursor);
    try testing.expect(on.shell_integration_features.sudo);
    try testing.expect(on.shell_integration_features.title);
    try testing.expectEqual(@as(usize, 0), on.diagnostics.items.len);
}

test "config: env value is trimmed around the '='" {
    const testing = std.testing;
    var cfg = try Config.parse(testing.allocator, "env = FOO = bar \n");
    defer cfg.deinit();
    try testing.expectEqual(@as(usize, 1), cfg.env.items.len);
    try testing.expectEqualStrings("FOO", cfg.env.items[0].key);
    try testing.expectEqualStrings("bar", cfg.env.items[0].value);
}

test "config: selection defaults match ghostty; word-chars parses" {
    const testing = std.testing;
    var def = try Config.parse(testing.allocator, "\n");
    defer def.deinit();
    try testing.expect(def.selection_clear_on_typing);
    try testing.expect(def.selection_clear_on_copy);
    try testing.expect(def.selection_word_chars == null);

    var cfg = try Config.parse(testing.allocator, "selection-word-chars = /\\()\n");
    defer cfg.deinit();
    try testing.expectEqualStrings("/\\()", cfg.selection_word_chars.?);
    try testing.expectEqual(@as(usize, 0), cfg.diagnostics.items.len);
}

test "config: theme simple and conditional forms" {
    const testing = std.testing;
    var simple = try Config.parse(testing.allocator, "theme = rose-pine\n");
    defer simple.deinit();
    try testing.expectEqualStrings("rose-pine", simple.theme.forState(.light).?);
    try testing.expectEqualStrings("rose-pine", simple.theme.forState(.dark).?);

    // ghostty's comma form, with a theme name containing spaces.
    var cond = try Config.parse(testing.allocator, "theme = light:Rose Pine Dawn,dark:rose-pine\n");
    defer cond.deinit();
    try testing.expectEqualStrings("Rose Pine Dawn", cond.theme.forState(.light).?);
    try testing.expectEqualStrings("rose-pine", cond.theme.forState(.dark).?);
    try testing.expectEqual(@as(usize, 0), cond.diagnostics.items.len);

    // A conditional missing one side is a diagnostic.
    var bad = try Config.parse(testing.allocator, "theme = light:only\n");
    defer bad.deinit();
    try testing.expectEqual(@as(usize, 1), bad.diagnostics.items.len);
}

test "config: config-file directives are recorded" {
    const testing = std.testing;
    var cfg = try Config.parse(testing.allocator,
        \\config-file = base.conf
        \\config-file = ?optional.conf
    );
    defer cfg.deinit();
    try testing.expectEqual(@as(usize, 2), cfg.config_files.items.len);
    try testing.expectEqualStrings("base.conf", cfg.config_files.items[0]);
    try testing.expectEqualStrings("?optional.conf", cfg.config_files.items[1]);
}
