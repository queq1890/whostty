//! whostty: renderer registry — selects the GPU backend and exposes the
//! backend-neutral surface to the app.
//!
//! Reference: ghostty `src/renderer.zig` (strategy: port). ghostty selects a
//! renderer at comptime (Metal on macOS, OpenGL elsewhere). whostty uses
//! WGL/OpenGL today and targets Direct3D as the long-term native backend
//! (#15). The drawable geometry (quads → vertices) is backend-neutral and
//! lives in `renderer/geometry.zig`; each backend only owns its GPU resources
//! and draw call but shares the same `Cell`/`SolidRect`/`Quad`/`Vertex` and
//! `geometry.build`. See PORTING.md.
const builtin = @import("builtin");

pub const geometry = @import("renderer/geometry.zig");

/// Backend-neutral drawable types, re-exported for app code so it never has to
/// know which backend is active.
pub const Cell = geometry.Cell;
pub const SolidRect = geometry.SolidRect;
pub const Quad = geometry.Quad;
pub const Vertex = geometry.Vertex;

/// The available GPU backends. OpenGL is the bring-up path; Direct3D is the
/// long-term native target (#15) and is not yet implemented.
pub const Backend = enum { opengl, direct3d };

/// The backend selected for this build. Direct3D selection is added with its
/// implementation (#15); until then OpenGL is the only option.
pub const active: Backend = .opengl;

/// The concrete renderer for the active backend.
pub const Renderer = switch (active) {
    .opengl => @import("renderer/OpenGL.zig").Renderer,
    .direct3d => @compileError("Direct3D backend not yet implemented (#15)"),
};

test {
    // Pull in the backend-neutral geometry tests.
    _ = geometry;
}
