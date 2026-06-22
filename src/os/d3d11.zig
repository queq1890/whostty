//! whostty: minimal Direct3D 11 / DXGI / d3dcompiler COM bindings (#15/#43).
//!
//! Hand-written vtable bindings — only the interfaces and methods the D3D11
//! renderer backend needs (device, immediate context, swap chain, render-target
//! view, textures + SRVs, sampler/blend/rasterizer states, input layout, vertex
//! & pixel shaders, vertex buffer, and the shader-compiler blob). The method
//! order in each `Vtbl` mirrors `d3d11.h` / `dxgi.h` EXACTLY — a wrong slot order
//! faults at run time, not compile time. Unused slots are kept (named after their
//! real method) but typed as `*const anyopaque` placeholders so the slots we DO
//! call land at the correct vtable index. Every COM method uses the Windows
//! stdcall convention (`callconv(.winapi)`); the first parameter is always `This`.
//!
//! Mirrors the `src/os/dwrite.zig` pattern. The entry points link via zig's
//! bundled mingw `d3d11.def` / `d3dcompiler_47.def`. See PORTING.md and
//! `renderer/Direct3D11.zig`.
const std = @import("std");
const w = @import("windows.zig");

pub const HRESULT = w.HRESULT;
pub const BOOL = w.BOOL;
pub const HWND = w.HWND;

/// COM GUID (== Win32 GUID / IID layout).
pub const GUID = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,
};

/// HRESULT success test (S_OK and any other non-negative code).
pub inline fn SUCCEEDED(hr: HRESULT) bool {
    return hr >= 0;
}

// --- Constants -------------------------------------------------------------

pub const D3D_DRIVER_TYPE_HARDWARE: i32 = 1;
pub const D3D_DRIVER_TYPE_WARP: i32 = 5;
pub const D3D11_SDK_VERSION: u32 = 7;

// Feature levels (D3D_FEATURE_LEVEL).
pub const D3D_FEATURE_LEVEL_11_0: i32 = 0xb000;
pub const D3D_FEATURE_LEVEL_10_1: i32 = 0xa100;
pub const D3D_FEATURE_LEVEL_10_0: i32 = 0xa000;

// DXGI formats.
pub const DXGI_FORMAT_UNKNOWN: u32 = 0;
pub const DXGI_FORMAT_R32G32B32A32_FLOAT: u32 = 2;
pub const DXGI_FORMAT_R32G32B32_FLOAT: u32 = 6;
pub const DXGI_FORMAT_R32G32_FLOAT: u32 = 16;
pub const DXGI_FORMAT_R32_FLOAT: u32 = 41;
pub const DXGI_FORMAT_R8G8B8A8_UNORM: u32 = 28;
pub const DXGI_FORMAT_R8_UNORM: u32 = 61;

pub const DXGI_USAGE_RENDER_TARGET_OUTPUT: u32 = 0x20;
pub const DXGI_SWAP_EFFECT_DISCARD: u32 = 0;
pub const DXGI_SWAP_EFFECT_FLIP_DISCARD: u32 = 4;

pub const D3D11_USAGE_DEFAULT: u32 = 0;
pub const D3D11_USAGE_DYNAMIC: u32 = 2;
pub const D3D11_BIND_VERTEX_BUFFER: u32 = 0x1;
pub const D3D11_BIND_SHADER_RESOURCE: u32 = 0x8;
pub const D3D11_CPU_ACCESS_WRITE: u32 = 0x10000;
pub const D3D11_MAP_WRITE_DISCARD: u32 = 4;

pub const D3D11_INPUT_PER_VERTEX_DATA: u32 = 0;
pub const D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST: u32 = 4;

// Blend.
pub const D3D11_BLEND_ZERO: u32 = 1;
pub const D3D11_BLEND_ONE: u32 = 2;
pub const D3D11_BLEND_SRC_ALPHA: u32 = 5;
pub const D3D11_BLEND_INV_SRC_ALPHA: u32 = 6;
pub const D3D11_BLEND_OP_ADD: u32 = 1;
pub const D3D11_COLOR_WRITE_ENABLE_ALL: u8 = 0x0F;

// Rasterizer.
pub const D3D11_FILL_SOLID: i32 = 3;
pub const D3D11_CULL_NONE: i32 = 1;

// Sampler.
pub const D3D11_FILTER_MIN_MAG_MIP_POINT: u32 = 0;
pub const D3D11_TEXTURE_ADDRESS_CLAMP: u32 = 3;
pub const D3D11_COMPARISON_NEVER: u32 = 1;
pub const D3D11_FLOAT32_MAX: f32 = 3.402823466e+38;

// DXGI error: the device was lost / removed.
pub const DXGI_ERROR_DEVICE_REMOVED: HRESULT = @bitCast(@as(u32, 0x887A0005));
pub const DXGI_ERROR_DEVICE_RESET: HRESULT = @bitCast(@as(u32, 0x887A0007));

// IID for ID3D11Texture2D (needed by IDXGISwapChain::GetBuffer).
pub const IID_ID3D11Texture2D: GUID = .{
    .Data1 = 0x6f15aaf2,
    .Data2 = 0xd208,
    .Data3 = 0x4e89,
    .Data4 = .{ 0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c },
};

// --- Structs ---------------------------------------------------------------

pub const DXGI_RATIONAL = extern struct { Numerator: u32 = 0, Denominator: u32 = 0 };

pub const DXGI_MODE_DESC = extern struct {
    Width: u32 = 0,
    Height: u32 = 0,
    RefreshRate: DXGI_RATIONAL = .{},
    Format: u32 = 0,
    ScanlineOrdering: u32 = 0,
    Scaling: u32 = 0,
};

pub const DXGI_SAMPLE_DESC = extern struct { Count: u32 = 1, Quality: u32 = 0 };

pub const DXGI_SWAP_CHAIN_DESC = extern struct {
    BufferDesc: DXGI_MODE_DESC = .{},
    SampleDesc: DXGI_SAMPLE_DESC = .{},
    BufferUsage: u32 = 0,
    BufferCount: u32 = 0,
    OutputWindow: HWND,
    Windowed: BOOL = 0,
    SwapEffect: u32 = 0,
    Flags: u32 = 0,
};

pub const D3D11_BUFFER_DESC = extern struct {
    ByteWidth: u32 = 0,
    Usage: u32 = 0,
    BindFlags: u32 = 0,
    CPUAccessFlags: u32 = 0,
    MiscFlags: u32 = 0,
    StructureByteStride: u32 = 0,
};

pub const D3D11_TEXTURE2D_DESC = extern struct {
    Width: u32 = 0,
    Height: u32 = 0,
    MipLevels: u32 = 1,
    ArraySize: u32 = 1,
    Format: u32 = 0,
    SampleDesc: DXGI_SAMPLE_DESC = .{},
    Usage: u32 = 0,
    BindFlags: u32 = 0,
    CPUAccessFlags: u32 = 0,
    MiscFlags: u32 = 0,
};

pub const D3D11_SUBRESOURCE_DATA = extern struct {
    pSysMem: *const anyopaque,
    SysMemPitch: u32 = 0,
    SysMemSlicePitch: u32 = 0,
};

pub const D3D11_MAPPED_SUBRESOURCE = extern struct {
    pData: ?*anyopaque = null,
    RowPitch: u32 = 0,
    DepthPitch: u32 = 0,
};

pub const D3D11_INPUT_ELEMENT_DESC = extern struct {
    SemanticName: [*:0]const u8,
    SemanticIndex: u32 = 0,
    Format: u32 = 0,
    InputSlot: u32 = 0,
    AlignedByteOffset: u32 = 0,
    InputSlotClass: u32 = 0,
    InstanceDataStepRate: u32 = 0,
};

pub const D3D11_SAMPLER_DESC = extern struct {
    Filter: u32 = 0,
    AddressU: u32 = 0,
    AddressV: u32 = 0,
    AddressW: u32 = 0,
    MipLODBias: f32 = 0,
    MaxAnisotropy: u32 = 0,
    ComparisonFunc: u32 = 0,
    BorderColor: [4]f32 = .{ 0, 0, 0, 0 },
    MinLOD: f32 = 0,
    MaxLOD: f32 = 0,
};

pub const D3D11_RENDER_TARGET_BLEND_DESC = extern struct {
    BlendEnable: BOOL = 0,
    SrcBlend: u32 = 0,
    DestBlend: u32 = 0,
    BlendOp: u32 = 0,
    SrcBlendAlpha: u32 = 0,
    DestBlendAlpha: u32 = 0,
    BlendOpAlpha: u32 = 0,
    RenderTargetWriteMask: u8 = 0,
};

pub const D3D11_BLEND_DESC = extern struct {
    AlphaToCoverageEnable: BOOL = 0,
    IndependentBlendEnable: BOOL = 0,
    RenderTarget: [8]D3D11_RENDER_TARGET_BLEND_DESC = [_]D3D11_RENDER_TARGET_BLEND_DESC{.{}} ** 8,
};

pub const D3D11_RASTERIZER_DESC = extern struct {
    FillMode: i32 = 0,
    CullMode: i32 = 0,
    FrontCounterClockwise: BOOL = 0,
    DepthBias: i32 = 0,
    DepthBiasClamp: f32 = 0,
    SlopeScaledDepthBias: f32 = 0,
    DepthClipEnable: BOOL = 0,
    ScissorEnable: BOOL = 0,
    MultisampleEnable: BOOL = 0,
    AntialiasedLineEnable: BOOL = 0,
};

pub const D3D11_VIEWPORT = extern struct {
    TopLeftX: f32 = 0,
    TopLeftY: f32 = 0,
    Width: f32 = 0,
    Height: f32 = 0,
    MinDepth: f32 = 0,
    MaxDepth: f32 = 1,
};

// --- Leaf interfaces (we only call Release) --------------------------------
//
// Each lists IUnknown's three slots; only `Release` (slot 2) is typed.

fn ReleaseOnly(comptime Self: type) type {
    return extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*Self) callconv(.winapi) u32,
    };
}

pub const ID3D11Texture2D = extern struct {
    vtbl: *const ReleaseOnly(@This()),
    pub inline fn Release(self: *@This()) u32 {
        return self.vtbl.Release(self);
    }
};
pub const ID3D11RenderTargetView = extern struct {
    vtbl: *const ReleaseOnly(@This()),
    pub inline fn Release(self: *@This()) u32 {
        return self.vtbl.Release(self);
    }
};
pub const ID3D11ShaderResourceView = extern struct {
    vtbl: *const ReleaseOnly(@This()),
    pub inline fn Release(self: *@This()) u32 {
        return self.vtbl.Release(self);
    }
};
pub const ID3D11SamplerState = extern struct {
    vtbl: *const ReleaseOnly(@This()),
    pub inline fn Release(self: *@This()) u32 {
        return self.vtbl.Release(self);
    }
};
pub const ID3D11BlendState = extern struct {
    vtbl: *const ReleaseOnly(@This()),
    pub inline fn Release(self: *@This()) u32 {
        return self.vtbl.Release(self);
    }
};
pub const ID3D11RasterizerState = extern struct {
    vtbl: *const ReleaseOnly(@This()),
    pub inline fn Release(self: *@This()) u32 {
        return self.vtbl.Release(self);
    }
};
pub const ID3D11InputLayout = extern struct {
    vtbl: *const ReleaseOnly(@This()),
    pub inline fn Release(self: *@This()) u32 {
        return self.vtbl.Release(self);
    }
};
pub const ID3D11VertexShader = extern struct {
    vtbl: *const ReleaseOnly(@This()),
    pub inline fn Release(self: *@This()) u32 {
        return self.vtbl.Release(self);
    }
};
pub const ID3D11PixelShader = extern struct {
    vtbl: *const ReleaseOnly(@This()),
    pub inline fn Release(self: *@This()) u32 {
        return self.vtbl.Release(self);
    }
};
pub const ID3D11Buffer = extern struct {
    vtbl: *const ReleaseOnly(@This()),
    pub inline fn Release(self: *@This()) u32 {
        return self.vtbl.Release(self);
    }
};

/// ID3DBlob (== ID3D10Blob): the d3dcompiler output. IUnknown + 2 methods.
pub const ID3DBlob = extern struct {
    vtbl: *const Vtbl,
    pub const Vtbl = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*ID3DBlob) callconv(.winapi) u32,
        GetBufferPointer: *const fn (*ID3DBlob) callconv(.winapi) *anyopaque,
        GetBufferSize: *const fn (*ID3DBlob) callconv(.winapi) usize,
    };
    pub inline fn Release(self: *ID3DBlob) u32 {
        return self.vtbl.Release(self);
    }
    pub inline fn GetBufferPointer(self: *ID3DBlob) *anyopaque {
        return self.vtbl.GetBufferPointer(self);
    }
    pub inline fn GetBufferSize(self: *ID3DBlob) usize {
        return self.vtbl.GetBufferSize(self);
    }
};

// --- ID3D11Device ----------------------------------------------------------
//
// IUnknown(0..2), then ID3D11Device methods start at slot 3. We bind through
// CreateSamplerState (slot 23). Unused slots are `*const anyopaque` placeholders.

pub const ID3D11Device = extern struct {
    vtbl: *const Vtbl,

    pub const Vtbl = extern struct {
        QueryInterface: *const anyopaque, // 0
        AddRef: *const anyopaque, // 1
        Release: *const fn (*ID3D11Device) callconv(.winapi) u32, // 2
        CreateBuffer: *const fn (*ID3D11Device, *const D3D11_BUFFER_DESC, ?*const D3D11_SUBRESOURCE_DATA, *?*ID3D11Buffer) callconv(.winapi) HRESULT, // 3
        CreateTexture1D: *const anyopaque, // 4
        CreateTexture2D: *const fn (*ID3D11Device, *const D3D11_TEXTURE2D_DESC, ?*const D3D11_SUBRESOURCE_DATA, *?*ID3D11Texture2D) callconv(.winapi) HRESULT, // 5
        CreateTexture3D: *const anyopaque, // 6
        CreateShaderResourceView: *const fn (*ID3D11Device, ?*anyopaque, ?*const anyopaque, *?*ID3D11ShaderResourceView) callconv(.winapi) HRESULT, // 7
        CreateUnorderedAccessView: *const anyopaque, // 8
        CreateRenderTargetView: *const fn (*ID3D11Device, ?*anyopaque, ?*const anyopaque, *?*ID3D11RenderTargetView) callconv(.winapi) HRESULT, // 9
        CreateDepthStencilView: *const anyopaque, // 10
        CreateInputLayout: *const fn (*ID3D11Device, [*]const D3D11_INPUT_ELEMENT_DESC, u32, *const anyopaque, usize, *?*ID3D11InputLayout) callconv(.winapi) HRESULT, // 11
        CreateVertexShader: *const fn (*ID3D11Device, *const anyopaque, usize, ?*anyopaque, *?*ID3D11VertexShader) callconv(.winapi) HRESULT, // 12
        CreateGeometryShader: *const anyopaque, // 13
        CreateGeometryShaderWithStreamOutput: *const anyopaque, // 14
        CreatePixelShader: *const fn (*ID3D11Device, *const anyopaque, usize, ?*anyopaque, *?*ID3D11PixelShader) callconv(.winapi) HRESULT, // 15
        CreateHullShader: *const anyopaque, // 16
        CreateDomainShader: *const anyopaque, // 17
        CreateComputeShader: *const anyopaque, // 18
        CreateClassLinkage: *const anyopaque, // 19
        CreateBlendState: *const fn (*ID3D11Device, *const D3D11_BLEND_DESC, *?*ID3D11BlendState) callconv(.winapi) HRESULT, // 20
        CreateDepthStencilState: *const anyopaque, // 21
        CreateRasterizerState: *const fn (*ID3D11Device, *const D3D11_RASTERIZER_DESC, *?*ID3D11RasterizerState) callconv(.winapi) HRESULT, // 22
        CreateSamplerState: *const fn (*ID3D11Device, *const D3D11_SAMPLER_DESC, *?*ID3D11SamplerState) callconv(.winapi) HRESULT, // 23
    };

    pub inline fn Release(self: *ID3D11Device) u32 {
        return self.vtbl.Release(self);
    }
    pub inline fn CreateBuffer(self: *ID3D11Device, desc: *const D3D11_BUFFER_DESC, data: ?*const D3D11_SUBRESOURCE_DATA, out: *?*ID3D11Buffer) HRESULT {
        return self.vtbl.CreateBuffer(self, desc, data, out);
    }
    pub inline fn CreateTexture2D(self: *ID3D11Device, desc: *const D3D11_TEXTURE2D_DESC, data: ?*const D3D11_SUBRESOURCE_DATA, out: *?*ID3D11Texture2D) HRESULT {
        return self.vtbl.CreateTexture2D(self, desc, data, out);
    }
    pub inline fn CreateShaderResourceView(self: *ID3D11Device, res: ?*anyopaque, desc: ?*const anyopaque, out: *?*ID3D11ShaderResourceView) HRESULT {
        return self.vtbl.CreateShaderResourceView(self, res, desc, out);
    }
    pub inline fn CreateRenderTargetView(self: *ID3D11Device, res: ?*anyopaque, desc: ?*const anyopaque, out: *?*ID3D11RenderTargetView) HRESULT {
        return self.vtbl.CreateRenderTargetView(self, res, desc, out);
    }
    pub inline fn CreateInputLayout(self: *ID3D11Device, elems: [*]const D3D11_INPUT_ELEMENT_DESC, n: u32, bytecode: *const anyopaque, len: usize, out: *?*ID3D11InputLayout) HRESULT {
        return self.vtbl.CreateInputLayout(self, elems, n, bytecode, len, out);
    }
    pub inline fn CreateVertexShader(self: *ID3D11Device, bytecode: *const anyopaque, len: usize, linkage: ?*anyopaque, out: *?*ID3D11VertexShader) HRESULT {
        return self.vtbl.CreateVertexShader(self, bytecode, len, linkage, out);
    }
    pub inline fn CreatePixelShader(self: *ID3D11Device, bytecode: *const anyopaque, len: usize, linkage: ?*anyopaque, out: *?*ID3D11PixelShader) HRESULT {
        return self.vtbl.CreatePixelShader(self, bytecode, len, linkage, out);
    }
    pub inline fn CreateBlendState(self: *ID3D11Device, desc: *const D3D11_BLEND_DESC, out: *?*ID3D11BlendState) HRESULT {
        return self.vtbl.CreateBlendState(self, desc, out);
    }
    pub inline fn CreateRasterizerState(self: *ID3D11Device, desc: *const D3D11_RASTERIZER_DESC, out: *?*ID3D11RasterizerState) HRESULT {
        return self.vtbl.CreateRasterizerState(self, desc, out);
    }
    pub inline fn CreateSamplerState(self: *ID3D11Device, desc: *const D3D11_SAMPLER_DESC, out: *?*ID3D11SamplerState) HRESULT {
        return self.vtbl.CreateSamplerState(self, desc, out);
    }
};

// --- ID3D11DeviceContext ---------------------------------------------------
//
// IUnknown(0..2) + ID3D11DeviceChild(3..6) + ID3D11DeviceContext methods from
// slot 7. Bound exactly through ClearRenderTargetView (slot 50) — the highest
// method we call. Every slot below is named after its real d3d11.h method so the
// ordering is auditable; only the methods we call are typed.

pub const ID3D11DeviceContext = extern struct {
    vtbl: *const Vtbl,

    pub const Vtbl = extern struct {
        QueryInterface: *const anyopaque, // 0
        AddRef: *const anyopaque, // 1
        Release: *const fn (*ID3D11DeviceContext) callconv(.winapi) u32, // 2
        GetDevice: *const anyopaque, // 3
        GetPrivateData: *const anyopaque, // 4
        SetPrivateData: *const anyopaque, // 5
        SetPrivateDataInterface: *const anyopaque, // 6
        VSSetConstantBuffers: *const anyopaque, // 7
        PSSetShaderResources: *const fn (*ID3D11DeviceContext, u32, u32, [*]const ?*ID3D11ShaderResourceView) callconv(.winapi) void, // 8
        PSSetShader: *const fn (*ID3D11DeviceContext, ?*ID3D11PixelShader, ?*const ?*anyopaque, u32) callconv(.winapi) void, // 9
        PSSetSamplers: *const fn (*ID3D11DeviceContext, u32, u32, [*]const ?*ID3D11SamplerState) callconv(.winapi) void, // 10
        VSSetShader: *const fn (*ID3D11DeviceContext, ?*ID3D11VertexShader, ?*const ?*anyopaque, u32) callconv(.winapi) void, // 11
        DrawIndexed: *const anyopaque, // 12
        Draw: *const fn (*ID3D11DeviceContext, u32, u32) callconv(.winapi) void, // 13
        Map: *const fn (*ID3D11DeviceContext, ?*anyopaque, u32, u32, u32, *D3D11_MAPPED_SUBRESOURCE) callconv(.winapi) HRESULT, // 14
        Unmap: *const fn (*ID3D11DeviceContext, ?*anyopaque, u32) callconv(.winapi) void, // 15
        PSSetConstantBuffers: *const anyopaque, // 16
        IASetInputLayout: *const fn (*ID3D11DeviceContext, ?*ID3D11InputLayout) callconv(.winapi) void, // 17
        IASetVertexBuffers: *const fn (*ID3D11DeviceContext, u32, u32, [*]const ?*ID3D11Buffer, [*]const u32, [*]const u32) callconv(.winapi) void, // 18
        IASetIndexBuffer: *const anyopaque, // 19
        DrawIndexedInstanced: *const anyopaque, // 20
        DrawInstanced: *const anyopaque, // 21
        GSSetConstantBuffers: *const anyopaque, // 22
        GSSetShader: *const anyopaque, // 23
        IASetPrimitiveTopology: *const fn (*ID3D11DeviceContext, u32) callconv(.winapi) void, // 24
        VSSetShaderResources: *const anyopaque, // 25
        VSSetSamplers: *const anyopaque, // 26
        Begin: *const anyopaque, // 27
        End: *const anyopaque, // 28
        GetData: *const anyopaque, // 29
        SetPredication: *const anyopaque, // 30
        GSSetShaderResources: *const anyopaque, // 31
        GSSetSamplers: *const anyopaque, // 32
        OMSetRenderTargets: *const fn (*ID3D11DeviceContext, u32, ?[*]const ?*ID3D11RenderTargetView, ?*anyopaque) callconv(.winapi) void, // 33
        OMSetRenderTargetsAndUnorderedAccessViews: *const anyopaque, // 34
        OMSetBlendState: *const fn (*ID3D11DeviceContext, ?*ID3D11BlendState, ?*const [4]f32, u32) callconv(.winapi) void, // 35
        OMSetDepthStencilState: *const anyopaque, // 36
        SOSetTargets: *const anyopaque, // 37
        DrawAuto: *const anyopaque, // 38
        DrawIndexedInstancedIndirect: *const anyopaque, // 39
        DrawInstancedIndirect: *const anyopaque, // 40
        Dispatch: *const anyopaque, // 41
        DispatchIndirect: *const anyopaque, // 42
        RSSetState: *const fn (*ID3D11DeviceContext, ?*ID3D11RasterizerState) callconv(.winapi) void, // 43
        RSSetViewports: *const fn (*ID3D11DeviceContext, u32, [*]const D3D11_VIEWPORT) callconv(.winapi) void, // 44
        RSSetScissorRects: *const anyopaque, // 45
        CopySubresourceRegion: *const anyopaque, // 46
        CopyResource: *const anyopaque, // 47
        UpdateSubresource: *const fn (*ID3D11DeviceContext, ?*anyopaque, u32, ?*const anyopaque, *const anyopaque, u32, u32) callconv(.winapi) void, // 48
        CopyStructureCount: *const anyopaque, // 49
        ClearRenderTargetView: *const fn (*ID3D11DeviceContext, ?*ID3D11RenderTargetView, *const [4]f32) callconv(.winapi) void, // 50
    };

    pub inline fn Release(self: *ID3D11DeviceContext) u32 {
        return self.vtbl.Release(self);
    }
    pub inline fn PSSetShaderResources(self: *ID3D11DeviceContext, start: u32, n: u32, views: [*]const ?*ID3D11ShaderResourceView) void {
        self.vtbl.PSSetShaderResources(self, start, n, views);
    }
    pub inline fn PSSetShader(self: *ID3D11DeviceContext, ps: ?*ID3D11PixelShader) void {
        self.vtbl.PSSetShader(self, ps, null, 0);
    }
    pub inline fn PSSetSamplers(self: *ID3D11DeviceContext, start: u32, n: u32, samplers: [*]const ?*ID3D11SamplerState) void {
        self.vtbl.PSSetSamplers(self, start, n, samplers);
    }
    pub inline fn VSSetShader(self: *ID3D11DeviceContext, vs: ?*ID3D11VertexShader) void {
        self.vtbl.VSSetShader(self, vs, null, 0);
    }
    pub inline fn Draw(self: *ID3D11DeviceContext, count: u32, start: u32) void {
        self.vtbl.Draw(self, count, start);
    }
    pub inline fn Map(self: *ID3D11DeviceContext, res: ?*anyopaque, sub: u32, map_type: u32, flags: u32, out: *D3D11_MAPPED_SUBRESOURCE) HRESULT {
        return self.vtbl.Map(self, res, sub, map_type, flags, out);
    }
    pub inline fn Unmap(self: *ID3D11DeviceContext, res: ?*anyopaque, sub: u32) void {
        self.vtbl.Unmap(self, res, sub);
    }
    pub inline fn IASetInputLayout(self: *ID3D11DeviceContext, layout: ?*ID3D11InputLayout) void {
        self.vtbl.IASetInputLayout(self, layout);
    }
    pub inline fn IASetVertexBuffers(self: *ID3D11DeviceContext, start: u32, n: u32, buffers: [*]const ?*ID3D11Buffer, strides: [*]const u32, offsets: [*]const u32) void {
        self.vtbl.IASetVertexBuffers(self, start, n, buffers, strides, offsets);
    }
    pub inline fn IASetPrimitiveTopology(self: *ID3D11DeviceContext, topology: u32) void {
        self.vtbl.IASetPrimitiveTopology(self, topology);
    }
    pub inline fn OMSetRenderTargets(self: *ID3D11DeviceContext, n: u32, views: ?[*]const ?*ID3D11RenderTargetView, depth: ?*anyopaque) void {
        self.vtbl.OMSetRenderTargets(self, n, views, depth);
    }
    pub inline fn OMSetBlendState(self: *ID3D11DeviceContext, blend: ?*ID3D11BlendState, factor: ?*const [4]f32, mask: u32) void {
        self.vtbl.OMSetBlendState(self, blend, factor, mask);
    }
    pub inline fn RSSetState(self: *ID3D11DeviceContext, raster: ?*ID3D11RasterizerState) void {
        self.vtbl.RSSetState(self, raster);
    }
    pub inline fn RSSetViewports(self: *ID3D11DeviceContext, n: u32, vps: [*]const D3D11_VIEWPORT) void {
        self.vtbl.RSSetViewports(self, n, vps);
    }
    pub inline fn UpdateSubresource(self: *ID3D11DeviceContext, res: ?*anyopaque, sub: u32, box: ?*const anyopaque, data: *const anyopaque, row_pitch: u32, depth_pitch: u32) void {
        self.vtbl.UpdateSubresource(self, res, sub, box, data, row_pitch, depth_pitch);
    }
    pub inline fn ClearRenderTargetView(self: *ID3D11DeviceContext, rtv: ?*ID3D11RenderTargetView, color: *const [4]f32) void {
        self.vtbl.ClearRenderTargetView(self, rtv, color);
    }
};

// --- IDXGISwapChain --------------------------------------------------------
//
// IUnknown(0..2) + IDXGIObject(3..6) + IDXGIDeviceSubObject(7) + IDXGISwapChain
// from slot 8. Bound through ResizeBuffers (slot 13).

pub const IDXGISwapChain = extern struct {
    vtbl: *const Vtbl,

    pub const Vtbl = extern struct {
        QueryInterface: *const anyopaque, // 0
        AddRef: *const anyopaque, // 1
        Release: *const fn (*IDXGISwapChain) callconv(.winapi) u32, // 2
        SetPrivateData: *const anyopaque, // 3
        GetPrivateData: *const anyopaque, // 4
        SetPrivateDataInterface: *const anyopaque, // 5
        GetParent: *const anyopaque, // 6
        GetDevice: *const anyopaque, // 7
        Present: *const fn (*IDXGISwapChain, u32, u32) callconv(.winapi) HRESULT, // 8
        GetBuffer: *const fn (*IDXGISwapChain, u32, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT, // 9
        SetFullscreenState: *const anyopaque, // 10
        GetFullscreenState: *const anyopaque, // 11
        GetDesc: *const anyopaque, // 12
        ResizeBuffers: *const fn (*IDXGISwapChain, u32, u32, u32, u32, u32) callconv(.winapi) HRESULT, // 13
    };

    pub inline fn Release(self: *IDXGISwapChain) u32 {
        return self.vtbl.Release(self);
    }
    pub inline fn Present(self: *IDXGISwapChain, sync_interval: u32, flags: u32) HRESULT {
        return self.vtbl.Present(self, sync_interval, flags);
    }
    pub inline fn GetBuffer(self: *IDXGISwapChain, buffer: u32, riid: *const GUID, out: *?*anyopaque) HRESULT {
        return self.vtbl.GetBuffer(self, buffer, riid, out);
    }
    pub inline fn ResizeBuffers(self: *IDXGISwapChain, count: u32, width: u32, height: u32, format: u32, flags: u32) HRESULT {
        return self.vtbl.ResizeBuffers(self, count, width, height, format, flags);
    }
};

// --- Entry points ----------------------------------------------------------

pub extern "d3d11" fn D3D11CreateDeviceAndSwapChain(
    pAdapter: ?*anyopaque,
    DriverType: i32,
    Software: ?*anyopaque,
    Flags: u32,
    pFeatureLevels: ?[*]const i32,
    FeatureLevels: u32,
    SDKVersion: u32,
    pSwapChainDesc: *const DXGI_SWAP_CHAIN_DESC,
    ppSwapChain: *?*IDXGISwapChain,
    ppDevice: *?*ID3D11Device,
    pFeatureLevel: ?*i32,
    ppImmediateContext: *?*ID3D11DeviceContext,
) callconv(.winapi) HRESULT;

pub extern "d3dcompiler_47" fn D3DCompile(
    pSrcData: *const anyopaque,
    SrcDataSize: usize,
    pSourceName: ?[*:0]const u8,
    pDefines: ?*const anyopaque,
    pInclude: ?*anyopaque,
    pEntrypoint: [*:0]const u8,
    pTarget: [*:0]const u8,
    Flags1: u32,
    Flags2: u32,
    ppCode: *?*ID3DBlob,
    ppErrorMsgs: *?*ID3DBlob,
) callconv(.winapi) HRESULT;
