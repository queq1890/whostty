//! whostty: Direct3D 11 renderer (#15/#43).
//!
//! A faithful port of the OpenGL backend (`renderer/OpenGL.zig`) onto D3D11: it
//! exposes the identical `Renderer` shape (init/deinit/setAtlas/setColorAtlas/
//! draw) and reuses that backend's host-tested geometry (`Cell`/`SolidRect`/
//! `Quad`/`Vertex` + `pushQuad`/`pushColorQuad`/`pushSolid`) verbatim — the same
//! single textured-quad pass over a flat quad list, with a per-vertex `mode`
//! (0 = alpha-coverage glyph tinted by color, 1 = solid, 2 = color glyph). Only
//! the GPU plumbing differs: a DXGI swap chain + device/context for the HWND,
//! HLSL shaders compiled at runtime (`D3DCompile`), a dynamic vertex buffer, an
//! R8 glyph atlas + an RGBA color-glyph atlas as `Texture2D`+SRV, and `Present`.
//!
//! Unlike GL (whose default framebuffer follows the window), the swap-chain back
//! buffer is fixed-size, so `draw` detects a size change and calls
//! `ResizeBuffers` internally — preserving the exact GL call contract (no extra
//! method, no apprt render-loop change). Present is owned here (the renderer
//! holds the swap chain), exposed via `present()`. See PORTING.md and ADR notes.
const std = @import("std");
const d3d = @import("../os/d3d11.zig");
const w = @import("../os/windows.zig");
const ogl = @import("OpenGL.zig");

const log = std.log.scoped(.d3d11);

// Shared geometry + types from the OpenGL backend (single source of truth).
pub const Cell = ogl.Cell;
pub const SolidRect = ogl.SolidRect;
pub const Quad = ogl.Quad;
pub const Vertex = ogl.Vertex;

/// HLSL mirror of the GLSL vertex+pixel shaders. The input layout binds vertex
/// fields by byte offset, so the VSIn field order need not match the `Vertex`
/// memory order — only the semantics do. The mode switch matches the GLSL:
/// `mode > 1.5` = color glyph (sample RGBA atlas, untinted); `> 0.5` = solid
/// fill; else alpha-coverage glyph tinted by color. Per-vertex alpha multiplies
/// the result. Positions are already NDC (pushQuad bakes the Y-flip), and D3D11
/// NDC is +Y up like GL, so the VS passes position straight through.
const hlsl_src =
    \\struct VSIn {
    \\    float2 pos   : POSITION;
    \\    float2 uv    : TEXCOORD0;
    \\    float3 color : COLOR0;
    \\    float  alpha : TEXCOORD1;
    \\    float  mode  : TEXCOORD2;
    \\};
    \\struct VSOut {
    \\    float4 pos   : SV_Position;
    \\    float2 uv    : TEXCOORD0;
    \\    float3 color : COLOR0;
    \\    float  alpha : TEXCOORD1;
    \\    float  mode  : TEXCOORD2;
    \\};
    \\VSOut vs_main(VSIn i) {
    \\    VSOut o;
    \\    o.pos   = float4(i.pos, 0.0, 1.0);
    \\    o.uv    = i.uv;
    \\    o.color = i.color;
    \\    o.alpha = i.alpha;
    \\    o.mode  = i.mode;
    \\    return o;
    \\}
    \\Texture2D    u_atlas       : register(t0);
    \\Texture2D    u_color_atlas : register(t1);
    \\SamplerState u_samp        : register(s0);
    \\float4 ps_main(VSOut i) : SV_Target {
    \\    if (i.mode > 1.5) {
    \\        float4 t = u_color_atlas.Sample(u_samp, i.uv);
    \\        return float4(t.rgb, t.a * i.alpha);
    \\    } else {
    \\        float base = (i.mode > 0.5) ? 1.0 : u_atlas.Sample(u_samp, i.uv).r;
    \\        return float4(i.color, base * i.alpha);
    \\    }
    \\}
;

pub const Renderer = struct {
    alloc: std.mem.Allocator,

    device: *d3d.ID3D11Device,
    ctx: *d3d.ID3D11DeviceContext,
    swapchain: *d3d.IDXGISwapChain,
    rtv: ?*d3d.ID3D11RenderTargetView = null,
    /// The current back-buffer size; a mismatch in `draw` triggers ResizeBuffers.
    bb_w: u32,
    bb_h: u32,

    vs: *d3d.ID3D11VertexShader,
    ps: *d3d.ID3D11PixelShader,
    input_layout: *d3d.ID3D11InputLayout,
    sampler: *d3d.ID3D11SamplerState,
    blend: *d3d.ID3D11BlendState,
    raster: *d3d.ID3D11RasterizerState,

    vbo: *d3d.ID3D11Buffer,
    /// Capacity of `vbo` in bytes; grows like an ArrayList.
    vbo_cap: u32,

    atlas_tex: ?*d3d.ID3D11Texture2D = null,
    atlas_srv: ?*d3d.ID3D11ShaderResourceView = null,
    atlas_size: u32 = 0,
    color_atlas_tex: ?*d3d.ID3D11Texture2D = null,
    color_atlas_srv: ?*d3d.ID3D11ShaderResourceView = null,
    color_atlas_size: u32 = 0,

    verts: std.ArrayList(Vertex),

    const initial_vbo_verts: u32 = 8192;

    /// Create the device + swap chain for `hwnd` and all GPU resources.
    pub fn init(alloc: std.mem.Allocator, hwnd: w.HWND) !Renderer {
        // Initial back-buffer size from the window's client area (>=1).
        var rect: w.RECT = undefined;
        _ = w.GetClientRect(hwnd, &rect);
        const cw: u32 = @intCast(@max(1, rect.right - rect.left));
        const ch: u32 = @intCast(@max(1, rect.bottom - rect.top));

        var scd: d3d.DXGI_SWAP_CHAIN_DESC = .{
            .BufferDesc = .{ .Width = cw, .Height = ch, .Format = d3d.DXGI_FORMAT_R8G8B8A8_UNORM },
            .SampleDesc = .{ .Count = 1, .Quality = 0 },
            .BufferUsage = d3d.DXGI_USAGE_RENDER_TARGET_OUTPUT,
            .BufferCount = 1,
            .OutputWindow = hwnd,
            .Windowed = w.TRUE,
            .SwapEffect = d3d.DXGI_SWAP_EFFECT_DISCARD,
            .Flags = 0,
        };

        const feature_levels = [_]i32{
            d3d.D3D_FEATURE_LEVEL_11_0,
            d3d.D3D_FEATURE_LEVEL_10_1,
            d3d.D3D_FEATURE_LEVEL_10_0,
        };

        var swapchain: ?*d3d.IDXGISwapChain = null;
        var device: ?*d3d.ID3D11Device = null;
        var ctx: ?*d3d.ID3D11DeviceContext = null;

        // Try hardware, then WARP (software) so a GPU-less / headless host still
        // renders (mirrors the OpenGL legacy-context fallback).
        var hr = d3d.D3D11CreateDeviceAndSwapChain(null, d3d.D3D_DRIVER_TYPE_HARDWARE, null, 0, &feature_levels, feature_levels.len, d3d.D3D11_SDK_VERSION, &scd, &swapchain, &device, null, &ctx);
        if (!d3d.SUCCEEDED(hr)) {
            log.warn("hardware D3D11 device failed (0x{x}); trying WARP", .{@as(u32, @bitCast(hr))});
            hr = d3d.D3D11CreateDeviceAndSwapChain(null, d3d.D3D_DRIVER_TYPE_WARP, null, 0, &feature_levels, feature_levels.len, d3d.D3D11_SDK_VERSION, &scd, &swapchain, &device, null, &ctx);
        }
        if (!d3d.SUCCEEDED(hr) or device == null or ctx == null or swapchain == null) {
            log.err("D3D11CreateDeviceAndSwapChain failed: 0x{x}", .{@as(u32, @bitCast(hr))});
            return error.D3D11DeviceFailed;
        }
        errdefer _ = swapchain.?.Release();
        errdefer _ = ctx.?.Release();
        errdefer _ = device.?.Release();

        const dev = device.?;

        // --- Shaders ---
        const vs_blob = try compile(hlsl_src, "vs_main", "vs_4_0");
        defer _ = vs_blob.Release();
        const ps_blob = try compile(hlsl_src, "ps_main", "ps_4_0");
        defer _ = ps_blob.Release();

        var vs: ?*d3d.ID3D11VertexShader = null;
        if (!d3d.SUCCEEDED(dev.CreateVertexShader(vs_blob.GetBufferPointer(), vs_blob.GetBufferSize(), null, &vs)) or vs == null)
            return error.D3D11ShaderFailed;
        errdefer _ = vs.?.Release();
        var ps: ?*d3d.ID3D11PixelShader = null;
        if (!d3d.SUCCEEDED(dev.CreatePixelShader(ps_blob.GetBufferPointer(), ps_blob.GetBufferSize(), null, &ps)) or ps == null)
            return error.D3D11ShaderFailed;
        errdefer _ = ps.?.Release();

        // --- Input layout (maps Vertex fields by byte offset to HLSL semantics) ---
        const layout = [_]d3d.D3D11_INPUT_ELEMENT_DESC{
            .{ .SemanticName = "POSITION", .SemanticIndex = 0, .Format = d3d.DXGI_FORMAT_R32G32_FLOAT, .AlignedByteOffset = @offsetOf(Vertex, "x") },
            .{ .SemanticName = "TEXCOORD", .SemanticIndex = 0, .Format = d3d.DXGI_FORMAT_R32G32_FLOAT, .AlignedByteOffset = @offsetOf(Vertex, "u") },
            .{ .SemanticName = "COLOR", .SemanticIndex = 0, .Format = d3d.DXGI_FORMAT_R32G32B32_FLOAT, .AlignedByteOffset = @offsetOf(Vertex, "r") },
            .{ .SemanticName = "TEXCOORD", .SemanticIndex = 1, .Format = d3d.DXGI_FORMAT_R32_FLOAT, .AlignedByteOffset = @offsetOf(Vertex, "a") },
            .{ .SemanticName = "TEXCOORD", .SemanticIndex = 2, .Format = d3d.DXGI_FORMAT_R32_FLOAT, .AlignedByteOffset = @offsetOf(Vertex, "m") },
        };
        var input_layout: ?*d3d.ID3D11InputLayout = null;
        if (!d3d.SUCCEEDED(dev.CreateInputLayout(&layout, layout.len, vs_blob.GetBufferPointer(), vs_blob.GetBufferSize(), &input_layout)) or input_layout == null)
            return error.D3D11LayoutFailed;
        errdefer _ = input_layout.?.Release();

        // --- Dynamic vertex buffer ---
        const vbo_cap: u32 = initial_vbo_verts * @sizeOf(Vertex);
        var vbo: ?*d3d.ID3D11Buffer = null;
        const vbo_desc: d3d.D3D11_BUFFER_DESC = .{
            .ByteWidth = vbo_cap,
            .Usage = d3d.D3D11_USAGE_DYNAMIC,
            .BindFlags = d3d.D3D11_BIND_VERTEX_BUFFER,
            .CPUAccessFlags = d3d.D3D11_CPU_ACCESS_WRITE,
        };
        if (!d3d.SUCCEEDED(dev.CreateBuffer(&vbo_desc, null, &vbo)) or vbo == null)
            return error.D3D11BufferFailed;
        errdefer _ = vbo.?.Release();

        // --- Sampler (point / clamp, matching GL NEAREST + CLAMP_TO_EDGE) ---
        var sampler: ?*d3d.ID3D11SamplerState = null;
        const samp_desc: d3d.D3D11_SAMPLER_DESC = .{
            .Filter = d3d.D3D11_FILTER_MIN_MAG_MIP_POINT,
            .AddressU = d3d.D3D11_TEXTURE_ADDRESS_CLAMP,
            .AddressV = d3d.D3D11_TEXTURE_ADDRESS_CLAMP,
            .AddressW = d3d.D3D11_TEXTURE_ADDRESS_CLAMP,
            .ComparisonFunc = d3d.D3D11_COMPARISON_NEVER,
            .MaxLOD = d3d.D3D11_FLOAT32_MAX,
        };
        if (!d3d.SUCCEEDED(dev.CreateSamplerState(&samp_desc, &sampler)) or sampler == null)
            return error.D3D11StateFailed;
        errdefer _ = sampler.?.Release();

        // --- Blend (straight alpha "over", matching GL SRC_ALPHA/INV_SRC_ALPHA) ---
        var blend: ?*d3d.ID3D11BlendState = null;
        var blend_desc: d3d.D3D11_BLEND_DESC = .{};
        blend_desc.RenderTarget[0] = .{
            .BlendEnable = w.TRUE,
            .SrcBlend = d3d.D3D11_BLEND_SRC_ALPHA,
            .DestBlend = d3d.D3D11_BLEND_INV_SRC_ALPHA,
            .BlendOp = d3d.D3D11_BLEND_OP_ADD,
            .SrcBlendAlpha = d3d.D3D11_BLEND_SRC_ALPHA,
            .DestBlendAlpha = d3d.D3D11_BLEND_INV_SRC_ALPHA,
            .BlendOpAlpha = d3d.D3D11_BLEND_OP_ADD,
            .RenderTargetWriteMask = d3d.D3D11_COLOR_WRITE_ENABLE_ALL,
        };
        if (!d3d.SUCCEEDED(dev.CreateBlendState(&blend_desc, &blend)) or blend == null)
            return error.D3D11StateFailed;
        errdefer _ = blend.?.Release();

        // --- Rasterizer (solid, no culling, matching GL) ---
        var raster: ?*d3d.ID3D11RasterizerState = null;
        const raster_desc: d3d.D3D11_RASTERIZER_DESC = .{
            .FillMode = d3d.D3D11_FILL_SOLID,
            .CullMode = d3d.D3D11_CULL_NONE,
            .DepthClipEnable = w.TRUE,
        };
        if (!d3d.SUCCEEDED(dev.CreateRasterizerState(&raster_desc, &raster)) or raster == null)
            return error.D3D11StateFailed;
        errdefer _ = raster.?.Release();

        var self: Renderer = .{
            .alloc = alloc,
            .device = dev,
            .ctx = ctx.?,
            .swapchain = swapchain.?,
            .bb_w = cw,
            .bb_h = ch,
            .vs = vs.?,
            .ps = ps.?,
            .input_layout = input_layout.?,
            .sampler = sampler.?,
            .blend = blend.?,
            .raster = raster.?,
            .vbo = vbo.?,
            .vbo_cap = vbo_cap,
            .verts = .empty,
        };

        // Render-target view for the back buffer.
        try self.createRtv();
        errdefer if (self.rtv) |r| {
            _ = r.Release();
        };

        // 1x1 transparent defaults so PSSetShaderResources always has two valid
        // SRVs even before setAtlas / setColorAtlas (the shader only samples the
        // ones a given mode needs, but binding valid SRVs avoids driver edges).
        const zero1: [4]u8 = .{ 0, 0, 0, 0 };
        self.uploadAtlas(false, zero1[0..1], 1) catch {};
        self.uploadAtlas(true, zero1[0..4], 1) catch {};

        return self;
    }

    pub fn deinit(self: *Renderer) void {
        if (self.atlas_srv) |x| _ = x.Release();
        if (self.atlas_tex) |x| _ = x.Release();
        if (self.color_atlas_srv) |x| _ = x.Release();
        if (self.color_atlas_tex) |x| _ = x.Release();
        _ = self.blend.Release();
        _ = self.raster.Release();
        _ = self.sampler.Release();
        _ = self.input_layout.Release();
        _ = self.ps.Release();
        _ = self.vs.Release();
        _ = self.vbo.Release();
        if (self.rtv) |r| _ = r.Release();
        _ = self.swapchain.Release();
        _ = self.ctx.Release();
        _ = self.device.Release();
        self.verts.deinit(self.alloc);
        self.* = undefined;
    }

    /// (Re)create the render-target view from back buffer 0.
    fn createRtv(self: *Renderer) !void {
        var backbuf: ?*anyopaque = null;
        if (!d3d.SUCCEEDED(self.swapchain.GetBuffer(0, &d3d.IID_ID3D11Texture2D, &backbuf)) or backbuf == null)
            return error.D3D11BackBufferFailed;
        defer _ = @as(*d3d.ID3D11Texture2D, @ptrCast(@alignCast(backbuf.?))).Release();
        var rtv: ?*d3d.ID3D11RenderTargetView = null;
        if (!d3d.SUCCEEDED(self.device.CreateRenderTargetView(backbuf, null, &rtv)) or rtv == null)
            return error.D3D11RtvFailed;
        self.rtv = rtv;
    }

    /// Upload (recreate) the alpha (`color == false`) or color (`color == true`)
    /// atlas texture + SRV from `data`. Mirrors GL's `glTexImage2D` reallocation
    /// on each `setAtlas` call.
    fn uploadAtlas(self: *Renderer, color: bool, data: []const u8, size: u32) !void {
        const fmt: u32 = if (color) d3d.DXGI_FORMAT_R8G8B8A8_UNORM else d3d.DXGI_FORMAT_R8_UNORM;
        const bpp: u32 = if (color) 4 else 1;

        const tex_desc: d3d.D3D11_TEXTURE2D_DESC = .{
            .Width = size,
            .Height = size,
            .MipLevels = 1,
            .ArraySize = 1,
            .Format = fmt,
            .SampleDesc = .{ .Count = 1, .Quality = 0 },
            .Usage = d3d.D3D11_USAGE_DEFAULT,
            .BindFlags = d3d.D3D11_BIND_SHADER_RESOURCE,
        };
        const sub: d3d.D3D11_SUBRESOURCE_DATA = .{
            .pSysMem = data.ptr,
            .SysMemPitch = size * bpp,
        };
        var tex: ?*d3d.ID3D11Texture2D = null;
        if (!d3d.SUCCEEDED(self.device.CreateTexture2D(&tex_desc, &sub, &tex)) or tex == null)
            return error.D3D11TextureFailed;
        errdefer _ = tex.?.Release();
        var srv: ?*d3d.ID3D11ShaderResourceView = null;
        if (!d3d.SUCCEEDED(self.device.CreateShaderResourceView(@ptrCast(tex), null, &srv)) or srv == null)
            return error.D3D11SrvFailed;

        if (color) {
            if (self.color_atlas_srv) |x| _ = x.Release();
            if (self.color_atlas_tex) |x| _ = x.Release();
            self.color_atlas_tex = tex;
            self.color_atlas_srv = srv;
            self.color_atlas_size = size;
        } else {
            if (self.atlas_srv) |x| _ = x.Release();
            if (self.atlas_tex) |x| _ = x.Release();
            self.atlas_tex = tex;
            self.atlas_srv = srv;
            self.atlas_size = size;
        }
    }

    /// Upload an R8 coverage atlas as the glyph texture.
    pub fn setAtlas(self: *Renderer, data: []const u8, size: u32) void {
        self.uploadAtlas(false, data, size) catch |e| log.err("setAtlas failed: {s}", .{@errorName(e)});
    }

    /// Upload an RGBA8 straight-alpha color-glyph atlas (emoji, #78).
    pub fn setColorAtlas(self: *Renderer, data: []const u8, size: u32) void {
        self.uploadAtlas(true, data, size) catch |e| log.err("setColorAtlas failed: {s}", .{@errorName(e)});
    }

    /// Clear and draw all quads in order. Detects a back-buffer size change and
    /// resizes the swap chain internally; identical contract to gl.Renderer.draw.
    pub fn draw(self: *Renderer, quads: []const Quad, clear: [3]f32, screen_w: u32, screen_h: u32) !void {
        // A minimized / zero-area window: skip the frame entirely. This avoids
        // resizing the swap chain down to 1x1 (and back) on every minimize/
        // restore and keeps the back buffer at the last visible size, so restore
        // is seamless with no extra reallocation.
        if (screen_w == 0 or screen_h == 0) return;

        // GPU-runtime failures (resize, buffer alloc, map) are NON-fatal: log and
        // skip the frame, leaving state recoverable for the next one — a transient
        // failure or device reset must not tear down the window. Only an
        // out-of-memory from quad building propagates, matching the OpenGL backend
        // (whose draw can likewise only fail from the allocator).
        self.ensureSize(screen_w, screen_h) catch |e| {
            log.warn("D3D11 resize failed; skipping frame: {s}", .{@errorName(e)});
            return;
        };
        const rtv = self.rtv orelse return;

        var rtvs = [_]?*d3d.ID3D11RenderTargetView{rtv};
        self.ctx.OMSetRenderTargets(1, &rtvs, null);
        const clear_rgba: [4]f32 = .{ clear[0], clear[1], clear[2], 1.0 };
        self.ctx.ClearRenderTargetView(rtv, &clear_rgba);

        self.verts.clearRetainingCapacity();
        for (quads) |q| switch (q) {
            .glyph => |cell| try ogl.pushQuad(&self.verts, self.alloc, cell, screen_w, screen_h, self.atlas_size),
            .solid => |rect| try ogl.pushSolid(&self.verts, self.alloc, rect, screen_w, screen_h),
            .color_glyph => |cell| try ogl.pushColorQuad(&self.verts, self.alloc, cell, screen_w, screen_h, self.color_atlas_size),
        };
        if (self.verts.items.len == 0) return; // background already cleared

        const bytes: u32 = @intCast(self.verts.items.len * @sizeOf(Vertex));
        self.ensureVbo(bytes) catch |e| {
            log.warn("D3D11 vertex-buffer alloc failed; skipping frame: {s}", .{@errorName(e)});
            return;
        };

        // Upload the vertices (WRITE_DISCARD = rename, no stall — like GL_DYNAMIC_DRAW).
        var mapped: d3d.D3D11_MAPPED_SUBRESOURCE = .{};
        if (!d3d.SUCCEEDED(self.ctx.Map(@ptrCast(self.vbo), 0, d3d.D3D11_MAP_WRITE_DISCARD, 0, &mapped)) or mapped.pData == null) {
            log.warn("D3D11 vertex-buffer map failed; skipping frame", .{});
            return;
        }
        const dst: [*]u8 = @ptrCast(mapped.pData.?);
        @memcpy(dst[0..bytes], std.mem.sliceAsBytes(self.verts.items)[0..bytes]);
        self.ctx.Unmap(@ptrCast(self.vbo), 0);

        const vp: d3d.D3D11_VIEWPORT = .{
            .TopLeftX = 0,
            .TopLeftY = 0,
            .Width = @floatFromInt(screen_w),
            .Height = @floatFromInt(screen_h),
            .MinDepth = 0,
            .MaxDepth = 1,
        };
        var vps = [_]d3d.D3D11_VIEWPORT{vp};
        self.ctx.RSSetViewports(1, &vps);
        self.ctx.RSSetState(self.raster);
        self.ctx.OMSetBlendState(self.blend, null, 0xffffffff);

        self.ctx.IASetInputLayout(self.input_layout);
        const stride: u32 = @sizeOf(Vertex);
        var strides = [_]u32{stride};
        var offsets = [_]u32{0};
        var vbos = [_]?*d3d.ID3D11Buffer{self.vbo};
        self.ctx.IASetVertexBuffers(0, 1, &vbos, &strides, &offsets);
        self.ctx.IASetPrimitiveTopology(d3d.D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);

        self.ctx.VSSetShader(self.vs);
        self.ctx.PSSetShader(self.ps);
        var srvs = [_]?*d3d.ID3D11ShaderResourceView{ self.atlas_srv, self.color_atlas_srv };
        self.ctx.PSSetShaderResources(0, 2, &srvs);
        var samplers = [_]?*d3d.ID3D11SamplerState{self.sampler};
        self.ctx.PSSetSamplers(0, 1, &samplers);

        self.ctx.Draw(@intCast(self.verts.items.len), 0);
    }

    /// Present the swap chain (replaces win.swapBuffers for the D3D arm).
    /// Non-fatal: a failed present logs and the frame is dropped. Device loss
    /// (TDR / driver reset / GPU switch) is reported distinctly; full device +
    /// swap-chain recreation is a follow-up — until then the draw path's
    /// skip-on-failure keeps the window alive (it stops rendering, not crashes).
    pub fn present(self: *Renderer) void {
        const hr = self.swapchain.Present(1, 0);
        if (d3d.SUCCEEDED(hr)) return;
        if (hr == d3d.DXGI_ERROR_DEVICE_REMOVED or hr == d3d.DXGI_ERROR_DEVICE_RESET) {
            log.err("D3D11 device lost (0x{x}); rendering will stall until restart", .{@as(u32, @bitCast(hr))});
        } else {
            log.err("Present failed: 0x{x}", .{@as(u32, @bitCast(hr))});
        }
    }

    fn ensureSize(self: *Renderer, sw: u32, sh: u32) !void {
        if (self.rtv != null and sw == self.bb_w and sh == self.bb_h) return;
        // Unbind + release the old view before resizing the buffers.
        self.ctx.OMSetRenderTargets(0, null, null);
        if (self.rtv) |r| {
            _ = r.Release();
            self.rtv = null;
        }
        const hr = self.swapchain.ResizeBuffers(0, sw, sh, d3d.DXGI_FORMAT_UNKNOWN, 0);
        if (!d3d.SUCCEEDED(hr)) {
            log.err("ResizeBuffers failed: 0x{x}", .{@as(u32, @bitCast(hr))});
            return error.D3D11ResizeFailed;
        }
        self.bb_w = sw;
        self.bb_h = sh;
        try self.createRtv();
    }

    fn ensureVbo(self: *Renderer, bytes: u32) !void {
        if (bytes <= self.vbo_cap) return;
        // Grow geometrically (like ArrayList) to amortize reallocation.
        var new_cap = self.vbo_cap;
        while (new_cap < bytes) new_cap *|= 2;
        var vbo: ?*d3d.ID3D11Buffer = null;
        const desc: d3d.D3D11_BUFFER_DESC = .{
            .ByteWidth = new_cap,
            .Usage = d3d.D3D11_USAGE_DYNAMIC,
            .BindFlags = d3d.D3D11_BIND_VERTEX_BUFFER,
            .CPUAccessFlags = d3d.D3D11_CPU_ACCESS_WRITE,
        };
        if (!d3d.SUCCEEDED(self.device.CreateBuffer(&desc, null, &vbo)) or vbo == null)
            return error.D3D11BufferFailed;
        _ = self.vbo.Release();
        self.vbo = vbo.?;
        self.vbo_cap = new_cap;
    }

    /// Compile one HLSL entry point at runtime via d3dcompiler.
    fn compile(src: []const u8, entry: [*:0]const u8, target: [*:0]const u8) !*d3d.ID3DBlob {
        var code: ?*d3d.ID3DBlob = null;
        var errors: ?*d3d.ID3DBlob = null;
        const hr = d3d.D3DCompile(src.ptr, src.len, "whostty.hlsl", null, null, entry, target, 0, 0, &code, &errors);
        if (errors) |e| {
            const p: [*]const u8 = @ptrCast(e.GetBufferPointer());
            log.err("HLSL compile ({s}): {s}", .{ target, p[0..e.GetBufferSize()] });
            _ = e.Release();
        }
        if (!d3d.SUCCEEDED(hr) or code == null) return error.D3D11ShaderCompileFailed;
        return code.?;
    }
};
