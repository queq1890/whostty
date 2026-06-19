# whostty 👻🪟

A native Windows terminal emulator that carries on [ghostty](https://github.com/ghostty-org/ghostty)'s
philosophy. whostty faithfully mirrors ghostty's `src/` layout but does **not**
reimplement the VT core — it depends on
[libghostty-vt](https://github.com/ghostty-org/ghostty/pull/8840) instead.

> Status: **slice-0 wired.** The end-to-end vertical slice is implemented — a
> Win32 window + WGL/OpenGL renderer, a ConPTY-backed shell, a reader thread
> feeding libghostty-vt, keyboard input, and resize. It cross-compiles and links
> for `x86_64-windows`. Running it on screen (and the Freetype glyph atlas via
> `-Dfreetype`) requires a Windows host with a GPU/display.

## Architecture

- **Hybrid**: own repository that mirrors ghostty's structure (apprt, renderer,
  font, config, …) but pulls in libghostty-vt as a pinned dependency for the VT
  core. See [ADR 0002](docs/adr/0002-hybrid-architecture.md).
- **Language**: Zig (same as ghostty; direct module import, no C FFI).
- **Windows-native**: Win32 `apprt/win32`, ConPTY (no WSL), WGL + OpenGL
  rendering first (Direct3D later), Freetype glyphs first (DirectWrite later).

See [CONTEXT.md](CONTEXT.md) for the project glossary and [docs/adr/](docs/adr/)
for architecture decisions.

## Building

Requires **Zig 0.15.2** (pinned in `.zigversion` and `build.zig.zon`'s
`minimum_zig_version`, matching the ghostty `v1.3.1` dependency).

```sh
zig build                          # build (host)
zig build test                     # host unit tests (termio, input, atlas, sizing, …)
zig build -Dtarget=x86_64-windows  # the real target: Win32 terminal
zig build -Dfreetype               # also build the Freetype glyph rasterizer
```

On a non-Windows host the binary runs a libghostty-vt wiring demo; the actual
terminal (`apprt/win32`) is produced by the Windows target. `-Dfreetype` fetches
freetype source, so it needs network access.

## Configuration

whostty reads `%APPDATA%\whostty\config` (ghostty's `key = value` format). All
options — colors, fonts, font features, the renderer backend, and keybindings —
are documented in [docs/configuration.md](docs/configuration.md).

## Upstream tracking

A scheduled Claude Routine watches ghostty major/minor releases weekly and opens
a porting-checklist issue describing what changed under the mirrored paths. The
routine's spec and operating prompt live in
[docs/release-routine.md](docs/release-routine.md); see
[PORTING.md](PORTING.md) for the mirrored-path map it reads.

## Acknowledgements

Built on the shoulders of [ghostty](https://github.com/ghostty-org/ghostty) by
Mitchell Hashimoto and contributors, and inspired by the early Windows porting
work explored by the community. Carries on the spirit of those efforts.

## License

[MIT](LICENSE). Ported portions retain ghostty's copyright notices; ghostty is
credited above for attribution.
