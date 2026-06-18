# whostty 👻🪟

A native Windows terminal emulator that carries on [ghostty](https://github.com/ghostty-org/ghostty)'s
philosophy. whostty faithfully mirrors ghostty's `src/` layout but does **not**
reimplement the VT core — it depends on
[libghostty-vt](https://github.com/ghostty-org/ghostty/pull/8840) instead.

> Status: **early bootstrap.** The first goal is a minimal end-to-end vertical
> slice (slice-0): a real Win32 window rendering an interactive shell via ConPTY.

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
zig build        # build
zig build run    # run (bootstrap: prints the libghostty-vt grid wiring check)
zig build test   # unit tests
```

## Upstream tracking

A scheduled Claude Routine watches ghostty major/minor releases weekly and opens
a porting-checklist issue describing what changed under the mirrored paths. See
[PORTING.md](PORTING.md) for the mirrored-path map.

## Acknowledgements

Built on the shoulders of [ghostty](https://github.com/ghostty-org/ghostty) by
Mitchell Hashimoto and contributors, and inspired by the early Windows porting
work explored by the community. Carries on the spirit of those efforts.

## License

[MIT](LICENSE). Ported portions retain ghostty's copyright notices; ghostty is
credited above for attribution.
