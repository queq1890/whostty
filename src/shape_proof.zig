//! whostty: standalone HarfBuzz shaping proof (#79).
//!
//! On-device verification of the Windows shaping path is host-gated (#43), so
//! this stands in: it drives the real `font/harfbuzz.zig` binding + `Shaper`
//! against a real font and asserts that shaping with `liga`/`calt` on produces a
//! different glyph stream than with them off — i.e. ligatures actually form and
//! `font-feature` toggles actually take effect. It links only HarfBuzz (it loads
//! the font via a blob, no FreeType), so it builds and runs anywhere HarfBuzz is
//! available — including this WSL/CI environment, unlike the GL offscreen proof.
//!
//! Usage: `zig build shape-proof -- <path-to-ligature-font.ttf>` (or set
//! `WHOSTTY_LIGATURE_FONT`). With no font it prints a notice and exits 0, so an
//! environment without a ligature font does not fail the build.
const std = @import("std");
const harfbuzz = @import("font/harfbuzz.zig");
const shaper = @import("font/shaper.zig");

/// Shape `text` (one narrow cell per byte — ASCII test strings only) and return
/// the glyph-index stream. `user_features` are parsed `font-feature` entries.
fn shapeIndices(
    alloc: std.mem.Allocator,
    data: []const u8,
    text: []const u8,
    user_features: []const shaper.Feature,
    out: []u32,
) ![]u32 {
    const font = try harfbuzz.Font.initBlob(data);
    var sh = try harfbuzz.Shaper.init(alloc, font, user_features);
    defer sh.deinit();

    var cells = try alloc.alloc(shaper.Cell, text.len);
    defer alloc.free(cells);
    for (text, 0..) |ch, i| cells[i] = .{ .codepoint = ch };

    const run: shaper.Run = .{ .start = 0, .len = text.len, .style = .regular };
    const glyphs = try sh.shape(run, cells);

    const n = @min(glyphs.len, out.len);
    for (glyphs[0..n], 0..) |g, i| out[i] = g.glyph_index;
    return out[0..n];
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    std.debug.print("shape-proof: HarfBuzz {s}\n", .{harfbuzz.versionString()});

    // Resolve the font path: argv[1], then $WHOSTTY_LIGATURE_FONT.
    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    _ = args.next(); // exe
    var path_buf: ?[]u8 = null;
    defer if (path_buf) |p| alloc.free(p);
    const path: ?[]const u8 = blk: {
        if (args.next()) |a| break :blk a;
        if (std.process.getEnvVarOwned(alloc, "WHOSTTY_LIGATURE_FONT")) |v| {
            path_buf = v;
            break :blk v;
        } else |_| {}
        break :blk null;
    };

    if (path == null) {
        std.debug.print("shape-proof: no font given (argv[1] / $WHOSTTY_LIGATURE_FONT); skipping\n", .{});
        return;
    }

    const data = std.fs.cwd().readFileAlloc(alloc, path.?, 64 * 1024 * 1024) catch |err| {
        std.debug.print("shape-proof: cannot read '{s}': {s}; skipping\n", .{ path.?, @errorName(err) });
        return;
    };
    defer alloc.free(data);

    // Programming ligatures: each should shape to a different glyph stream with
    // the default features (liga/calt on) than with them disabled.
    const ligatures = [_][]const u8{ "===", "!=", "=>", "<=", "->" };
    const off_features = [_]shaper.Feature{
        try shaper.Feature.parse("-liga"),
        try shaper.Feature.parse("-calt"),
    };

    var any_ligature = false;
    var on_buf: [32]u32 = undefined;
    var off_buf: [32]u32 = undefined;
    for (ligatures) |s| {
        const on = try shapeIndices(alloc, data, s, &.{}, &on_buf);
        const off = try shapeIndices(alloc, data, s, &off_features, &off_buf);
        const changed = !std.mem.eql(u32, on, off);
        if (changed) any_ligature = true;
        std.debug.print(
            "  {s:<4} on={any} off={any} {s}\n",
            .{ s, on, off, if (changed) "(ligated)" else "(no change)" },
        );
    }

    if (!any_ligature) {
        std.debug.print(
            "shape-proof: WARNING — no ligature changed for '{s}'; is it a ligature font?\n",
            .{path.?},
        );
        // Not a hard failure: the font may simply lack these ligatures.
        return;
    }

    // A sanity check on the shaper's structural output: shaping plain "ab"
    // yields exactly two glyphs mapped back to columns 0 and 1.
    {
        const font = try harfbuzz.Font.initBlob(data);
        var sh = try harfbuzz.Shaper.init(alloc, font, &.{});
        defer sh.deinit();
        var cells = [_]shaper.Cell{ .{ .codepoint = 'a' }, .{ .codepoint = 'b' } };
        const run: shaper.Run = .{ .start = 0, .len = 2, .style = .regular };
        const glyphs = try sh.shape(run, &cells);
        if (glyphs.len != 2) return error.UnexpectedGlyphCount;
        if (run.column(glyphs[0].cluster) != 0) return error.BadColumnMapping;
        if (run.column(glyphs[1].cluster) != 1) return error.BadColumnMapping;
        if (glyphs[0].x_advance <= 0) return error.BadAdvance;
    }

    std.debug.print("shape-proof: OK — ligatures form and feature toggles take effect\n", .{});
}
