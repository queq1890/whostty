# Dynamic Colors: Make `terminal.colors` the Source of Truth, Seeded From Config

The renderer resolved foreground / background / palette from a `Theme` struct
built once from config at startup. So OSC 4/10/11/12 — the escape sequences a
program uses to change colors at runtime (themes, light/dark switching, palette
remaps) — had no visible effect, and color queries (`OSC 11 ; ?`, used by apps
to detect the terminal's background) went unanswered, so tools fell back to
wrong light/dark assumptions. This makes libghostty-vt's `terminal.colors` the
authoritative color state (#83).

## Decision

- **`terminal.colors` is the single source of truth for default fg/bg/palette.**
  libghostty-vt already records OSC color changes there (the readonly handler
  applies `color_operation` set/reset). The renderer now reads from it —
  `terminal.colors.foreground.get() orelse theme.fg`, `…background…`, and
  `terminal.colors.palette.current` — so a runtime change renders the next
  frame. The framebuffer clear color (what default-background cells show
  through) tracks `terminal.colors.background` via `Termio.backgroundColor`.
- **Seed it from config at startup.** `Termio.seedColors(fg, bg, palette)` primes
  each `DynamicRGB.default` (and the palette) from the configured `Theme` before
  the reader thread starts. `DynamicRGB.get()` returns `override orelse default`,
  so before any OSC change a query/read yields the configured color, and after
  an OSC change it yields the override — no separate "is it set?" plumbing, and
  the config palette overrides survive (they are the seeded defaults).
- **Answer color queries from that same state.** The `ResponseHandler`
  (ADR 0006) gains a `color_operation` arm: it delegates the whole operation to
  the readonly handler first (applying any set/reset), then replies to each `?`
  query with the resulting color in the 16-bit `rgb:RRRR/GGGG/BBBB` form
  (ghostty's default `osc-color-report-format`), echoing the request's ST/BEL
  terminator. Replies ride the existing response queue back to the pty.

## Considered Options

- **`terminal.colors` authoritative, seeded from config (chosen)** — one owner
  for color state, read by both the renderer and the query handler; OSC changes
  and queries are automatically consistent. Cost: a seeding step at startup and
  a per-frame `terminal.colors` read under the existing grid lock.
- **Keep `Theme` authoritative; layer OSC changes on top** — would mean the
  renderer consults two sources (config Theme + an OSC override map) and the
  query handler a third. Rejected: duplicated color state drifts, and it
  re-implements what libghostty-vt's `terminal.colors` already tracks.
- **Pass config colors into the query handler for fallback** — answers queries
  without seeding, but the renderer still wouldn't see OSC changes, and the
  handler would need its own copy of the config palette. Rejected: seeding
  `terminal.colors` solves both the render and the query path at once.

## Consequences

- OSC 10/11 (fg/bg), OSC 4 (palette), and OSC 12 (cursor) all take visible
  effect, and OSC 10/11/12/4 queries are answered from the same state. The
  cursor color follows the identical seed-then-override model: the configured
  cursor color seeds `terminal.colors.cursor.default`, OSC 12 sets the override,
  and both `buildQuads` and the query reply read `terminal.colors.cursor.get()`,
  so a queried cursor color is always the one the cursor shows. The renderer's
  selection colors stay config-driven (not OSC-settable in scope).
- Set-then-query of the *same* target in one OSC reports the new value (matching
  ghostty); only a nonsensical query-*before*-set of the same target in one
  sequence would differ, because sets are applied before queries are reported.
- This reuses the response queue and handler from [0006](0006-vt-response-write-back.md)
  and is the color foundation the rest of #67 builds on (OSC 8 / 52 / notifications
  in #85 route their replies through the same queue).
