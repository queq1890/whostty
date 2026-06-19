//! whostty: font discovery — resolve a font family to a concrete face/file.
//!
//! Reference: ghostty `src/font/discovery.zig` (`Descriptor` + a per-OS backend:
//! fontconfig / CoreText / DirectWrite). Strategy: hybrid — the `Descriptor` is
//! a faithful port of ghostty's shape, and the backend is DirectWrite (fresh
//! Windows code, replacing ghostty's coretext/fontconfig). Discovery only maps a
//! family *name* to a font *file path*; Freetype still rasterizes (`font/main.zig`,
//! #9). Harfbuzz shaping is separate (#13). See PORTING.md.
//!
//! This module is deliberately free of the `freetype` import (which is opt-in
//! behind `-Dfreetype`) and of Windows types in its core, so the `Descriptor`
//! and family-resolution logic compile and unit-test on the host. The actual
//! DirectWrite system-font enumeration is Windows-only (see `discover`).
const std = @import("std");
const builtin = @import("builtin");

/// The synthetic style requested for a face. Freetype can synthesize bold/italic
/// when a dedicated face isn't available; discovery prefers a real styled face
/// when the system has one.
pub const Style = enum { regular, bold, italic, bold_italic };

/// Whether a codepoint should render with its text or emoji (color) glyph. Text
/// and emoji come from different faces, so the shaper splits runs on it and
/// discovery picks a different family for each (#13/#14).
pub const Presentation = enum { text, emoji };

/// The default presentation of a codepoint. This is a pragmatic subset of the
/// Unicode emoji ranges — enough to route the common pictographic/emoji blocks
/// to a color-emoji face — not the full emoji-data table (which, with its
/// text-default exceptions and variation-selector overrides, belongs in a
/// generated Unicode source and can be wired in later). Returns `.text` for
/// everything else, including CJK (which is wide but not emoji).
pub fn presentation(cp: u32) Presentation {
    return if (isEmojiPresentation(cp)) .emoji else .text;
}

fn isEmojiPresentation(cp: u32) bool {
    return (cp >= 0x1F300 and cp <= 0x1FAFF) or // pictographs, emoticons, transport, supplemental
        (cp >= 0x2600 and cp <= 0x27BF) or // misc symbols + dingbats
        (cp >= 0x1F1E6 and cp <= 0x1F1FF) or // regional indicators (flags)
        cp == 0x2B50 or cp == 0x2B55; // star, heavy circle
}

/// Default emoji-font fallbacks, best-first. Segoe UI Emoji ships on Windows.
pub const default_emoji = [_][]const u8{
    "Segoe UI Emoji",
    "Segoe UI Symbol",
};

/// A request for a font. A faithful subset of ghostty's `font.Descriptor`:
/// enough fields to pick a family and a style at a size. `family == null` means
/// "use the default monospace fallback chain".
pub const Descriptor = struct {
    family: ?[]const u8 = null,
    /// Point size.
    size: f32 = 12,
    bold: bool = false,
    italic: bool = false,
    /// Prefer monospaced faces (terminals always do).
    monospace: bool = true,

    pub fn style(self: Descriptor) Style {
        if (self.bold and self.italic) return .bold_italic;
        if (self.bold) return .bold;
        if (self.italic) return .italic;
        return .regular;
    }

    /// The DirectWrite `DWRITE_FONT_WEIGHT` for this descriptor: 400 normal,
    /// 700 bold (the values DirectWrite uses).
    pub fn dwriteWeight(self: Descriptor) u32 {
        return if (self.bold) 700 else 400;
    }

    /// The DirectWrite `DWRITE_FONT_STYLE`: 0 = NORMAL, 2 = ITALIC.
    pub fn dwriteStyle(self: Descriptor) u32 {
        return if (self.italic) 2 else 0;
    }

    /// Build a descriptor for one face variant of a configured font. The app
    /// requests up to four variants (regular/bold/italic/bold-italic) from the
    /// same family at the same size; this maps a `Style` onto the bold/italic
    /// flags so each can be discovered (or synthesized) independently.
    pub fn forStyle(family: ?[]const u8, size: f32, s: Style) Descriptor {
        return .{
            .family = family,
            .size = size,
            .bold = s == .bold or s == .bold_italic,
            .italic = s == .italic or s == .bold_italic,
        };
    }
};

/// A resolved face: the family that was actually chosen and the file path to
/// hand to Freetype. The path is owned by the caller's allocator.
pub const Resolved = struct {
    family: []const u8,
    path: []const u8,
    style: Style,
};

/// Default monospace fallbacks, best-first. Cascadia ships with modern Windows
/// Terminal installs; Consolas and Lucida Console are on essentially every
/// Windows machine, so the chain always lands somewhere sensible.
pub const default_monospace = [_][]const u8{
    "Cascadia Mono",
    "Cascadia Code",
    "Consolas",
    "Lucida Console",
    "Courier New",
};

/// Choose a family name from `available` (compared case-insensitively):
///   1. the `requested` family if present,
///   2. otherwise the first default-monospace fallback that's installed,
///   3. otherwise the first available family.
/// Returns null only when `available` is empty. Pure and host-tested; the
/// DirectWrite backend feeds it the system family list.
pub fn resolveFamily(requested: ?[]const u8, available: []const []const u8) ?[]const u8 {
    if (available.len == 0) return null;

    if (requested) |req| {
        if (req.len != 0) {
            for (available) |a| {
                if (std.ascii.eqlIgnoreCase(a, req)) return a;
            }
        }
    }

    return firstInChain(&default_monospace, available) orelse available[0];
}

/// Like `resolveFamily`, but presentation-aware: emoji codepoints ignore the
/// (monospace) requested family — which won't carry color glyphs — and use the
/// emoji fallback chain instead. Text uses the normal path.
pub fn resolveFamilyFor(
    requested: ?[]const u8,
    pres: Presentation,
    available: []const []const u8,
) ?[]const u8 {
    if (available.len == 0) return null;
    return switch (pres) {
        .text => resolveFamily(requested, available),
        .emoji => firstInChain(&default_emoji, available) orelse available[0],
    };
}

/// The first family in `chain` that's present in `available` (case-insensitive).
fn firstInChain(chain: []const []const u8, available: []const []const u8) ?[]const u8 {
    for (chain) |want| {
        for (available) |a| {
            if (std.ascii.eqlIgnoreCase(a, want)) return a;
        }
    }
    return null;
}

/// Resolve a descriptor to a concrete font file on this system.
///
/// Windows: enumerate the system font collection via DirectWrite, pick the
/// family per `resolveFamily`, select the face matching `dwriteWeight`/
/// `dwriteStyle`, and return its on-disk file path (via the local font-file
/// loader). The concrete COM sequence is:
///
///   DWriteCreateFactory(ISOLATED, IID_IDWriteFactory, &factory)
///   factory->GetSystemFontCollection(&collection, FALSE)
///   collection->FindFamilyName(name, &index, &exists)
///   collection->GetFontFamily(index, &family)
///   family->GetFirstMatchingFont(weight, STRETCH_NORMAL, style, &font)
///   font->CreateFontFace(&face)
///   face->GetFiles(&n, &file)
///   file->GetReferenceKey(&key, &keySize) + GetLoader(&loader)
///   loader as IDWriteLocalFontFileLoader->GetFilePathFromKey(...)
///
/// This requires hand-written COM vtable bindings in `os/windows.zig` and a
/// Windows host to verify (a wrong vtable layout faults at run time, not at
/// compile time), so it is intentionally not landed blind in this environment.
/// Until then it reports `error.Unimplemented`; the app falls back to its
/// bundled/configured font path. The pure pieces above (`Descriptor`,
/// `resolveFamily`, weight/style mapping) are complete and tested and are what
/// the backend will call.
pub fn discover(alloc: std.mem.Allocator, desc: Descriptor) !Resolved {
    _ = alloc;
    _ = desc;
    if (comptime builtin.os.tag != .windows) return error.Unsupported;
    return error.Unimplemented;
}

const testing = std.testing;

test "discovery: style derivation" {
    try testing.expectEqual(Style.regular, (Descriptor{}).style());
    try testing.expectEqual(Style.bold, (Descriptor{ .bold = true }).style());
    try testing.expectEqual(Style.italic, (Descriptor{ .italic = true }).style());
    try testing.expectEqual(Style.bold_italic, (Descriptor{ .bold = true, .italic = true }).style());
}

test "discovery: forStyle maps a Style onto bold/italic flags" {
    const reg = Descriptor.forStyle("Consolas", 13, .regular);
    try testing.expectEqualStrings("Consolas", reg.family.?);
    try testing.expectEqual(@as(f32, 13), reg.size);
    try testing.expect(!reg.bold and !reg.italic);

    const bi = Descriptor.forStyle("Consolas", 13, .bold_italic);
    try testing.expect(bi.bold and bi.italic);
    try testing.expectEqual(Style.bold_italic, bi.style());

    try testing.expect(Descriptor.forStyle(null, 12, .bold).bold);
    try testing.expect(Descriptor.forStyle(null, 12, .italic).italic);
}

test "discovery: DirectWrite weight/style mapping" {
    try testing.expectEqual(@as(u32, 400), (Descriptor{}).dwriteWeight());
    try testing.expectEqual(@as(u32, 700), (Descriptor{ .bold = true }).dwriteWeight());
    try testing.expectEqual(@as(u32, 0), (Descriptor{}).dwriteStyle());
    try testing.expectEqual(@as(u32, 2), (Descriptor{ .italic = true }).dwriteStyle());
}

test "discovery: presentation routes emoji vs text" {
    try testing.expectEqual(Presentation.text, presentation('A'));
    try testing.expectEqual(Presentation.text, presentation(0x4E00)); // CJK: wide but text
    try testing.expectEqual(Presentation.emoji, presentation(0x1F600)); // grinning face
    try testing.expectEqual(Presentation.emoji, presentation(0x2764)); // heavy black heart
    try testing.expectEqual(Presentation.emoji, presentation(0x1F1FA)); // regional indicator U
    try testing.expectEqual(Presentation.emoji, presentation(0x1FAE0)); // melting face (extended-A)
}

test "discovery: resolveFamily prefers the requested family (case-insensitive)" {
    const available = [_][]const u8{ "Arial", "Consolas", "Cascadia Mono" };
    try testing.expectEqualStrings("Consolas", resolveFamily("consolas", &available).?);
    try testing.expectEqualStrings("Cascadia Mono", resolveFamily("CASCADIA MONO", &available).?);
}

test "discovery: resolveFamily falls back through the monospace chain" {
    // Requested family absent -> first installed fallback wins (Cascadia Mono
    // outranks Consolas in the chain).
    const available = [_][]const u8{ "Arial", "Consolas", "Cascadia Mono", "Times New Roman" };
    try testing.expectEqualStrings("Cascadia Mono", resolveFamily("Nonexistent Font", &available).?);
}

test "discovery: resolveFamily returns the first available when nothing matches" {
    const available = [_][]const u8{ "Some Display Font", "Another Display Font" };
    try testing.expectEqualStrings("Some Display Font", resolveFamily("Whatever", &available).?);
    // A null/empty request with no fallback installed also yields the first.
    try testing.expectEqualStrings("Some Display Font", resolveFamily(null, &available).?);
}

test "discovery: resolveFamily on an empty system list is null" {
    const empty = [_][]const u8{};
    try testing.expect(resolveFamily("Consolas", &empty) == null);
}

test "discovery: resolveFamilyFor routes emoji to the emoji chain" {
    const available = [_][]const u8{ "Consolas", "Segoe UI Emoji", "Arial" };
    // Emoji ignores the requested monospace family and picks the emoji font.
    try testing.expectEqualStrings(
        "Segoe UI Emoji",
        resolveFamilyFor("Consolas", .emoji, &available).?,
    );
    // Text behaves like resolveFamily.
    try testing.expectEqualStrings(
        "Consolas",
        resolveFamilyFor("Consolas", .text, &available).?,
    );
}

test "discovery: resolveFamilyFor falls back to first available when no emoji font" {
    const available = [_][]const u8{ "Consolas", "Arial" };
    try testing.expectEqualStrings("Consolas", resolveFamilyFor(null, .emoji, &available).?);
    const empty = [_][]const u8{};
    try testing.expect(resolveFamilyFor(null, .emoji, &empty) == null);
}

test "discovery: discover is unsupported off-Windows" {
    if (builtin.os.tag != .windows) {
        try testing.expectError(error.Unsupported, discover(testing.allocator, .{}));
    }
}
