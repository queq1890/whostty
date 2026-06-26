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
/// loader). The COM sequence (implemented in `discoverWindows`) is:
///
///   DWriteCreateFactory(SHARED, IID_IDWriteFactory, &factory)
///   factory->GetSystemFontCollection(&collection, FALSE)
///   <enumerate family names> -> resolveFamily picks the winner
///   collection->FindFamilyName(name, &index, &exists)
///   collection->GetFontFamily(index, &family)
///   family->GetFirstMatchingFont(weight, STRETCH_NORMAL, style, &font)
///   font->CreateFontFace(&face)
///   face->GetFiles(&n, &file)
///   file->GetReferenceKey(&key, &keySize) + GetLoader(&loader)
///   loader as IDWriteLocalFontFileLoader->GetFilePathFromKey(...)
///
/// The hand-written COM vtable bindings live in `os/dwrite.zig`. Errors propagate
/// to the caller (the app then falls back to its bundled/configured font path).
/// Returns a `Resolved` whose `family` and `path` are owned by `alloc`. Verified
/// on a real Windows host (Georgia, Courier New, and the default chain all
/// resolve to their real font files and load).
pub fn discover(alloc: std.mem.Allocator, desc: Descriptor) !Resolved {
    if (comptime builtin.os.tag != .windows) return error.Unsupported;
    return discoverWindows(alloc, desc);
}

const dw = if (builtin.os.tag == .windows) @import("../os/dwrite.zig") else struct {};
const win = if (builtin.os.tag == .windows) @import("../os/windows.zig") else struct {};

/// DirectWrite backend for `discover`. Enumerates the system font collection's
/// family names, picks one per `resolveFamily`, selects the styled face, and
/// resolves it to an on-disk file path via the local font-file loader. Every
/// COM object acquired is released on every return path (factory last).
fn discoverWindows(alloc: std.mem.Allocator, desc: Descriptor) !Resolved {
    var factory_raw: ?*anyopaque = null;
    if (!dw.SUCCEEDED(dw.DWriteCreateFactory(
        dw.DWRITE_FACTORY_TYPE_SHARED,
        &dw.IID_IDWriteFactory,
        &factory_raw,
    ))) return error.DWriteFactoryFailed;
    const factory: *dw.IDWriteFactory = @ptrCast(@alignCast(factory_raw.?));
    defer _ = factory.Release();

    var collection: ?*dw.IDWriteFontCollection = null;
    if (!dw.SUCCEEDED(factory.GetSystemFontCollection(&collection, win.FALSE)) or collection == null)
        return error.DWriteCollectionFailed;
    const coll = collection.?;
    defer _ = coll.Release();

    // Enumerate every family's primary (locale-0) name into an owned list so the
    // pure `resolveFamily` can pick the winner case-insensitively.
    const count = coll.GetFontFamilyCount();
    var names = std.ArrayList([]const u8){};
    defer {
        for (names.items) |n| alloc.free(n);
        names.deinit(alloc);
    }
    try names.ensureTotalCapacity(alloc, count);

    var i: dw.UINT32 = 0;
    while (i < count) : (i += 1) {
        const name = familyName(alloc, coll, i) catch continue;
        names.append(alloc, name) catch {
            alloc.free(name);
            return error.OutOfMemory;
        };
    }

    const chosen = resolveFamily(desc.family, names.items) orelse return error.NoFontFound;
    // `chosen` is a slice into `names`; dupe it now since we free `names` on exit.
    const chosen_owned = try alloc.dupe(u8, chosen);
    errdefer alloc.free(chosen_owned);

    const path = try familyFilePath(alloc, coll, chosen, desc);
    return .{ .family = chosen_owned, .path = path, .style = desc.style() };
}

/// Every system font-family name (locale-0), sorted case-sensitively, each plus
/// the slice owned by `alloc` (free each entry, then the slice). Backs the
/// `+list-fonts` CLI action (#53). Windows-only; errors on other hosts. The
/// platform code lives in `listFamiliesWindows` (called only after the comptime
/// guard) so it isn't analyzed off-Windows — matching `discover`.
pub fn listFamilies(alloc: std.mem.Allocator) ![][]const u8 {
    if (comptime builtin.os.tag != .windows) return error.Unsupported;
    return listFamiliesWindows(alloc);
}

fn listFamiliesWindows(alloc: std.mem.Allocator) ![][]const u8 {
    var factory_raw: ?*anyopaque = null;
    if (!dw.SUCCEEDED(dw.DWriteCreateFactory(
        dw.DWRITE_FACTORY_TYPE_SHARED,
        &dw.IID_IDWriteFactory,
        &factory_raw,
    ))) return error.DWriteFactoryFailed;
    const factory: *dw.IDWriteFactory = @ptrCast(@alignCast(factory_raw.?));
    defer _ = factory.Release();

    var collection: ?*dw.IDWriteFontCollection = null;
    if (!dw.SUCCEEDED(factory.GetSystemFontCollection(&collection, win.FALSE)) or collection == null)
        return error.DWriteCollectionFailed;
    const coll = collection.?;
    defer _ = coll.Release();

    const count = coll.GetFontFamilyCount();
    var names = std.ArrayList([]const u8){};
    errdefer {
        for (names.items) |n| alloc.free(n);
        names.deinit(alloc);
    }
    try names.ensureTotalCapacity(alloc, count);

    var i: dw.UINT32 = 0;
    while (i < count) : (i += 1) {
        const name = familyName(alloc, coll, i) catch continue;
        names.append(alloc, name) catch {
            alloc.free(name);
            return error.OutOfMemory;
        };
    }

    const slice = try names.toOwnedSlice(alloc);
    std.mem.sort([]const u8, slice, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return slice;
}

/// Read family index `i`'s first localized name as owned UTF-8.
fn familyName(alloc: std.mem.Allocator, coll: *dw.IDWriteFontCollection, i: dw.UINT32) ![]const u8 {
    var family: ?*dw.IDWriteFontFamily = null;
    if (!dw.SUCCEEDED(coll.GetFontFamily(i, &family)) or family == null) return error.NoFamily;
    const fam = family.?;
    defer _ = fam.Release();

    var strings: ?*dw.IDWriteLocalizedStrings = null;
    if (!dw.SUCCEEDED(fam.GetFamilyNames(&strings)) or strings == null) return error.NoNames;
    const s = strings.?;
    defer _ = s.Release();

    var len: dw.UINT32 = 0;
    if (!dw.SUCCEEDED(s.GetStringLength(0, &len))) return error.NoName;

    const buf = try alloc.alloc(u16, len + 1);
    defer alloc.free(buf);
    if (!dw.SUCCEEDED(s.GetString(0, buf.ptr, len + 1))) return error.NoName;

    return std.unicode.utf16LeToUtf8Alloc(alloc, buf[0..len]);
}

/// Resolve a chosen family name to a concrete face file path (owned UTF-8).
fn familyFilePath(
    alloc: std.mem.Allocator,
    coll: *dw.IDWriteFontCollection,
    family_name: []const u8,
    desc: Descriptor,
) ![]const u8 {
    const name_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, family_name);
    defer alloc.free(name_w);

    var index: dw.UINT32 = 0;
    var exists: win.BOOL = win.FALSE;
    if (!dw.SUCCEEDED(coll.FindFamilyName(name_w.ptr, &index, &exists)) or exists == win.FALSE)
        return error.FamilyNotFound;

    var family: ?*dw.IDWriteFontFamily = null;
    if (!dw.SUCCEEDED(coll.GetFontFamily(index, &family)) or family == null) return error.NoFamily;
    const fam = family.?;
    defer _ = fam.Release();

    var font: ?*dw.IDWriteFont = null;
    if (!dw.SUCCEEDED(fam.GetFirstMatchingFont(
        @intCast(desc.dwriteWeight()),
        dw.DWRITE_FONT_STRETCH_NORMAL,
        @intCast(desc.dwriteStyle()),
        &font,
    )) or font == null) return error.NoMatchingFont;
    const f = font.?;
    defer _ = f.Release();

    var face: ?*dw.IDWriteFontFace = null;
    if (!dw.SUCCEEDED(f.CreateFontFace(&face)) or face == null) return error.NoFontFace;
    const fc = face.?;
    defer _ = fc.Release();

    // GetFiles is in/out on the count: query the count, then fetch one file.
    var n_files: dw.UINT32 = 0;
    if (!dw.SUCCEEDED(fc.GetFiles(&n_files, null)) or n_files == 0) return error.NoFontFile;
    n_files = 1;
    var file: ?*dw.IDWriteFontFile = null;
    if (!dw.SUCCEEDED(fc.GetFiles(&n_files, @ptrCast(&file))) or file == null) return error.NoFontFile;
    const ff = file.?;
    defer _ = ff.Release();

    var key: ?*const anyopaque = null;
    var key_size: dw.UINT32 = 0;
    if (!dw.SUCCEEDED(ff.GetReferenceKey(&key, &key_size))) return error.NoReferenceKey;

    var loader: ?*dw.IDWriteFontFileLoader = null;
    if (!dw.SUCCEEDED(ff.GetLoader(&loader)) or loader == null) return error.NoLoader;
    const ld = loader.?;
    defer _ = ld.Release();

    var local_raw: ?*anyopaque = null;
    if (!dw.SUCCEEDED(ld.QueryInterface(&dw.IID_IDWriteLocalFontFileLoader, &local_raw)) or local_raw == null)
        return error.NotLocalLoader;
    const local: *dw.IDWriteLocalFontFileLoader = @ptrCast(@alignCast(local_raw.?));
    defer _ = local.Release();

    var len: dw.UINT32 = 0;
    if (!dw.SUCCEEDED(local.GetFilePathLengthFromKey(key, key_size, &len))) return error.NoFilePath;

    const path_w = try alloc.alloc(u16, len + 1);
    defer alloc.free(path_w);
    if (!dw.SUCCEEDED(local.GetFilePathFromKey(key, key_size, path_w.ptr, len + 1)))
        return error.NoFilePath;

    return std.unicode.utf16LeToUtf8Alloc(alloc, path_w[0..len]);
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

test "discovery: discover resolves a system family to a real font file (Windows)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = testing.allocator;
    const resolved = try discover(alloc, .{ .family = "Consolas" });
    defer alloc.free(resolved.family);
    defer alloc.free(resolved.path);

    // The path must exist on disk and look like a font file.
    try std.fs.cwd().access(resolved.path, .{});
    const lower = try std.ascii.allocLowerString(alloc, resolved.path);
    defer alloc.free(lower);
    const is_font = std.mem.endsWith(u8, lower, ".ttf") or
        std.mem.endsWith(u8, lower, ".ttc") or
        std.mem.endsWith(u8, lower, ".otf");
    try testing.expect(is_font);
}
