//! whostty: configuration package root (aggregator).
//!
//! Mirrors ghostty `src/config.zig`: the `Config` struct and value types live in
//! `config/Config.zig`, with the supporting system split across sibling files
//! (`formatter`, `file_load`, `theme`, `conditional`, `string`, `command`). This
//! file re-exports the public surface so importers keep using `@import("config.zig")`.
//! See PORTING.md and the #49 epic.
const formatter = @import("config/formatter.zig");
const file_load = @import("config/file_load.zig");

pub const Config = @import("config/Config.zig");
pub const conditional = @import("config/conditional.zig");
pub const theme = @import("config/theme.zig");
pub const string = @import("config/string.zig");
pub const path = @import("config/path.zig");

// Formatter
pub const FileFormatter = formatter.FileFormatter;
pub const EntryFormatter = formatter.EntryFormatter;
pub const entryFormatter = formatter.entryFormatter;
pub const formatEntry = formatter.formatEntry;

// File loading (Windows path resolution + recursive includes + theme)
pub const preferredDefaultFilePath = file_load.preferredDefaultFilePath;
pub const loadDefaultFiles = file_load.loadDefaultFiles;
pub const loadFile = file_load.loadFile;
pub const loadRecursiveFiles = file_load.loadRecursiveFiles;

// Conditional state
pub const ConditionalState = conditional.State;

// Value types (re-exported for ergonomic access)
pub const Color = Config.Color;
pub const CursorStyle = Config.CursorStyle;
pub const RendererBackend = Config.RendererBackend;
pub const Command = Config.Command;
pub const ThemeSpec = Config.ThemeSpec;
pub const MetricModifier = Config.MetricModifier;
pub const FontVariation = Config.FontVariation;
pub const EnvEntry = Config.EnvEntry;
pub const WindowDecoration = Config.WindowDecoration;
pub const WindowTheme = Config.WindowTheme;
pub const WindowSaveState = Config.WindowSaveState;
pub const ConfirmCloseSurface = Config.ConfirmCloseSurface;
pub const CopyOnSelect = Config.CopyOnSelect;
pub const ClipboardAccess = Config.ClipboardAccess;
pub const MouseShiftCapture = Config.MouseShiftCapture;
pub const GraphemeWidthMethod = Config.GraphemeWidthMethod;
pub const CustomShaderAnimation = Config.CustomShaderAnimation;
pub const BackgroundImageFit = Config.BackgroundImageFit;
pub const BackgroundImagePosition = Config.BackgroundImagePosition;
pub const FreetypeLoadFlags = Config.FreetypeLoadFlags;
pub const ShellIntegration = Config.ShellIntegration;
pub const ShellIntegrationFeatures = Config.ShellIntegrationFeatures;

// Config file line format
pub const LineIterator = Config.LineIterator;
pub const KeyValue = Config.KeyValue;
pub const parseBool = Config.parseBool;

// Unknown (whomux-overlaid) keys surfaced to the consumer (#140)
pub const Unknown = Config.Unknown;

test {
    @import("std").testing.refAllDecls(@This());
}
