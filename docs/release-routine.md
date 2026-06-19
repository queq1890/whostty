# ghostty Release Routine

The **Release Routine** is a scheduled [Claude Routine](https://code.claude.com/docs)
(a cloud agent) that watches ghostty upstream releases and opens a porting
checklist when a new major/minor release lands. It keeps whostty's faithful port
honest without anyone having to babysit the ghostty changelog.

This file is the **canonical spec and prompt** for that Routine. The Routine
itself is configured in the Claude UI (cadence + this prompt); the repo holds the
source of truth so the behavior is reviewable and versioned alongside
[PORTING.md](../PORTING.md) and [ADR 0002](adr/0002-hybrid-architecture.md).

## Why a Routine, not CI

Per ADR 0002, whostty mirrors ghostty's structure but depends on libghostty-vt
for the VT core. Upstream tracking is therefore a *judgement* task (which changed
files fall under our mirrored paths, and what they imply for the port), not a
mechanical build gate. A Routine reads the diff and writes a smart issue; it does
**not** poll CI or modify the repo. See CONTEXT.md ("Release Routine").

## Spec

| Aspect | Behavior |
|--------|----------|
| **Cadence** | Weekly. |
| **Trigger** | ghostty's latest GitHub release. Act only on a new **major or minor** tag; ignore patch releases (e.g. `v1.3.1` → `v1.3.2` is skipped; `v1.3.x` → `v1.4.0` or `v2.0.0` fires). |
| **State** | Derived, no repo writes for bookkeeping. The "last handled" tag is the newest tag named in an existing issue labeled `ghostty-release`. If none exists, the pinned tag in `build.zig.zon` is the baseline. |
| **Scope** | Only files under the **mirrored paths** defined in PORTING.md. The VT core (`src/terminal/`, `src/input/` encode) is excluded — it's delegated to libghostty-vt. |
| **Output** | One GitHub issue labeled `ghostty-release` with a porting checklist (below). |
| **Idempotency** | If an open `ghostty-release` issue already names the target tag, do nothing. |
| **Side effects** | Read-only against the repo except for creating the one issue. Never push commits, never bump the pin itself — the bump is a checklist item for a human/port PR. |

## Mirrored paths (the watch set)

Read these from PORTING.md's **Map** table at run time (don't hard-code — the map
grows). As of this writing the watched ghostty paths include:

- `src/main.zig`
- `src/Surface.zig`
- `src/apprt.zig`
- `src/config/`, `src/cli/args.zig` (config file format)
- `src/renderer/OpenGL.zig`
- `src/font/Atlas.zig`, `src/font/main.zig`
- `src/input.zig`

Explicitly **excluded** (delegated or out of scope): `src/terminal/`,
`src/input/` (encode), plus the GTK/macOS apprt layers, `inspector/`, `crash/`,
`benchmark/`, `synthetic/`, `shell-integration/`, `terminfo/`.

The Windows-specific layers (`apprt/win32`, ConPTY `pty.zig`, WGL/OpenGL glue,
DirectWrite) have no 1:1 upstream counterpart; a relevant upstream change there
is noted as "review for behavioral parity," not a line-by-line re-port.

## Routine prompt

Paste the following as the Routine's instruction. It is deliberately
self-contained.

```
You are the whostty ghostty-release watcher. Run weekly. Be read-only against
the repository except for creating at most one issue. Do not push commits and do
not bump any pinned version yourself.

Repository: queq1890/whostty

Steps:
1. Find ghostty's latest GitHub release tag (ghostty-org/ghostty). Parse it as
   semver vMAJOR.MINOR.PATCH.
2. Determine the baseline tag:
   - Look at existing issues labeled `ghostty-release`. Take the newest ghostty
     tag mentioned in their titles/bodies as the baseline.
   - If there are none, use the `ghostty` dependency tag pinned in
     build.zig.zon (currently the value after `archive/refs/tags/`).
3. Decide whether to act:
   - If latest MAJOR.MINOR == baseline MAJOR.MINOR, this is only a patch bump —
     STOP, do nothing.
   - If an open `ghostty-release` issue already targets the latest tag — STOP.
4. Read PORTING.md from the default branch and extract the set of watched ghostty
   `src/` paths from the Map table (the "ghostty path" column for non-dependency
   rows). These are the mirrored paths.
5. Get the diff of ghostty between the baseline tag and the latest tag (GitHub
   compare API). Keep only changed files whose paths fall under a mirrored path.
6. Create ONE issue, labeled `ghostty-release`, titled:
       "[ghostty-release] port <baseline> -> <latest>"
   Body:
   - A one-line summary (release name/date, baseline -> latest).
   - "## Re-port checklist" — a markdown task list, one unchecked item per
     changed mirrored file, each linking to that file's diff in the ghostty
     compare view and naming the whostty counterpart from PORTING.md.
   - "## Windows-layer review" — any changed upstream paths that whostty mirrors
     only as a template (apprt, renderer glue), to eyeball for behavioral parity.
   - "## Pin bump" — an unchecked item: update the `ghostty` dependency tag and
     hash in build.zig.zon to <latest>, and update PORTING.md's "Pinned upstream"
     line.
   - If no mirrored files changed, still open the issue but say so and reduce it
     to just the pin-bump item (the VT core may have changed behind
     libghostty-vt; bumping keeps us current).
7. Do not modify any files. The checklist is for a follow-up port PR.
```

## Maintenance

- When a new layer is ported, add its row to PORTING.md — the Routine picks it up
  automatically because it reads the map at run time.
- The `ghostty-release` label must exist in the repo for filtering and labeling
  to work.
- After a port PR lands, the pin in `build.zig.zon` and the "Pinned upstream"
  line in PORTING.md should reflect the newly handled tag; that closes the loop
  for the next run's baseline.
