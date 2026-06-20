# Cursor as Appended Quads in the Single-Pass Renderer; Per-Quad Alpha for Translucency

whostty's OpenGL backend is a single textured-quad pass over a flat `[]Quad`
list: glyph quads sample the R8 coverage atlas, solid quads fill with their
color. Issue #69 (terminal cursor rendering) needs the cursor — block / bar /
underline / hollow — plus `cursor-opacity`. ghostty draws the cursor through a
dedicated path (cursor sprites and a richer cell program with a full compositing
model); whostty has no such machinery yet, and a single surface does not justify
one.

## Decision

- **Draw the cursor as ordinary quads appended last.** The cursor shape is one
  or more `SolidRect` quads; a *block* additionally re-appends the glyph beneath
  it in the cursor-text color. They are appended at the end of the per-frame
  quad list, so the renderer's existing slice-order layering paints them on top.
  No separate shader, program, or sprite sheet.
- **Add a per-quad alpha vertex attribute** (location 4; `Vertex.a`, defaulting
  to 1.0) so a translucent cursor — and the later dim/`background-opacity` work
  (#70) — blends over whatever is already drawn. The fragment shader multiplies
  the resolved coverage/solid value by `v_alpha`.
- **Resolve cursor visibility/style in a backend-agnostic `renderer/cursor.zig`**
  that faithfully ports ghostty's `renderer/cursor.zig` `style()` priority order,
  taking the terminal state as flattened inputs (whostty has no `RenderState`):
  in-viewport → preedit → DECTCEM (mode 25) → focus (hollow) → blink phase
  (mode 12) → the terminal's requested style.

## Considered Options

- **Per-quad alpha attribute (chosen)** — one extra float per vertex. Generalizes
  to faint/dim text and `background-opacity` (#70). Cost: the `Vertex` layout
  change touches the hot path and the `offscreen-proof` harness's hand-written
  attribute setup, which must bind the new attribute or it reads alpha 0.
- **CPU pre-blend the cursor color against the cell background** — no GL change,
  but wrong whenever the cursor overlaps a glyph or a non-default background, and
  it cannot express "see the glyph through a translucent block". Rejected as a
  band-aid that the appearance epic (#70) would have to tear out.
- **A separate cursor render pass / program** (closest to ghostty) — more
  faithful, but a second program + GL state + draw call to fill a single rect.
  Premature for a single-surface bring-up; deferred until a richer compositor or
  the native D3D backend (#15) is warranted.

## Consequences

- Default alpha is 1.0, so the attribute is inert for existing glyph/solid quads:
  the render proof is unchanged at 719 lit pixels.
- `offscreen-proof` must bind vertex attribute 4 (a *disabled* attribute reads a
  constant 0 → fully transparent → nothing draws). The proof now also rasterizes
  a block cursor (exactly 256 red pixels for a 16×16 cell) as a regression guard,
  since on-device launch is WDAC-blocked.
- The cursor is read under the termio mutex in `buildQuads` (the reader thread
  mutates `screen.cursor` concurrently). Position is mapped from the cursor's
  active-area pin to the viewport via `PageList.pointFromPin(.viewport, …)`, with
  an explicit `x < cols and y < rows` bound so a cursor scrolled below the
  viewport is not drawn off-grid.
- Cursor colors default to the cell beneath it (fill = cell foreground, block
  text = cell background → an inverted cell), overridable by `cursor-color` /
  `cursor-text` / `cursor-opacity`.
- This single-pass + per-quad-alpha model is the contract a future native D3D
  backend (#15) or compositor must preserve or deliberately supersede. See
  [0002](0002-hybrid-architecture.md) for why the VT-owned cursor state is read
  from libghostty-vt rather than reimplemented.
