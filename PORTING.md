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

## Test porting policy

We do **not** migrate ghostty's test suite wholesale — that conflicts with the
hybrid architecture (ADR 0002). Instead, tests travel with the code, per layer:

- `port` rows — porting a file **includes porting/adapting its ghostty test
  cases** in the same unit of work. Tests are part of "faithful".
- `template` rows — no portable upstream test (the Windows layer has no 1:1
  counterpart); write **fresh** tests for the new code.
- `dependency` rows — the VT-core tests stay upstream in libghostty-vt and are
  **not** duplicated here; we only test our usage of the library.

The `Tests` column below tracks this per layer.

## Map

| Layer | ghostty path | whostty path | Strategy | Status | Tests |
|-------|--------------|--------------|----------|--------|-------|
| VT core | `src/terminal/` | — (via `ghostty-vt` module) | dependency | done | upstream |
| VT input encoding | `src/input/` (key/mouse/paste encode) | — (via `ghostty-vt` `input`) | dependency | done | upstream |
| Entrypoint | `src/main.zig` | `src/main.zig` | port | done | done (vt wiring) |
| App (Windows) | `src/apprt/gtk/App.zig` | `src/apprt/win32/App.zig` | template | slice-0 + SGR cells, config-driven colors/size (#12/#17) | links |
| Surface | `src/Surface.zig` | `src/Surface.zig` | port | resize done | done (host: sizing) |
| apprt registry | `src/apprt.zig` | `src/apprt.zig` | port | scaffolded | port tests |
| apprt (Windows) | `src/apprt/gtk/` | `src/apprt/win32/Window.zig` | template | done (window+WGL) | fresh tests |
| Windows API | (ghostty `src/os/windows.zig`) | `src/os/windows.zig` | template | done | fresh tests |
| PTY | `src/pty.zig` | `src/pty.zig` (ConPTY) | template | done | fresh tests |
| Terminal IO | `src/termio.zig`, `src/termio/` | `src/termio.zig` | port | done + viewport scroll (#16) | done (host) |
| Scrollback scroll | `src/Surface.zig` (scroll); storage in VT core | `src/scroll.zig` (wheel→rows) + `termio` scroll, viewport in `ghostty-vt` `PageList` | port + dependency | wheel scroll + scroll-to-bottom (#16) | done (host: wheel accum) |
| Renderer (OpenGL) | `src/renderer/OpenGL.zig` | `src/renderer/OpenGL.zig` (WGL/GL 3.3) | port | SGR fg/bg + decorations (#12) | done (host: geometry, solid quads) |
| SGR color/attrs | `src/terminal/sgr.zig`, `src/terminal/style.zig` | resolved via `ghostty-vt` (`Style.fg`/`bg`, palette) in `apprt/win32/App.zig` | dependency | fg/bg/inverse/underline/strike/overline (#12) | upstream (resolution) |
| Glyph atlas | `src/font/Atlas.zig` | `src/font/Atlas.zig` | port | done | done (host) |
| Font (Freetype) | `src/font/main.zig` | `src/font/main.zig` | port | opt-in (`-Dfreetype`); synthetic bold/italic deferred (#13/#14) | host (needs font + network) |
| Input (app-side) | `src/input.zig` | `src/input.zig` | port | done | done (host) |
| Config | `src/config/Config.zig`, `src/cli/args.zig` (LineIterator) | `src/config.zig` | port | file format + initial options (#17) | done (host) |
| Tabs / splits | ghostty apprt split paneling | `src/apprt/win32/SplitTree.zig` | template | split tree + layout/close (#18) | done (host: tree + geometry) |

Rows are added lazily as layers are ported. "scaffolded" = stub exists with a
reference header; "done" = ported and building.

## Explicitly excluded (for now)

These ghostty paths are out of scope and intentionally not mirrored yet:
`cli/` (full CLI arg parsing — only the config line format is ported, see the
Config row), `inspector/`, `crash/`, `benchmark/`, `synthetic/`,
`shell-integration/`, `terminfo/`, plus the macOS/GTK-specific apprt layers.
