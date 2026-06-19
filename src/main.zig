//! whostty entrypoint.
//!
//! Bootstrap/slice-0 stage. On Windows it drives the ConPTY pty layer; on other
//! hosts (used for cross-compiling checks and host-side unit tests) it falls
//! back to a libghostty-vt wiring demo. The full Win32 apprt + renderer are
//! tracked as slice-0 work (see the repo issues and PORTING.md).
const std = @import("std");
const builtin = @import("builtin");
const vt = @import("ghostty-vt");

pub fn main() !void {
    if (comptime builtin.os.tag == .windows) {
        var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
        defer _ = gpa.deinit();
        return @import("apprt/win32/App.zig").run(gpa.allocator());
    }
    return runVtDemo();
}

/// Non-Windows host: prove the libghostty-vt wiring by feeding bytes and
/// reading the grid back.
fn runVtDemo() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var term = try vt.Terminal.init(alloc, .{ .cols = 80, .rows = 24 });
    defer term.deinit(alloc);

    try term.printString("whostty: libghostty-vt is wired up.");

    const dump = try term.plainString(alloc);
    defer alloc.free(dump);

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buf);
    const out = &stdout.interface;
    try out.print("{s}\n", .{std.mem.trimRight(u8, dump, " \n")});
    try out.flush();
}

test {
    // Pull in host-testable slice-0 modules' tests.
    _ = @import("termio.zig");
    _ = @import("input.zig");
    _ = @import("font/Atlas.zig");
    _ = @import("renderer/OpenGL.zig");
    _ = @import("renderer.zig");
    _ = @import("Surface.zig");
    _ = @import("config.zig");
    _ = @import("scroll.zig");
    _ = @import("apprt/win32/SplitTree.zig");
    _ = @import("font/discovery.zig");
    _ = @import("font/shaper.zig");
    if (@import("build_options").freetype) _ = @import("font/main.zig");
}

test "vt: feed bytes and read back grid state" {
    const alloc = std.testing.allocator;

    var term = try vt.Terminal.init(alloc, .{ .cols = 20, .rows = 3 });
    defer term.deinit(alloc);

    try term.printString("hello");

    const dump = try term.plainString(alloc);
    defer alloc.free(dump);

    try std.testing.expect(std.mem.indexOf(u8, dump, "hello") != null);
}
