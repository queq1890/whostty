# Configuration

whostty reads a plain-text config file at startup from
`%APPDATA%\whostty\config`. The format is ported from ghostty: one
`key = value` per line, `#` comments, blank lines ignored, values optionally
wrapped in double quotes. Unknown keys and bad values are **non-fatal** — they're
collected as diagnostics and the rest of the file still loads.

```
# %APPDATA%\whostty\config
font-family = JetBrains Mono
font-size   = 13
background  = #1d1f21
foreground  = #c5c8c6
cursor-style = bar
```

See [PORTING.md](../PORTING.md) for how each option maps to a ghostty source and
which layer consumes it.

## Options

| Key | Value | Default | Notes |
|-----|-------|---------|-------|
| `font-family` | string | (system default) | Face selection lands with DirectWrite discovery (#14). |
| `font-size` | number (pt) | `12` | |
| `background` | color | `#000000` | |
| `foreground` | color | `#ffffff` | |
| `cursor-style` | `block` \| `bar` \| `underline` | `block` | |
| `cursor-color` | color | (foreground) | |
| `selection-background` | color | (derived) | |
| `selection-foreground` | color | (derived) | |
| `bold-is-bright` | bool | `false` | Render bold text with the bright palette colors. |
| `renderer` | `opengl` \| `direct3d` | `opengl` | `direct3d` is reserved (#15); falls back to OpenGL today. |
| `palette` | `<index>=<color>` | (VT defaults) | Repeatable; overrides one of the 256 palette entries. |
| `font-feature` | `<feature>` | (none) | Repeatable; see below. |
| `keybind` | `<trigger>=<action>` | (see defaults) | Repeatable; see below. |

### Colors

A color is `#RRGGBB` or `#RGB` (the `#` is optional), or one of the basic named
colors (`black`, `red`, `green`, `yellow`, `blue`, `magenta`, `cyan`, `white`).

### Booleans

`true`/`yes`/`1` and `false`/`no`/`0`. A bare key with no value (e.g.
`bold-is-bright`) means `true`.

### `font-feature`

OpenType feature toggles applied during shaping. A feature is a 4-character tag,
optionally signed or valued:

```
font-feature = -liga      # disable standard ligatures
font-feature = +calt      # enable contextual alternates
font-feature = ss01=2     # stylistic set 01, value 2
```

### `palette`

```
palette = 0=#1d1f21
palette = 1=red
```

## Keybindings

A `keybind` line is `trigger = action` where the trigger is `+`-joined modifiers
and one key:

```
keybind = ctrl+shift+right=new_split:right
keybind = ctrl+shift+t=new_tab
```

- **Modifiers**: `ctrl` (`control`), `shift`, `alt` (`opt`/`option`),
  `super` (`cmd`/`win`).
- **Keys**: a single printable character (letters fold case; hold `shift`
  separately), or a named key: `enter`/`return`, `tab`, `space`,
  `escape`/`esc`, `backspace`, `up`, `down`, `left`, `right`, `home`, `end`,
  `pageup`/`page_up`, `pagedown`/`page_down`.

User `keybind` lines override the defaults per trigger.

### Actions

| Action | Argument | Meaning |
|--------|----------|---------|
| `new_split` | `left`\|`right`\|`up`\|`down` | Split the focused pane. |
| `goto_split` | `left`\|`right`\|`up`\|`down` | Move focus to the adjacent pane. |
| `new_tab` | — | Open a new tab. |
| `close_surface` | — | Close the focused pane/tab. |
| `next_tab` / `previous_tab` | — | Cycle tabs. |
| `goto_tab` | number | Activate a tab by index. |
| `scroll_page_up` / `scroll_page_down` | — | Scroll one page through scrollback. |
| `scroll_to_top` / `scroll_to_bottom` | — | Jump to the ends of scrollback. |

### Default bindings

| Trigger | Action |
|---------|--------|
| `ctrl+shift+t` | `new_tab` |
| `ctrl+shift+w` | `close_surface` |
| `ctrl+pagedown` / `ctrl+pageup` | `next_tab` / `previous_tab` |
| `ctrl+shift+right`/`left`/`down`/`up` | `new_split:<dir>` |
| `alt+right`/`left`/`down`/`up` | `goto_split:<dir>` |
| `shift+pageup` / `shift+pagedown` | `scroll_page_up` / `scroll_page_down` |

> Note: the config parsing, keybinding grammar, split/tab models, and scrollback
> math are implemented and host-tested. Dispatching key events into these models,
> and the native font/render backends, land with a Windows build host — see the
> per-layer status in [PORTING.md](../PORTING.md).
