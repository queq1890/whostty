//! whostty entrypoint.
//!
//! Bootstrap/slice-0 stage. On Windows it drives the ConPTY pty layer; on other
//! hosts (used for cross-compiling checks and host-side unit tests) it falls
//! back to a libghostty-vt wiring demo. The full Win32 apprt + renderer are
//! tracked as slice-0 work (see the repo issues and PORTING.md).
const std = @import("std");
const builtin = @import("builtin");
const vt = @import("ghostty-vt");
const cli = @import("cli.zig");

const version_string = "whostty 0.0.0 (ghostty v1.3.1, libghostty-vt)";

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // argsAlloc returns [][:0]u8; re-view it as []const []const u8 for the parser.
    const argv = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, argv);
    const args = try alloc.alloc([]const u8, argv.len);
    defer alloc.free(args);
    for (argv, 0..) |a, i| args[i] = a;

    var opts = try cli.parse(alloc, args[1..]);
    defer opts.deinit();

    switch (opts.action) {
        .help => return printHelp(),
        .version => return printVersion(),
        .run => {},
    }

    if (comptime builtin.os.tag == .windows) {
        return @import("apprt/win32/App.zig").run(alloc, opts);
    }
    return runVtDemo();
}

fn printVersion() !void {
    var buf: [256]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);
    const out = &stdout.interface;
    try out.print("{s}\n", .{version_string});
    try out.flush();
}

fn printHelp() !void {
    const help =
        \\Usage: whostty [options] [-e command [args...]]
        \\
        \\Launch the whostty terminal.
        \\
        \\Options:
        \\  -e <command...>    Run <command> instead of the default shell.
        \\  --<key>=<value>    Set a config option (same keys as the config file,
        \\                     e.g. --font-size=14 --background=#101010). May also
        \\                     be written as --<key> <value>.
        \\  --help, -h         Show this help.
        \\  --version, -V      Show the version.
        \\
        \\Config file: %APPDATA%\whostty\config
        \\
    ;
    var buf: [1024]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);
    const out = &stdout.interface;
    try out.writeAll(help);
    try out.flush();
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
    _ = @import("input/Binding.zig");
    _ = @import("apprt/win32/keymap.zig");
    _ = @import("os/windows.zig");
    _ = @import("mouse.zig");
    _ = @import("cli.zig");
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
