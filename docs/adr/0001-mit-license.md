# Adopt the MIT License

whostty is a faithful port of ghostty, which is MIT-licensed; ported files are
therefore derivative works bound by MIT's notice-retention terms. We adopt MIT
for the whole project to keep licensing frictionless, retain ghostty's copyright
notices in ported code, and credit ghostty for attribution in `NOTICE`/README.

## Considered Options

- **MIT (chosen)** — matches upstream, so no relicensing friction on ported code.
- **Apache-2.0 / other** — rejected: derivatives of MIT code must retain MIT
  notices anyway, so switching adds obligations without real benefit.

## Consequences

- ghostty copyright/license notices must be preserved in ported sources.
- ghostty must be credited (attribution) in `NOTICE` or the README.
- libghostty-vt (also ghostty-derived, MIT) stays license-compatible as a dependency.
