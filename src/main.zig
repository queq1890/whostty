//! whostty entrypoint.
//!
//! Bootstrap stage: this only proves the libghostty-vt wiring — it constructs a
//! terminal, feeds it bytes, and reads back the grid state. The Win32 apprt,
//! ConPTY, renderer, and font layers are tracked as slice-0 work (see the repo
//! issues and PORTING.md).
const std = @import("std");
const vt = @import("ghostty-vt");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Construct a small terminal and feed it bytes, then read the grid back.
    var term = try vt.Terminal.init(alloc, .{ .cols = 80, .rows = 24 });
    defer term.deinit(alloc);

    try term.printString("whostty: libghostty-vt is wired up.");

    const dump = try term.plainString(alloc);
    defer alloc.free(dump);

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buf);
    const w = &stdout.interface;
    try w.print("{s}\n", .{std.mem.trimRight(u8, dump, " \n")});
    try w.flush();
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
