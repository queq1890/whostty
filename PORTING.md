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
| Terminal IO | `src/termio.zig`, `src/termio/` | `src/termio.zig` | port | done + viewport scroll (#16) + VT response write-back (DSR/DA/DECRQM/ENQ) via a handler wrapping `ReadonlyHandler` (#81) + OSC 4/10/11/12 color queries answered from `terminal.colors` (#83) + focus reporting (DEC mode 1004 → `CSI I`/`CSI O`) (#85); xtversion/size/kitty-query replies (#82), OSC 52/notifications/bell (#85) deferred | done (host) |
| Scrollback scroll | `src/Surface.zig` (scroll); storage in VT core | `src/scroll.zig` (wheel→rows, page, scrollbar thumb) + `termio` scroll, viewport in `ghostty-vt` `PageList` | port + dependency | wheel + page scroll, scroll-to-bottom, scrollbar geometry (#16) | done (host: wheel/page/scrollbar) |
| Renderer registry | `src/renderer.zig` | `src/renderer.zig` | template | backend abstraction + `renderer` config selector; Direct3D backend pending a Windows host (#15) | done (host: enum guard) |
| Renderer (OpenGL) | `src/renderer/OpenGL.zig` | `src/renderer/OpenGL.zig` (WGL/GL 3.3) | port | SGR fg/bg + decorations (#12) + per-quad alpha attribute for translucency (#69) | done (host: geometry, solid quads) |
| Renderer (appearance) | `src/renderer/cell.zig`, `glsl/common.glsl` (`contrasted_color`) | `src/renderer/color.zig` + `apprt/win32/App.zig` | port | minimum-contrast (WCAG) + faint/dim opacity (#70); background-opacity/blur/image (Win32 compositor) + per-glyph min-contrast exemption deferred | done (host: contrast math); GL (offscreen-proof: alpha blend) |
| Renderer (cursor) | `src/renderer/cursor.zig` | `src/renderer/cursor.zig` | port | block/bar/underline/hollow + blink + hollow-when-unfocused + cursor color/text/opacity (#69); `lock`/sprite cursors deferred | done (host: resolveStyle+geometry); GL (offscreen-proof: 256-px block) |
| SGR color/attrs | `src/terminal/sgr.zig`, `src/terminal/style.zig` | resolved via `ghostty-vt` (`Style.fg`/`bg`, palette) in `apprt/win32/App.zig` | dependency | fg/bg/inverse/underline/strike/overline (#12); default fg/bg + palette read from `terminal.colors` so OSC 4/10/11 dynamic changes render (#83) | upstream (resolution) |
| Glyph atlas | `src/font/Atlas.zig` | `src/font/Atlas.zig` | port | shelf packer + `Placement`; atlas growth/eviction deferred (#66) | done (host) |
| Glyph cache | `src/font/` (cache) | `src/font/GlyphCache.zig` | port | on-demand rasterize+pack of any codepoint the face has (no longer ASCII-only) + dirty re-upload; per-codepoint fallback (#75) / atlas growth deferred (#66) | done (host + offscreen-proof: non-ASCII U+2500) |
| Font (Freetype) | `src/font/main.zig` | `src/font/main.zig` | port | opt-in (`-Dfreetype`); `glyphIndex` (skip absent glyphs) added (#66); synthetic bold/italic deferred (#13/#14/#77) | host (needs font + network) |
| Font discovery | `src/font/discovery.zig` (Descriptor + backend) | `src/font/discovery.zig` (DirectWrite) | template | Descriptor + family resolution/fallback + DW weight/style mapping + emoji presentation (#14); DirectWrite COM enumeration pending a Windows host | done (host: core); COM untested |
| Text shaping | `src/font/shaper/run.zig`, `shaper/harfbuzz.zig` | `src/font/shaper.zig` | port | presentation-aware run segmentation + `font-feature` parsing (#13); Harfbuzz shaping seamed pending the dependency + a compiler | done (host: run iterator, features) |
| Input (app-side) | `src/input.zig` | `src/input.zig` | port | Ctrl/Shift/Alt modifier encoding + nav/function keys (Home/End/PgUp/PgDn/Ins/Del/F1-F12) + cursor-key (DECCKM)/keypad/modify-other-keys options via `KeyEncodeOptions.fromTerminal` (#82). Alt+special keys are routed via WM_SYSKEYDOWN (except Alt+F4 → window close); modified Enter/Tab faithfully emit ghostty's fixterms `CSI 27;…~` form. Kitty keyboard output + `CSI ? u` reply + Alt-as-Meta (WM_SYSCHAR) deferred (kitty forced off to stay consistent with the WM_CHAR text path) | done (host) |
| Keybindings | `src/input/Binding.zig` | `src/input/Binding.zig` + apprt dispatch | port | chord/action grammar + Set + defaults + `keybind` config, and Win32 event→trigger→action dispatch (scroll actions live; split/tab await multi-surface) (#18/#16) | done (host); dispatch link-checked |
| Config | `src/config/Config.zig`, `src/cli/args.zig` (LineIterator) | `src/config.zig` | port | file format + options: colors/font/cursor/palette/renderer/font-feature/keybind/cursor+selection colors/cursor-text/cursor-opacity/bold-is-bright/scrollback-limit (#17/#69) | done (host) |
| Surface mgmt (tabs/splits) | `src/apprt/gtk/` (Split/Notebook) | `src/apprt/win32/SplitTree.zig` | template | split tree (split/close/resize/equalize/layout/focus-nav/hit-test) + tab list model (#18) | fresh (host) |
| GL context | `src/renderer/opengl/` (context) | `src/apprt/win32/Window.zig` (WGL) | template | 3.3-core context via `wglCreateContextAttribsARB` + sentinel-guarded loader; verified headless via `offscreen-proof` (#46) | host (EGL/Mesa proof) |
| Clipboard | `src/apprt/gtk/Surface.zig` (clipboard); `src/input/paste.zig` | `src/os/windows.zig` (CF_UNICODETEXT) + `vt.input.encodePaste` | template + dependency | copy/paste; bracketed-paste + unsafe-strip delegated to libghostty-vt (#50) | done (host: UTF-16↔8) |
| Selection | `src/Surface.zig` (mouse select); `src/terminal/Selection.zig` | `src/Surface.zig` + `src/termio.zig` (drag → `screen.select`) | port + dependency | left-drag select + highlight via tracked pins; range/text by `ghostty-vt` (#51); word/line + threshold pending | done (host: hit-test, select round-trip) |
| Mouse report | `src/Surface.zig` `mouseReport` | `src/mouse.zig` + `apprt/win32` wiring | template | SGR 1006 + X10 button press/release encode (not exposed by libghostty-vt); motion/wheel/other formats pending (#52) | done (host: encoder) |
| CLI | `src/cli/args.zig`, `src/cli/Action.zig` | `src/cli.zig` | port | `-e command`, `--key[=value]` config flags, `--help`/`--version`; `+action` subcommands pending (#53) | done (host: parser) |

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
- **Tier 1 — usable terminal**: first cut **landed** — clipboard copy/paste
  (#50), mouse-drag selection + highlight (#51), and SGR/X10 mouse reporting
  (#52). Follow-ups: word/line (double/triple-click) + sub-cell-threshold
  selection, mouse motion/wheel reporting + utf8/urxvt/sgr_pixels formats. (VT
  selection / paste / OSC 8 *encoding* is delegated to libghostty-vt; mouse
  *encoding* is not exposed, so it is ported in `src/mouse.zig`.)
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
