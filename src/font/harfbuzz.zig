//! whostty: HarfBuzz text shaping (#79).
//!
//! Reference: ghostty `pkg/harfbuzz/` (the Zig binding) + `src/font/shaper/
//! harfbuzz.zig` (the shaper). Strategy: port — a minimal, hand-written binding
//! (like `os/dwrite.zig`) plus the `Shaper` that turns a `shaper.Run` into
//! positioned glyphs via `hb_shape`. This is what makes ligatures, contextual
//! alternates, `font-feature` toggles, and complex/RTL scripts work; before it
//! the renderer drew one glyph per cell (no shaping). See PORTING.md.
//!
//! This file is only compiled when `-Dharfbuzz` is set (it links the HarfBuzz C
//! library); the pure run-segmentation / feature-parsing logic lives in the
//! always-built `shaper.zig`, which this builds on.
//!
//! The binding is hand-written `extern` declarations against HarfBuzz's stable
//! C ABI (no `@cImport`, so no HarfBuzz headers are needed to compile whostty —
//! only the linked library). Struct layouts and enum values below are fixed by
//! that ABI.
const std = @import("std");
const Allocator = std.mem.Allocator;
const shaper = @import("shaper.zig");

const Run = shaper.Run;
const Cell = shaper.Cell;
const ShapedGlyph = shaper.ShapedGlyph;

// --- HarfBuzz C ABI ---------------------------------------------------------

const hb_buffer_t = opaque {};
const hb_blob_t = opaque {};
const hb_face_t = opaque {};
const hb_font_t = opaque {};

/// `hb_glyph_info_t`. After shaping, `codepoint` holds the glyph index (not the
/// input Unicode codepoint), and `cluster` is the value passed to `hb_buffer_add`
/// — we use it to carry the run-relative cell index back out.
const GlyphInfo = extern struct {
    codepoint: u32,
    mask: u32,
    cluster: u32,
    var1: u32,
    var2: u32,
};

/// `hb_glyph_position_t`. Advances/offsets are in 26.6 fixed point at the font's
/// set scale; we right-shift by 6 to get whole pixels.
const GlyphPosition = extern struct {
    x_advance: i32,
    y_advance: i32,
    x_offset: i32,
    y_offset: i32,
    @"var": u32,
};

/// `hb_feature_t`: a 4-byte OpenType tag (packed big-endian), an integer value,
/// and the [start,end) range it applies to. We always apply globally.
const hb_feature_t = extern struct {
    tag: u32,
    value: u32,
    start: c_uint,
    end: c_uint,
};

/// `HB_FEATURE_GLOBAL_START` / `..._END`: apply a feature to the whole buffer.
const HB_FEATURE_GLOBAL_START: c_uint = 0;
const HB_FEATURE_GLOBAL_END: c_uint = std.math.maxInt(c_uint);

/// `hb_buffer_cluster_level_t`. `monotone_graphemes` (0) is HarfBuzz's default
/// and the right choice for a terminal grid.
const HB_BUFFER_CLUSTER_LEVEL_MONOTONE_GRAPHEMES: c_int = 0;

/// `hb_buffer_content_type_t`. The low-level `hb_buffer_add` (unlike the bulk
/// `hb_buffer_add_utf*`) does not set the content type, so we set it to
/// `unicode` (1) explicitly before adding — HarfBuzz asserts on it.
const HB_BUFFER_CONTENT_TYPE_UNICODE: c_int = 1;

/// `hb_memory_mode_t`. `readonly` (1): HarfBuzz must not modify or free the blob.
const HB_MEMORY_MODE_READONLY: c_int = 1;

extern fn hb_buffer_create() ?*hb_buffer_t;
extern fn hb_buffer_destroy(*hb_buffer_t) void;
extern fn hb_buffer_reset(*hb_buffer_t) void;
extern fn hb_buffer_set_content_type(*hb_buffer_t, content_type: c_int) void;
extern fn hb_buffer_add(*hb_buffer_t, codepoint: u32, cluster: c_uint) void;
extern fn hb_buffer_guess_segment_properties(*hb_buffer_t) void;
extern fn hb_buffer_set_cluster_level(*hb_buffer_t, level: c_int) void;
extern fn hb_buffer_get_length(*hb_buffer_t) c_uint;
extern fn hb_buffer_get_glyph_infos(*hb_buffer_t, length: *c_uint) [*]GlyphInfo;
extern fn hb_buffer_get_glyph_positions(*hb_buffer_t, length: *c_uint) ?[*]GlyphPosition;

extern fn hb_font_create(*hb_face_t) ?*hb_font_t;
extern fn hb_font_destroy(*hb_font_t) void;

extern fn hb_blob_create(data: [*]const u8, length: c_uint, mode: c_int, user_data: ?*anyopaque, destroy: ?*anyopaque) ?*hb_blob_t;
extern fn hb_blob_destroy(*hb_blob_t) void;
extern fn hb_face_create(*hb_blob_t, index: c_uint) ?*hb_face_t;
extern fn hb_face_destroy(*hb_face_t) void;

// FreeType integration. The argument is an `FT_Face`; we type it `*anyopaque` so
// this binding need not import the freetype module. `hb_ft_font_create_referenced`
// takes a reference on the face (released when the hb_font is destroyed), and
// `hb_ft_font_set_funcs` wires HarfBuzz's glyph metrics to FreeType.
extern fn hb_ft_font_create_referenced(ft_face: *anyopaque) ?*hb_font_t;
extern fn hb_ft_font_set_funcs(*hb_font_t) void;

extern fn hb_shape(*hb_font_t, *hb_buffer_t, features: ?[*]const hb_feature_t, num_features: c_uint) void;

extern fn hb_version_string() [*:0]const u8;

// --- Thin Zig wrappers ------------------------------------------------------

pub fn versionString() [:0]const u8 {
    return std.mem.span(hb_version_string());
}

/// A HarfBuzz font: glyph metrics + the OpenType tables shaping reads. Created
/// either from a FreeType face (the renderer path) or directly from a font file
/// blob (the standalone shaping proof / tests — no FreeType needed).
pub const Font = struct {
    handle: *hb_font_t,
    /// Owned face + blob when created via `initBlob`; null for the FreeType path
    /// (HarfBuzz owns the referenced FT_Face).
    blob: ?*hb_blob_t = null,
    face: ?*hb_face_t = null,

    /// Create from a FreeType `FT_Face` (pass `face.inner.handle`). HarfBuzz
    /// references the face and uses FreeType for glyph functions.
    pub fn initFreetype(ft_face: *anyopaque) error{HarfbuzzFailed}!Font {
        const handle = hb_ft_font_create_referenced(ft_face) orelse
            return error.HarfbuzzFailed;
        hb_ft_font_set_funcs(handle);
        return .{ .handle = handle };
    }

    /// Create from an in-memory font file using HarfBuzz's own OpenType glyph
    /// functions. `data` must outlive the font (it is referenced read-only).
    pub fn initBlob(data: []const u8) error{HarfbuzzFailed}!Font {
        const blob = hb_blob_create(
            data.ptr,
            @intCast(data.len),
            HB_MEMORY_MODE_READONLY,
            null,
            null,
        ) orelse return error.HarfbuzzFailed;
        errdefer hb_blob_destroy(blob);
        const face = hb_face_create(blob, 0) orelse return error.HarfbuzzFailed;
        errdefer hb_face_destroy(face);
        const handle = hb_font_create(face) orelse return error.HarfbuzzFailed;
        return .{ .handle = handle, .blob = blob, .face = face };
    }

    pub fn deinit(self: *Font) void {
        hb_font_destroy(self.handle);
        if (self.face) |f| hb_face_destroy(f);
        if (self.blob) |b| hb_blob_destroy(b);
        self.* = undefined;
    }
};

/// Pack a 4-byte OpenType tag into HarfBuzz's `hb_tag_t` (big-endian). e.g.
/// `"liga"` -> 0x6C696761.
fn packTag(tag: [4]u8) u32 {
    return std.mem.readInt(u32, &tag, .big);
}

/// Features applied to every run unless the user overrides them. `liga`
/// (standard ligatures) and `calt` (contextual alternates) are what programming
/// fonts use for `==`, `=>`, `!=`, etc.; both default on, matching ghostty.
pub const default_features = [_]shaper.Feature{
    .{ .tag = "liga".*, .value = 1 },
    .{ .tag = "calt".*, .value = 1 },
};

/// Turns a `shaper.Run` into positioned glyphs via HarfBuzz. Holds a reusable
/// buffer and the parsed feature list so steady-state shaping is allocation-free.
/// The glyph slice returned by `shape` is owned by the Shaper and valid only
/// until the next `shape` call.
pub const Shaper = struct {
    alloc: Allocator,
    font: Font,
    /// Reused across shape calls to avoid per-run allocation.
    buf: *hb_buffer_t,
    /// Parsed features in HarfBuzz form (defaults followed by user features).
    feats: []hb_feature_t,
    /// Shaped output, reused across calls.
    glyphs: std.ArrayListUnmanaged(ShapedGlyph) = .{},

    /// One `shaper.Feature` (tag + value) in HarfBuzz's global-range form.
    fn hbFeature(f: shaper.Feature) hb_feature_t {
        return .{
            .tag = packTag(f.tag),
            .value = f.value,
            .start = HB_FEATURE_GLOBAL_START,
            .end = HB_FEATURE_GLOBAL_END,
        };
    }

    /// `font` is taken by value and owned by the Shaper (destroyed in `deinit`,
    /// or here on error). `user_features` are the already-parsed `font-feature`
    /// config entries; they follow the defaults, so a user `-liga` overrides the
    /// default `liga` (HarfBuzz takes the later of duplicate tags).
    pub fn init(
        alloc: Allocator,
        font: Font,
        user_features: []const shaper.Feature,
    ) error{ OutOfMemory, HarfbuzzFailed }!Shaper {
        var owned_font = font;
        errdefer owned_font.deinit();

        const buf = hb_buffer_create() orelse return error.HarfbuzzFailed;
        errdefer hb_buffer_destroy(buf);

        var list: std.ArrayListUnmanaged(hb_feature_t) = .{};
        errdefer list.deinit(alloc);
        for (default_features) |f| try list.append(alloc, hbFeature(f));
        for (user_features) |f| try list.append(alloc, hbFeature(f));

        return .{
            .alloc = alloc,
            .font = owned_font,
            .buf = buf,
            .feats = try list.toOwnedSlice(alloc),
        };
    }

    pub fn deinit(self: *Shaper) void {
        hb_buffer_destroy(self.buf);
        self.alloc.free(self.feats);
        self.glyphs.deinit(self.alloc);
        self.font.deinit();
        self.* = undefined;
    }

    /// Shape one run. `cells` is the full row slice the run indexes into. Returns
    /// the positioned glyphs; each glyph's `cluster` is the run-relative cell
    /// index (map to a column with `run.column(cluster)`). Valid until the next
    /// `shape` call.
    pub fn shape(self: *Shaper, run: Run, cells: []const Cell) error{ OutOfMemory, HarfbuzzFailed }![]const ShapedGlyph {
        hb_buffer_reset(self.buf);
        hb_buffer_set_content_type(self.buf, HB_BUFFER_CONTENT_TYPE_UNICODE);

        // Add each cell's codepoint with cluster = its run-relative index. Spacer
        // tails carry no codepoint of their own (they belong to the preceding
        // wide cell's cluster), so they are not added; the wide cell's glyph
        // already advances across both columns.
        var ri: u32 = 0;
        while (ri < run.len) : (ri += 1) {
            const cell = cells[run.start + ri];
            if (cell.width == .spacer_tail) continue;
            hb_buffer_add(self.buf, @intCast(cell.codepoint), ri);
        }

        // Fill in direction/script/language from the buffer's contents, then
        // shape. `monotone_graphemes` keeps clusters in column order.
        hb_buffer_guess_segment_properties(self.buf);
        hb_buffer_set_cluster_level(self.buf, HB_BUFFER_CLUSTER_LEVEL_MONOTONE_GRAPHEMES);
        hb_shape(self.font.handle, self.buf, if (self.feats.len > 0) self.feats.ptr else null, @intCast(self.feats.len));

        const n = hb_buffer_get_length(self.buf);
        self.glyphs.clearRetainingCapacity();
        if (n == 0) return self.glyphs.items[0..0];

        var info_len: c_uint = 0;
        const infos = hb_buffer_get_glyph_infos(self.buf, &info_len);
        var pos_len: c_uint = 0;
        const positions = hb_buffer_get_glyph_positions(self.buf, &pos_len) orelse
            return error.HarfbuzzFailed;
        // HarfBuzz guarantees these are equal; assume it.
        std.debug.assert(info_len == pos_len);

        try self.glyphs.ensureTotalCapacity(self.alloc, info_len);
        var i: usize = 0;
        while (i < info_len) : (i += 1) {
            const info = infos[i];
            const pos = positions[i];
            self.glyphs.appendAssumeCapacity(.{
                .glyph_index = info.codepoint,
                .cluster = info.cluster,
                .x_advance = pos.x_advance >> 6,
                .y_advance = pos.y_advance >> 6,
                .x_offset = pos.x_offset >> 6,
                .y_offset = pos.y_offset >> 6,
            });
        }
        return self.glyphs.items;
    }
};

const testing = std.testing;

test "harfbuzz: packTag is big-endian" {
    try testing.expectEqual(@as(u32, 0x6C696761), packTag("liga".*));
    try testing.expectEqual(@as(u32, 0x63616C74), packTag("calt".*));
    // Space-padded short tag.
    try testing.expectEqual(@as(u32, 0x61612020), packTag("aa  ".*));
}

test "harfbuzz: default features are liga + calt, both on" {
    try testing.expectEqual(@as(usize, 2), default_features.len);
    try testing.expectEqualSlices(u8, "liga", &default_features[0].tag);
    try testing.expectEqual(@as(u32, 1), default_features[0].value);
    try testing.expectEqualSlices(u8, "calt", &default_features[1].tag);
    try testing.expectEqual(@as(u32, 1), default_features[1].value);
}

test "harfbuzz: links and reports a version" {
    // Exercises the C ABI link path; the version is non-empty for any real build.
    try testing.expect(versionString().len > 0);
}
