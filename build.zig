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

    const build_options = b.addOptions();
    build_options.addOption(bool, "freetype", enable_freetype);

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
        if (b.lazyDependency("freetype", .{ .target = target, .optimize = optimize })) |dep| {
            exe.root_module.addImport("freetype", dep.module("freetype"));
            // The freetype module's `@cImport` pulls in libc headers (e.g.
            // <string.h>). Link libc so they resolve — for cross-compiled
            // Windows targets this is satisfied by Zig's bundled MinGW.
            exe.root_module.link_libc = true;
            // The module only provides the Zig bindings; link the compiled
            // freetype C library so the FT_* symbols resolve.
            exe.root_module.linkLibrary(dep.artifact("freetype"));
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
    if (b.lazyDependency("freetype", .{ .target = native_target, .optimize = optimize })) |dep| {
        offscreen.root_module.addImport("freetype", dep.module("freetype"));
        offscreen.root_module.linkLibrary(dep.artifact("freetype"));
        const off_run = b.addRunArtifact(offscreen);
        off_step.dependOn(&off_run.step);
    }
}
