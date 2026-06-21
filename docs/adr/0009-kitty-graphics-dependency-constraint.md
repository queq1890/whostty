# Kitty Graphics (#84) Is Blocked by the libghostty-vt Build Configuration

The VT/OSC write-back epic (#67) lists the **kitty graphics protocol** (#84) —
inline image display (`icat`, `timg`, image previews). whostty's architecture
([ADR 0002](0002-hybrid-architecture.md)) delegates the entire VT core to
libghostty-vt (the `ghostty-vt` Zig module), so the natural implementation is to
drive libghostty-vt's kitty graphics command parser, image store, and render
placements. **That code is compiled out of the module whostty depends on, and
there is no build option to turn it back on.**

## What we found

In ghostty v1.3.1, kitty graphics is gated on a build option:

```zig
// src/terminal/kitty.zig
pub const graphics = if (build_options.kitty_graphics)
    @import("kitty/graphics.zig")
else
    struct {};

// src/terminal/build_options.zig — kitty_graphics is synthesized, not free:
opts.addOption(bool, "kitty_graphics", self.oniguruma);
```

So `kitty_graphics == oniguruma`. And for the **Zig module** specifically
(`ghostty-vt`, what whostty imports — not the full ghostty app), oniguruma is
hard-disabled upstream:

```zig
// src/build/GhosttyZig.zig
// We presently don't allow Oniguruma in our Zig module at all.
// We should expose this as a build option in the future so we can
// conditionally do this.
vt_options.oniguruma = false;
```

This is not configurable from whostty's `build.zig`: whostty consumes the
prebuilt `ghostty.module("ghostty-vt")`, and the `oniguruma = false` is fixed
inside the dependency's own module construction, with a comment noting a future
build option is desired but absent in v1.3.1.

Confirmed empirically against whostty's actual build graph: `vt.kitty.graphics`
resolves to the empty `struct {}` — `@hasDecl(vt.kitty.graphics, "Command")`,
`"Image"`, and `"ImageStorage"` are all **false**. The parser, image decoder,
and image storage are simply not present.

## Decision

**Defer #84; do not vendor or reimplement the kitty graphics stack.** Two paths
exist and both are rejected for now:

- **Reimplement kitty graphics inside whostty** — port the APC command parser,
  base64 / PNG / RGB(A) decode, the image store keyed by id, placement geometry
  that follows scrollback, Unicode placeholder handling, and add an
  RGBA-texture quad path to the renderer (today it draws only alpha-coverage
  glyph quads and solid quads). Rejected: it duplicates a large subsystem that
  libghostty-vt *already has but compiles out*, and it is a deliberate
  divergence from "delegate the VT core to libghostty-vt" (ADR 0002) — the exact
  thing that architecture exists to avoid. It is also unverifiable from the WSL
  dev environment (no on-device image-render smoke test).
- **Patch the dependency to flip `oniguruma`/`kitty_graphics` on** — rejected: we
  do not fork pinned dependencies; the upstream comment says the build option is
  intended future work, so the supported fix is upstream exposing it.

The supported path forward is **upstream exposing `kitty_graphics` (or
`oniguruma`) as a `ghostty-vt` module option**, after which whostty drives the
existing parser/store/render-placement and adds only the texture-quad upload.
Until then #84 stays open and blocked, tracked with this constraint.

## Consequences

- #84 cannot be completed at the libghostty-vt version whostty pins; it is a
  documented dependency blocker, not an oversight. The rest of #67 (responses
  #81, dynamic colors #83, keyboard #82, side channels #85) is independent of
  this and proceeds.
- The same `oniguruma=false` also disables **tmux control mode** in the module;
  if that is ever scoped, it shares this blocker.
- When the upstream option lands, the renderer work (an RGBA / BGRA texture-quad
  path) is the only net-new piece on whostty's side — and it shares the 4-byte
  color-glyph atlas work already anticipated for color emoji (#78).
