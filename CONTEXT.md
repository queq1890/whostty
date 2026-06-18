# whostty

A native Windows terminal emulator that carries on ghostty's philosophy. It
faithfully mirrors ghostty's `src/` layout, but does **not** reimplement the VT
core — it depends on **libghostty-vt** instead (a "hybrid" structure).
Implementation proceeds via Claude Code dynamic workflows + adversarial review,
porting files one at a time.

## Language

**whostty**:
This project. A Windows terminal emulator that uses ghostty as its reference. A
separate repository, but it mirrors ghostty's `src/` structure faithfully.
_Avoid_: ghostty-windows (refers to an existing, different port — do not conflate)

**ghostty**:
The upstream terminal emulator (written in Zig) used as the reference. The
"canon" for whostty's structure and behavior.
_Avoid_: upstream (ambiguous — may also mean libghostty-vt's upstream; say "ghostty" for the app itself)

**libghostty-vt**:
A zero-dependency Zig/C library, extracted from ghostty's core, that parses VT
sequences and maintains terminal state. whostty depends on it rather than
reimplementing the VT core.
_Avoid_: ghostty-vt (correct as the Zig module name, but this doc standardizes on libghostty-vt)

**apprt**:
Application runtime — the platform-specific layer for window creation, input,
and OS integration. In ghostty: `apprt/gtk` (Linux), `apprt/embedded` (macOS),
etc. whostty has `apprt/win32`.
_Avoid_: backend, platform layer

**ConPTY**:
The native Windows pseudo console (`CreatePseudoConsole`), used by whostty's PTY
layer. WSL is not used.
_Avoid_: PTY (the generic concept; say ConPTY for the Windows implementation)

**faithful port**:
The policy of mapping each ghostty file to a whostty file 1:1, copying
structure, naming, and behavior. Reimplemented layers (e.g. `apprt/win32`) are
generated using ghostty's corresponding layer (`apprt/gtk`) as a reference.
_Avoid_: rewrite, port-to-another-language (implies a language change; whostty stays Zig)

**mirrored path**:
A path under ghostty's `src/` for which whostty holds a faithfully-ported
counterpart. Excludes the VT core (delegated to libghostty-vt). Serves as the
criterion for "what must be re-ported" when tracking upstream.

**Release Routine**:
A Claude Routine (scheduled cloud agent) that watches ghostty major/minor
releases weekly, reads the diff under mirrored paths, and opens an issue with a
porting checklist. It derives the last-handled tag from existing
`ghostty-release`-labeled issues and does not write to the repo.
_Avoid_: cron, GitHub Actions (this project uses a Routine, not CI polling)

## Relationships

- **whostty** mirrors **ghostty**'s structure but depends on **libghostty-vt** and does not reimplement the VT core
- **whostty** has `apprt/win32`, which uses **ConPTY** internally
- A **faithful port** is the unit of work that generates a **whostty** file from its **ghostty** counterpart
- The **Release Routine** watches the diff under **mirrored paths** and opens porting-checklist issues

## Flagged ambiguities

- "Same philosophy as the Bun Rust port" initially looked like a **language (Rust)** decision, but was resolved as a metaphor for the **development method** (fast, faithful porting via dynamic workflows + adversarial review). The implementation language stays **Zig**.
- The tension between "mirror the directory structure completely" and "use libghostty-vt" was resolved with the **hybrid** approach (mirror structure; depend on the library only for the VT core).
