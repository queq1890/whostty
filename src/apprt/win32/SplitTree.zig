//! whostty: surface split tree (tabs / splits surface management).
//!
//! Reference: ghostty's apprt split handling (e.g. `src/apprt/gtk` split
//! paneling) (strategy: template — Win32 has no 1:1 counterpart, so ghostty is
//! only a structural reference). This models a single tab's surfaces as a
//! binary split tree: each leaf is a surface, each branch splits its area
//! horizontally or vertically at a ratio. The tree is pure data + geometry so
//! it is host-testable independently of the Win32 window and libghostty-vt;
//! the app layer maps the computed rects onto child surfaces. See PORTING.md.
const std = @import("std");

/// Split direction. `horizontal` places children left/right (a vertical
/// divider); `vertical` places them top/bottom (a horizontal divider). This
/// matches the common terminal convention (ghostty's `right`/`down`).
pub const Dir = enum { horizontal, vertical };

/// A pixel rectangle.
pub const Rect = struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,
};

/// A surface identifier. Opaque to the tree; assigned by the caller.
pub const SurfaceId = u32;

/// A node is either a leaf (one surface) or a split of two child nodes.
pub const Node = union(enum) {
    leaf: SurfaceId,
    split: Split,
};

pub const Split = struct {
    dir: Dir,
    /// Fraction of the parent extent given to child `a` (0..1).
    ratio: f32,
    a: *Node,
    b: *Node,
};

/// A placed surface produced by `layout`.
pub const Placement = struct {
    surface: SurfaceId,
    rect: Rect,
};

pub const Error = error{
    /// The surface id was not found in the tree.
    NotFound,
    /// Closing would remove the last remaining surface.
    LastSurface,
};

/// A split tree owning its nodes. One instance corresponds to one tab.
pub const SplitTree = struct {
    alloc: std.mem.Allocator,
    root: *Node,

    /// Create a tree with a single surface.
    pub fn init(alloc: std.mem.Allocator, first: SurfaceId) !SplitTree {
        const root = try alloc.create(Node);
        root.* = .{ .leaf = first };
        return .{ .alloc = alloc, .root = root };
    }

    pub fn deinit(self: *SplitTree) void {
        freeNode(self.alloc, self.root);
        self.* = undefined;
    }

    fn freeNode(alloc: std.mem.Allocator, node: *Node) void {
        switch (node.*) {
            .leaf => {},
            .split => |s| {
                freeNode(alloc, s.a);
                freeNode(alloc, s.b);
            },
        }
        alloc.destroy(node);
    }

    /// Split the leaf holding `target`, replacing it with a split whose first
    /// child keeps `target` and whose second child is the new surface `new`.
    pub fn split(self: *SplitTree, target: SurfaceId, dir: Dir, ratio: f32, new: SurfaceId) !void {
        const node = findLeaf(self.root, target) orelse return Error.NotFound;

        const a = try self.alloc.create(Node);
        errdefer self.alloc.destroy(a);
        const b = try self.alloc.create(Node);

        a.* = .{ .leaf = target };
        b.* = .{ .leaf = new };
        node.* = .{ .split = .{
            .dir = dir,
            .ratio = std.math.clamp(ratio, 0.05, 0.95),
            .a = a,
            .b = b,
        } };
    }

    /// Close the surface `target`, promoting its sibling subtree in place.
    pub fn close(self: *SplitTree, target: SurfaceId) !void {
        // Closing the root leaf removes the last surface.
        switch (self.root.*) {
            .leaf => |id| return if (id == target) Error.LastSurface else Error.NotFound,
            .split => {},
        }

        // Find the split node one of whose direct children is the target leaf.
        const parent = findParentOfLeaf(self.root, target) orelse return Error.NotFound;
        const s = parent.split;

        const removed, const sibling = if (isLeafWith(s.a, target))
            .{ s.a, s.b }
        else
            .{ s.b, s.a };

        // Promote the sibling into the parent slot, then free the removed leaf
        // and the now-empty sibling shell.
        freeNode(self.alloc, removed);
        parent.* = sibling.*;
        self.alloc.destroy(sibling);
    }

    /// Compute the rect for every surface within `area`, in left-to-right,
    /// depth-first order. Appended to `out`.
    pub fn layout(self: *const SplitTree, out: *std.ArrayList(Placement), alloc: std.mem.Allocator, area: Rect) !void {
        try layoutNode(self.root, out, alloc, area);
    }

    fn layoutNode(node: *const Node, out: *std.ArrayList(Placement), alloc: std.mem.Allocator, area: Rect) !void {
        switch (node.*) {
            .leaf => |id| try out.append(alloc, .{ .surface = id, .rect = area }),
            .split => |s| {
                const a_area, const b_area = divide(area, s.dir, s.ratio);
                try layoutNode(s.a, out, alloc, a_area);
                try layoutNode(s.b, out, alloc, b_area);
            },
        }
    }

    /// Number of surfaces (leaves) in the tree.
    pub fn count(self: *const SplitTree) usize {
        return countLeaves(self.root);
    }

    /// True if `target` is present.
    pub fn contains(self: *const SplitTree, target: SurfaceId) bool {
        return findLeaf(self.root, target) != null;
    }
};

/// Split `area` into two along `dir` at `ratio`, allotting `ratio` to the
/// first child. The split consumes no pixels itself (a divider can be drawn on
/// top by the app). The second child takes the remainder so no pixels are lost
/// to rounding.
fn divide(area: Rect, dir: Dir, ratio: f32) struct { Rect, Rect } {
    switch (dir) {
        .horizontal => {
            const aw: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(area.w)) * ratio));
            return .{
                .{ .x = area.x, .y = area.y, .w = aw, .h = area.h },
                .{ .x = area.x + @as(i32, @intCast(aw)), .y = area.y, .w = area.w - aw, .h = area.h },
            };
        },
        .vertical => {
            const ah: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(area.h)) * ratio));
            return .{
                .{ .x = area.x, .y = area.y, .w = area.w, .h = ah },
                .{ .x = area.x, .y = area.y + @as(i32, @intCast(ah)), .w = area.w, .h = area.h - ah },
            };
        },
    }
}

fn isLeafWith(node: *const Node, target: SurfaceId) bool {
    return switch (node.*) {
        .leaf => |id| id == target,
        .split => false,
    };
}

/// Find the leaf node holding `target`, or null.
fn findLeaf(node: *Node, target: SurfaceId) ?*Node {
    return switch (node.*) {
        .leaf => |id| if (id == target) node else null,
        .split => |s| findLeaf(s.a, target) orelse findLeaf(s.b, target),
    };
}

/// Find the split node one of whose direct children is the leaf `target`.
fn findParentOfLeaf(node: *Node, target: SurfaceId) ?*Node {
    switch (node.*) {
        .leaf => return null,
        .split => |s| {
            if (isLeafWith(s.a, target) or isLeafWith(s.b, target)) return node;
            return findParentOfLeaf(s.a, target) orelse findParentOfLeaf(s.b, target);
        },
    }
}

fn countLeaves(node: *const Node) usize {
    return switch (node.*) {
        .leaf => 1,
        .split => |s| countLeaves(s.a) + countLeaves(s.b),
    };
}

test "split tree: single surface lays out over the whole area" {
    const alloc = std.testing.allocator;
    var tree = try SplitTree.init(alloc, 1);
    defer tree.deinit();

    var out: std.ArrayList(Placement) = .empty;
    defer out.deinit(alloc);
    try tree.layout(&out, alloc, .{ .x = 0, .y = 0, .w = 800, .h = 600 });

    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqual(@as(SurfaceId, 1), out.items[0].surface);
    try std.testing.expectEqual(@as(u32, 800), out.items[0].rect.w);
    try std.testing.expectEqual(@as(u32, 600), out.items[0].rect.h);
}

test "split tree: horizontal split divides width, no pixels lost" {
    const alloc = std.testing.allocator;
    var tree = try SplitTree.init(alloc, 1);
    defer tree.deinit();
    try tree.split(1, .horizontal, 0.5, 2);
    try std.testing.expectEqual(@as(usize, 2), tree.count());

    var out: std.ArrayList(Placement) = .empty;
    defer out.deinit(alloc);
    try tree.layout(&out, alloc, .{ .x = 0, .y = 0, .w = 801, .h = 600 });

    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    // First child keeps the original surface on the left.
    try std.testing.expectEqual(@as(SurfaceId, 1), out.items[0].surface);
    try std.testing.expectEqual(@as(i32, 0), out.items[0].rect.x);
    // Second child abuts it and the widths cover the full area exactly.
    try std.testing.expectEqual(@as(SurfaceId, 2), out.items[1].surface);
    try std.testing.expectEqual(out.items[0].rect.w, @as(u32, @intCast(out.items[1].rect.x)));
    try std.testing.expectEqual(@as(u32, 801), out.items[0].rect.w + out.items[1].rect.w);
    // Both keep full height for a horizontal split.
    try std.testing.expectEqual(@as(u32, 600), out.items[0].rect.h);
    try std.testing.expectEqual(@as(u32, 600), out.items[1].rect.h);
}

test "split tree: vertical split divides height" {
    const alloc = std.testing.allocator;
    var tree = try SplitTree.init(alloc, 1);
    defer tree.deinit();
    try tree.split(1, .vertical, 0.25, 2);

    var out: std.ArrayList(Placement) = .empty;
    defer out.deinit(alloc);
    try tree.layout(&out, alloc, .{ .x = 0, .y = 0, .w = 400, .h = 400 });

    // ratio 0.25 -> top child gets 100, bottom 300; widths unchanged.
    try std.testing.expectEqual(@as(u32, 100), out.items[0].rect.h);
    try std.testing.expectEqual(@as(i32, 100), out.items[1].rect.y);
    try std.testing.expectEqual(@as(u32, 300), out.items[1].rect.h);
    try std.testing.expectEqual(@as(u32, 400), out.items[0].rect.w);
}

test "split tree: nested split produces three surfaces" {
    const alloc = std.testing.allocator;
    var tree = try SplitTree.init(alloc, 1);
    defer tree.deinit();
    try tree.split(1, .horizontal, 0.5, 2);
    try tree.split(2, .vertical, 0.5, 3); // split the right pane top/bottom

    try std.testing.expectEqual(@as(usize, 3), tree.count());
    try std.testing.expect(tree.contains(3));

    var out: std.ArrayList(Placement) = .empty;
    defer out.deinit(alloc);
    try tree.layout(&out, alloc, .{ .x = 0, .y = 0, .w = 800, .h = 600 });
    try std.testing.expectEqual(@as(usize, 3), out.items.len);
    // Left pane unchanged at half width, full height.
    try std.testing.expectEqual(@as(SurfaceId, 1), out.items[0].surface);
    try std.testing.expectEqual(@as(u32, 400), out.items[0].rect.w);
    try std.testing.expectEqual(@as(u32, 600), out.items[0].rect.h);
    // Right pane split into two half-height rows.
    try std.testing.expectEqual(@as(u32, 300), out.items[1].rect.h);
    try std.testing.expectEqual(@as(u32, 300), out.items[2].rect.h);
}

test "split tree: close promotes the sibling" {
    const alloc = std.testing.allocator;
    var tree = try SplitTree.init(alloc, 1);
    defer tree.deinit();
    try tree.split(1, .horizontal, 0.5, 2);
    try tree.split(2, .vertical, 0.5, 3);

    // Close surface 3: its sibling (2) takes the right pane back.
    try tree.close(3);
    try std.testing.expectEqual(@as(usize, 2), tree.count());
    try std.testing.expect(!tree.contains(3));

    var out: std.ArrayList(Placement) = .empty;
    defer out.deinit(alloc);
    try tree.layout(&out, alloc, .{ .x = 0, .y = 0, .w = 800, .h = 600 });
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqual(@as(SurfaceId, 2), out.items[1].surface);
    try std.testing.expectEqual(@as(u32, 600), out.items[1].rect.h);
}

test "split tree: close down to one keeps the survivor" {
    const alloc = std.testing.allocator;
    var tree = try SplitTree.init(alloc, 1);
    defer tree.deinit();
    try tree.split(1, .horizontal, 0.5, 2);
    try tree.close(1);
    try std.testing.expectEqual(@as(usize, 1), tree.count());
    try std.testing.expect(tree.contains(2));
    try std.testing.expect(!tree.contains(1));
}

test "split tree: error cases" {
    const alloc = std.testing.allocator;
    var tree = try SplitTree.init(alloc, 1);
    defer tree.deinit();

    try std.testing.expectError(Error.LastSurface, tree.close(1));
    try std.testing.expectError(Error.NotFound, tree.close(99));
    try std.testing.expectError(Error.NotFound, tree.split(99, .horizontal, 0.5, 2));
}
