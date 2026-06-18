# Porting Map

This file maps ghostty `src/` paths to their whostty counterparts. It defines
the **mirrored paths** — the surface whostty faithfully ports — and excludes the
VT core, which is delegated to libghostty-vt.

The map serves two roles:

1. It tells the porting workflow which ghostty file is the reference for each
   whostty file.
2. It is the source of truth the **Release Routine** uses to decide which
   upstream changes require re-porting.

## Pinned upstream

- ghostty tag: **v1.3.1** (pinned in `build.zig.zon` as the `ghostty` dependency)
- libghostty-vt module: `ghostty-vt` (root source `src/lib_vt.zig`)

When bumping the pin, update this line and re-port any changes under the
mirrored paths below.

## Strategy legend

- `port` — faithful 1:1 port from the ghostty reference.
- `template` — no upstream counterpart (Windows-specific); ghostty's analogous
  layer is used only as a structural template (e.g. `apprt/gtk` → `apprt/win32`).
- `dependency` — provided by libghostty-vt, not ported.

## Map

| Layer | ghostty path | whostty path | Strategy | Status |
|-------|--------------|--------------|----------|--------|
| VT core | `src/terminal/` | — (via `ghostty-vt` module) | dependency | done |
| VT input encoding | `src/input/` (key/mouse/paste encode) | — (via `ghostty-vt` `input`) | dependency | done |
| Entrypoint | `src/main.zig` | `src/main.zig` | port | scaffolded |
| App | `src/App.zig` | `src/App.zig` | port | scaffolded |
| Surface | `src/Surface.zig` | `src/Surface.zig` | port | scaffolded |
| apprt registry | `src/apprt.zig` | `src/apprt.zig` | port | scaffolded |
| apprt (Windows) | `src/apprt/gtk/` | `src/apprt/win32/` | template | scaffolded |
| PTY | `src/pty.zig` | `src/pty.zig` (ConPTY) | template | scaffolded |
| Terminal IO | `src/termio.zig`, `src/termio/` | `src/termio.zig` | port | scaffolded |
| Renderer registry | `src/renderer.zig` | `src/renderer.zig` | port | scaffolded |
| Renderer (OpenGL) | `src/renderer/OpenGL.zig` | `src/renderer/OpenGL.zig` (WGL) | port | scaffolded |
| Font | `src/font/main.zig` | `src/font/main.zig` (Freetype) | port | scaffolded |
| Input (app-side) | `src/input.zig` | `src/input.zig` | port | scaffolded |

Rows are added lazily as layers are ported. "scaffolded" = stub exists with a
reference header; "done" = ported and building.

## Explicitly excluded (for now)

These ghostty paths are out of scope until after slice-0 and are intentionally
not mirrored yet: `cli/`, `config/` (config file), `inspector/`, `crash/`,
`benchmark/`, `synthetic/`, `shell-integration/`, `terminfo/`, plus the
macOS/GTK-specific apprt layers.
