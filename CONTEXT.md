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

**parity (the goal)**:
"Operate this repo like ghostty" resolves to **full feature parity** with
ghostty: every ghostty `src/` path not delegated to libghostty-vt is eventually
ported. Nothing under `src/` is permanently out of scope — items previously
called "excluded" are merely **deferred**. This is the north star, not a
near-term milestone; work is sequenced by daily-driver criticality (host-gate →
usable-terminal wiring → quality/native backends → ecosystem).
_Avoid_: "operations posture only", "MVP" (both were rejected framings)

**completeness ledger**:
PORTING.md's role under the parity goal: the single source of truth for "what
must exist." Completeness is mechanically checkable —
`ghostty v1.3.1 src/ tree − (delegated ∪ ledger rows) = unfiled gap`. An item is
"filed" only when it is a not-done ledger row **with a linked issue**.

**host-gate**:
The single root dependency blocking all on-device work (render proof, on-device
verification, and the native D3D11 / DirectWrite / Harfbuzz backends): the lack
of a reliable Windows dev host where a freshly-built **unsigned** exe can launch
(Device Guard / WDAC blocks it). Code-signing resolves it and is reused as
distribution signing.
_Avoid_: treating render-proof, native backends, and signing as separate
unrelated blockers — they share this one dependency.

## Relationships

- **whostty** mirrors **ghostty**'s structure but depends on **libghostty-vt** and does not reimplement the VT core
- **whostty** has `apprt/win32`, which uses **ConPTY** internally
- A **faithful port** is the unit of work that generates a **whostty** file from its **ghostty** counterpart
- The **Release Routine** watches the diff under **mirrored paths** and opens porting-checklist issues

## Flagged ambiguities

- "Same philosophy as the Bun Rust port" initially looked like a **language (Rust)** decision, but was resolved as a metaphor for the **development method** (fast, faithful porting via dynamic workflows + adversarial review). The implementation language stays **Zig**.
- The tension between "mirror the directory structure completely" and "use libghostty-vt" was resolved with the **hybrid** approach (mirror structure; depend on the library only for the VT core).
- "Operate this repo like ghostty" was ambiguous between matching ghostty's **operations posture** (CI + Release Routine + faithful-port flow) and full **feature parity**. Resolved as **parity** (north star): the whole in-scope ghostty `src/` surface is tracked via the **completeness ledger**, and PORTING.md's "excluded (for now)" list becomes **deferred-but-tracked** rows.
