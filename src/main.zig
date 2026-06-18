//! whostty entrypoint.
//!
//! Bootstrap/slice-0 stage. On Windows it drives the ConPTY pty layer; on other
//! hosts (used for cross-compiling checks and host-side unit tests) it falls
//! back to a libghostty-vt wiring demo. The full Win32 apprt + renderer are
//! tracked as slice-0 work (see the repo issues and PORTING.md).
const std = @import("std");
const builtin = @import("builtin");
const vt = @import("ghostty-vt");
const Pty = @import("pty.zig").Pty;

// Force analysis (and thus link checking) of the Windows-only modules on
// Windows builds. Full integration is tracked by #11.
comptime {
    if (builtin.os.tag == .windows) {
        const Window = @import("apprt/win32/Window.zig").Window;
        _ = &Window.init;
        _ = &Window.deinit;
        _ = &Window.pump;
        _ = &Window.poll;
        _ = &Window.swapBuffers;
        _ = &Window.clientSize;
        _ = &Window.makeCurrent;
    }
}

pub fn main() !void {
    if (comptime builtin.os.tag == .windows) {
        return runConpty();
    }
    return runVtDemo();
}

/// Windows: open a ConPTY, spawn a shell, and pump its output through
/// libghostty-vt, dumping the resulting grid. A seed for the slice-0
/// integration (see #11).
fn runConpty() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var pty = try Pty.open(.{ .ws_row = 24, .ws_col = 80 });
    defer pty.deinit();

    var child = try pty.spawn(alloc, "cmd.exe /c echo whostty conpty ok");
    defer child.deinit();

    var term = try vt.Terminal.init(alloc, .{ .cols = 80, .rows = 24 });
    defer term.deinit(alloc);

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = pty.read(&buf) catch |err| switch (err) {
            error.Eof => break,
            else => return err,
        };
        try term.printString(buf[0..n]);
    }

    const dump = try term.plainString(alloc);
    defer alloc.free(dump);
    std.debug.print("{s}\n", .{std.mem.trimRight(u8, dump, " \n")});
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
