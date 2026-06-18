# Hybrid Architecture: Mirror ghostty's Structure, Depend on libghostty-vt for the VT Core

whostty mirrors ghostty's `src/` layout (apprt, renderer, font, config, etc.)
file-for-file, but does **not** reimplement the VT core: it depends on
libghostty-vt instead. This keeps the project recognizably ghostty-shaped — so
upstream changes can be re-ported 1:1 — while avoiding a fork of the large,
fast-moving terminal core that the upstream team has already extracted into a
zero-dependency library.

## Considered Options

- **Hybrid (chosen)** — own repo mirroring ghostty's layout; libghostty-vt as a
  pinned dependency for the VT core. Honors both "mirror the structure" and "use
  libghostty-vt"; the pinned ghostty tag becomes the unit for upstream tracking.
- **Fork ghostty** — vendor the whole repo (including `src/terminal/`) and add
  `apprt/win32`. Rejected: carries the entire VT core as maintenance surface and
  fights the upstream direction of consuming libghostty-vt as a library.
- **Independent consumer app (phantty-style)** — own structure, libghostty-vt as
  a library. Rejected: abandons the "mirror ghostty's structure" goal that makes
  faithful 1:1 re-porting possible.

## Consequences

- whostty has no `src/terminal*`; that VT surface lives behind libghostty-vt.
- Windows-specific layers (`apprt/win32`, ConPTY, WGL/OpenGL, font) have no
  upstream counterpart to port line-by-line and are written fresh, using
  ghostty's `apprt/gtk` etc. as a structural template.
- "Mirrored paths" (everything except the VT core) define what the Release
  Routine watches for re-porting. See [0001](0001-mit-license.md) for licensing.
