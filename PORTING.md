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

- ghostty tag: _(TBD — set when the dependency is pinned in `build.zig.zon`)_

## Map

| Layer | ghostty path | whostty path | Strategy | Status |
|-------|--------------|--------------|----------|--------|
| VT core | `src/terminal*` | — (delegated to libghostty-vt) | dependency | n/a |
| _(to be filled in as layers are ported)_ | | | | |

**Strategy** legend:

- `port` — faithful 1:1 port from the ghostty reference.
- `template` — no upstream counterpart (Windows-specific); ghostty's analogous
  layer is used only as a structural template (e.g. `apprt/gtk` → `apprt/win32`).
- `dependency` — provided by libghostty-vt, not ported.
