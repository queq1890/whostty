//! whostty engine: the apprt-free host vtable (#132, epic E0 #141).
//!
//! Stability: experimental (ADR 0010). Promoted to stable once whomux's host
//! implementation (whomux #13/#23) has driven the shape.
//!
//! The engine model is platform-free, but a live terminal surface still needs a
//! handful of services only the *host* (the windowing app — whostty's own
//! `apprt/win32` today, whomux's Win32 runtime tomorrow) can provide: an OpenGL
//! context to render into, a way to ask for a redraw, the system clipboard, the
//! window title/cursor/IME caret. Rather than the engine reaching into Win32,
//! the host supplies this small vtable and the engine calls back through it.
//!
//! This is the inverse of the import boundary: whomux imports the engine model
//! (`whostty-engine`) AND implements this `Host` so the engine can drive the
//! window it owns — the same cut line as ADR 0002 (engine draws the terminal,
//! host owns the app shell). It is platform-free (only function-pointer types),
//! so it lives in the engine layer and passes the non-Windows boundary check.

const std = @import("std");

/// The pointer shape the surface wants shown, resolved by the host to a native
/// cursor. Mouse-tracking apps and hovered hyperlinks change this; the default
/// is the I-beam over the grid.
pub const CursorShape = enum {
    /// Arrow — used over chrome / when the app hides the text cursor.
    default,
    /// I-beam — the normal text-area pointer.
    text,
    /// Hand — over a hyperlink (OSC 8 / detected URL).
    pointer,
};

/// Services the host supplies to the engine. The host fills in `ctx` (its own
/// state, e.g. the window) and a `*const VTable`; the engine calls the methods
/// below, which forward to the vtable with `ctx`. All calls happen on the
/// surface's owning (UI) thread unless a method says otherwise.
pub const Host = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Ask the host to schedule a repaint of the surface (e.g. Win32
        /// InvalidateRect, or set a dirty flag the frame loop reads). Coalescing
        /// is the host's choice; the engine may call this many times per frame.
        request_redraw: *const fn (ctx: *anyopaque) void,

        /// Make the host's OpenGL context current on the calling thread. Called
        /// before the engine issues GL for this surface.
        make_current: *const fn (ctx: *anyopaque) void,

        /// Present the rendered frame (swap buffers).
        swap_buffers: *const fn (ctx: *anyopaque) void,

        /// Resolve an OpenGL function pointer by name (wglGetProcAddress /
        /// eglGetProcAddress). Null if unavailable.
        gl_proc_address: *const fn (ctx: *anyopaque, name: [*:0]const u8) ?*const anyopaque,

        /// Set the window title (OSC 0/2). The slice is borrowed for the call.
        set_title: *const fn (ctx: *anyopaque, title: []const u8) void,

        /// Set the pointer shape over the surface.
        set_cursor_shape: *const fn (ctx: *anyopaque, shape: CursorShape) void,

        /// Write UTF-8 text to the system clipboard (OSC 52 / copy).
        clipboard_write: *const fn (ctx: *anyopaque, text: []const u8) void,

        /// Read the system clipboard as UTF-8 (paste). Returns an allocation
        /// owned by the caller (freed with the same allocator), or null when the
        /// clipboard holds no text. Errors propagate (e.g. OOM, OS failure).
        clipboard_read: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator) anyerror!?[]u8,

        /// Place the IME composition window at the given client-pixel position
        /// (the text cursor), so CJK / dead-key candidates open at the caret.
        set_ime_position: *const fn (ctx: *anyopaque, x: i32, y: i32) void,
    };

    // --- Convenience wrappers: call the vtable with `ctx` so engine code reads
    //     `host.requestRedraw()` instead of `host.vtable.request_redraw(host.ctx)`.

    pub fn requestRedraw(self: Host) void {
        self.vtable.request_redraw(self.ctx);
    }
    pub fn makeCurrent(self: Host) void {
        self.vtable.make_current(self.ctx);
    }
    pub fn swapBuffers(self: Host) void {
        self.vtable.swap_buffers(self.ctx);
    }
    pub fn glProcAddress(self: Host, name: [*:0]const u8) ?*const anyopaque {
        return self.vtable.gl_proc_address(self.ctx, name);
    }
    pub fn setTitle(self: Host, title: []const u8) void {
        self.vtable.set_title(self.ctx, title);
    }
    pub fn setCursorShape(self: Host, shape: CursorShape) void {
        self.vtable.set_cursor_shape(self.ctx, shape);
    }
    pub fn clipboardWrite(self: Host, text: []const u8) void {
        self.vtable.clipboard_write(self.ctx, text);
    }
    pub fn clipboardRead(self: Host, alloc: std.mem.Allocator) anyerror!?[]u8 {
        return self.vtable.clipboard_read(self.ctx, alloc);
    }
    pub fn setImePosition(self: Host, x: i32, y: i32) void {
        self.vtable.set_ime_position(self.ctx, x, y);
    }
};

// --- Tests: a fake host proves the contract is implementable and the wrappers
//     route every call to the vtable with the host's own ctx. This stands in for
//     whomux's real Win32 host until #13/#23 drive the shape (ADR 0010).

const FakeHost = struct {
    redraws: u32 = 0,
    made_current: u32 = 0,
    swaps: u32 = 0,
    last_title: []const u8 = "",
    last_shape: CursorShape = .default,
    clipboard: []const u8 = "",
    ime_x: i32 = 0,
    ime_y: i32 = 0,

    fn host(self: *FakeHost) Host {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: Host.VTable = .{
        .request_redraw = redraw,
        .make_current = makeCurrent,
        .swap_buffers = swap,
        .gl_proc_address = glProc,
        .set_title = setTitle,
        .set_cursor_shape = setShape,
        .clipboard_write = clipWrite,
        .clipboard_read = clipRead,
        .set_ime_position = setIme,
    };

    fn fromCtx(ctx: *anyopaque) *FakeHost {
        return @ptrCast(@alignCast(ctx));
    }
    fn redraw(ctx: *anyopaque) void {
        fromCtx(ctx).redraws += 1;
    }
    fn makeCurrent(ctx: *anyopaque) void {
        fromCtx(ctx).made_current += 1;
    }
    fn swap(ctx: *anyopaque) void {
        fromCtx(ctx).swaps += 1;
    }
    fn glProc(ctx: *anyopaque, name: [*:0]const u8) ?*const anyopaque {
        _ = ctx;
        // A real host returns wgl/egl pointers; the fake reports "glClear known,
        // everything else unknown" so the wrapper's null path is covered too.
        return if (std.mem.eql(u8, std.mem.span(name), "glClear")) @ptrFromInt(0xC0FFEE) else null;
    }
    fn setTitle(ctx: *anyopaque, title: []const u8) void {
        fromCtx(ctx).last_title = title;
    }
    fn setShape(ctx: *anyopaque, shape: CursorShape) void {
        fromCtx(ctx).last_shape = shape;
    }
    fn clipWrite(ctx: *anyopaque, text: []const u8) void {
        fromCtx(ctx).clipboard = text;
    }
    fn clipRead(ctx: *anyopaque, alloc: std.mem.Allocator) anyerror!?[]u8 {
        const s = fromCtx(ctx);
        if (s.clipboard.len == 0) return null;
        return try alloc.dupe(u8, s.clipboard);
    }
    fn setIme(ctx: *anyopaque, x: i32, y: i32) void {
        const s = fromCtx(ctx);
        s.ime_x = x;
        s.ime_y = y;
    }
};

test "host vtable wrappers route every call to the host ctx" {
    var fake: FakeHost = .{};
    const h = fake.host();

    h.requestRedraw();
    h.requestRedraw();
    h.makeCurrent();
    h.swapBuffers();
    h.setTitle("whostty");
    h.setCursorShape(.pointer);
    h.setImePosition(12, 34);

    try std.testing.expectEqual(@as(u32, 2), fake.redraws);
    try std.testing.expectEqual(@as(u32, 1), fake.made_current);
    try std.testing.expectEqual(@as(u32, 1), fake.swaps);
    try std.testing.expectEqualStrings("whostty", fake.last_title);
    try std.testing.expectEqual(CursorShape.pointer, fake.last_shape);
    try std.testing.expectEqual(@as(i32, 12), fake.ime_x);
    try std.testing.expectEqual(@as(i32, 34), fake.ime_y);

    try std.testing.expect(h.glProcAddress("glClear") != null);
    try std.testing.expect(h.glProcAddress("glNope") == null);
}

test "host clipboard round-trips through the vtable" {
    var fake: FakeHost = .{};
    const h = fake.host();

    try std.testing.expect((try h.clipboardRead(std.testing.allocator)) == null);

    h.clipboardWrite("copied text");
    try std.testing.expectEqualStrings("copied text", fake.clipboard);

    const pasted = (try h.clipboardRead(std.testing.allocator)).?;
    defer std.testing.allocator.free(pasted);
    try std.testing.expectEqualStrings("copied text", pasted);
}
