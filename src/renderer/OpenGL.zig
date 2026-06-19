//! whostty: OpenGL renderer backend.
//!
//! Reference: ghostty `src/renderer/OpenGL.zig` (strategy: port). This is the
//! WGL/OpenGL backend behind the renderer abstraction; it consumes the
//! backend-neutral geometry from `geometry.zig` and only owns the GL program,
//! buffers, atlas texture, and draw call. A single textured-quad pass draws
//! both glyph coverage and solid fills via a per-vertex `mode` (see the
//! fragment shader). GL >= 2.0 entry points are loaded at runtime via a proc
//! loader (wglGetProcAddress); GL 1.1 calls bind directly to opengl32.
//! Direct3D is the long-term native backend (#15). See PORTING.md.
const std = @import("std");
const builtin = @import("builtin");
const geometry = @import("geometry.zig");

// Re-export the shared geometry types so existing callers (apprt) can keep
// using `OpenGL.Cell` / `OpenGL.Quad` etc. through the active backend.
pub const Cell = geometry.Cell;
pub const SolidRect = geometry.SolidRect;
pub const Quad = geometry.Quad;
pub const Vertex = geometry.Vertex;
pub const pushQuad = geometry.pushQuad;
pub const pushSolid = geometry.pushSolid;

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
const GL_CLAMP_TO_EDGE: GLint = 0x812F;
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

    fn load(get: GetProcFn) GlExt {
        const L = struct {
            fn p(g: GetProcFn, comptime T: type, name: [*:0]const u8) T {
                return @ptrCast(g(name) orelse @panic("GL function not found"));
            }
        };
        return .{
            .createShader = L.p(get, *const fn (GLenum) callconv(.winapi) GLuint, "glCreateShader"),
            .shaderSource = L.p(get, @TypeOf(@as(GlExt, undefined).shaderSource), "glShaderSource"),
            .compileShader = L.p(get, @TypeOf(@as(GlExt, undefined).compileShader), "glCompileShader"),
            .getShaderiv = L.p(get, @TypeOf(@as(GlExt, undefined).getShaderiv), "glGetShaderiv"),
            .createProgram = L.p(get, @TypeOf(@as(GlExt, undefined).createProgram), "glCreateProgram"),
            .attachShader = L.p(get, @TypeOf(@as(GlExt, undefined).attachShader), "glAttachShader"),
            .linkProgram = L.p(get, @TypeOf(@as(GlExt, undefined).linkProgram), "glLinkProgram"),
            .getProgramiv = L.p(get, @TypeOf(@as(GlExt, undefined).getProgramiv), "glGetProgramiv"),
            .useProgram = L.p(get, @TypeOf(@as(GlExt, undefined).useProgram), "glUseProgram"),
            .deleteShader = L.p(get, @TypeOf(@as(GlExt, undefined).deleteShader), "glDeleteShader"),
            .genBuffers = L.p(get, @TypeOf(@as(GlExt, undefined).genBuffers), "glGenBuffers"),
            .bindBuffer = L.p(get, @TypeOf(@as(GlExt, undefined).bindBuffer), "glBindBuffer"),
            .bufferData = L.p(get, @TypeOf(@as(GlExt, undefined).bufferData), "glBufferData"),
            .genVertexArrays = L.p(get, @TypeOf(@as(GlExt, undefined).genVertexArrays), "glGenVertexArrays"),
            .bindVertexArray = L.p(get, @TypeOf(@as(GlExt, undefined).bindVertexArray), "glBindVertexArray"),
            .vertexAttribPointer = L.p(get, @TypeOf(@as(GlExt, undefined).vertexAttribPointer), "glVertexAttribPointer"),
            .enableVertexAttribArray = L.p(get, @TypeOf(@as(GlExt, undefined).enableVertexAttribArray), "glEnableVertexAttribArray"),
            .getUniformLocation = L.p(get, @TypeOf(@as(GlExt, undefined).getUniformLocation), "glGetUniformLocation"),
            .uniform1i = L.p(get, @TypeOf(@as(GlExt, undefined).uniform1i), "glUniform1i"),
            .activeTexture = L.p(get, @TypeOf(@as(GlExt, undefined).activeTexture), "glActiveTexture"),
        };
    }
};

const vertex_shader_src: [:0]const u8 =
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

const fragment_shader_src: [:0]const u8 =
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
        const gl = GlExt.load(get);

        const vs = try compile(gl, GL_VERTEX_SHADER, vertex_shader_src);
        const fs = try compile(gl, GL_FRAGMENT_SHADER, fragment_shader_src);
        const program = gl.createProgram();
        gl.attachShader(program, vs);
        gl.attachShader(program, fs);
        gl.linkProgram(program);
        var ok: GLint = 0;
        gl.getProgramiv(program, GL_LINK_STATUS, &ok);
        if (ok == 0) return error.LinkFailed;
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
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
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

        try geometry.build(&self.verts, self.alloc, quads, screen_w, screen_h, self.atlas_size);
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
        if (ok == 0) return error.ShaderCompileFailed;
        return sh;
    }
};
