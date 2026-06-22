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
| App (Windows) | `src/apprt/gtk/App.zig` | `src/apprt/win32/App.zig` | template | slice-0 + SGR cells, config-driven colors/size (#12/#17); **frame pacing** (`src/frame.zig`): redraw only when the terminal's dirty generation, the (blinking) cursor phase, focus, or a UI event changed — otherwise the loop sleeps via `MsgWaitForMultipleObjects` and the reader thread wakes it with `PostMessage` on new output (#72) | links; frame-pacing logic host-tested |
| Surface | `src/Surface.zig` | `src/Surface.zig` | port | resize done + window padding (`window-padding-x/y/-balance`): `layout()` reserves padding on each side, fits the grid, and offsets the origin (renderer + mouse both honor it); balance centers the grid (#71). Per-cell selection reverse-video done (#51, `buildQuads`); custom GLSL shaders deferred (host) | done (host: layout/origin); GL (offscreen-proof: pad shifts glyph) |
| apprt registry | `src/apprt.zig` | `src/apprt.zig` | port | scaffolded | port tests |
| apprt (Windows) | `src/apprt/gtk/` | `src/apprt/win32/Window.zig` | template | done (window+WGL); **live window title** (#89, done) from OSC 0/2 (`Termio` captures `.window_title` → UI thread drains → `Window.setTitle`/`SetWindowTextW`, codepoint-bounded UTF-16 to avoid overflow); CSI 21t/22t/23t deferred (#89). **Window-state actions** (#91, done): `toggleFullscreen` (borderless windowed fullscreen — saves `GetWindowPlacement`+`GWL_STYLE`, drops `WS_OVERLAPPEDWINDOW`, `SetWindowPos` to the nearest monitor's `rcMonitor`; restores style then placement), `toggleMaximize` (`IsZoomed`?`SW_RESTORE`:`SW_MAXIMIZE`), `toggleDecorations` (flip `WS_CAPTION\|WS_THICKFRAME` + `SetWindowPos SWP_FRAMECHANGED`) — all fire WM_SIZE so the existing resize path re-grids/re-ptys with no extra wiring; and **close-confirmation** (mirrors ghostty `Surface.needsConfirmQuit` default `.true`): WM_CLOSE is swallowed into the `.close` event, and the apprt prompts via `MessageBoxW(MB_YESNO)` only when the shell pid has a live child (a foreground command is running — `CreateToolhelp32Snapshot` walk), proceeding silently otherwise. **IME composition** (#88, done): `WM_IME_*` feed the committed result string to the pty and pin the IME composition + candidate windows to the focused caret (`ImmSetCompositionWindow`/`ImmSetCandidateWindow`). **DPI/scale changes** (#90, done): per-monitor-DPI-v2 awareness + `WM_DPICHANGED` rebuilds the glyph cache + HarfBuzz shaper + cell metrics at the new scale (the face opens at the DPI-scaled point size; 96 DPI is unchanged). **App-lifecycle + windowing actions** (#92, done): `quit`/`close_window`/`goto_window`/`present_terminal`/`toggle_window_float_on_top`/`toggle_visibility` via a mutex-guarded live-window registry on `App` (cross-window steps use only thread-safe `PostMessageW`/`SetForegroundWindow`). **Single-instance/IPC** (#93, done, opt-in `single-instance`): a named mutex + a hidden message-only listener route a second launch's new-window request into the running process. Live config reload deferred to the config epic (#49) | fresh tests |
| Windows API | (ghostty `src/os/windows.zig`) | `src/os/windows.zig` | template | done; window-state externs added (#91): `SetWindowPos`/`Get`+`SetWindowPlacement`/`IsZoomed`/`MonitorFromWindow`/`GetMonitorInfoW`/`MessageBoxW` + `WINDOWPLACEMENT`/`MONITORINFO`/`GWL_*`/`SW_*`/`SWP_*`/`WS_CAPTION`/`WS_THICKFRAME`/`MB_*`, and toolhelp `CreateToolhelp32Snapshot`/`Process32FirstW`/`NextW`+`PROCESSENTRY32W`+`GetProcessId` behind `shellHasRunningChild()` | fresh tests |
| PTY | `src/pty.zig` | `src/pty.zig` (ConPTY) | template | done | fresh tests |
| Terminal IO | `src/termio.zig`, `src/termio/` | `src/termio.zig` | port | done + viewport scroll (#16) + VT response write-back (DSR/DA/DECRQM/ENQ) via a handler wrapping `ReadonlyHandler` (#81) + OSC 4/10/11/12 color queries answered from `terminal.colors` (#83) + focus reporting (DEC mode 1004 → `CSI I`/`CSI O`) + OSC 52 clipboard (#85) + kitty-keyboard query (`CSI ? u`) reply (#82) + out-of-band side channels captured & drained on the UI thread: BEL → window flash, OSC 7 cwd, OSC 9/777 notifications, OSC 9;4 progress (#85, ADR 0008); xtversion/size replies + kitty key *output* (#82) deferred; OS toast/taskbar surfacing host-only (#43) | done (host) |
| Scrollback scroll | `src/Surface.zig` (scroll); storage in VT core | `src/scroll.zig` (wheel→rows, page, scrollbar thumb) + `termio` scroll, viewport in `ghostty-vt` `PageList` | port + dependency | wheel + page scroll, scroll-to-bottom, scrollbar geometry (#16); **visible scrollbar** rendered as an overlay thumb on the right edge from `PageList.scrollbar()` row counts, shown only with scrollback (#73, drag-thumb interaction deferred) | done (host: wheel/page/scrollbar + `Termio.scrollbar`); GL (offscreen-proof: thumb tracks viewport) |
| Renderer registry | `src/renderer.zig` | `src/renderer.zig` | template | backend abstraction + `renderer` config selector; Direct3D backend pending a Windows host (#15) | done (host: enum guard) |
| Renderer (OpenGL) | `src/renderer/OpenGL.zig` | `src/renderer/OpenGL.zig` (WGL/GL 3.3) | port | SGR fg/bg + decorations (#12) + per-quad alpha attribute for translucency (#69) | done (host: geometry, solid quads) |
| Decoration sprites | `src/font/sprite/underline.zig` | `src/renderer/decoration.zig` + `apprt/win32/App.zig` | port (slice) | underline styles single/double/dotted/dashed/curly drawn as solid rects (no atlas) instead of one flat line (#80); strikethrough/overline single-line | done (host: rect geometry); GL (offscreen-proof: dotted gaps, curly squiggle) |
| Sprite glyphs | `src/font/sprite/` (`Box.zig`, `Canvas.zig`) | `src/font/sprite.zig` (used by `GlyphCache`) | port (slice) | block elements (U+2580–259F: halves/eighths/quadrants/shades) + braille (U+2800–28FF) + box-drawing lines (U+2500–257F: light/heavy/double lines, corners, tees, crosses via a center-segment table; mixed-weight/partial variants fall to the font) rasterized procedurally into a cell-sized alpha bitmap, packed like a font glyph, font-independent (#76); Powerline/Nerd Font symbols follow-up | done (host: per-category pixels, box segments on the center axes); GL (offscreen-proof: full block, quadrant, box-drawing cross) |
| Renderer (appearance) | `src/renderer/cell.zig`, `glsl/common.glsl` (`contrasted_color`) | `src/renderer/color.zig` + `apprt/win32/App.zig` | port | minimum-contrast (WCAG) + faint/dim opacity + bold-is-bright (bold maps palette 0–7 → 8–15 via `Style.fg`'s `bold = .bright`) (#70); `bold-color` (fixed) + background-opacity/blur/image (Win32 compositor) + per-glyph min-contrast exemption deferred | done (host: contrast math); GL (offscreen-proof: alpha blend, bold→bright palette) |
| Renderer (cursor) | `src/renderer/cursor.zig` | `src/renderer/cursor.zig` | port | block/bar/underline/hollow + blink + hollow-when-unfocused + cursor color/text/opacity (#69); `lock`/sprite cursors deferred | done (host: resolveStyle+geometry); GL (offscreen-proof: 256-px block) |
| SGR color/attrs | `src/terminal/sgr.zig`, `src/terminal/style.zig` | resolved via `ghostty-vt` (`Style.fg`/`bg`, palette) in `apprt/win32/App.zig` | dependency | fg/bg/inverse/underline/strike/overline (#12); default fg/bg + palette read from `terminal.colors` so OSC 4/10/11 dynamic changes render (#83) | upstream (resolution) |
| Glyph atlas | `src/font/Atlas.zig` | `src/font/Atlas.zig` | port | shelf packer + `Placement`; 1-bpp alpha + 4-bpp RGBA variant for color glyphs (`initBpp`) (#78); atlas growth/eviction deferred (#66) | done (host) |
| Glyph cache | `src/font/` (cache) | `src/font/GlyphCache.zig` | port | on-demand rasterize+pack of any codepoint the face has (no longer ASCII-only) + dirty re-upload; keyed by (codepoint, bold, italic) so styled glyphs pack distinct atlas entries (#77); **per-codepoint fallback** (`addFallback` chain — codepoints the primary lacks render from a fallback face, e.g. CJK/symbols) (#75); atlas growth deferred (#66) | done (host + offscreen-proof: non-ASCII U+2500, CJK U+4E00 via fallback) |
| Font (Freetype) | `src/font/main.zig` | `src/font/main.zig` | port | opt-in (`-Dfreetype`); `glyphIndex` (skip absent glyphs) added (#66); synthetic bold (outline embolden) + italic (outline shear) from the single regular face (#77); **color glyphs** (emoji): bitmap-strike faces (`FT_Select_Size`) + `rasterizeColor` (`FT_LOAD_COLOR` → BGRA → straight-alpha RGBA scaled to the cell, both CBDT and COLR) — build enables `enable-libpng` so Freetype decodes PNG strikes (#78); per-style families (`font-family-bold` etc.) deferred (#13/#14) | host (needs font); GL (offscreen-proof: bold adds ink, emoji renders in color) |
| Renderer (color glyphs) | `src/renderer/opengl/` (textured quad) | `src/renderer/OpenGL.zig` (2nd RGBA texture + shader mode 2) + `GlyphCache` color atlas | port | emoji packed into a 4-bpp color atlas, drawn untinted via a `color_glyph` quad sampling `u_color_atlas` (#78); aspect/wide-cell emoji sizing rides with wide-char support | done (host: cache color path); GL (offscreen-proof: 226 colorful px) |
| Font discovery | `src/font/discovery.zig` (Descriptor + backend) | `src/font/discovery.zig` (DirectWrite) + `src/os/dwrite.zig` (COM bindings) | template | Descriptor + family resolution/fallback + DW weight/style mapping + emoji presentation (#14); **DirectWrite COM enumeration** resolves the configured `font-family` to a concrete font file (hand-written `os/dwrite.zig` vtable bindings) and the app loads it, falling back to the default on error (#74) | done (host: core); on-device verified (Georgia/Courier New/default all resolve + load) |
| Text shaping | `src/font/shaper/run.zig`, `shaper/harfbuzz.zig` | `src/font/shaper.zig` (run iterator + types) + `src/font/harfbuzz.zig` (binding + Shaper) | port | presentation-aware run segmentation + `font-feature` parsing (#13); **HarfBuzz shaping wired** (#79): a hand-written HarfBuzz binding + `Shaper` turn a run into positioned glyphs — ligatures, contextual alternates, complex scripts, `font-feature` toggles — built from the HarfBuzz amalgam under `-Dharfbuzz` (requires `-Dfreetype`). The apprt segments each row into runs, shapes with the primary face, and draws shaped glyphs by index (`GlyphCache.getByIndex` + `Face.rasterizeIndex`), leaving cells the primary lacks (CJK/emoji) to the per-codepoint fallback path. Bidi/RTL + wide/emoji-aware run breaking deferred | done (host: run iterator, features; **`shape-proof`: real ligature substitution + feature toggles** against JetBrains Mono/Lilex); apprt shaped-render path on-device (#43) |
| Input (app-side) | `src/input.zig` | `src/input.zig` | port | Ctrl/Shift/Alt modifier encoding + nav/function keys (Home/End/PgUp/PgDn/Ins/Del/F1-F12) + cursor-key (DECCKM)/keypad/modify-other-keys options via `KeyEncodeOptions.fromTerminal` (#82). Alt+special keys are routed via WM_SYSKEYDOWN (except Alt+F4 → window close); modified Enter/Tab faithfully emit ghostty's fixterms `CSI 27;…~` form. The kitty-keyboard query (`CSI ? u`) is answered from the active screen's flags; kitty keyboard *output* + Alt-as-Meta (WM_SYSCHAR) deferred (kitty forced off to stay consistent with the WM_CHAR text path) | done (host) |
| Keybindings | `src/input/Binding.zig` | `src/input/Binding.zig` + apprt dispatch | port | chord/action grammar + Set + defaults + `keybind` config, and Win32 event→trigger→action dispatch (scroll + clipboard actions live; **window-state** `toggle_fullscreen`/`toggle_maximize`/`toggle_window_decorations` live, defaults `ctrl+shift+enter`/`ctrl+shift+m`/`ctrl+shift+b` (#91); **split/tab live** (#87): `ctrl+shift+arrow`=new_split, `alt+arrow`=goto_split, `ctrl+shift+w`=close_surface, `ctrl+shift+t`=new_tab, `ctrl+pageup`/`pagedown`=prev/next tab; **app-lifecycle live** (#92): `ctrl+shift+q`=quit, with `close_window`/`goto_window`/`present_terminal`/`toggle_window_float_on_top`/`toggle_visibility` config-available) (#18/#16/#91/#87/#92) | done (host); dispatch link-checked, window-state + split/close on-device verified |
| Config | `src/config/Config.zig`, `src/cli/args.zig` (LineIterator) | `src/config.zig` | port | file format + options: colors/font/cursor/palette/renderer/font-feature/keybind/cursor+selection colors/cursor-text/cursor-opacity/bold-is-bright/scrollback-limit (#17/#69) | done (host) |
| Surface mgmt (tabs/splits) | `src/apprt/gtk/` (Split/Notebook) | `src/apprt/win32/SplitTree.zig` + `apprt/win32/App.zig` (`Pane`/`WinState`) | template | split tree (split/close/resize/equalize/layout/focus-nav/hit-test + `dividers`/`anyLeaf`) + tab list model (#18); **wired into the apprt (#87)**: each pane is an independent terminal (own ConPTY+VT+reader thread+`Surface`, heap-stable), instantiated from the tree; `new_split`/`goto_split`(directional, `focusTarget`)/`close_surface`(sibling collapses; last pane closes the window)/`new_tab`/`next_tab`/`previous_tab`/`goto_tab` dispatched via `performAction`; render composites every pane (per-pane bg/cursor/scrollbar) + split dividers + a tab strip in one GL pass; mouse routed to the pane under the cursor (focus on click, drag owned per-pane), tab-strip click switches tabs; only the focused pane shows a solid cursor (others hollow). IME (#88) and split-resize/equalize keybinds are follow-ups | fresh (host: tree incl. dividers/anyLeaf); on-device verified (split → 3 panes, close → collapse) |
| GL context | `src/renderer/opengl/` (context) | `src/apprt/win32/Window.zig` (WGL) | template | 3.3-core context via `wglCreateContextAttribsARB` + sentinel-guarded loader; verified headless via `offscreen-proof` (#46) | host (EGL/Mesa proof) |
| Clipboard | `src/apprt/gtk/Surface.zig` (clipboard); `src/input/paste.zig` | `src/os/windows.zig` (CF_UNICODETEXT) + `vt.input.encodePaste` | template + dependency | copy/paste; bracketed-paste + unsafe-strip delegated to libghostty-vt (#50); OSC 52 write (base64-decode → clipboard, queued to the UI thread), OSC 52 read denied for privacy (#85) | done (host: UTF-16↔8, OSC 52 decode/deny) |
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
  (Direct3D 11, multi-surface runtime, scrollbar drawing — see the rows above and
  #43; HarfBuzz shaping is now built from source and verified via `shape-proof`,
  #79), and the **full `config/` system** (#49):
  the Config row ports the file format + options, but ghostty's `config/`
  (formatter, conditional, theme, ~14.5K LOC) and themes are not yet ported.
  **Kitty graphics (#84) is blocked at the dependency layer**: the `ghostty-vt`
  module is built with `oniguruma=false`, which compiles out `vt.kitty.graphics`
  (no parser/image/storage), and there is no build option to flip it — see
  [ADR 0009](docs/adr/0009-kitty-graphics-dependency-constraint.md).
- **Tier 3 — ecosystem**: `cli/` full arg parsing/actions (#53), `terminfo/`
  (#54), `shell-integration/` (#55), `inspector/` (#56), `crash/` (#57), and
  packaging/installer/auto-update (#58, shares signing with the host-gate).

Permanently out of scope (tooling, not the GUI terminal, so excluded from the
completeness invariant): `benchmark/`, `synthetic/`, `build/`, the alternate
`main_*.zig` targets (wasm/bench/c/gen), and the macOS/GTK-specific apprt layers.
