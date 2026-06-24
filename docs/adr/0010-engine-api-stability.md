# Versioned Engine API with a Staged, Minimal-Export-First Stability Policy

whostty is the terminal engine [whomux](https://github.com/queq1890/whomux)
imports (`whomux : whostty :: cmux : libghostty`). The set of public Zig modules
whostty exports — the **engine boundary** — is a contract another repository
builds on, so it needs an explicit stability and versioning policy. This ADR
defines it.

The policy is **staged, minimal-export-first**: export the smallest surface that
unblocks the next downstream consumer, mark everything as `experimental` until it
has a real consumer, and only then promote it to `stable`. The boundary grows
issue-by-issue across epic E0 (#130–#140) rather than landing as one big "engine
SDK".

## Context

- The engine model was extracted into a platform-free layer in #129 and first
  exported as the `whostty-engine` module in #130. The remaining E0 issues
  (#132–#140) layer on the apprt-free Surface host vtable, the foundational
  Surface APIs, the unified cwd, the attention side channel, OSC 133 / OSC 8,
  terminfo, scrollback search and the config resolver.
- whostty is pre-1.0 and still being ported toward ghostty parity; its internals
  churn. whomux must be able to depend on a *named, predictable* slice of it
  without that churn breaking the downstream build on every commit.
- There is exactly one consumer (whomux), both repos share an owner, and they
  are pinned by commit/tag — so the policy optimizes for *clarity and cheap
  evolution*, not for a frozen public API serving unknown third parties.

## Decision

### 1. The engine boundary is the only supported import surface

Downstream may import **only** modules whostty registers in its build graph
(`b.addModule` / re-exports), currently:

| module / API | stability | since |
|---|---|---|
| `whostty-engine` | stable | #130 |
| `ghostty-vt` (re-export) | stable (tracks the pinned ghostty tag) | #130 |
| `whostty-engine`'s `host` (the apprt-free `Host` vtable) | experimental | #132 |

Anything reached by deep-importing whostty source paths that are not part of an
exported module is unsupported and may break without notice. New exported
modules and the host-vtable contract are added by #132–#140 and listed here as
they land.

### 2. Stability tiers

Each exported declaration is one of:

- **stable** — shape is settled; breaking changes require a minor version bump
  and a CHANGELOG/PORTING note. This is what whomux pins against.
- **experimental** — exported so a downstream issue can integrate against it, but
  the shape may still change. Marked in the doc comment with
  `Stability: experimental`. Promoted to stable once a real consumer has driven
  the shape.

A declaration enters as `experimental` the moment it is exported and is promoted
only after a whomux issue consumes it, so "stable" always means "proven by use".

### 3. Versioning

- The engine boundary is versioned by whostty's release tags (`v0.0.x` today).
  whomux pins whostty by commit or tag in its `build.zig.zon`; bumping the pin is
  a deliberate, reviewable step.
- Within the `0.x` series, **minor** bumps may break the boundary (each is called
  out in the release notes / PORTING.md); **patch** bumps never do.
- The single re-exported transitive dependency that crosses the boundary is
  `ghostty-vt`; whomux consumes whostty's pin rather than pinning ghostty
  itself, so the VT core version is whatever whostty's `build.zig.zon` pins.

### 4. The boundary is engine-only; the host stays downstream

The export surface never includes window/apprt/event-loop/clipboard/GL-context
code. Those are supplied by the host (whomux) through the apprt-free host vtable
(#132). This keeps the same cut line as ADR
[0002](0002-hybrid-architecture.md) / whomux ADR 0002: whostty draws a terminal,
the host owns the app shell.

## Considered Options

- **Staged minimal-export-first (chosen)** — export the smallest unblocking
  surface, grow it per E0 issue, promote experimental→stable on real use. Matches
  how the two repos are actually built out and keeps churn visible.
- **Big-bang engine SDK** — design and freeze the full Surface/renderer/pty/font/
  VT/config API up front, then build whomux against it. Rejected: the API shape
  isn't known until whomux drives it; freezing early guarantees rework and a
  large speculative surface.
- **No boundary; whomux deep-imports whostty source** — cheapest now, but every
  whostty refactor breaks whomux and there is no contract to reason about.
  Rejected.

## Consequences

- This table (§1) is the source of truth for what whomux may import; every E0
  export issue updates it and the README "Engine module exports" section.
- whomux integration issues may consume `experimental` exports, accepting that
  the shape can shift until promotion; the pin makes each shift a deliberate bump.
- Breaking the boundary is allowed pre-1.0 but must be a minor bump with a
  PORTING.md note, so a pin update never silently breaks the downstream build.
