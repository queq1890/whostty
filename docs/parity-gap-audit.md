# Parity gap audit: ghostty v1.3.1 → whostty

> Snapshot audit, 2026-06-20. Produced by a multi-agent gap-analysis workflow
> (11 capability domains, analyze → adversarial verify → synthesize; 23 agents,
> **180 verified gaps → 50 consolidated**). This is a point-in-time companion to the
> mechanical completeness ledger in PORTING.md (#59) and the parity dashboard #47;
> see [ADR 0003](adr/0003-full-parity-completeness-ledger.md). When the source tree
> moves, trust PORTING.md + the issues over this snapshot.

## Method

Each domain was compared ghostty-source ↔ whostty-source by an analysis agent, then a
skeptic agent re-checked the whostty source to refute false positives ("whostty actually
has it"). Only confirmed/corrected, Windows-applicable, not-already-present gaps were kept.
macOS / GTK / Wayland / Metal-only capabilities were excluded as irrelevant to a Windows port.

## Summary

whostty is at roughly "slice-0": a single runnable Win32 terminal window with a ConPTY-backed VT grid, an OpenGL glyph renderer (ASCII-only, hard-coded Consolas), basic char-granular drag selection, and ~13 keybind actions, several of which are bound-but-no-op. Compared to ghostty v1.3.1 it is missing nearly every layer above "draw text and type into it": there is no visible cursor, no VT response write-back (DSR/DA/cursor-position), no dynamic title, no font discovery/fallback/styling/shaping/sprites, no multi-surface/tab/split/apprt action contract, no IME, no scrollback search/navigation, almost no config-key surface, and no shell-integration/terminfo/env injection. The existing open issues (#49 config, #50 clipboard, #51 selection, #52 mouse, #53 cli, #54 terminfo, #55 shell-integration, #56 inspector, #57 crash, #58 packaging) cover the "port these directories" work, but four large user-facing domains have NO tracking issue: (1) the renderer/appearance layer including the cursor, (2) the VT/OSC/escape write-back + protocol layer, (3) font discovery/fallback/styling/sprites/shaping, and (4) the apprt windowing/multi-surface contract + IME. The highest-leverage near-term gaps are the cursor (invisible today), VT response write-back (TUIs hang without it), font discovery + fallback (only ASCII/Consolas renders), IME (no CJK/dead-key input on a Windows terminal), and the apprt action contract (unblocks all windowing). Recommended new epics: "Renderer & cursor", "VT/OSC protocol write-back", "Font engine (discovery/fallback/shaping/sprites)", and "apprt windowing + multi-surface + IME"; everything else folds into the existing epics.

## Epics filed from this audit

Four large user-facing layers had **no tracking issue**; they were filed as new epics,
sequenced by daily-driver criticality (常用可能性順):

- **#65 (P1) Renderer & cursor** — the terminal cursor is not drawn today; + appearance, frame pacing, scrollbar
- **#66 (P2) Font engine** — discovery (DirectWrite) / fallback / styling / Harfbuzz shaping / sprites (only ASCII+Consolas today)
- **#67 (P3) VT/OSC protocol write-back** — DSR/DA responses (TUIs hang without them) + OSC wiring + kitty protocols
- **#68 (P4) apprt windowing + multi-surface + IME** — performAction contract, tabs/splits/new-window, IME (no CJK input today)
- **#94 Scrollback search** — standalone parity feature under #47 (fits no single epic)

Everything else folds into existing epics: #49 config, #50 clipboard, #51 selection,
#52 mouse, #53 cli, #54 terminfo, #55 shell-integration, #56 inspector, #57 crash, #58 packaging.

## Gaps mapped to the new epics (26)

| Sev | Status | Capability | Tracked under |
|-----|--------|------------|---------------|
| high | absent | Terminal cursor rendering (block/bar/underline) + blink + hollow-unfocused + cursor color/text/opacity | #65 |
| high | partial | System font discovery (DirectWrite) so configured/installed font-family actually resolves | #66 |
| high | absent | Codepoint fallback chain across multiple faces (CJK/symbols/rare scripts) | #66 |
| high | absent | Built-in sprite font: box-drawing/block/braille/geometric + Powerline/Nerd Font symbols | #66 |
| high | partial | Styled face selection + synthetic bold/italic + per-style font-family-bold/italic | #66 |
| high | absent | Color emoji / BGRA color glyph rendering | #66 |
| high | partial | Harfbuzz text shaping (ligatures, complex/RTL scripts, font-feature toggles) | #66 |
| high | absent | VT response write-back path (DSR / DA / cursor-position / mode queries / ENQ) | #67 |
| high | partial | Keyboard modifier encoding + kitty keyboard protocol output (answer CSI ?u) | #67 |
| high | absent | apprt performAction contract + multi-surface lifecycle (registry, create/destroy, quit-on-last-close) | #68 |
| high | partial | Tabs + splits + new-window wired to the apprt (new/close/goto/move/resize/equalize/zoom) | #68 |
| high | absent | IME / dead-key composition (WM_IME_*, candidate window at cursor) | #68 |
| high | absent | Scrollback search (start/search/navigate/end) + search appearance config | #94 |
| medium | absent | Background appearance: opacity/transparency, blur, image, minimum-contrast, bold-is-bright/bold-color, faint-opacity | #65 |
| medium | partial | Window padding + per-cell reverse-video selection + custom GLSL shaders | #65 |
| medium | absent | vsync / frame pacing + dirty-tracking (redraw only on change) | #65 |
| medium | partial | Visible scrollbar widget (render + drag + config) | #65 |
| medium | partial | Text decoration sprites: double/dotted/dashed/curly underline, strikethrough, overline | #66 |
| medium | partial | OSC 4/10/11/12 dynamic colors: render from terminal.colors and answer color queries | #67 |
| medium | absent | Kitty graphics protocol (inline image display) | #67 |
| medium | absent | OSC 52 / OSC 7 / OSC 8 / OSC 9-777-99 / OSC 9;4 / BEL / focus-reporting wiring (notifications, links, bell, progress, focus) | #67 |
| medium | absent | Window title from OSC 0/2 (and CSI 21t / title stack) applied to the live Win32 window | #68 |
| medium | absent | DPI / scale change handling (WM_DPICHANGED) to keep glyphs crisp across monitors | #68 |
| medium | absent | Window state actions: fullscreen/maximize/decorations toggle + dynamic title + close confirmation + live config reload | #68 |
| low | absent | App-lifecycle + extra windowing actions (quit/close_window/new_window/close_all/goto_window/present/quick-terminal/tab-overview/float/visibility) | #68 |
| low | absent | Single-instance / IPC (+new-window into a running process) | #68 |

## Gaps folded into existing epics (24)

These refine the scope of epics that already existed (their bodies were updated with the
concrete sub-scope below); they are not separate issues.

| Sev | Status | Capability | Tracked under |
|-----|--------|------------|---------------|
| high | absent | Themes: theme key, built-in catalog, light/dark OS-appearance, conditional config | #49 |
| high | partial | Command / working-directory / env config keys (config-level, not just CLI -e); COMSPEC/shell resolution | #49 |
| high | partial | Clipboard copy/paste wiring + unsafe-paste protection + OSC 52 write/read + clipboard policy keys | #50 |
| high | absent | Double/triple-click word/line selection + shift-extend + rectangular selection | #51 |
| high | partial | Mouse reporting: motion (button/any), encodings (UTF-8/urxvt/SGR-pixels), wheel-to-app, alternate-scroll, buttons 4-9 | #52 |
| high | partial | Keybind action coverage + chords/tables/flags/remap (font-size, fullscreen, reload, palette, etc.) | #53 |
| high | absent | +action CLI dispatch + validate-config + show-config + list-fonts (and --config-file) | #53 |
| high | absent | TERM/COLORTERM/TERM_PROGRAM env injection + bundled xterm-ghostty terminfo | #54 |
| high | absent | Automatic shell-integration injection (OSC 133 marks, OSC 7 cwd, cursor-shape, sudo/ssh helpers) + jump-to-prompt | #55 |
| medium | absent | Font rendering tuning + metric adjustment + codepoint-map config keys (adjust-*, font-thicken, freetype-load-flags, font-variation, grapheme-width-method) | #49 |
| medium | absent | Initial window geometry/state + position/size persistence config (size, position, decoration, maximize/fullscreen, title, save-state) | #49 |
| medium | absent | Shell-integration / bell / notification / scrollbar-link / lifecycle / terminal-protocol config keys | #49 |
| medium | partial | Config file discovery/includes/recursive loading + --config-file flag + +edit-config | #49 |
| medium | absent | Selection auto-scroll past viewport edge + scroll-to-selection | #51 |
| medium | absent | Link (URL/OSC8) hover detection, highlight, pointer shape, and click-to-open | #52 |
| medium | absent | Mouse pointer shape changes (I-beam/pointer/crosshair) + auto-hide while typing + cursor-click-to-move + right-click action + copy-on-select | #52 |
| medium | partial | Scroll-management keybinds: clear_screen/select_all + fractional/line/page scroll + scroll_to_row + scroll-to-bottom config | #53 |
| medium | absent | Windows-standard ctrl+insert / shift+insert copy/paste defaults (recognize Insert trigger) | #53 |
| low | absent | Palette generation/harmonization + selection word-chars/clear-on config | #49 |
| low | absent | Custom GLSL shaders + split/search appearance config keys | #49 |
| low | partial | Configurable scroll multiplier + precision/touchpad scrolling | #52 |
| low | absent | Raw input-injection actions (text/csi/esc/cursor_key) + action chains/named tables + power-user toggles (inspector/palette/quick-terminal/secure-input) | #53 |
| low | absent | write_screen/scrollback/selection_file dump actions | #53 |
| low | absent | Low-value +action subcommands (+list-keybinds/-actions/-colors, +show-face, +ssh-cache, +version detail, +help, +new-window, +crash-report, +boo) | #53 |

## Relationship to PORTING.md

PORTING.md is the *mechanical* ledger (row-per-path, #59); this audit is *capability-first*
(what a user can/can't do). They converge: every gap here resolves to one or more PORTING.md
rows. Where they disagree, PORTING.md and the linked issues are authoritative.
