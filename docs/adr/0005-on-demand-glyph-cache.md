# On-Demand Glyph Cache: Rasterize Any Codepoint Lazily, Re-Upload the Atlas When It Grows

The bring-up renderer pre-rasterized printable ASCII (U+0020–U+007E) into a fixed
array at startup and uploaded the atlas once. Every other codepoint — accented
Latin, box-drawing, Powerline, symbols, CJK — drew blank, which makes most TUIs
(vim, tmux, htop) and any non-English text unusable. This replaces the fixed
array with an on-demand glyph cache.

## Decision

- **Rasterize lazily, cache by codepoint.** `font/GlyphCache.zig` maps `u21 →
  ?Atlas.Placement`. The first time a codepoint is drawn it is rasterized via
  Freetype, packed into the atlas, and cached; subsequent frames hit the cache.
  A cached **null** records "draw nothing" (a blank/space glyph, a codepoint the
  face lacks, or the atlas being full) so it is not retried every frame.
- **Re-upload the atlas only when it changes.** Packing a new glyph sets a
  `dirty` flag; the render loop calls `takeDirty()` and re-uploads the atlas
  texture (`Renderer.setAtlas`) before drawing, so a glyph is visible the same
  frame it is first seen. In steady state (all visible glyphs cached) there is no
  re-upload.
- **Draw nothing for codepoints the face lacks**, not the `.notdef` box (via
  `Face.glyphIndex`). This matches ghostty's behavior before per-codepoint
  fallback and avoids a screen full of tofu for, e.g., CJK in a Latin face.
- **Keep the non-freetype build glyph-free** behind a comptime `ft` flag, the
  same way the bring-up build already gated the font import. The glyph cache type
  is `void` there and every lookup site is comptime-eliminated.

## Considered Options

- **On-demand cache + dirty re-upload (chosen)** — any codepoint the face has
  renders, with a one-time rasterize cost per glyph. Cost: per-glyph dirty
  tracking + a full-atlas re-upload when new glyphs appear, and an atlas that can
  eventually fill (handled today by caching null / drawing blank; growth or
  eviction is follow-up).
- **Pre-build a larger fixed set** (ASCII + Latin-1 + a curated box/symbol
  range) — no per-frame machinery, but the boundary is arbitrary, still blanks
  anything outside it, and wastes atlas space + startup time on glyphs that may
  never be drawn. Rejected: re-opens the "which codepoints?" question the
  on-demand cache answers structurally.
- **Per-frame full re-upload (no dirty flag)** — simpler, but re-uploads a
  256 KB texture every frame even when nothing changed. Rejected as needless hot-
  path cost; `takeDirty` makes uploads proportional to *new* glyphs.

## Consequences

- ASCII now rasterizes lazily instead of at startup; the rendered result is
  identical, just deferred to first sight.
- The atlas is fixed at 512×512 (a few hundred glyphs). When it fills, further
  new glyphs draw blank (cached null). **Atlas growth / eviction is deferred** —
  tracked with the font epic (#66) and the fallback work (#75). A heavy-Unicode
  session can therefore lose late glyphs until then.
- Glyphs are rasterized inside `buildQuads` under the termio lock (the UI thread,
  where rendering already happens). New glyphs are rare (first sight only), so the
  brief lock hold is acceptable; if it ever shows up, move rasterization out of
  the lock.
- This cache is the foundation for per-codepoint fallback to other faces (#75),
  bold/italic faces (#77), the sprite renderer (#76), and decoration sprites
  (#80). It builds on [0002](0002-hybrid-architecture.md) (Freetype lives in the
  Windows font layer, with no upstream line-by-line counterpart) and reuses the
  atlas + GL upload path from the renderer.
