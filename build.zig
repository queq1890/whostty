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

    const exe = b.addExecutable(.{
        .name = "whostty",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("ghostty-vt", ghostty_vt);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run whostty");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
}
