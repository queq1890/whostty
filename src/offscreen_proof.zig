//! whostty: headless OpenGL render proof (Linux/EGL, not shipped).
//!
//! On-device verification of the Windows renderer is blocked (WDAC won't launch
//! unsigned exes). This harness instead exercises the *exact* render logic —
//! the real `renderer/OpenGL.zig` shaders + `Vertex`/`pushQuad`/`pushSolid`
//! geometry, the real `font/main.zig` Freetype rasterizer, and the real
//! `font/Atlas.zig` packer — on a genuine GL 3.3 core context (Mesa/llvmpipe,
//! surfaceless EGL), renders a few glyphs, reads the framebuffer back, and
//! asserts glyphs reached lit pixels. This proves the atlas+shader+cell path is
//! correct independently of the WGL/Win32 wrapper, and validates the 3.3-core
//! requirement that the Windows context fix (wglCreateContextAttribsARB) depends
//! on. Build/run: `zig build offscreen-proof -Dfreetype` on a host with Mesa.
const std = @import("std");
const gl = @import("renderer/OpenGL.zig");
const cursor = @import("renderer/cursor.zig");
const GlyphCache = @import("font/GlyphCache.zig");
const font = @import("font/main.zig");
const Atlas = @import("font/Atlas.zig");
const Termio = @import("termio.zig").Termio;
const surface = @import("Surface.zig");
const scroll = @import("scroll.zig");
const decoration = @import("renderer/decoration.zig");
const vt = @import("ghostty-vt");
const vtcolor = vt.color;

// --- dynamic loader --------------------------------------------------------
extern "c" fn dlopen(path: [*:0]const u8, flag: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: ?*anyopaque, sym: [*:0]const u8) ?*anyopaque;
const RTLD_NOW = 0x2;
const RTLD_GLOBAL = 0x100;

const GetProc = *const fn ([*:0]const u8) callconv(.c) ?*const anyopaque;

// --- EGL -------------------------------------------------------------------
const EGL_PLATFORM_SURFACELESS_MESA: u32 = 0x31DD;
const EGL_OPENGL_API: u32 = 0x30A2;
const EGL_NONE: i32 = 0x3038;
const EGL_SURFACE_TYPE: i32 = 0x3033;
const EGL_PBUFFER_BIT: i32 = 0x0001;
const EGL_RENDERABLE_TYPE: i32 = 0x3040;
const EGL_OPENGL_BIT: i32 = 0x0008;
const EGL_RED_SIZE: i32 = 0x3024;
const EGL_GREEN_SIZE: i32 = 0x3023;
const EGL_BLUE_SIZE: i32 = 0x3022;
const EGL_ALPHA_SIZE: i32 = 0x3021;
const EGL_CONTEXT_MAJOR_VERSION: i32 = 0x3098;
const EGL_CONTEXT_MINOR_VERSION: i32 = 0x30FB;
const EGL_CONTEXT_OPENGL_PROFILE_MASK: i32 = 0x30FD;
const EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT: i32 = 0x00000001;

// --- GL constants ----------------------------------------------------------
const GL_FRAGMENT_SHADER: u32 = 0x8B30;
const GL_VERTEX_SHADER: u32 = 0x8B31;
const GL_COMPILE_STATUS: u32 = 0x8B81;
const GL_LINK_STATUS: u32 = 0x8B82;
const GL_ARRAY_BUFFER: u32 = 0x8892;
const GL_DYNAMIC_DRAW: u32 = 0x88E8;
const GL_FLOAT: u32 = 0x1406;
const GL_TRIANGLES: u32 = 0x0004;
const GL_TEXTURE_2D: u32 = 0x0DE1;
const GL_TEXTURE0: u32 = 0x84C0;
const GL_RED: u32 = 0x1903;
const GL_R8: i32 = 0x8229;
const GL_UNSIGNED_BYTE: u32 = 0x1401;
const GL_TEXTURE_MIN_FILTER: u32 = 0x2801;
const GL_TEXTURE_MAG_FILTER: u32 = 0x2800;
const GL_NEAREST: i32 = 0x2600;
const GL_TEXTURE_WRAP_S: u32 = 0x2802;
const GL_TEXTURE_WRAP_T: u32 = 0x2803;
const GL_CLAMP_TO_EDGE: i32 = 0x812F;
const GL_UNPACK_ALIGNMENT: u32 = 0x0CF5;
const GL_BLEND: u32 = 0x0BE2;
const GL_SRC_ALPHA: u32 = 0x0302;
const GL_ONE_MINUS_SRC_ALPHA: u32 = 0x0303;
const GL_COLOR_BUFFER_BIT: u32 = 0x4000;
const GL_RGBA: u32 = 0x1908;
const GL_FRAMEBUFFER: u32 = 0x8D40;
const GL_RENDERBUFFER: u32 = 0x8D41;
const GL_RGBA8: i32 = 0x8058;
const GL_COLOR_ATTACHMENT0: u32 = 0x8CE0;
const GL_FRAMEBUFFER_COMPLETE: u32 = 0x8CD5;

// GL function-pointer table (C calling convention — this is Linux, not WGL).
const GL = struct {
    createShader: *const fn (u32) callconv(.c) u32,
    shaderSource: *const fn (u32, i32, [*]const [*:0]const u8, ?[*]const i32) callconv(.c) void,
    compileShader: *const fn (u32) callconv(.c) void,
    getShaderiv: *const fn (u32, u32, *i32) callconv(.c) void,
    getShaderInfoLog: *const fn (u32, i32, ?*i32, [*]u8) callconv(.c) void,
    createProgram: *const fn () callconv(.c) u32,
    attachShader: *const fn (u32, u32) callconv(.c) void,
    linkProgram: *const fn (u32) callconv(.c) void,
    getProgramiv: *const fn (u32, u32, *i32) callconv(.c) void,
    getProgramInfoLog: *const fn (u32, i32, ?*i32, [*]u8) callconv(.c) void,
    useProgram: *const fn (u32) callconv(.c) void,
    genBuffers: *const fn (i32, [*]u32) callconv(.c) void,
    bindBuffer: *const fn (u32, u32) callconv(.c) void,
    bufferData: *const fn (u32, isize, ?*const anyopaque, u32) callconv(.c) void,
    genVertexArrays: *const fn (i32, [*]u32) callconv(.c) void,
    bindVertexArray: *const fn (u32) callconv(.c) void,
    vertexAttribPointer: *const fn (u32, i32, u32, u8, i32, ?*const anyopaque) callconv(.c) void,
    enableVertexAttribArray: *const fn (u32) callconv(.c) void,
    genTextures: *const fn (i32, [*]u32) callconv(.c) void,
    bindTexture: *const fn (u32, u32) callconv(.c) void,
    texParameteri: *const fn (u32, u32, i32) callconv(.c) void,
    texImage2D: *const fn (u32, i32, i32, i32, i32, i32, u32, u32, ?*const anyopaque) callconv(.c) void,
    pixelStorei: *const fn (u32, i32) callconv(.c) void,
    activeTexture: *const fn (u32) callconv(.c) void,
    getUniformLocation: *const fn (u32, [*:0]const u8) callconv(.c) i32,
    uniform1i: *const fn (i32, i32) callconv(.c) void,
    genFramebuffers: *const fn (i32, [*]u32) callconv(.c) void,
    bindFramebuffer: *const fn (u32, u32) callconv(.c) void,
    genRenderbuffers: *const fn (i32, [*]u32) callconv(.c) void,
    bindRenderbuffer: *const fn (u32, u32) callconv(.c) void,
    renderbufferStorage: *const fn (u32, u32, i32, i32) callconv(.c) void,
    framebufferRenderbuffer: *const fn (u32, u32, u32, u32) callconv(.c) void,
    checkFramebufferStatus: *const fn (u32) callconv(.c) u32,
    viewport: *const fn (i32, i32, i32, i32) callconv(.c) void,
    clearColor: *const fn (f32, f32, f32, f32) callconv(.c) void,
    clear: *const fn (u32) callconv(.c) void,
    enable: *const fn (u32) callconv(.c) void,
    blendFunc: *const fn (u32, u32) callconv(.c) void,
    drawArrays: *const fn (u32, i32, i32) callconv(.c) void,
    readPixels: *const fn (i32, i32, i32, i32, u32, u32, [*]u8) callconv(.c) void,
    finish: *const fn () callconv(.c) void,

    fn load(get: GetProc) GL {
        const L = struct {
            fn p(g: GetProc, comptime T: type, name: [*:0]const u8) T {
                return @ptrCast(g(name) orelse std.debug.panic("missing GL fn: {s}", .{name}));
            }
        };
        var self: GL = undefined;
        inline for (@typeInfo(GL).@"struct".fields) |f| {
            if (comptime std.mem.eql(u8, f.name, "load")) continue;
            const gl_name = "gl" ++ [_]u8{std.ascii.toUpper(f.name[0])} ++ f.name[1..] ++ "\x00";
            @field(self, f.name) = L.p(get, f.type, @ptrCast(gl_name.ptr));
        }
        return self;
    }
};

fn compile(g: GL, kind: u32, src: [:0]const u8) u32 {
    const sh = g.createShader(kind);
    var ptr: [*:0]const u8 = src.ptr;
    g.shaderSource(sh, 1, @ptrCast(&ptr), null);
    g.compileShader(sh);
    var ok: i32 = 0;
    g.getShaderiv(sh, GL_COMPILE_STATUS, &ok);
    if (ok == 0) {
        var buf: [1024]u8 = undefined;
        var n: i32 = 0;
        g.getShaderInfoLog(sh, buf.len, &n, &buf);
        std.debug.panic("shader compile failed: {s}", .{buf[0..@intCast(@max(0, n))]});
    }
    return sh;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const out = std.debug;

    // --- EGL surfaceless 3.3 core context (Mesa) ---
    const egl = dlopen("libEGL.so.1", RTLD_NOW | RTLD_GLOBAL) orelse return error.NoEGL;
    _ = dlopen("libGL.so.1", RTLD_NOW | RTLD_GLOBAL);
    const eglGetProcAddress: GetProc = @ptrCast(dlsym(egl, "eglGetProcAddress").?);
    const eglGetPlatformDisplay: *const fn (u32, ?*anyopaque, ?[*]const isize) callconv(.c) ?*anyopaque =
        @ptrCast(dlsym(egl, "eglGetPlatformDisplay") orelse eglGetProcAddress("eglGetPlatformDisplay").?);
    const eglInitialize: *const fn (?*anyopaque, ?*i32, ?*i32) callconv(.c) u32 = @ptrCast(dlsym(egl, "eglInitialize").?);
    const eglChooseConfig: *const fn (?*anyopaque, [*]const i32, ?[*]?*anyopaque, i32, *i32) callconv(.c) u32 = @ptrCast(dlsym(egl, "eglChooseConfig").?);
    const eglBindAPI: *const fn (u32) callconv(.c) u32 = @ptrCast(dlsym(egl, "eglBindAPI").?);
    const eglCreateContext: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, [*]const i32) callconv(.c) ?*anyopaque = @ptrCast(dlsym(egl, "eglCreateContext").?);
    const eglMakeCurrent: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) u32 = @ptrCast(dlsym(egl, "eglMakeCurrent").?);

    const dpy = eglGetPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA, null, null) orelse return error.NoDisplay;
    if (eglInitialize(dpy, null, null) == 0) return error.EglInit;
    const cfg_attrs = [_]i32{
        EGL_SURFACE_TYPE,    EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
        EGL_RED_SIZE,        8,               EGL_GREEN_SIZE,      8,
        EGL_BLUE_SIZE,       8,               EGL_ALPHA_SIZE,      8,
        EGL_NONE,
    };
    var config: ?*anyopaque = null;
    var num_cfg: i32 = 0;
    if (eglChooseConfig(dpy, &cfg_attrs, @ptrCast(&config), 1, &num_cfg) == 0 or num_cfg == 0) return error.NoConfig;
    _ = eglBindAPI(EGL_OPENGL_API);
    const ctx_attrs = [_]i32{
        EGL_CONTEXT_MAJOR_VERSION,       3, EGL_CONTEXT_MINOR_VERSION, 3,
        EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
        EGL_NONE,
    };
    const ctx = eglCreateContext(dpy, config, null, &ctx_attrs) orelse return error.NoContext;
    if (eglMakeCurrent(dpy, null, null, ctx) == 0) return error.MakeCurrent;
    const g = GL.load(eglGetProcAddress);
    out.print("[proof] GL 3.3 core context current (surfaceless Mesa)\n", .{});

    // --- Build the atlas with the REAL font + atlas code ---
    const font_path = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf";
    std.fs.accessAbsolute(font_path, .{}) catch {
        out.print("[proof] SKIP: test font not found at {s}\n", .{font_path});
        return;
    };
    const px: u32 = 32;
    var lib = try font.Library.init();
    defer lib.deinit();
    var face = try font.Face.init(lib, font_path, px);
    defer face.deinit();
    const m = face.metrics();
    out.print("[proof] face metrics: cell {d}x{d} ascent {d}\n", .{ m.cell_width, m.cell_height, m.ascent });

    var atlas = try Atlas.init(alloc, 512);
    defer atlas.deinit(alloc);

    const text = "Hi42";
    var quads: std.ArrayList(gl.Quad) = .empty;
    defer quads.deinit(alloc);

    const screen_w: u32 = m.cell_width * (@as(u32, @intCast(text.len)) + 2);
    const screen_h: u32 = m.cell_height * 2;
    var ink_atlas: usize = 0; // total inked atlas texels of the drawn glyphs

    for (text, 0..) |ch, i| {
        var glyph = try face.rasterize(alloc, ch, .{});
        defer glyph.deinit(alloc);
        if (glyph.width == 0 or glyph.height == 0) continue;
        for (glyph.pixels) |p| {
            if (p != 0) ink_atlas += 1;
        }
        const region = try atlas.reserve(glyph.width, glyph.height);
        atlas.set(region, glyph.pixels);
        // Same placement formula as App.buildQuads (row 0).
        const cell_x: i32 = @intCast(i * m.cell_width);
        try quads.append(alloc, .{ .glyph = .{
            .px = cell_x + glyph.bearing_x,
            .py = @as(i32, @intCast(m.ascent)) - glyph.bearing_y,
            .sx = region.x,
            .sy = region.y,
            .sw = region.width,
            .sh = region.height,
            .r = 1,
            .g = 1,
            .b = 1,
        } });
    }
    out.print("[proof] {d} glyph quads, {d} inked atlas texels\n", .{ quads.items.len, ink_atlas });

    // --- GL setup mirroring Renderer.init + setAtlas + draw ---
    const vs = compile(g, GL_VERTEX_SHADER, gl.vertex_shader_src);
    const fs = compile(g, GL_FRAGMENT_SHADER, gl.fragment_shader_src);
    const program = g.createProgram();
    g.attachShader(program, vs);
    g.attachShader(program, fs);
    g.linkProgram(program);
    var ok: i32 = 0;
    g.getProgramiv(program, GL_LINK_STATUS, &ok);
    if (ok == 0) return error.LinkFailed;
    out.print("[proof] real shaders compiled + linked on a 3.3 core context\n", .{});

    var vao: u32 = 0;
    var vbo: u32 = 0;
    g.genVertexArrays(1, @ptrCast(&vao));
    g.genBuffers(1, @ptrCast(&vbo));
    g.bindVertexArray(vao);
    g.bindBuffer(GL_ARRAY_BUFFER, vbo);
    const stride: i32 = @sizeOf(gl.Vertex);
    g.vertexAttribPointer(0, 2, GL_FLOAT, 0, stride, @ptrFromInt(0));
    g.enableVertexAttribArray(0);
    g.vertexAttribPointer(1, 2, GL_FLOAT, 0, stride, @ptrFromInt(@offsetOf(gl.Vertex, "u")));
    g.enableVertexAttribArray(1);
    g.vertexAttribPointer(2, 3, GL_FLOAT, 0, stride, @ptrFromInt(@offsetOf(gl.Vertex, "r")));
    g.enableVertexAttribArray(2);
    g.vertexAttribPointer(3, 1, GL_FLOAT, 0, stride, @ptrFromInt(@offsetOf(gl.Vertex, "m")));
    g.enableVertexAttribArray(3);
    g.vertexAttribPointer(4, 1, GL_FLOAT, 0, stride, @ptrFromInt(@offsetOf(gl.Vertex, "a")));
    g.enableVertexAttribArray(4);

    // Atlas texture (same params as Renderer.setAtlas).
    var tex: u32 = 0;
    g.genTextures(1, @ptrCast(&tex));
    g.bindTexture(GL_TEXTURE_2D, tex);
    g.pixelStorei(GL_UNPACK_ALIGNMENT, 1);
    g.texImage2D(GL_TEXTURE_2D, 0, GL_R8, @intCast(atlas.size), @intCast(atlas.size), 0, GL_RED, GL_UNSIGNED_BYTE, atlas.data.ptr);
    g.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    g.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    g.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    g.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

    g.enable(GL_BLEND);
    g.blendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);

    // Offscreen render target.
    var fbo: u32 = 0;
    var rbo: u32 = 0;
    g.genFramebuffers(1, @ptrCast(&fbo));
    g.bindFramebuffer(GL_FRAMEBUFFER, fbo);
    g.genRenderbuffers(1, @ptrCast(&rbo));
    g.bindRenderbuffer(GL_RENDERBUFFER, rbo);
    g.renderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, @intCast(screen_w), @intCast(screen_h));
    g.framebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rbo);
    if (g.checkFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) return error.FboIncomplete;

    // Build the vertex stream with the REAL pushQuad geometry.
    var verts: std.ArrayList(gl.Vertex) = .empty;
    defer verts.deinit(alloc);
    for (quads.items) |q| switch (q) {
        .glyph => |cell| try gl.pushQuad(&verts, alloc, cell, screen_w, screen_h, atlas.size),
        .solid => |rect| try gl.pushSolid(&verts, alloc, rect, screen_w, screen_h),
    };

    // Draw.
    const clear = [3]f32{ 0.1, 0.1, 0.12 };
    g.viewport(0, 0, @intCast(screen_w), @intCast(screen_h));
    g.clearColor(clear[0], clear[1], clear[2], 1.0);
    g.clear(GL_COLOR_BUFFER_BIT);
    g.useProgram(program);
    g.bindVertexArray(vao);
    g.bindBuffer(GL_ARRAY_BUFFER, vbo);
    g.bufferData(GL_ARRAY_BUFFER, @intCast(verts.items.len * @sizeOf(gl.Vertex)), verts.items.ptr, GL_DYNAMIC_DRAW);
    g.activeTexture(GL_TEXTURE0);
    g.bindTexture(GL_TEXTURE_2D, tex);
    g.uniform1i(g.getUniformLocation(program, "u_atlas"), 0);
    g.drawArrays(GL_TRIANGLES, 0, @intCast(verts.items.len));
    g.finish();

    // Read back + count lit pixels.
    const n = @as(usize, screen_w) * @as(usize, screen_h);
    const buf = try alloc.alloc(u8, n * 4);
    defer alloc.free(buf);
    g.readPixels(0, 0, @intCast(screen_w), @intCast(screen_h), GL_RGBA, GL_UNSIGNED_BYTE, buf.ptr);

    const cr: i16 = @intFromFloat(@round(clear[0] * 255.0));
    const cg: i16 = @intFromFloat(@round(clear[1] * 255.0));
    const cb: i16 = @intFromFloat(@round(clear[2] * 255.0));
    var lit: usize = 0;
    var min_x: usize = n;
    var max_x: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const r: i16 = buf[i * 4 + 0];
        const gg: i16 = buf[i * 4 + 1];
        const b: i16 = buf[i * 4 + 2];
        if (@abs(r - cr) > 2 or @abs(gg - cg) > 2 or @abs(b - cb) > 2) {
            lit += 1;
            const x = i % screen_w;
            min_x = @min(min_x, x);
            max_x = @max(max_x, x);
        }
    }
    out.print("[proof] framebuffer {d}x{d}: lit_pixels={d}/{d} ({d:.2}%), lit x-range [{d}..{d}]\n", .{
        screen_w, screen_h, lit, n, @as(f64, @floatFromInt(lit)) * 100.0 / @as(f64, @floatFromInt(n)),
        if (lit > 0) min_x else 0, max_x,
    });

    if (lit == 0) {
        out.print("[proof] FAIL: nothing rendered (lit_pixels == 0)\n", .{});
        return error.NothingRendered;
    }
    // The lit pixels should be in the same ballpark as the inked atlas texels
    // (NEAREST sampling, 1:1 glyph scale) — sanity that we drew the glyphs, not
    // garbage filling the whole frame.
    if (lit >= n) {
        out.print("[proof] FAIL: whole frame lit — likely a solid-fill/atlas bug\n", .{});
        return error.SuspiciousFill;
    }
    out.print("[proof] PASS: real shaders + atlas + Freetype glyphs rasterized to {d} lit pixels (ink atlas={d})\n", .{ lit, ink_atlas });

    // --- Cursor render proof (#69) ----------------------------------------
    // Exercise the real `renderer/cursor.zig` shapeQuads -> pushSolid -> GL path:
    // a red block cursor over a 16x16 cell must paint ~256 red pixels. This
    // proves the cursor reaches the framebuffer (on-device launch is WDAC-
    // blocked), independent of the Win32/apprt wrapper.
    {
        var cq: std.ArrayList(gl.Quad) = .empty;
        defer cq.deinit(alloc);
        try cursor.shapeQuads(&cq, alloc, .block, .{ .px = 4, .py = 4, .cell_w = 16, .cell_h = 16, .thickness = 2 }, .{ 1, 0, 0 }, 1.0);

        var cverts: std.ArrayList(gl.Vertex) = .empty;
        defer cverts.deinit(alloc);
        for (cq.items) |q| switch (q) {
            .glyph => |c| try gl.pushQuad(&cverts, alloc, c, screen_w, screen_h, atlas.size),
            .solid => |rect| try gl.pushSolid(&cverts, alloc, rect, screen_w, screen_h),
        };

        g.clearColor(clear[0], clear[1], clear[2], 1.0);
        g.clear(GL_COLOR_BUFFER_BIT);
        g.bufferData(GL_ARRAY_BUFFER, @intCast(cverts.items.len * @sizeOf(gl.Vertex)), cverts.items.ptr, GL_DYNAMIC_DRAW);
        g.drawArrays(GL_TRIANGLES, 0, @intCast(cverts.items.len));
        g.finish();

        g.readPixels(0, 0, @intCast(screen_w), @intCast(screen_h), GL_RGBA, GL_UNSIGNED_BYTE, buf.ptr);
        var red: usize = 0;
        var j: usize = 0;
        while (j < n) : (j += 1) {
            if (buf[j * 4] > 200 and buf[j * 4 + 1] < 60 and buf[j * 4 + 2] < 60) red += 1;
        }
        out.print("[proof] cursor: red pixels = {d} (expect ~256 for a 16x16 block)\n", .{red});
        if (red < 150 or red > 400) {
            out.print("[proof] FAIL: block cursor did not paint its cell\n", .{});
            return error.CursorNotRendered;
        }
        out.print("[proof] PASS: block cursor (shapeQuads -> pushSolid) rasterized {d} red pixels\n", .{red});
    }

    // --- Translucency proof (#70 faint / cursor-opacity) ------------------
    // A white solid at alpha 0.5 over the dark clear must blend to ~halfway:
    // out = 0.5*1.0 + 0.5*clear. This validates the per-quad alpha blend that
    // faint (dim) text and cursor-opacity depend on, end-to-end on real GL.
    {
        var tverts: std.ArrayList(gl.Vertex) = .empty;
        defer tverts.deinit(alloc);
        try gl.pushSolid(&tverts, alloc, .{ .px = 4, .py = 4, .w = 16, .h = 16, .r = 1, .g = 1, .b = 1, .a = 0.5 }, screen_w, screen_h);

        g.clearColor(clear[0], clear[1], clear[2], 1.0);
        g.clear(GL_COLOR_BUFFER_BIT);
        g.bufferData(GL_ARRAY_BUFFER, @intCast(tverts.items.len * @sizeOf(gl.Vertex)), tverts.items.ptr, GL_DYNAMIC_DRAW);
        g.drawArrays(GL_TRIANGLES, 0, @intCast(tverts.items.len));
        g.finish();
        g.readPixels(0, 0, @intCast(screen_w), @intCast(screen_h), GL_RGBA, GL_UNSIGNED_BYTE, buf.ptr);

        // Expected blended red channel = 0.5*255 + 0.5*(clear[0]*255).
        const want: f64 = 0.5 * 255.0 + 0.5 * (@as(f64, clear[0]) * 255.0);
        var found = false;
        var k: usize = 0;
        while (k < n) : (k += 1) {
            const r: f64 = @floatFromInt(buf[k * 4]);
            // The blended fill is distinctly brighter than the clear but well
            // below opaque white; assert a pixel near the predicted midpoint.
            if (@abs(r - want) <= 8) {
                found = true;
                break;
            }
        }
        out.print("[proof] translucency: want blended R~={d:.0}; matched={}\n", .{ want, found });
        if (!found) {
            out.print("[proof] FAIL: alpha 0.5 fill did not blend to the predicted midpoint\n", .{});
            return error.AlphaBlendWrong;
        }
        out.print("[proof] PASS: per-quad alpha 0.5 blended correctly (faint / cursor-opacity path)\n", .{});
    }

    // --- Glyph cache proof (#66): non-ASCII rasterized on demand ----------
    // The real `font/GlyphCache.zig` must rasterize and pack an arbitrary
    // codepoint (here U+2500 BOX DRAWINGS LIGHT HORIZONTAL) on demand, and that
    // glyph must reach lit pixels through the real shader/atlas path. Proves the
    // renderer is no longer ASCII-only, independent of the Win32 wrapper.
    {
        var cache = try GlyphCache.init(alloc, font_path, 32, 512);
        defer cache.deinit();

        if (cache.get('A', false, false) == null) return error.NoAsciiGlyph;
        const box = cache.get(0x2500, false, false) orelse return error.NoBoxGlyph;
        if (!cache.takeDirty()) return error.CacheNotDirty;
        out.print("[proof] glyphcache: 'A' + U+2500 packed on demand (atlas {d})\n", .{cache.atlas.size});

        // Upload the cache's atlas and render the box-drawing glyph.
        g.bindTexture(GL_TEXTURE_2D, tex);
        g.pixelStorei(GL_UNPACK_ALIGNMENT, 1);
        g.texImage2D(GL_TEXTURE_2D, 0, GL_R8, @intCast(cache.atlas.size), @intCast(cache.atlas.size), 0, GL_RED, GL_UNSIGNED_BYTE, cache.atlas.data.ptr);

        var gverts: std.ArrayList(gl.Vertex) = .empty;
        defer gverts.deinit(alloc);
        try gl.pushQuad(&gverts, alloc, .{
            .px = 10,
            .py = 10,
            .sx = box.region.x,
            .sy = box.region.y,
            .sw = box.region.width,
            .sh = box.region.height,
            .r = 1,
            .g = 1,
            .b = 1,
        }, screen_w, screen_h, cache.atlas.size);

        g.clearColor(clear[0], clear[1], clear[2], 1.0);
        g.clear(GL_COLOR_BUFFER_BIT);
        g.bufferData(GL_ARRAY_BUFFER, @intCast(gverts.items.len * @sizeOf(gl.Vertex)), gverts.items.ptr, GL_DYNAMIC_DRAW);
        g.drawArrays(GL_TRIANGLES, 0, @intCast(gverts.items.len));
        g.finish();
        g.readPixels(0, 0, @intCast(screen_w), @intCast(screen_h), GL_RGBA, GL_UNSIGNED_BYTE, buf.ptr);

        var glit: usize = 0;
        var q: usize = 0;
        while (q < n) : (q += 1) {
            const r: i16 = buf[q * 4];
            const gg: i16 = buf[q * 4 + 1];
            const b: i16 = buf[q * 4 + 2];
            if (@abs(r - cr) > 2 or @abs(gg - cg) > 2 or @abs(b - cb) > 2) glit += 1;
        }
        out.print("[proof] glyphcache: U+2500 lit pixels = {d}\n", .{glit});
        if (glit == 0) {
            out.print("[proof] FAIL: non-ASCII glyph rendered blank\n", .{});
            return error.NonAsciiGlyphBlank;
        }
        out.print("[proof] PASS: non-ASCII glyph U+2500 rasterized on demand to {d} lit pixels\n", .{glit});
    }

    // --- Dynamic background proof (#83): OSC 11 -> clear color -------------
    // A real Termio parses OSC 11 (set default background); the resolved
    // `backgroundColor` must reach the framebuffer clear color. Proves the
    // renderer treats `terminal.colors` as authoritative for the default bg,
    // so runtime color changes are visible — independent of the Win32 wrapper.
    {
        const io = try Termio.create(alloc, 4, 2, 1 << 16);
        defer io.destroy();
        io.seedColors(.{ .r = 0x11, .g = 0x11, .b = 0x11 }, .{ .r = 0x22, .g = 0x22, .b = 0x22 }, null, &vtcolor.default);
        try io.process("\x1b]11;rgb:00/ff/00\x07"); // pure green background
        const bg = io.backgroundColor(.{ .r = 0, .g = 0, .b = 0 });
        if (bg.r != 0x00 or bg.g != 0xff or bg.b != 0x00) return error.OscBgNotApplied;

        g.clearColor(
            @as(f32, @floatFromInt(bg.r)) / 255.0,
            @as(f32, @floatFromInt(bg.g)) / 255.0,
            @as(f32, @floatFromInt(bg.b)) / 255.0,
            1.0,
        );
        g.clear(GL_COLOR_BUFFER_BIT);
        g.finish();
        g.readPixels(0, 0, @intCast(screen_w), @intCast(screen_h), GL_RGBA, GL_UNSIGNED_BYTE, buf.ptr);

        const ci = ((screen_h / 2) * screen_w + screen_w / 2) * 4;
        const pr = buf[ci];
        const pg = buf[ci + 1];
        const pb = buf[ci + 2];
        out.print("[proof] osc-colors: OSC 11 background pixel = rgb({d},{d},{d})\n", .{ pr, pg, pb });
        if (pr > 8 or pg < 247 or pb > 8) {
            out.print("[proof] FAIL: OSC 11 background did not reach the framebuffer\n", .{});
            return error.OscBgNotRendered;
        }
        out.print("[proof] PASS: OSC 11 dynamic background reached the clear color (green framebuffer)\n", .{});
    }

    // --- Synthetic bold proof (#77): bold adds ink through the real path ----
    // The GlyphCache must synthesize a heavier 'H' from the regular face (no
    // bold font file), and that extra ink must survive the atlas + shader path
    // to the framebuffer — proving synthetic styling, not just a cache key.
    {
        var cache = try GlyphCache.init(alloc, font_path, 32, 512);
        defer cache.deinit();
        const reg = cache.get('H', false, false) orelse return error.NoRegularH;
        const bold = cache.get('H', true, false) orelse return error.NoBoldH;

        // Upload the atlas once (now holds both the regular and bold 'H').
        g.bindTexture(GL_TEXTURE_2D, tex);
        g.pixelStorei(GL_UNPACK_ALIGNMENT, 1);
        g.texImage2D(GL_TEXTURE_2D, 0, GL_R8, @intCast(cache.atlas.size), @intCast(cache.atlas.size), 0, GL_RED, GL_UNSIGNED_BYTE, cache.atlas.data.ptr);

        var counts: [2]usize = .{ 0, 0 };
        for ([_]Atlas.Placement{ reg, bold }, 0..) |place, pass| {
            var gv: std.ArrayList(gl.Vertex) = .empty;
            defer gv.deinit(alloc);
            try gl.pushQuad(&gv, alloc, .{
                .px = 10,
                .py = 10,
                .sx = place.region.x,
                .sy = place.region.y,
                .sw = place.region.width,
                .sh = place.region.height,
                .r = 1,
                .g = 1,
                .b = 1,
            }, screen_w, screen_h, cache.atlas.size);
            g.clearColor(clear[0], clear[1], clear[2], 1.0);
            g.clear(GL_COLOR_BUFFER_BIT);
            g.bufferData(GL_ARRAY_BUFFER, @intCast(gv.items.len * @sizeOf(gl.Vertex)), gv.items.ptr, GL_DYNAMIC_DRAW);
            g.drawArrays(GL_TRIANGLES, 0, @intCast(gv.items.len));
            g.finish();
            g.readPixels(0, 0, @intCast(screen_w), @intCast(screen_h), GL_RGBA, GL_UNSIGNED_BYTE, buf.ptr);
            var plit: usize = 0;
            var qq: usize = 0;
            while (qq < n) : (qq += 1) {
                const r: i16 = buf[qq * 4];
                const gg: i16 = buf[qq * 4 + 1];
                const b: i16 = buf[qq * 4 + 2];
                if (@abs(r - cr) > 2 or @abs(gg - cg) > 2 or @abs(b - cb) > 2) plit += 1;
            }
            counts[pass] = plit;
        }
        out.print("[proof] synthetic-bold: regular 'H' lit={d}, bold 'H' lit={d}\n", .{ counts[0], counts[1] });
        if (counts[0] == 0 or counts[1] <= counts[0]) {
            out.print("[proof] FAIL: synthetic bold did not add ink over regular\n", .{});
            return error.BoldNotBolder;
        }
        out.print("[proof] PASS: synthetic bold rasterized through the atlas/shader with more ink than regular\n", .{});
    }

    // --- Window padding proof (#71): the origin offset shifts the render ----
    // Two halves verify padding: `surface.layout` (the math — origin from the
    // configured padding) is covered by host unit tests in Surface.zig, and the
    // GL pipeline honoring an x-origin is shown here by drawing the SAME glyph at
    // origin 0 vs the padded origin and asserting its lit pixels move right by
    // exactly the padding. (buildQuads — which feeds `origin` into every
    // cell/cursor path in the live loop — is Win32-only and not exercised here;
    // its per-path wiring is covered by review and tracked for a host test when
    // buildQuads is extracted into a testable renderer module.)
    {
        var cache = try GlyphCache.init(alloc, font_path, 16, 256);
        defer cache.deinit();
        const h = cache.get('H', false, false) orelse return error.NoPadH;
        g.bindTexture(GL_TEXTURE_2D, tex);
        g.pixelStorei(GL_UNPACK_ALIGNMENT, 1);
        g.texImage2D(GL_TEXTURE_2D, 0, GL_R8, @intCast(cache.atlas.size), @intCast(cache.atlas.size), 0, GL_RED, GL_UNSIGNED_BYTE, cache.atlas.data.ptr);

        const pad_x: u32 = 20;
        const lay = surface.layout(screen_w, screen_h, 16, 16, .{ .x = @intCast(pad_x), .y = 8 });
        if (lay.origin_x != pad_x) return error.PadOriginWrong; // no balance -> origin == pad

        var mins: [2]usize = .{ screen_w, screen_w };
        for ([_]u32{ 0, lay.origin_x }, 0..) |ox, pass| {
            var gv: std.ArrayList(gl.Vertex) = .empty;
            defer gv.deinit(alloc);
            try gl.pushQuad(&gv, alloc, .{
                .px = @as(i32, @intCast(ox)) + h.bearing_x,
                .py = 20,
                .sx = h.region.x,
                .sy = h.region.y,
                .sw = h.region.width,
                .sh = h.region.height,
                .r = 1,
                .g = 1,
                .b = 1,
            }, screen_w, screen_h, cache.atlas.size);
            g.clearColor(clear[0], clear[1], clear[2], 1.0);
            g.clear(GL_COLOR_BUFFER_BIT);
            g.bufferData(GL_ARRAY_BUFFER, @intCast(gv.items.len * @sizeOf(gl.Vertex)), gv.items.ptr, GL_DYNAMIC_DRAW);
            g.drawArrays(GL_TRIANGLES, 0, @intCast(gv.items.len));
            g.finish();
            g.readPixels(0, 0, @intCast(screen_w), @intCast(screen_h), GL_RGBA, GL_UNSIGNED_BYTE, buf.ptr);
            var mn: usize = screen_w;
            var any = false;
            var k: usize = 0;
            while (k < n) : (k += 1) {
                const r: i16 = buf[k * 4];
                const gg: i16 = buf[k * 4 + 1];
                const b: i16 = buf[k * 4 + 2];
                if (@abs(r - cr) > 2 or @abs(gg - cg) > 2 or @abs(b - cb) > 2) {
                    mn = @min(mn, k % screen_w);
                    any = true;
                }
            }
            if (!any) return error.PadNothingLit;
            mins[pass] = mn;
        }
        out.print("[proof] window-padding: leftmost lit x — no-pad={d}, pad(20)={d}\n", .{ mins[0], mins[1] });
        // The SAME glyph drawn at origin 0 vs origin pad_x shifts its leftmost
        // lit pixel by EXACTLY pad_x — the internal bearing/first-lit-column
        // offset is identical in both, so it cancels. Asserting the exact shift
        // is robust to any (even negative) bearing, unlike an absolute floor.
        if (mins[1] != mins[0] + pad_x) {
            out.print("[proof] FAIL: padding did not shift the glyph by exactly the configured pad\n", .{});
            return error.PaddingNotApplied;
        }
        out.print("[proof] PASS: window padding shifted the rendered glyph right by exactly the configured pad\n", .{});
    }

    // --- Scrollbar proof (#73): the thumb tracks the viewport position ------
    // `scroll.scrollbarThumb` (host-tested) sizes/places the thumb; here we draw
    // it as a solid on the right edge at two scroll offsets and confirm the lit
    // thumb moves DOWN the track as the viewport moves toward the live bottom —
    // proving the thumb geometry reaches the framebuffer. (The App-side
    // `appendScrollbar` mapping is Win32-only and cross-compile-verified.)
    {
        const total: usize = 100;
        const len: usize = 20;
        const track: f32 = @floatFromInt(screen_h);
        const bar_w: u32 = 6;
        const bar_x: i32 = @intCast(screen_w - bar_w);

        var centers: [2]f32 = .{ 0, 0 };
        // offset 0 = scrolled to the oldest line (thumb at top); offset total-len
        // = the live bottom (thumb at the track end).
        for ([_]usize{ 0, total - len }, 0..) |off, pass| {
            const thumb = scroll.scrollbarThumb(total, len, off, track);
            var sv: std.ArrayList(gl.Vertex) = .empty;
            defer sv.deinit(alloc);
            try gl.pushSolid(&sv, alloc, .{
                .px = bar_x,
                .py = @intFromFloat(@round(thumb.offset)),
                .w = bar_w,
                .h = @max(1, @as(u32, @intFromFloat(@round(thumb.size)))),
                .r = 1,
                .g = 1,
                .b = 1,
            }, screen_w, screen_h);
            g.clearColor(clear[0], clear[1], clear[2], 1.0);
            g.clear(GL_COLOR_BUFFER_BIT);
            g.bufferData(GL_ARRAY_BUFFER, @intCast(sv.items.len * @sizeOf(gl.Vertex)), sv.items.ptr, GL_DYNAMIC_DRAW);
            g.drawArrays(GL_TRIANGLES, 0, @intCast(sv.items.len));
            g.finish();
            g.readPixels(0, 0, @intCast(screen_w), @intCast(screen_h), GL_RGBA, GL_UNSIGNED_BYTE, buf.ptr);
            // Average y of lit pixels in the right-edge band (x >= bar_x).
            var sum_y: usize = 0;
            var cnt: usize = 0;
            var pix: usize = 0;
            while (pix < n) : (pix += 1) {
                const x = pix % screen_w;
                if (x < @as(usize, @intCast(bar_x))) continue;
                const r: i16 = buf[pix * 4];
                const gg: i16 = buf[pix * 4 + 1];
                const b: i16 = buf[pix * 4 + 2];
                if (@abs(r - cr) > 2 or @abs(gg - cg) > 2 or @abs(b - cb) > 2) {
                    // readPixels is bottom-up (GL origin is bottom-left), so flip
                    // to screen coords (top = 0) to match the renderer's y-down
                    // projection — the scrollbar's py=0 is the visual top.
                    sum_y += screen_h - 1 - (pix / screen_w);
                    cnt += 1;
                }
            }
            if (cnt == 0) return error.ScrollbarNothingLit;
            centers[pass] = @as(f32, @floatFromInt(sum_y)) / @as(f32, @floatFromInt(cnt));
        }
        out.print("[proof] scrollbar: thumb center y — top-offset={d:.1}, bottom-offset={d:.1}\n", .{ centers[0], centers[1] });
        // Moving the viewport to the bottom must push the thumb clearly downward.
        if (centers[1] <= centers[0] + @as(f32, @floatFromInt(screen_h)) / 4.0) {
            out.print("[proof] FAIL: scrollbar thumb did not move down as the viewport scrolled\n", .{});
            return error.ScrollbarNotTracking;
        }
        out.print("[proof] PASS: scrollbar thumb tracks the viewport position (moves down toward the live bottom)\n", .{});
    }

    // --- bold-is-bright proof (#70): a bold palette cell uses the bright color
    // Exercise the EXACT `Style.fg` options whostty's buildQuads passes: a bold
    // cell with palette index 1 resolves to palette[1] normally, but to the
    // bright counterpart palette[9] when `bold = .bright` (bold-is-bright). This
    // proves the resolution effect + that the `.bright` literal whostty uses
    // compiles. (buildQuads itself — which passes this option at both fg sites —
    // is Win32-only and not reached here; that wiring is covered by review and
    // tracked for a host test when buildQuads is extracted into a testable module.)
    {
        var pal = vtcolor.default;
        var st: vt.Style = .{};
        st.flags.bold = true;
        st.fg_color = .{ .palette = 1 };
        const white: vtcolor.RGB = .{ .r = 0xff, .g = 0xff, .b = 0xff };
        const normal = st.fg(.{ .default = white, .palette = &pal });
        const bright = st.fg(.{ .default = white, .palette = &pal, .bold = .bright });
        out.print("[proof] bold-is-bright: palette[1]=rgb({d},{d},{d}) bold=rgb({d},{d},{d}) palette[9]=rgb({d},{d},{d})\n", .{
            normal.r, normal.g, normal.b, bright.r, bright.g, bright.b, pal[9].r, pal[9].g, pal[9].b,
        });
        if (normal.r == bright.r and normal.g == bright.g and normal.b == bright.b) {
            out.print("[proof] FAIL: bold-is-bright did not change the color\n", .{});
            return error.BoldNotBright;
        }
        if (bright.r != pal[9].r or bright.g != pal[9].g or bright.b != pal[9].b) {
            out.print("[proof] FAIL: bold color is not the bright palette entry (9)\n", .{});
            return error.BoldWrongColor;
        }
        out.print("[proof] PASS: bold-is-bright maps palette 1 -> 9 (Style.fg resolution; buildQuads wiring review-covered)\n", .{});
    }

    // --- Decoration sprites proof (#80): underline styles draw distinctly -----
    // Render the SAME `decoration.underlineRects` geometry buildQuads uses: a
    // dotted underline must leave gaps (fewer lit pixels than a solid single),
    // and a curly underline must oscillate (span more than one row) — proving
    // the styles reach the framebuffer as more than one flat line.
    {
        const cw: u32 = 40;
        const base: i32 = 20;
        const thick: u32 = 2;

        const Measure = struct {
            fn run(g2: GL, alloc2: std.mem.Allocator, rects: []const decoration.Rect, sw: u32, sh: u32, buf2: []u8, n2: usize, c: [3]i16) struct { lit: usize, min_y: usize, max_y: usize } {
                var dverts: std.ArrayList(gl.Vertex) = .empty;
                defer dverts.deinit(alloc2);
                for (rects) |r| gl.pushSolid(&dverts, alloc2, .{ .px = r.x, .py = r.y, .w = r.w, .h = r.h, .r = 1, .g = 1, .b = 1 }, sw, sh) catch {};
                g2.clearColor(0.1, 0.1, 0.12, 1.0);
                g2.clear(GL_COLOR_BUFFER_BIT);
                g2.bufferData(GL_ARRAY_BUFFER, @intCast(dverts.items.len * @sizeOf(gl.Vertex)), dverts.items.ptr, GL_DYNAMIC_DRAW);
                g2.drawArrays(GL_TRIANGLES, 0, @intCast(dverts.items.len));
                g2.finish();
                g2.readPixels(0, 0, @intCast(sw), @intCast(sh), GL_RGBA, GL_UNSIGNED_BYTE, buf2.ptr);
                var dlit: usize = 0;
                var dmn: usize = sh;
                var dmx: usize = 0;
                var di: usize = 0;
                while (di < n2) : (di += 1) {
                    if (@abs(@as(i16, buf2[di * 4]) - c[0]) > 2 or @abs(@as(i16, buf2[di * 4 + 1]) - c[1]) > 2 or @abs(@as(i16, buf2[di * 4 + 2]) - c[2]) > 2) {
                        dlit += 1;
                        const dyrow = di / sw;
                        dmn = @min(dmn, dyrow);
                        dmx = @max(dmx, dyrow);
                    }
                }
                // No lit pixels -> a 0-span (dmn was left at sh); normalize so the
                // caller's `max_y - min_y` never underflows (usize).
                if (dlit == 0) {
                    dmn = 0;
                    dmx = 0;
                }
                return .{ .lit = dlit, .min_y = dmn, .max_y = dmx };
            }
        };
        const cc = [3]i16{ cr, cg, cb };

        var single_rects: std.ArrayList(decoration.Rect) = .empty;
        defer single_rects.deinit(alloc);
        var dotted_rects: std.ArrayList(decoration.Rect) = .empty;
        defer dotted_rects.deinit(alloc);
        var curly_rects: std.ArrayList(decoration.Rect) = .empty;
        defer curly_rects.deinit(alloc);
        try decoration.underlineRects(&single_rects, alloc, .single, cw, base, thick);
        try decoration.underlineRects(&dotted_rects, alloc, .dotted, cw, base, thick);
        try decoration.underlineRects(&curly_rects, alloc, .curly, cw, base, thick);

        const single = Measure.run(g, alloc, single_rects.items, screen_w, screen_h, buf, n, cc);
        const dotted = Measure.run(g, alloc, dotted_rects.items, screen_w, screen_h, buf, n, cc);
        const curly = Measure.run(g, alloc, curly_rects.items, screen_w, screen_h, buf, n, cc);

        out.print("[proof] decorations: single lit={d}, dotted lit={d} (gaps), curly y-span={d}\n", .{ single.lit, dotted.lit, curly.max_y - curly.min_y });
        if (dotted.lit == 0 or dotted.lit >= single.lit) {
            out.print("[proof] FAIL: dotted underline did not leave gaps\n", .{});
            return error.DottedNoGaps;
        }
        if (curly.max_y <= curly.min_y) {
            out.print("[proof] FAIL: curly underline did not oscillate\n", .{});
            return error.CurlyFlat;
        }
        out.print("[proof] PASS: underline styles draw distinctly (dotted gaps, curly squiggle)\n", .{});
    }
}
