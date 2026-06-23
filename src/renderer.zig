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

/// WCAG contrast + minimum-contrast foreground adjustment (backend-agnostic).
pub const color = @import("renderer/color.zig");

/// Which backend to use. Mirrors `config.RendererBackend`; the app maps the
/// config value onto this and constructs the matching backend.
pub const Backend = enum {
    opengl,
    direct3d,
};

/// The Direct3D 11 backend (#15/#43) — the native Windows renderer.
///
/// A faithful port of the OpenGL one: it creates a device + swap chain for the
/// HWND (`D3D11CreateDeviceAndSwapChain`), an R8 glyph atlas + RGBA color atlas
/// as `Texture2D` + SRV, a runtime-compiled HLSL vertex/pixel shader pair, a
/// dynamic vertex buffer, and `Present` per frame — sharing the OpenGL backend's
/// host-tested `pushQuad`/`pushSolid`/`pushColorQuad` geometry rather than
/// reimplementing it. The app selects it with `renderer = direct3d`.
pub const Direct3D11 = @import("renderer/Direct3D11.zig");

test {
    // Pull the implemented backends' host tests in via the abstraction module.
    _ = OpenGL;
    _ = Direct3D11;
    _ = cursor;
    _ = color;
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
