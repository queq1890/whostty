# whostty 👻🪟

A native Windows terminal emulator that carries on [ghostty](https://github.com/ghostty-org/ghostty)'s
philosophy. whostty faithfully mirrors ghostty's `src/` layout but does **not**
reimplement the VT core — it depends on
[libghostty-vt](https://github.com/ghostty-org/ghostty/pull/8840) instead.

> Status: **usable terminal.** On top of slice-0 (Win32 window + WGL/OpenGL
> renderer, ConPTY shell, libghostty-vt, keyboard, resize) the daily-driver
> basics are in: a real **GL 3.3 core context** (so glyphs actually rasterize —
> proven headlessly, see *Verifying the renderer*), **clipboard** copy/paste,
> mouse-drag **text selection** with highlight, and **mouse reporting** (SGR/X10)
> for TUIs. It cross-compiles and links for `x86_64-windows` and passes host unit
> tests. Running the GUI needs a Windows host where the build can launch (an
> enforced WDAC/Device-Guard policy blocks unsigned exes — see issue #48).

## Architecture

- **Hybrid**: own repository that mirrors ghostty's structure (apprt, renderer,
  font, config, …) but pulls in libghostty-vt as a pinned dependency for the VT
  core. See [ADR 0002](docs/adr/0002-hybrid-architecture.md).
- **Language**: Zig (same as ghostty; direct module import, no C FFI).
- **Windows-native**: Win32 `apprt/win32`, ConPTY (no WSL), WGL + OpenGL
  rendering first (Direct3D later), Freetype glyphs first (DirectWrite later).
- **Importable engine boundary** (epic E0): the platform-free engine layer is
  published as a Zig module so [whomux](https://github.com/queq1890/whomux) can
  pin whostty and drive the terminal from its own Win32 host. The export surface
  and its stability policy are defined in
  [ADR 0010](docs/adr/0010-engine-api-stability.md).

### Engine module exports

A downstream package pins whostty in its `build.zig.zon` and imports:

| module | what it is |
|---|---|
| `whostty-engine` | the platform-free engine model (#129/#130): `grid` (cell/layout geometry), `split` (`SplitTree`/`TabList`), `mouse` (VT mouse-report encoding), `scroll`, `frame`, and `host` (the apprt-free `Host` vtable, #132) — zero Win32 / ConPTY / WGL dependency. |
| `ghostty-vt` | the pinned libghostty-vt VT core, re-exported so the consumer shares whostty's single pin (no second, drifting ghostty-vt dependency). |

```zig
// downstream build.zig
const whostty = b.dependency("whostty", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("whostty-engine", whostty.module("whostty-engine"));
exe.root_module.addImport("ghostty-vt", whostty.module("ghostty-vt"));
```

Per the staged minimal-export-first policy
([ADR 0010](docs/adr/0010-engine-api-stability.md)) the engine model is the first
stable export; the apprt-free Surface host vtable, foundational Surface APIs,
unified cwd, the attention side channel, OSC 133 / OSC 8, terminfo and the config
resolver are layered onto the boundary by the remaining E0 issues.

See [CONTEXT.md](CONTEXT.md) for the project glossary and [docs/adr/](docs/adr/)
for architecture decisions.

## Building

Requires **Zig 0.15.2** (pinned in `.zigversion` and `build.zig.zon`'s
`minimum_zig_version`, matching the ghostty `v1.3.1` dependency).

```sh
zig build                          # build (host)
zig build test                     # host unit tests (termio, input, atlas, mouse, …)
zig build -Dtarget=x86_64-windows  # the real target: Win32 terminal
zig build -Dfreetype               # also build the Freetype glyph rasterizer
```

On a non-Windows host the binary runs a libghostty-vt wiring demo; the actual
terminal (`apprt/win32`) is produced by the Windows target. `-Dfreetype` fetches
freetype source, so it needs network access.

### Running from the command line

The build produces `zig-out\bin\whostty.exe`. To launch it by name like
`ghostty`, put it on your `PATH` (copy it into a directory already on `PATH`,
e.g. `%LOCALAPPDATA%\Microsoft\WindowsApps`, or add its folder via
`setx PATH "%PATH%;C:\path\to\whostty"`). Then:

```sh
whostty                       # open the terminal (default shell: cmd.exe)
whostty -e pwsh -NoLogo       # run a specific program instead of the shell
whostty --font-size=16 --background=#101010   # config options as flags
whostty --help                # usage; --version for the version
```

`--<key>=<value>` (or `--<key> <value>`) accepts any config-file key and is
applied on top of `%APPDATA%\whostty\config`. Full `+action` subcommands
(`+list-fonts`, …) are a follow-up.

### Interaction

`Ctrl+Shift+C` / `Ctrl+Shift+V` copy/paste; left-drag selects text (`Shift`
forces local selection even when an app has mouse reporting on); `Shift+PageUp` /
`Shift+PageDown` and the mouse wheel scroll the scrollback. Keybindings are
configurable (see *Configuration*).

### Verifying the renderer

The Win32 GUI can't be screenshotted under some lockdown policies, so two checks
stand in for an on-screen look:

```sh
zig build offscreen-proof -Dfreetype   # headless: runs the REAL shaders + atlas +
                                        # Freetype path on an EGL/Mesa GL 3.3 core
                                        # context and asserts glyphs reach pixels
```

When running the Windows build, set `WHOSTTY_RENDER_DEBUG=1` to print a lit-pixel
count a few frames in (`lit_pixels > 0` ⇒ the GPU is drawing glyphs).

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
