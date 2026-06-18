//! whostty: a single-channel (8-bit alpha) glyph atlas with shelf packing.
//!
//! Reference: ghostty `src/font/Atlas.zig` (strategy: port — slice-0 uses a
//! simple shelf packer, no rebalancing/growth beyond the fixed size; enough for
//! monospace ASCII). See PORTING.md.
const std = @import("std");
const Atlas = @This();

/// Region reserved for a glyph, in texel coordinates.
pub const Region = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

pub const Error = error{AtlasFull};

/// Square, single-channel pixel store (row-major, 1 byte per texel).
data: []u8,
size: u32,

// Shelf-packing cursor.
cursor_x: u32 = 0,
cursor_y: u32 = 0,
shelf_height: u32 = 0,

/// 1px padding between glyphs to avoid sampling bleed.
const padding: u32 = 1;

pub fn init(alloc: std.mem.Allocator, size: u32) !Atlas {
    const data = try alloc.alloc(u8, size * size);
    @memset(data, 0);
    return .{ .data = data, .size = size };
}

pub fn deinit(self: *Atlas, alloc: std.mem.Allocator) void {
    alloc.free(self.data);
    self.* = undefined;
}

/// Reserve a region of the given size, advancing the shelf cursor.
pub fn reserve(self: *Atlas, width: u32, height: u32) Error!Region {
    if (width > self.size or height > self.size) return error.AtlasFull;

    // Move to a new shelf if the current row can't fit the width.
    if (self.cursor_x + width > self.size) {
        self.cursor_y += self.shelf_height + padding;
        self.cursor_x = 0;
        self.shelf_height = 0;
    }
    if (self.cursor_y + height > self.size) return error.AtlasFull;

    const region: Region = .{
        .x = self.cursor_x,
        .y = self.cursor_y,
        .width = width,
        .height = height,
    };

    self.cursor_x += width + padding;
    self.shelf_height = @max(self.shelf_height, height);
    return region;
}

/// Copy a tightly-packed `width*height` coverage bitmap into a region.
pub fn set(self: *Atlas, region: Region, pixels: []const u8) void {
    std.debug.assert(pixels.len == region.width * region.height);
    var row: u32 = 0;
    while (row < region.height) : (row += 1) {
        const dst = (region.y + row) * self.size + region.x;
        @memcpy(self.data[dst..][0..region.width], pixels[row * region.width ..][0..region.width]);
    }
}

test "atlas: reservations stay in bounds and do not overlap on a shelf" {
    const alloc = std.testing.allocator;
    var atlas = try Atlas.init(alloc, 64);
    defer atlas.deinit(alloc);

    const a = try atlas.reserve(10, 12);
    const b = try atlas.reserve(10, 12);
    try std.testing.expect(a.x + a.width <= atlas.size);
    try std.testing.expect(b.x >= a.x + a.width); // packed left-to-right
    try std.testing.expectEqual(@as(u32, 0), a.y);
}

test "atlas: wraps to a new shelf when the row is full" {
    const alloc = std.testing.allocator;
    var atlas = try Atlas.init(alloc, 32);
    defer atlas.deinit(alloc);

    _ = try atlas.reserve(20, 10);
    const wrapped = try atlas.reserve(20, 10); // 20+20 > 32 -> new shelf
    try std.testing.expect(wrapped.y > 0);
    try std.testing.expectEqual(@as(u32, 0), wrapped.x);
}

test "atlas: set writes coverage at the region origin" {
    const alloc = std.testing.allocator;
    var atlas = try Atlas.init(alloc, 16);
    defer atlas.deinit(alloc);

    const r = try atlas.reserve(2, 2);
    atlas.set(r, &[_]u8{ 255, 255, 255, 255 });
    try std.testing.expectEqual(@as(u8, 255), atlas.data[r.y * atlas.size + r.x]);
}

test "atlas: reports full when out of space" {
    const alloc = std.testing.allocator;
    var atlas = try Atlas.init(alloc, 8);
    defer atlas.deinit(alloc);
    try std.testing.expectError(error.AtlasFull, atlas.reserve(9, 9));
}
