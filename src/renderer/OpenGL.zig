//! whostty: OpenGL renderer.
//!
//! Reference: ghostty `src/renderer/OpenGL.zig` (strategy: port — ghostty's
//! renderer is far richer (cell program, image program, custom shaders);
//! whostty draws a single textured-quad pass over a flat list of quads. Two
//! quad kinds share one pass via a per-vertex `mode`: glyph quads sample an R8
//! coverage atlas (mode 0), solid quads ignore the atlas and fill with their
//! color (mode 1). Solid quads back SGR background colors and the underline /
//! strikethrough / overline decorations (#12). GL >= 2.0 entry points are
//! loaded at runtime via a proc loader (wglGetProcAddress); GL 1.1 calls bind
//! directly to opengl32. The renderer consumes atlas bytes and per-cell
//! placement, so it has no dependency on the font/Freetype layer. See
//! PORTING.md.
const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.opengl);

/// A drawable glyph: a glyph region in the atlas placed at a pixel position,
/// tinted by a foreground color.
pub const Cell = struct {
    /// Top-left pixel position of the glyph bitmap in the window.
    px: i32,
    py: i32,
    /// Source region in the atlas (texels).
    sx: u32,
    sy: u32,
    sw: u32,
    sh: u32,
    /// Foreground color (0..1).
    r: f32 = 1,
    g: f32 = 1,
    b: f32 = 1,
};

/// A solid filled rectangle in window pixels, tinted by a color. Used for SGR
/// background fills and the underline / strikethrough / overline decorations.
pub const SolidRect = struct {
    px: i32,
    py: i32,
    w: u32,
    h: u32,
    /// Fill color (0..1).
    r: f32,
    g: f32,
    b: f32,
};

/// A single drawable primitive. Quads are drawn in slice order, so callers
/// control layering: emit a cell's background solid before its glyph, and any
/// decoration solids after it.
pub const Quad = union(enum) {
    glyph: Cell,
    solid: SolidRect,
};

/// Per-vertex draw mode discriminator (see the fragment shader).
const mode_glyph: f32 = 0;
const mode_solid: f32 = 1;

/// Interleaved vertex: position (NDC) + atlas uv + color + draw mode.
pub const Vertex = extern struct {
    x: f32,
    y: f32,
    u: f32,
    v: f32,
    r: f32,
    g: f32,
    b: f32,
    /// 0 = sample the atlas coverage (glyph), 1 = solid fill.
    m: f32,
};

/// Pixel rect -> NDC. y is flipped (pixel y grows down, NDC y grows up).
/// Returns the four NDC corners as (x0, x1, y0, y1).
fn ndcRect(px: i32, py: i32, w: u32, h: u32, screen_w: u32, screen_h: u32) struct {
    x0: f32,
    x1: f32,
    y0: f32,
    y1: f32,
} {
    const sw: f32 = @floatFromInt(screen_w);
    const sh: f32 = @floatFromInt(screen_h);
    const x0f: f32 = @floatFromInt(px);
    const y0f: f32 = @floatFromInt(py);
    const x1f: f32 = @floatFromInt(px + @as(i32, @intCast(w)));
    const y1f: f32 = @floatFromInt(py + @as(i32, @intCast(h)));
    return .{
        .x0 = (x0f / sw) * 2.0 - 1.0,
        .x1 = (x1f / sw) * 2.0 - 1.0,
        .y0 = 1.0 - (y0f / sh) * 2.0,
        .y1 = 1.0 - (y1f / sh) * 2.0,
    };
}

/// Append the 6 vertices (two triangles) for one glyph cell into `out`. Pure
/// geometry: pixel rect -> NDC, atlas rect -> uv. Host-testable.
pub fn pushQuad(
    out: *std.ArrayList(Vertex),
    alloc: std.mem.Allocator,
    cell: Cell,
    screen_w: u32,
    screen_h: u32,
    atlas_size: u32,
) !void {
    const as: f32 = @floatFromInt(atlas_size);
    const n = ndcRect(cell.px, cell.py, cell.sw, cell.sh, screen_w, screen_h);

    const su0: f32 = @as(f32, @floatFromInt(cell.sx)) / as;
    const su1: f32 = @as(f32, @floatFromInt(cell.sx + cell.sw)) / as;
    const sv0: f32 = @as(f32, @floatFromInt(cell.sy)) / as;
    const sv1: f32 = @as(f32, @floatFromInt(cell.sy + cell.sh)) / as;

    const tl: Vertex = .{ .x = n.x0, .y = n.y0, .u = su0, .v = sv0, .r = cell.r, .g = cell.g, .b = cell.b, .m = mode_glyph };
    const tr: Vertex = .{ .x = n.x1, .y = n.y0, .u = su1, .v = sv0, .r = cell.r, .g = cell.g, .b = cell.b, .m = mode_glyph };
    const bl: Vertex = .{ .x = n.x0, .y = n.y1, .u = su0, .v = sv1, .r = cell.r, .g = cell.g, .b = cell.b, .m = mode_glyph };
    const br: Vertex = .{ .x = n.x1, .y = n.y1, .u = su1, .v = sv1, .r = cell.r, .g = cell.g, .b = cell.b, .m = mode_glyph };

    try out.appendSlice(alloc, &.{ tl, bl, br, tl, br, tr });
}

/// Append the 6 vertices for one solid filled rect into `out`. uv is unused
/// (the fragment shader ignores the atlas in solid mode). Host-testable.
pub fn pushSolid(
    out: *std.ArrayList(Vertex),
    alloc: std.mem.Allocator,
    rect: SolidRect,
    screen_w: u32,
    screen_h: u32,
) !void {
    const n = ndcRect(rect.px, rect.py, rect.w, rect.h, screen_w, screen_h);
    const tl: Vertex = .{ .x = n.x0, .y = n.y0, .u = 0, .v = 0, .r = rect.r, .g = rect.g, .b = rect.b, .m = mode_solid };
    const tr: Vertex = .{ .x = n.x1, .y = n.y0, .u = 0, .v = 0, .r = rect.r, .g = rect.g, .b = rect.b, .m = mode_solid };
    const bl: Vertex = .{ .x = n.x0, .y = n.y1, .u = 0, .v = 0, .r = rect.r, .g = rect.g, .b = rect.b, .m = mode_solid };
    const br: Vertex = .{ .x = n.x1, .y = n.y1, .u = 0, .v = 0, .r = rect.r, .g = rect.g, .b = rect.b, .m = mode_solid };
    try out.appendSlice(alloc, &.{ tl, bl, br, tl, br, tr });
}

// --- GL constants ----------------------------------------------------------

const GLenum = c_uint;
const GLuint = c_uint;
const GLint = c_int;
const GLsizei = c_int;
const GLfloat = f32;
const GLboolean = u8;
const GLchar = u8;
const GLbitfield = c_uint;
const GLintptr = isize;
const GLsizeiptr = isize;

const GL_COLOR_BUFFER_BIT: GLbitfield = 0x00004000;
const GL_TRIANGLES: GLenum = 0x0004;
const GL_TEXTURE_2D: GLenum = 0x0DE1;
const GL_TEXTURE0: GLenum = 0x84C0;
const GL_RED: GLenum = 0x1903;
const GL_R8: GLenum = 0x8229;
const GL_UNSIGNED_BYTE: GLenum = 0x1401;
const GL_FLOAT: GLenum = 0x1406;
const GL_FALSE: GLboolean = 0;
const GL_TRUE: GLboolean = 1;
const GL_TEXTURE_MIN_FILTER: GLenum = 0x2801;
const GL_TEXTURE_MAG_FILTER: GLenum = 0x2800;
const GL_TEXTURE_WRAP_S: GLenum = 0x2802;
const GL_TEXTURE_WRAP_T: GLenum = 0x2803;
const GL_LINEAR: GLint = 0x2601;
const GL_NEAREST: GLint = 0x2600;
const GL_CLAMP_TO_EDGE: GLint = 0x812F;
const GL_RGBA: GLenum = 0x1908;
const GL_BLEND: GLenum = 0x0BE2;
const GL_SRC_ALPHA: GLenum = 0x0302;
const GL_ONE_MINUS_SRC_ALPHA: GLenum = 0x0303;
const GL_ARRAY_BUFFER: GLenum = 0x8892;
const GL_DYNAMIC_DRAW: GLenum = 0x88E8;
const GL_VERTEX_SHADER: GLenum = 0x8B31;
const GL_FRAGMENT_SHADER: GLenum = 0x8B30;
const GL_COMPILE_STATUS: GLenum = 0x8B81;
const GL_LINK_STATUS: GLenum = 0x8B82;
const GL_UNPACK_ALIGNMENT: GLenum = 0x0CF5;

// GL 1.1 (exported by opengl32).
extern "opengl32" fn glClear(mask: GLbitfield) callconv(.winapi) void;
extern "opengl32" fn glClearColor(r: GLfloat, g: GLfloat, b: GLfloat, a: GLfloat) callconv(.winapi) void;
extern "opengl32" fn glViewport(x: GLint, y: GLint, w: GLsizei, h: GLsizei) callconv(.winapi) void;
extern "opengl32" fn glEnable(cap: GLenum) callconv(.winapi) void;
extern "opengl32" fn glBlendFunc(s: GLenum, d: GLenum) callconv(.winapi) void;
extern "opengl32" fn glGenTextures(n: GLsizei, textures: [*]GLuint) callconv(.winapi) void;
extern "opengl32" fn glBindTexture(target: GLenum, texture: GLuint) callconv(.winapi) void;
extern "opengl32" fn glTexParameteri(target: GLenum, pname: GLenum, param: GLint) callconv(.winapi) void;
extern "opengl32" fn glTexImage2D(target: GLenum, level: GLint, internalFormat: GLint, w: GLsizei, h: GLsizei, border: GLint, format: GLenum, type: GLenum, pixels: ?*const anyopaque) callconv(.winapi) void;
extern "opengl32" fn glPixelStorei(pname: GLenum, param: GLint) callconv(.winapi) void;
extern "opengl32" fn glDrawArrays(mode: GLenum, first: GLint, count: GLsizei) callconv(.winapi) void;
extern "opengl32" fn glReadPixels(x: GLint, y: GLint, w: GLsizei, h: GLsizei, format: GLenum, type: GLenum, pixels: ?*anyopaque) callconv(.winapi) void;
extern "opengl32" fn glFinish() callconv(.winapi) void;

/// Proc loader: maps a GL function name to its address (wglGetProcAddress).
pub const GetProcFn = *const fn ([*:0]const u8) callconv(.winapi) ?*const anyopaque;

/// GL >= 2.0 entry points, loaded at runtime.
const GlExt = struct {
    createShader: *const fn (GLenum) callconv(.winapi) GLuint,
    shaderSource: *const fn (GLuint, GLsizei, [*]const [*:0]const GLchar, ?[*]const GLint) callconv(.winapi) void,
    compileShader: *const fn (GLuint) callconv(.winapi) void,
    getShaderiv: *const fn (GLuint, GLenum, *GLint) callconv(.winapi) void,
    createProgram: *const fn () callconv(.winapi) GLuint,
    attachShader: *const fn (GLuint, GLuint) callconv(.winapi) void,
    linkProgram: *const fn (GLuint) callconv(.winapi) void,
    getProgramiv: *const fn (GLuint, GLenum, *GLint) callconv(.winapi) void,
    useProgram: *const fn (GLuint) callconv(.winapi) void,
    deleteShader: *const fn (GLuint) callconv(.winapi) void,
    genBuffers: *const fn (GLsizei, [*]GLuint) callconv(.winapi) void,
    bindBuffer: *const fn (GLenum, GLuint) callconv(.winapi) void,
    bufferData: *const fn (GLenum, GLsizeiptr, ?*const anyopaque, GLenum) callconv(.winapi) void,
    genVertexArrays: *const fn (GLsizei, [*]GLuint) callconv(.winapi) void,
    bindVertexArray: *const fn (GLuint) callconv(.winapi) void,
    vertexAttribPointer: *const fn (GLuint, GLint, GLenum, GLboolean, GLsizei, ?*const anyopaque) callconv(.winapi) void,
    enableVertexAttribArray: *const fn (GLuint) callconv(.winapi) void,
    getUniformLocation: *const fn (GLuint, [*:0]const GLchar) callconv(.winapi) GLint,
    uniform1i: *const fn (GLint, GLint) callconv(.winapi) void,
    activeTexture: *const fn (GLenum) callconv(.winapi) void,
    getShaderInfoLog: *const fn (GLuint, GLsizei, ?*GLsizei, [*]GLchar) callconv(.winapi) void,
    getProgramInfoLog: *const fn (GLuint, GLsizei, ?*GLsizei, [*]GLchar) callconv(.winapi) void,

    fn load(get: GetProcFn) !GlExt {
        const L = struct {
            fn p(g: GetProcFn, comptime T: type, name: [*:0]const u8) !T {
                // wglGetProcAddress returns null for unsupported names, and
                // (famously) the sentinels 1, 2, 3 or -1 on some drivers — guard
                // both so we never call through a bogus pointer.
                const addr = g(name) orelse {
                    log.err("GL function unavailable (null): {s}", .{name});
                    return error.GlFunctionMissing;
                };
                const a = @intFromPtr(addr);
                if (a <= 3 or a == std.math.maxInt(usize)) {
                    log.err("GL function unavailable (sentinel {d}): {s}", .{ a, name });
                    return error.GlFunctionMissing;
                }
                return @ptrCast(addr);
            }
        };
        return .{
            .createShader = try L.p(get, *const fn (GLenum) callconv(.winapi) GLuint, "glCreateShader"),
            .shaderSource = try L.p(get, @TypeOf(@as(GlExt, undefined).shaderSource), "glShaderSource"),
            .compileShader = try L.p(get, @TypeOf(@as(GlExt, undefined).compileShader), "glCompileShader"),
            .getShaderiv = try L.p(get, @TypeOf(@as(GlExt, undefined).getShaderiv), "glGetShaderiv"),
            .createProgram = try L.p(get, @TypeOf(@as(GlExt, undefined).createProgram), "glCreateProgram"),
            .attachShader = try L.p(get, @TypeOf(@as(GlExt, undefined).attachShader), "glAttachShader"),
            .linkProgram = try L.p(get, @TypeOf(@as(GlExt, undefined).linkProgram), "glLinkProgram"),
            .getProgramiv = try L.p(get, @TypeOf(@as(GlExt, undefined).getProgramiv), "glGetProgramiv"),
            .useProgram = try L.p(get, @TypeOf(@as(GlExt, undefined).useProgram), "glUseProgram"),
            .deleteShader = try L.p(get, @TypeOf(@as(GlExt, undefined).deleteShader), "glDeleteShader"),
            .genBuffers = try L.p(get, @TypeOf(@as(GlExt, undefined).genBuffers), "glGenBuffers"),
            .bindBuffer = try L.p(get, @TypeOf(@as(GlExt, undefined).bindBuffer), "glBindBuffer"),
            .bufferData = try L.p(get, @TypeOf(@as(GlExt, undefined).bufferData), "glBufferData"),
            .genVertexArrays = try L.p(get, @TypeOf(@as(GlExt, undefined).genVertexArrays), "glGenVertexArrays"),
            .bindVertexArray = try L.p(get, @TypeOf(@as(GlExt, undefined).bindVertexArray), "glBindVertexArray"),
            .vertexAttribPointer = try L.p(get, @TypeOf(@as(GlExt, undefined).vertexAttribPointer), "glVertexAttribPointer"),
            .enableVertexAttribArray = try L.p(get, @TypeOf(@as(GlExt, undefined).enableVertexAttribArray), "glEnableVertexAttribArray"),
            .getUniformLocation = try L.p(get, @TypeOf(@as(GlExt, undefined).getUniformLocation), "glGetUniformLocation"),
            .uniform1i = try L.p(get, @TypeOf(@as(GlExt, undefined).uniform1i), "glUniform1i"),
            .activeTexture = try L.p(get, @TypeOf(@as(GlExt, undefined).activeTexture), "glActiveTexture"),
            .getShaderInfoLog = try L.p(get, @TypeOf(@as(GlExt, undefined).getShaderInfoLog), "glGetShaderInfoLog"),
            .getProgramInfoLog = try L.p(get, @TypeOf(@as(GlExt, undefined).getProgramInfoLog), "glGetProgramInfoLog"),
        };
    }
};

pub const vertex_shader_src: [:0]const u8 =
    \\#version 330 core
    \\layout (location = 0) in vec2 a_pos;
    \\layout (location = 1) in vec2 a_uv;
    \\layout (location = 2) in vec3 a_color;
    \\layout (location = 3) in float a_mode;
    \\out vec2 v_uv;
    \\out vec3 v_color;
    \\out float v_mode;
    \\void main() {
    \\    v_uv = a_uv;
    \\    v_color = a_color;
    \\    v_mode = a_mode;
    \\    gl_Position = vec4(a_pos, 0.0, 1.0);
    \\}
;

pub const fragment_shader_src: [:0]const u8 =
    \\#version 330 core
    \\in vec2 v_uv;
    \\in vec3 v_color;
    \\in float v_mode;
    \\out vec4 frag;
    \\uniform sampler2D u_atlas;
    \\void main() {
    \\    // mode 0: glyph (alpha from atlas coverage); mode 1: solid fill.
    \\    float a = (v_mode > 0.5) ? 1.0 : texture(u_atlas, v_uv).r;
    \\    frag = vec4(v_color, a);
    \\}
;

/// The GL renderer. Windows-only (binds opengl32); construct on a thread with
/// a current WGL context.
pub const Renderer = struct {
    gl: GlExt,
    program: GLuint,
    vao: GLuint,
    vbo: GLuint,
    atlas_tex: GLuint,
    atlas_size: u32,
    verts: std.ArrayList(Vertex),
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, get: GetProcFn) !Renderer {
        const gl = try GlExt.load(get);

        const vs = try compile(gl, GL_VERTEX_SHADER, vertex_shader_src);
        const fs = try compile(gl, GL_FRAGMENT_SHADER, fragment_shader_src);
        const program = gl.createProgram();
        gl.attachShader(program, vs);
        gl.attachShader(program, fs);
        gl.linkProgram(program);
        var ok: GLint = 0;
        gl.getProgramiv(program, GL_LINK_STATUS, &ok);
        if (ok == 0) {
            var buf: [1024]GLchar = undefined;
            var n: GLsizei = 0;
            gl.getProgramInfoLog(program, buf.len, &n, &buf);
            log.err("program link failed: {s}", .{buf[0..@intCast(@max(0, n))]});
            return error.LinkFailed;
        }
        gl.deleteShader(vs);
        gl.deleteShader(fs);

        var vao: GLuint = 0;
        var vbo: GLuint = 0;
        gl.genVertexArrays(1, @ptrCast(&vao));
        gl.genBuffers(1, @ptrCast(&vbo));
        gl.bindVertexArray(vao);
        gl.bindBuffer(GL_ARRAY_BUFFER, vbo);

        const stride: GLsizei = @sizeOf(Vertex);
        gl.vertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, stride, @ptrFromInt(0));
        gl.enableVertexAttribArray(0);
        gl.vertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, stride, @ptrFromInt(@offsetOf(Vertex, "u")));
        gl.enableVertexAttribArray(1);
        gl.vertexAttribPointer(2, 3, GL_FLOAT, GL_FALSE, stride, @ptrFromInt(@offsetOf(Vertex, "r")));
        gl.enableVertexAttribArray(2);
        gl.vertexAttribPointer(3, 1, GL_FLOAT, GL_FALSE, stride, @ptrFromInt(@offsetOf(Vertex, "m")));
        gl.enableVertexAttribArray(3);

        var tex: GLuint = 0;
        glGenTextures(1, @ptrCast(&tex));

        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);

        return .{
            .gl = gl,
            .program = program,
            .vao = vao,
            .vbo = vbo,
            .atlas_tex = tex,
            .atlas_size = 0,
            .verts = .empty,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.verts.deinit(self.alloc);
        self.* = undefined;
    }

    /// Upload an R8 coverage atlas as the glyph texture.
    pub fn setAtlas(self: *Renderer, data: []const u8, size: u32) void {
        self.atlas_size = size;
        glBindTexture(GL_TEXTURE_2D, self.atlas_tex);
        glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
        glTexImage2D(GL_TEXTURE_2D, 0, @intCast(GL_R8), @intCast(size), @intCast(size), 0, GL_RED, GL_UNSIGNED_BYTE, data.ptr);
        // Nearest filtering (matching ghostty) avoids sampling neighbouring
        // glyphs' coverage at atlas-rect edges under the 1px padding.
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    }

    /// Clear and draw all quads in order. `clear` is the background fill (the
    /// default cell background), `screen_w/h` are the framebuffer pixels. Quads
    /// are emitted in slice order so the caller controls layering (background
    /// solids before glyphs, decoration solids after).
    pub fn draw(self: *Renderer, quads: []const Quad, clear: [3]f32, screen_w: u32, screen_h: u32) !void {
        glViewport(0, 0, @intCast(screen_w), @intCast(screen_h));
        glClearColor(clear[0], clear[1], clear[2], 1.0);
        glClear(GL_COLOR_BUFFER_BIT);

        self.verts.clearRetainingCapacity();
        for (quads) |q| switch (q) {
            .glyph => |cell| try pushQuad(&self.verts, self.alloc, cell, screen_w, screen_h, self.atlas_size),
            .solid => |rect| try pushSolid(&self.verts, self.alloc, rect, screen_w, screen_h),
        };
        if (self.verts.items.len == 0) return;

        self.gl.useProgram(self.program);
        self.gl.bindVertexArray(self.vao);
        self.gl.bindBuffer(GL_ARRAY_BUFFER, self.vbo);
        self.gl.bufferData(
            GL_ARRAY_BUFFER,
            @intCast(self.verts.items.len * @sizeOf(Vertex)),
            self.verts.items.ptr,
            GL_DYNAMIC_DRAW,
        );

        self.gl.activeTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, self.atlas_tex);
        self.gl.uniform1i(self.gl.getUniformLocation(self.program, "u_atlas"), 0);

        glDrawArrays(GL_TRIANGLES, 0, @intCast(self.verts.items.len));
    }

    fn compile(gl: GlExt, kind: GLenum, src: [:0]const u8) !GLuint {
        const sh = gl.createShader(kind);
        var ptr: [*:0]const GLchar = src.ptr;
        gl.shaderSource(sh, 1, @ptrCast(&ptr), null);
        gl.compileShader(sh);
        var ok: GLint = 0;
        gl.getShaderiv(sh, GL_COMPILE_STATUS, &ok);
        if (ok == 0) {
            var buf: [1024]GLchar = undefined;
            var n: GLsizei = 0;
            gl.getShaderInfoLog(sh, buf.len, &n, &buf);
            log.err("shader compile failed ({s}): {s}", .{
                if (kind == GL_VERTEX_SHADER) "vertex" else "fragment",
                buf[0..@intCast(@max(0, n))],
            });
            return error.ShaderCompileFailed;
        }
        return sh;
    }

    /// Debug-only render self-check: read the back buffer and count pixels that
    /// differ from the clear colour, logging the tally to stderr. Lets a build
    /// that can't be screenshotted (WDAC, no capture) confirm glyphs reached
    /// pixels. Gated by the caller (WHOSTTY_RENDER_DEBUG=1); allocates w*h*4.
    /// Call after `draw` and before `swapBuffers` (reads the back buffer).
    pub fn debugCountLitPixels(self: *Renderer, clear: [3]f32, screen_w: u32, screen_h: u32) void {
        glFinish();
        const n = @as(usize, screen_w) * @as(usize, screen_h);
        if (n == 0) return;
        const buf = self.alloc.alloc(u8, n * 4) catch return;
        defer self.alloc.free(buf);
        glReadPixels(0, 0, @intCast(screen_w), @intCast(screen_h), GL_RGBA, GL_UNSIGNED_BYTE, buf.ptr);
        const cr: i16 = @intFromFloat(@round(clear[0] * 255.0));
        const cg: i16 = @intFromFloat(@round(clear[1] * 255.0));
        const cb: i16 = @intFromFloat(@round(clear[2] * 255.0));
        var lit: usize = 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const r: i16 = buf[i * 4 + 0];
            const g: i16 = buf[i * 4 + 1];
            const b: i16 = buf[i * 4 + 2];
            if (@abs(r - cr) > 2 or @abs(g - cg) > 2 or @abs(b - cb) > 2) lit += 1;
        }
        log.info("[render-debug] {d}x{d} verts={d} lit_pixels={d}/{d} ({d:.3}%)", .{
            screen_w, screen_h, self.verts.items.len, lit, n,
            @as(f64, @floatFromInt(lit)) * 100.0 / @as(f64, @floatFromInt(n)),
        });
    }
};

test "renderer: pushQuad maps pixel rect to NDC and emits 6 verts" {
    const alloc = std.testing.allocator;
    var verts: std.ArrayList(Vertex) = .empty;
    defer verts.deinit(alloc);

    // A 10x10 glyph at top-left of a 100x100 window, atlas 100.
    try pushQuad(&verts, alloc, .{ .px = 0, .py = 0, .sx = 0, .sy = 0, .sw = 10, .sh = 10 }, 100, 100, 100);
    try std.testing.expectEqual(@as(usize, 6), verts.items.len);

    // Top-left pixel (0,0) -> NDC (-1, +1).
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), verts.items[0].x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), verts.items[0].y, 0.0001);
    // uv at origin is (0,0).
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), verts.items[0].u, 0.0001);
}

test "renderer: center pixel maps near NDC origin" {
    const alloc = std.testing.allocator;
    var verts: std.ArrayList(Vertex) = .empty;
    defer verts.deinit(alloc);
    try pushQuad(&verts, alloc, .{ .px = 50, .py = 50, .sx = 0, .sy = 0, .sw = 0, .sh = 0 }, 100, 100, 100);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), verts.items[0].x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), verts.items[0].y, 0.0001);
}

test "renderer: glyph quads carry the glyph mode" {
    const alloc = std.testing.allocator;
    var verts: std.ArrayList(Vertex) = .empty;
    defer verts.deinit(alloc);
    try pushQuad(&verts, alloc, .{ .px = 0, .py = 0, .sx = 0, .sy = 0, .sw = 4, .sh = 4 }, 100, 100, 100);
    for (verts.items) |v| try std.testing.expectEqual(mode_glyph, v.m);
}

test "renderer: pushSolid maps full cell rect, solid mode, zero uv" {
    const alloc = std.testing.allocator;
    var verts: std.ArrayList(Vertex) = .empty;
    defer verts.deinit(alloc);

    // A 10x10 fill at top-left of a 100x100 window with color (1, 0, 0).
    try pushSolid(&verts, alloc, .{ .px = 0, .py = 0, .w = 10, .h = 10, .r = 1, .g = 0, .b = 0 }, 100, 100);
    try std.testing.expectEqual(@as(usize, 6), verts.items.len);

    for (verts.items) |v| {
        try std.testing.expectEqual(mode_solid, v.m);
        // Solid quads do not sample the atlas: uv is pinned to the origin.
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), v.u, 0.0001);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), v.v, 0.0001);
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), v.r, 0.0001);
    }
    // Top-left pixel (0,0) -> NDC (-1, +1).
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), verts.items[0].x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), verts.items[0].y, 0.0001);
}
