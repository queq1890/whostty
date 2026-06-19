//! whostty: surface management — split trees and a tab list.
//!
//! Reference: ghostty manages splits per-apprt (e.g. `src/apprt/gtk` drives GTK
//! `Paned` widgets) and tabs via the apprt notebook. Strategy: template — the
//! Win32 apprt has no 1:1 counterpart, so ghostty's split/tab *semantics* are
//! the reference and these models are fresh, host-testable code (see PORTING.md
//! test-porting policy).
//!
//! Two cooperating models live here, both deliberately free of any Windows
//! types so they compile and unit-test on the host:
//!
//!   * `SplitTree` — a binary tree of surfaces. Each leaf is a surface; each
//!     internal node splits its area horizontally or vertically by a ratio.
//!     It owns nothing but the tree shape; surfaces are referred to by an
//!     opaque `SurfaceId` the apprt assigns.
//!   * `TabList` — an ordered set of tabs, each owning a `SplitTree`, with an
//!     active index. The window renders the active tab's layout.
//!
//! Pixel geometry (`layout`) and directional focus (`focusTarget`) are pure
//! functions of the tree, so the apprt can ask "where does each surface go?"
//! and "what's left of here?" without any platform state.
const std = @import("std");

/// An opaque handle to a surface (terminal pane). The apprt assigns these; the
/// tree only ever compares and stores them.
pub const SurfaceId = u32;

/// A rectangle in pixels (or any consistent unit). Origin top-left.
pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
};

/// The direction a new split is placed relative to the focused surface, matching
/// ghostty's `new_split` directions.
pub const Direction = enum {
    left,
    right,
    up,
    down,

    /// The split axis this direction implies.
    pub fn orientation(self: Direction) Orientation {
        return switch (self) {
            .left, .right => .horizontal,
            .up, .down => .vertical,
        };
    }

    /// Whether the *new* surface becomes the second child (right/bottom). For
    /// `right`/`down` the new pane follows the existing one; for `left`/`up` it
    /// precedes it.
    fn newIsSecond(self: Direction) bool {
        return switch (self) {
            .right, .down => true,
            .left, .up => false,
        };
    }
};

/// A split's axis. `horizontal` divides space left/right; `vertical` divides it
/// top/bottom.
pub const Orientation = enum { horizontal, vertical };

/// A tree node: either a leaf surface or an internal split of two children.
pub const Node = union(enum) {
    leaf: SurfaceId,
    split: Split,
};

/// An internal split node. `a` is the left/top child, `b` the right/bottom one.
/// `ratio` is the fraction of the parent's space given to `a`, in (0, 1).
pub const Split = struct {
    orientation: Orientation,
    ratio: f32 = 0.5,
    a: *Node,
    b: *Node,
};

/// The result of laying a tree out over a bounding rect: one entry per surface.
pub const Placement = struct {
    surface: SurfaceId,
    rect: Rect,
};

/// A binary tree of surfaces. Owns its `Node` allocations.
pub const SplitTree = struct {
    alloc: std.mem.Allocator,
    root: *Node,

    /// Create a tree holding a single surface.
    pub fn init(alloc: std.mem.Allocator, root_surface: SurfaceId) !SplitTree {
        const node = try alloc.create(Node);
        node.* = .{ .leaf = root_surface };
        return .{ .alloc = alloc, .root = node };
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

    /// The number of surfaces (leaves) in the tree.
    pub fn count(self: *const SplitTree) usize {
        return countNode(self.root);
    }

    fn countNode(node: *const Node) usize {
        return switch (node.*) {
            .leaf => 1,
            .split => |s| countNode(s.a) + countNode(s.b),
        };
    }

    /// Whether `surface` is present in the tree.
    pub fn contains(self: *const SplitTree, surface: SurfaceId) bool {
        return findLeaf(self.root, surface) != null;
    }

    fn findLeaf(node: *Node, surface: SurfaceId) ?*Node {
        return switch (node.*) {
            .leaf => |id| if (id == surface) node else null,
            .split => |s| findLeaf(s.a, surface) orelse findLeaf(s.b, surface),
        };
    }

    fn isLeafWith(node: *const Node, surface: SurfaceId) bool {
        return switch (node.*) {
            .leaf => |id| id == surface,
            .split => false,
        };
    }

    /// Split the pane holding `surface` in `dir`, placing `new_surface` in the
    /// freshly created half. The existing surface keeps its content; both halves
    /// start at an equal ratio. Errors if `surface` isn't in the tree.
    pub fn split(
        self: *SplitTree,
        surface: SurfaceId,
        dir: Direction,
        new_surface: SurfaceId,
    ) !void {
        const target = findLeaf(self.root, surface) orelse return error.SurfaceNotFound;

        // Move the existing leaf into a new child node, mint the new pane, then
        // turn the target node into the split that holds both.
        const existing = try self.alloc.create(Node);
        errdefer self.alloc.destroy(existing);
        existing.* = .{ .leaf = surface };
        const fresh = try self.alloc.create(Node);
        fresh.* = .{ .leaf = new_surface };

        const new_second = dir.newIsSecond();
        target.* = .{ .split = .{
            .orientation = dir.orientation(),
            .ratio = 0.5,
            .a = if (new_second) existing else fresh,
            .b = if (new_second) fresh else existing,
        } };
    }

    /// Close the pane holding `surface`; its sibling subtree takes over the
    /// parent's space. Errors if `surface` is absent or is the last pane (the
    /// caller closes the tab/window instead).
    pub fn close(self: *SplitTree, surface: SurfaceId) !void {
        switch (self.root.*) {
            .leaf => |id| return if (id == surface) error.CannotCloseLast else error.SurfaceNotFound,
            .split => {},
        }

        const parent = findParent(self.root, surface) orelse return error.SurfaceNotFound;
        const s = switch (parent.*) {
            .split => |sp| sp,
            .leaf => unreachable,
        };

        const close_is_a = isLeafWith(s.a, surface);
        const keep = if (close_is_a) s.b else s.a;
        const drop = if (close_is_a) s.a else s.b;

        // Pull the kept subtree up into the parent node, then free the closed
        // leaf and the now-empty kept-child shell (its children moved by value).
        const keep_contents = keep.*;
        freeNode(self.alloc, drop);
        parent.* = keep_contents;
        self.alloc.destroy(keep);
    }

    fn findParent(node: *Node, surface: SurfaceId) ?*Node {
        switch (node.*) {
            .leaf => return null,
            .split => |s| {
                if (isLeafWith(s.a, surface) or isLeafWith(s.b, surface)) return node;
                return findParent(s.a, surface) orelse findParent(s.b, surface);
            },
        }
    }

    /// Reset every split to an equal (0.5) ratio.
    pub fn equalize(self: *SplitTree) void {
        equalizeNode(self.root);
    }

    fn equalizeNode(node: *Node) void {
        switch (node.*) {
            .leaf => {},
            .split => |*s| {
                s.ratio = 0.5;
                equalizeNode(s.a);
                equalizeNode(s.b);
            },
        }
    }

    /// Compute the rect for every surface within `bounds`, appending a
    /// `Placement` per leaf to `out` (in left-to-right, top-to-bottom tree
    /// order).
    pub fn layout(
        self: *const SplitTree,
        bounds: Rect,
        alloc: std.mem.Allocator,
        out: *std.ArrayList(Placement),
    ) !void {
        try layoutNode(self.root, bounds, alloc, out);
    }

    fn layoutNode(
        node: *const Node,
        bounds: Rect,
        alloc: std.mem.Allocator,
        out: *std.ArrayList(Placement),
    ) !void {
        switch (node.*) {
            .leaf => |id| try out.append(alloc, .{ .surface = id, .rect = bounds }),
            .split => |s| switch (s.orientation) {
                .horizontal => {
                    const aw = bounds.width * s.ratio;
                    try layoutNode(s.a, .{
                        .x = bounds.x,
                        .y = bounds.y,
                        .width = aw,
                        .height = bounds.height,
                    }, alloc, out);
                    try layoutNode(s.b, .{
                        .x = bounds.x + aw,
                        .y = bounds.y,
                        .width = bounds.width - aw,
                        .height = bounds.height,
                    }, alloc, out);
                },
                .vertical => {
                    const ah = bounds.height * s.ratio;
                    try layoutNode(s.a, .{
                        .x = bounds.x,
                        .y = bounds.y,
                        .width = bounds.width,
                        .height = ah,
                    }, alloc, out);
                    try layoutNode(s.b, .{
                        .x = bounds.x,
                        .y = bounds.y + ah,
                        .width = bounds.width,
                        .height = bounds.height - ah,
                    }, alloc, out);
                },
            },
        }
    }

    /// The surface that should receive focus when moving `dir` from `current`,
    /// computed from the laid-out geometry: the nearest pane whose center lies
    /// in that direction and whose perpendicular span overlaps `current`.
    /// Returns null when there's no pane that way.
    pub fn focusTarget(
        self: *const SplitTree,
        current: SurfaceId,
        dir: Direction,
        bounds: Rect,
        alloc: std.mem.Allocator,
    ) !?SurfaceId {
        var list: std.ArrayList(Placement) = .empty;
        defer list.deinit(alloc);
        try self.layout(bounds, alloc, &list);

        var cur: ?Rect = null;
        for (list.items) |p| {
            if (p.surface == current) cur = p.rect;
        }
        const c = cur orelse return error.SurfaceNotFound;
        const c_cx = c.x + c.width / 2;
        const c_cy = c.y + c.height / 2;

        var best: ?SurfaceId = null;
        var best_dist: f32 = std.math.floatMax(f32);
        for (list.items) |p| {
            if (p.surface == current) continue;
            const cx = p.rect.x + p.rect.width / 2;
            const cy = p.rect.y + p.rect.height / 2;

            const in_dir = switch (dir) {
                .left => cx < c_cx and overlap1d(p.rect.y, p.rect.height, c.y, c.height),
                .right => cx > c_cx and overlap1d(p.rect.y, p.rect.height, c.y, c.height),
                .up => cy < c_cy and overlap1d(p.rect.x, p.rect.width, c.x, c.width),
                .down => cy > c_cy and overlap1d(p.rect.x, p.rect.width, c.x, c.width),
            };
            if (!in_dir) continue;

            const dist = switch (dir) {
                .left, .right => @abs(cx - c_cx),
                .up, .down => @abs(cy - c_cy),
            };
            if (dist < best_dist) {
                best_dist = dist;
                best = p.surface;
            }
        }
        return best;
    }

    fn overlap1d(a_start: f32, a_len: f32, b_start: f32, b_len: f32) bool {
        return a_start < b_start + b_len and b_start < a_start + a_len;
    }
};

/// An ordered list of tabs, each owning a `SplitTree`, with one active tab.
pub const TabList = struct {
    alloc: std.mem.Allocator,
    tabs: std.ArrayList(SplitTree) = .empty,
    active: usize = 0,

    pub fn init(alloc: std.mem.Allocator) TabList {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *TabList) void {
        for (self.tabs.items) |*t| t.deinit();
        self.tabs.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn count(self: *const TabList) usize {
        return self.tabs.items.len;
    }

    /// Append a new tab whose tree holds `root_surface`, make it active, and
    /// return its index.
    pub fn addTab(self: *TabList, root_surface: SurfaceId) !usize {
        const tree = try SplitTree.init(self.alloc, root_surface);
        try self.tabs.append(self.alloc, tree);
        self.active = self.tabs.items.len - 1;
        return self.active;
    }

    /// The active tab's tree, or null when there are no tabs.
    pub fn activeTree(self: *TabList) ?*SplitTree {
        if (self.tabs.items.len == 0) return null;
        return &self.tabs.items[self.active];
    }

    /// Close the active tab. The active index clamps to the previous tab (so it
    /// stays in range). Returns false when no tab remained to close.
    pub fn closeActiveTab(self: *TabList) bool {
        if (self.tabs.items.len == 0) return false;
        var removed = self.tabs.orderedRemove(self.active);
        removed.deinit();
        if (self.active >= self.tabs.items.len and self.active > 0) {
            self.active = self.tabs.items.len - 1;
        }
        return true;
    }

    /// Activate the next tab, wrapping around.
    pub fn nextTab(self: *TabList) void {
        if (self.tabs.items.len == 0) return;
        self.active = (self.active + 1) % self.tabs.items.len;
    }

    /// Activate the previous tab, wrapping around.
    pub fn prevTab(self: *TabList) void {
        if (self.tabs.items.len == 0) return;
        self.active = (self.active + self.tabs.items.len - 1) % self.tabs.items.len;
    }

    /// Activate the tab at `index` if it's in range.
    pub fn activate(self: *TabList, index: usize) void {
        if (index < self.tabs.items.len) self.active = index;
    }
};

const testing = std.testing;

test "SplitTree: single surface lays out over the whole bounds" {
    var tree = try SplitTree.init(testing.allocator, 1);
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 1), tree.count());
    try testing.expect(tree.contains(1));
    try testing.expect(!tree.contains(2));

    var out: std.ArrayList(Placement) = .empty;
    defer out.deinit(testing.allocator);
    try tree.layout(.{ .width = 800, .height = 600 }, testing.allocator, &out);

    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(@as(SurfaceId, 1), out.items[0].surface);
    try testing.expectEqual(@as(f32, 800), out.items[0].rect.width);
    try testing.expectEqual(@as(f32, 600), out.items[0].rect.height);
}

test "SplitTree: horizontal split places new pane on the right" {
    var tree = try SplitTree.init(testing.allocator, 1);
    defer tree.deinit();
    try tree.split(1, .right, 2);

    try testing.expectEqual(@as(usize, 2), tree.count());
    try testing.expect(tree.contains(2));

    var out: std.ArrayList(Placement) = .empty;
    defer out.deinit(testing.allocator);
    try tree.layout(.{ .width = 800, .height = 600 }, testing.allocator, &out);

    try testing.expectEqual(@as(usize, 2), out.items.len);
    // Existing pane keeps the left half.
    try testing.expectEqual(@as(SurfaceId, 1), out.items[0].surface);
    try testing.expectEqual(@as(f32, 0), out.items[0].rect.x);
    try testing.expectEqual(@as(f32, 400), out.items[0].rect.width);
    // New pane gets the right half.
    try testing.expectEqual(@as(SurfaceId, 2), out.items[1].surface);
    try testing.expectEqual(@as(f32, 400), out.items[1].rect.x);
    try testing.expectEqual(@as(f32, 400), out.items[1].rect.width);
    try testing.expectEqual(@as(f32, 600), out.items[1].rect.height);
}

test "SplitTree: split left puts the new pane first" {
    var tree = try SplitTree.init(testing.allocator, 1);
    defer tree.deinit();
    try tree.split(1, .left, 2);

    var out: std.ArrayList(Placement) = .empty;
    defer out.deinit(testing.allocator);
    try tree.layout(.{ .width = 800, .height = 600 }, testing.allocator, &out);

    try testing.expectEqual(@as(SurfaceId, 2), out.items[0].surface);
    try testing.expectEqual(@as(f32, 0), out.items[0].rect.x);
    try testing.expectEqual(@as(SurfaceId, 1), out.items[1].surface);
    try testing.expectEqual(@as(f32, 400), out.items[1].rect.x);
}

test "SplitTree: vertical split divides height" {
    var tree = try SplitTree.init(testing.allocator, 1);
    defer tree.deinit();
    try tree.split(1, .down, 2);

    var out: std.ArrayList(Placement) = .empty;
    defer out.deinit(testing.allocator);
    try tree.layout(.{ .width = 800, .height = 600 }, testing.allocator, &out);

    try testing.expectEqual(@as(f32, 0), out.items[0].rect.y);
    try testing.expectEqual(@as(f32, 300), out.items[0].rect.height);
    try testing.expectEqual(@as(f32, 300), out.items[1].rect.y);
    try testing.expectEqual(@as(f32, 300), out.items[1].rect.height);
    try testing.expectEqual(@as(f32, 800), out.items[1].rect.width);
}

test "SplitTree: nested splits compose" {
    var tree = try SplitTree.init(testing.allocator, 1);
    defer tree.deinit();
    try tree.split(1, .right, 2); // [1 | 2]
    try tree.split(2, .down, 3); // [1 | (2 over 3)]

    try testing.expectEqual(@as(usize, 3), tree.count());

    var out: std.ArrayList(Placement) = .empty;
    defer out.deinit(testing.allocator);
    try tree.layout(.{ .width = 800, .height = 600 }, testing.allocator, &out);

    try testing.expectEqual(@as(usize, 3), out.items.len);
    // Pane 1 still owns the left half full-height.
    try testing.expectEqual(@as(SurfaceId, 1), out.items[0].surface);
    try testing.expectEqual(@as(f32, 400), out.items[0].rect.width);
    try testing.expectEqual(@as(f32, 600), out.items[0].rect.height);
    // Panes 2 and 3 split the right half top/bottom.
    try testing.expectEqual(@as(SurfaceId, 2), out.items[1].surface);
    try testing.expectEqual(@as(f32, 400), out.items[1].rect.x);
    try testing.expectEqual(@as(f32, 300), out.items[1].rect.height);
    try testing.expectEqual(@as(SurfaceId, 3), out.items[2].surface);
    try testing.expectEqual(@as(f32, 300), out.items[2].rect.y);
}

test "SplitTree: closing a pane collapses the split" {
    var tree = try SplitTree.init(testing.allocator, 1);
    defer tree.deinit();
    try tree.split(1, .right, 2);
    try tree.split(2, .down, 3); // [1 | (2 over 3)]

    try tree.close(2); // right half becomes just pane 3

    try testing.expectEqual(@as(usize, 2), tree.count());
    try testing.expect(!tree.contains(2));

    var out: std.ArrayList(Placement) = .empty;
    defer out.deinit(testing.allocator);
    try tree.layout(.{ .width = 800, .height = 600 }, testing.allocator, &out);

    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqual(@as(SurfaceId, 1), out.items[0].surface);
    try testing.expectEqual(@as(SurfaceId, 3), out.items[1].surface);
    // Pane 3 now owns the full right half.
    try testing.expectEqual(@as(f32, 400), out.items[1].rect.x);
    try testing.expectEqual(@as(f32, 400), out.items[1].rect.width);
    try testing.expectEqual(@as(f32, 600), out.items[1].rect.height);
}

test "SplitTree: cannot close the last pane" {
    var tree = try SplitTree.init(testing.allocator, 1);
    defer tree.deinit();
    try testing.expectError(error.CannotCloseLast, tree.close(1));
    try testing.expectError(error.SurfaceNotFound, tree.close(9));
}

test "SplitTree: split of a missing surface errors" {
    var tree = try SplitTree.init(testing.allocator, 1);
    defer tree.deinit();
    try testing.expectError(error.SurfaceNotFound, tree.split(9, .right, 2));
}

test "SplitTree: equalize resets ratios" {
    var tree = try SplitTree.init(testing.allocator, 1);
    defer tree.deinit();
    try tree.split(1, .right, 2);
    // Skew the ratio, then equalize.
    switch (tree.root.*) {
        .split => |*s| s.ratio = 0.8,
        .leaf => unreachable,
    }
    tree.equalize();

    var out: std.ArrayList(Placement) = .empty;
    defer out.deinit(testing.allocator);
    try tree.layout(.{ .width = 800, .height = 600 }, testing.allocator, &out);
    try testing.expectEqual(@as(f32, 400), out.items[0].rect.width);
}

test "SplitTree: focusTarget moves between panes" {
    var tree = try SplitTree.init(testing.allocator, 1);
    defer tree.deinit();
    try tree.split(1, .right, 2); // [1 | 2]
    try tree.split(2, .down, 3); // [1 | (2 over 3)]

    const bounds: Rect = .{ .width = 800, .height = 600 };

    // From pane 1, moving right reaches the nearest right pane (2, the top one).
    try testing.expectEqual(@as(?SurfaceId, 2), try tree.focusTarget(1, .right, bounds, testing.allocator));
    // From 2, down reaches 3; from 3, up reaches 2.
    try testing.expectEqual(@as(?SurfaceId, 3), try tree.focusTarget(2, .down, bounds, testing.allocator));
    try testing.expectEqual(@as(?SurfaceId, 2), try tree.focusTarget(3, .up, bounds, testing.allocator));
    // From 2, left reaches 1.
    try testing.expectEqual(@as(?SurfaceId, 1), try tree.focusTarget(2, .left, bounds, testing.allocator));
    // Nothing to the left of pane 1.
    try testing.expectEqual(@as(?SurfaceId, null), try tree.focusTarget(1, .left, bounds, testing.allocator));
}

test "TabList: add, switch, and close tabs" {
    var tabs = TabList.init(testing.allocator);
    defer tabs.deinit();

    try testing.expectEqual(@as(usize, 0), tabs.count());
    try testing.expect(tabs.activeTree() == null);

    _ = try tabs.addTab(1);
    _ = try tabs.addTab(2);
    _ = try tabs.addTab(3);
    try testing.expectEqual(@as(usize, 3), tabs.count());
    try testing.expectEqual(@as(usize, 2), tabs.active); // last added is active

    tabs.nextTab(); // wraps to 0
    try testing.expectEqual(@as(usize, 0), tabs.active);
    tabs.prevTab(); // wraps to 2
    try testing.expectEqual(@as(usize, 2), tabs.active);

    tabs.activate(1);
    try testing.expectEqual(@as(usize, 1), tabs.active);

    // The active tree is usable for splits.
    const tree = tabs.activeTree().?;
    try tree.split(2, .right, 9);
    try testing.expectEqual(@as(usize, 2), tree.count());

    try testing.expect(tabs.closeActiveTab());
    try testing.expectEqual(@as(usize, 2), tabs.count());
    // active clamped to last valid index.
    try testing.expect(tabs.active < tabs.count());
}

test "TabList: closing the last remaining tab empties the list" {
    var tabs = TabList.init(testing.allocator);
    defer tabs.deinit();
    _ = try tabs.addTab(1);
    try testing.expect(tabs.closeActiveTab());
    try testing.expectEqual(@as(usize, 0), tabs.count());
    try testing.expect(!tabs.closeActiveTab());
}
