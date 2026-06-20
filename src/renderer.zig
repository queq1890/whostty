//! whostty: renderer backend abstraction.
//!
//! Reference: ghostty `src/renderer.zig` selects a backend (`OpenGL`, `Metal`)
//! behind a common surface so the app is backend-agnostic. Strategy: template —
//! whostty's backends are Windows-specific. WGL/OpenGL is the bring-up path and
//! default; Direct3D is the long-term native target (#15). See PORTING.md.
//!
//! The selected backend is configured via `renderer` in the config file
//! (`config.RendererBackend`). This module names the abstraction and the
//! contract each backend satisfies; it does not force a vtable on the hot path —
//! the app holds a concrete backend chosen at startup (ghostty does the same
//! with a comptime/config switch).
//!
//! ## Backend contract
//!
//! Every backend exposes the same shape the apprt already drives on `OpenGL`:
//!
//!   * `init(...) !Backend`            — create GPU resources for the surface.
//!   * `deinit(self)`                  — release them.
//!   * `resize(self, w, h)`            — viewport follows the window.
//!   * `draw(self, clear, quads)`      — clear to a background color and draw
//!                                       the frame's textured/solid cell quads.
//!   * atlas upload for glyph coverage bytes.
//!
//! Keeping the method names/shape identical across backends is what lets the
//! apprt swap one for the other without touching the frame loop.
const std = @import("std");

/// The OpenGL (WGL) backend — the implemented, default renderer.
pub const OpenGL = @import("renderer/OpenGL.zig");

/// Cursor style resolution + shape geometry (backend-agnostic).
pub const cursor = @import("renderer/cursor.zig");

/// Which backend to use. Mirrors `config.RendererBackend`; the app maps the
/// config value onto this and constructs the matching backend.
pub const Backend = enum {
    opengl,
    direct3d,
};

/// Direct3D backend (#15) — the long-term native Windows renderer.
///
/// Not yet implemented. A faithful D3D11 path mirrors the OpenGL one: create a
/// device + swap chain for the HWND (`D3D11CreateDeviceAndSwapChain`), a glyph
/// atlas as a `Texture2D` + SRV, a textured-quad vertex/pixel shader pair, a
/// dynamic vertex buffer for per-cell quads, and `Present` per frame — the same
/// quad geometry the OpenGL backend's host-tested `pushQuad` already produces,
/// so that math is shared rather than reimplemented.
///
/// This is COM-heavy (device, context, swap chain, buffers, shaders, blend
/// state) and must be written and verified on a Windows host with a compiler; a
/// wrong interface layout faults at run time, not compile time. It is therefore
/// not landed blind in this environment. Selecting `renderer = direct3d` today
/// falls back to OpenGL with a warning (see `apprt/win32/App.zig`).
pub const direct3d_status = "pending: needs a Windows host + compiler to verify the COM device/swapchain path (#15)";

test {
    // Pull the implemented backend's host tests in via the abstraction module.
    _ = OpenGL;
    _ = cursor;
}

test "renderer: backend enum mirrors the config selector names" {
    // Guards against the two enums drifting apart. Both must list the same
    // backends in the same spelling so the app can map one to the other.
    const config = @import("config.zig");
    const a = std.meta.fields(Backend);
    const b = std.meta.fields(config.RendererBackend);
    try std.testing.expectEqual(a.len, b.len);
    inline for (a, b) |fa, fb| {
        try std.testing.expectEqualStrings(fa.name, fb.name);
    }
}
