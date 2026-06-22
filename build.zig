const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The VT core is delegated to libghostty-vt (the `ghostty-vt` module),
    // pulled from a pinned ghostty release tag. whostty does not reimplement
    // the terminal core. See ADR 0002 and PORTING.md.
    const ghostty = b.dependency("ghostty", .{
        .target = target,
        .optimize = optimize,
        // SIMD pulls in vendored C/C++ (highway/simdutf). Keep it off for the
        // bootstrap; revisit once the renderer needs it.
        .simd = false,
    });
    const ghostty_vt = ghostty.module("ghostty-vt");

    // Freetype (built from source) for glyph rasterization is opt-in: the
    // upstream source download is not reachable in all environments, and the
    // renderer itself does not depend on it (it consumes atlas bytes). Enable
    // with -Dfreetype on a network-unrestricted machine.
    const enable_freetype = b.option(
        bool,
        "freetype",
        "Build the Freetype glyph rasterizer (fetches freetype source)",
    ) orelse false;

    // HarfBuzz text shaping (#79): ligatures, contextual alternates, complex /
    // RTL scripts, `font-feature` toggles. Built from the HarfBuzz amalgam and
    // linked when enabled. Shaping needs an `hb_font` wrapping the Freetype face,
    // so it requires -Dfreetype. (The `shape-proof` step builds HarfBuzz on its
    // own, without Freetype, via the font-blob path.)
    const enable_harfbuzz = b.option(
        bool,
        "harfbuzz",
        "Build HarfBuzz text shaping (#79); requires -Dfreetype",
    ) orelse false;
    if (enable_harfbuzz and !enable_freetype) {
        std.debug.panic("-Dharfbuzz requires -Dfreetype (the shaper builds an hb_font from the Freetype face)", .{});
    }

    const build_options = b.addOptions();
    build_options.addOption(bool, "freetype", enable_freetype);
    build_options.addOption(bool, "harfbuzz", enable_harfbuzz);

    const exe = b.addExecutable(.{
        .name = "whostty",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("ghostty-vt", ghostty_vt);
    exe.root_module.addImport("build_options", build_options.createModule());
    // A GUI terminal must be a Windows-subsystem app: a console-subsystem exe
    // owns a console that the spawned shell attaches to instead of the ConPTY
    // (so its output bypasses libghostty-vt and nothing renders). GUI subsystem
    // means no console exists for the child to inherit.
    if (target.result.os.tag == .windows) exe.subsystem = .Windows;
    if (enable_freetype) {
        // enable-libpng builds Freetype with PNG support so it can decode the
        // PNG-compressed CBDT color-bitmap strikes used by color-emoji fonts
        // (Noto Color Emoji) — otherwise FT_Load_Glyph returns Unimplemented for
        // them. Needed by the color-glyph path (#78).
        if (b.lazyDependency("freetype", .{ .target = target, .optimize = optimize, .@"enable-libpng" = true })) |dep| {
            exe.root_module.addImport("freetype", dep.module("freetype"));
            // The freetype module's `@cImport` pulls in libc headers (e.g.
            // <string.h>). Link libc so they resolve — for cross-compiled
            // Windows targets this is satisfied by Zig's bundled MinGW.
            exe.root_module.link_libc = true;
            // The module only provides the Zig bindings; link the compiled
            // freetype C library so the FT_* symbols resolve.
            exe.root_module.linkLibrary(dep.artifact("freetype"));
            // Shaping rides on the Freetype face: build + link HarfBuzz with the
            // FreeType glyph functions so the shaper can build an hb_font (#79).
            if (enable_harfbuzz) _ = linkHarfbuzz(b, exe.root_module, target, optimize, dep);
        }
    }
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run whostty");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    // Headless render proof (Linux/EGL + Mesa): exercises the real OpenGL.zig
    // shaders/geometry, font/main.zig (Freetype) and font/Atlas.zig on a genuine
    // GL 3.3 core context and asserts glyphs reach lit pixels — on-device
    // verification of the Windows renderer is WDAC-blocked, so this stands in.
    // Always built for the native host; requires the freetype source + Mesa.
    // Pin glibc to 2.42 (the max Zig 0.15.2 bundles) so the build works on hosts
    // reporting a newer glibc; the binary still runs against the system glibc.
    const native_target = b.resolveTargetQuery(.{ .glibc_version = .{ .major = 2, .minor = 42, .patch = 0 } });
    const offscreen = b.addExecutable(.{
        .name = "offscreen-proof",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/offscreen_proof.zig"),
            .target = native_target,
            .optimize = optimize,
        }),
    });
    offscreen.root_module.link_libc = true;
    // The proof drives a real `Termio` (VT parse -> terminal.colors) for the
    // dynamic-color render check, so it needs the libghostty-vt module too.
    offscreen.root_module.addImport("ghostty-vt", ghostty_vt);
    const off_step = b.step("offscreen-proof", "Headless GL render proof (Linux/EGL)");
    if (b.lazyDependency("freetype", .{ .target = native_target, .optimize = optimize, .@"enable-libpng" = true })) |dep| {
        offscreen.root_module.addImport("freetype", dep.module("freetype"));
        offscreen.root_module.linkLibrary(dep.artifact("freetype"));
        const off_run = b.addRunArtifact(offscreen);
        off_step.dependOn(&off_run.step);
    }

    // Standalone HarfBuzz shaping proof (#79): drives the real `font/harfbuzz.zig`
    // binding + `Shaper` against a real font and asserts ligatures form + feature
    // toggles take effect. It loads the font via a blob (no Freetype) and only
    // links HarfBuzz, so unlike the GL offscreen proof it builds AND runs in this
    // environment. Pass a ligature font: `zig build shape-proof -- <font.ttf>`.
    const shape_proof = b.addExecutable(.{
        .name = "shape-proof",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/shape_proof.zig"),
            .target = native_target,
            .optimize = optimize,
        }),
    });
    shape_proof.root_module.link_libc = true;
    const shape_step = b.step("shape-proof", "Standalone HarfBuzz shaping proof (#79)");
    if (linkHarfbuzz(b, shape_proof.root_module, native_target, optimize, null)) {
        const shape_run = b.addRunArtifact(shape_proof);
        if (b.args) |args| shape_run.addArgs(args);
        shape_step.dependOn(&shape_run.step);
    }
}

/// Build HarfBuzz from its amalgam (`src/harfbuzz.cc`) as a static library and
/// link it into `mod`. When `freetype_dep` is non-null, HarfBuzz is built with
/// the FreeType glyph functions (the renderer path); when null, it uses its own
/// OpenType glyph functions (the `shape-proof` path — no FreeType needed).
/// Returns false if the (lazy) HarfBuzz source isn't fetched yet, so the caller
/// can skip wiring the run step until Zig refetches.
fn linkHarfbuzz(
    b: *std.Build,
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    freetype_dep: ?*std.Build.Dependency,
) bool {
    const upstream = b.lazyDependency("harfbuzz", .{}) orelse return false;

    const lib = b.addLibrary(.{
        .name = "harfbuzz",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
    });
    lib.linkLibC();
    lib.linkLibCpp();

    var flags: std.ArrayList([]const u8) = .empty;
    defer flags.deinit(b.allocator);
    flags.appendSlice(b.allocator, &.{"-DHAVE_STDBOOL_H"}) catch @panic("OOM");
    if (target.result.os.tag != .windows) {
        flags.appendSlice(b.allocator, &.{
            "-DHAVE_UNISTD_H",
            "-DHAVE_SYS_MMAN_H",
            "-DHAVE_PTHREAD=1",
        }) catch @panic("OOM");
    }

    if (freetype_dep) |ft| {
        flags.appendSlice(b.allocator, &.{
            "-DHAVE_FREETYPE=1",
            // Assume a recent Freetype (the pinned one is 2.14.x).
            "-DHAVE_FT_GET_VAR_BLEND_COORDINATES=1",
            "-DHAVE_FT_SET_VAR_BLEND_COORDINATES=1",
            "-DHAVE_FT_DONE_MM_VAR=1",
            "-DHAVE_FT_GET_TRANSFORM=1",
        }) catch @panic("OOM");
        // Link the compiled Freetype and put its headers on HarfBuzz's include
        // path so `hb-ft.cc` finds <ft2build.h>.
        lib.linkLibrary(ft.artifact("freetype"));
        lib.addIncludePath(ft.builder.dependency("freetype", .{}).path("include"));
    }

    lib.addIncludePath(upstream.path("src"));
    lib.addCSourceFile(.{
        .file = upstream.path("src/harfbuzz.cc"),
        .flags = flags.items,
    });

    mod.linkLibrary(lib);
    return true;
}
