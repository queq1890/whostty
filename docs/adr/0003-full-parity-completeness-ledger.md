# Full Parity as the North Star; PORTING.md as the Completeness Ledger

"Operate this repo like ghostty" is resolved to mean **full feature parity**:
every ghostty `src/` path not delegated to libghostty-vt is eventually ported.
Nothing under `src/` is permanently out of scope — the paths PORTING.md
previously called "excluded (for now)" become **deferred-but-tracked** rows.
To make "is everything filed?" answerable, PORTING.md is designated the
**completeness ledger**: completeness is checkable mechanically as
`ghostty src/ tree − (delegated ∪ ledger rows) = unfiled gap`, and an item is
"filed" only when it is a not-done ledger row with a linked issue.

## Considered Options

- **Full parity + completeness ledger (chosen)** — the whole in-scope ghostty
  `src/` surface is tracked in PORTING.md; deferral is explicit, not silent. Fits
  the project's "faithful 1:1 port" identity and makes coverage verifiable.
- **Operations posture only** — match ghostty's CI + Release Routine + porting
  flow, and let features accrete ad hoc. Rejected: leaves "what's left?"
  unanswerable and lets the backlog drift from ghostty's actual tree.
- **MVP terminal** — a hand-picked "good enough" feature subset. Rejected: the
  subset boundary is arbitrary and re-opens the same scope question later.

## Consequences

- PORTING.md must enumerate the *whole* in-scope `src/` tree, not only ported
  rows; expanding it to a row-per-path ledger is itself tracked work.
- Work is sequenced by daily-driver criticality, not ghostty's directory order:
  host-gate → usable-terminal wiring → quality/native backends → ecosystem.
- The **host-gate** (a signed-build-capable Windows dev host) is the single root
  dependency for all on-device work; its code-signing output is reused for
  distribution. See CONTEXT.md.
- `benchmark/`, `synthetic/`, `build/`, the alternate `main_*.zig` targets, and
  the macOS/GTK apprt layers stay out of scope and are excluded from the
  completeness invariant.
- The Release Routine (see [docs/release-routine.md](../release-routine.md))
  keeps the ledger honest by diffing upstream against the mirrored paths.
