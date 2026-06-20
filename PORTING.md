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
| Scrollback scroll | `src/Surface.zig` (scroll); storage in VT core | `src/scroll.zig` (wheel→rows, page, scrollbar thumb) + `termio` scroll, viewport in `ghostty-vt` `PageList` | port + dependency | wheel + page scroll, scroll-to-bottom, scrollbar geometry (#16) | done (host: wheel/page/scrollbar) |
| Renderer registry | `src/renderer.zig` | `src/renderer.zig` | template | backend abstraction + `renderer` config selector; Direct3D backend pending a Windows host (#15) | done (host: enum guard) |
| Renderer (OpenGL) | `src/renderer/OpenGL.zig` | `src/renderer/OpenGL.zig` (WGL/GL 3.3) | port | SGR fg/bg + decorations (#12) | done (host: geometry, solid quads) |
| SGR color/attrs | `src/terminal/sgr.zig`, `src/terminal/style.zig` | resolved via `ghostty-vt` (`Style.fg`/`bg`, palette) in `apprt/win32/App.zig` | dependency | fg/bg/inverse/underline/strike/overline (#12) | upstream (resolution) |
| Glyph atlas | `src/font/Atlas.zig` | `src/font/Atlas.zig` | port | done | done (host) |
| Font (Freetype) | `src/font/main.zig` | `src/font/main.zig` | port | opt-in (`-Dfreetype`); synthetic bold/italic deferred (#13/#14) | host (needs font + network) |
| Font discovery | `src/font/discovery.zig` (Descriptor + backend) | `src/font/discovery.zig` (DirectWrite) | template | Descriptor + family resolution/fallback + DW weight/style mapping + emoji presentation (#14); DirectWrite COM enumeration pending a Windows host | done (host: core); COM untested |
| Text shaping | `src/font/shaper/run.zig`, `shaper/harfbuzz.zig` | `src/font/shaper.zig` | port | presentation-aware run segmentation + `font-feature` parsing (#13); Harfbuzz shaping seamed pending the dependency + a compiler | done (host: run iterator, features) |
| Input (app-side) | `src/input.zig` | `src/input.zig` | port | done | done (host) |
| Keybindings | `src/input/Binding.zig` | `src/input/Binding.zig` + apprt dispatch | port | chord/action grammar + Set + defaults + `keybind` config, and Win32 event→trigger→action dispatch (scroll actions live; split/tab await multi-surface) (#18/#16) | done (host); dispatch link-checked |
| Config | `src/config/Config.zig`, `src/cli/args.zig` (LineIterator) | `src/config.zig` | port | file format + options: colors/font/cursor/palette/renderer/font-feature/keybind/cursor+selection colors/bold-is-bright/scrollback-limit (#17) | done (host) |
| Surface mgmt (tabs/splits) | `src/apprt/gtk/` (Split/Notebook) | `src/apprt/win32/SplitTree.zig` | template | split tree (split/close/resize/equalize/layout/focus-nav/hit-test) + tab list model (#18) | fresh (host) |

Rows are added lazily as layers are ported. "scaffolded" = stub exists with a
reference header; "done" = ported and building.

## Completeness invariant

The goal is **full parity** (see CONTEXT.md): every ghostty `src/` path not
delegated to libghostty-vt is eventually ported. This table is therefore the
**completeness ledger** — it must enumerate the *whole* in-scope ghostty `src/`
tree, not only the rows ported so far. Completeness is checkable mechanically:

    ghostty v1.3.1 src/ tree − (delegated ∪ rows in this file) = unfiled gap

An item counts as "filed" only when it is a not-done row **with a linked issue**.
The rows above cover slice-0 + early flesh-out; the areas below are the known
**deferred** remainder and still need ledger rows + issues. (The full row-by-row
enumeration against the v1.3.1 tree is itself tracked work — #59.)

## Deferred (tracked, not excluded)

Previously listed as "excluded (for now)". Under the full-parity goal these are
**not** out of scope — they are deferred and filed. Rough sequencing by
daily-driver criticality (tracked under the roadmap epic #47):

- **Tier 0 — host-gate** (#48): secure a Windows dev host + code-signing so
  unsigned builds can launch; unblocks render proof (#46), on-device
  verification, and every native backend (#43). Single root dependency; signing
  is reused for distribution.
- **Tier 1 — usable terminal**: app-side wiring on top of the delegated VT cores
  — clipboard/copy (#50), text selection hit-test + render (#51), and
  `surface_mouse.zig` pointer/mouse routing (#52). The VT-level selection /
  mouse / paste / OSC 8 *encoding* is delegated to libghostty-vt; only the wiring
  is whostty's.
- **Tier 2 — quality / parity**: the native backends still pending a Windows host
  (Harfbuzz, DirectWrite COM, Direct3D 11, multi-surface runtime, scrollbar
  drawing — see the rows above and #43), and the **full `config/` system** (#49):
  the Config row ports the file format + options, but ghostty's `config/`
  (formatter, conditional, theme, ~14.5K LOC) and themes are not yet ported.
- **Tier 3 — ecosystem**: `cli/` full arg parsing/actions (#53), `terminfo/`
  (#54), `shell-integration/` (#55), `inspector/` (#56), `crash/` (#57), and
  packaging/installer/auto-update (#58, shares signing with the host-gate).

Permanently out of scope (tooling, not the GUI terminal, so excluded from the
completeness invariant): `benchmark/`, `synthetic/`, `build/`, the alternate
`main_*.zig` targets (wasm/bench/c/gen), and the macOS/GTK-specific apprt layers.
