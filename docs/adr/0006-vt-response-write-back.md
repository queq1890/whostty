# VT Response Write-Back: Wrap the Readonly Handler and Drain Replies on the UI Thread

whostty fed pty output into libghostty-vt's `ReadonlyStream` and rendered the
grid, but the **reverse path was missing**: the terminal never wrote replies
back to the pty. `ReadonlyStream` is built for replay tooling — it applies every
state-modifying action but deliberately drops the queries that require an
answer (DSR, DA, cursor-position report, DECRQM, ENQ). Without those replies a
large class of TUIs and shells hang or mis-detect capabilities while probing the
terminal. This adds the write-back path (#81).

## Decision

- **Wrap the readonly handler; don't reimplement it.** A new `ResponseHandler`
  holds a `vt.ReadonlyHandler` as `inner` and is installed via
  `vt.Stream(ResponseHandler)`. Its `vt` dispatch handles only the reply-owing
  actions (`device_attributes`, `device_status`, `request_mode`,
  `request_mode_unknown`) and delegates **every other action** to
  `inner.vt(action, value)`. None of the hundreds of lines of state-mutation
  logic (print, cursor, SGR, modes, charsets, OSC color, …) is duplicated —
  the upstream handler stays the single source of truth, and a libghostty-vt
  bump re-ports it for free.
- **Replies are bytes formatted to match ghostty.** DA quacks as a VT220
  (`\x1b[?62;22c` / `\x1b[>1;10;0c`); DSR answers `\x1b[0n` and the
  origin-mode-aware cursor report `\x1b[{row};{col}R`; DECRQM answers
  `\x1b[{?}{mode};{code}$y` with code 1=set / 2=reset / 0=unrecognized. The
  formats mirror `termio/stream_handler.zig`.
- **Queue replies; drain them on the UI thread.** The handler appends replies to
  `Termio.response`, an owned buffer guarded by the same mutex as the terminal
  (the reader thread fills it inside `process`). The UI thread drains it every
  frame via `takeResponse` and writes the bytes to the pty. Because the Win32
  message pump is non-blocking (`PeekMessage`) the main loop spins continuously,
  so a reply leaves within one frame of being generated.

## Considered Options

- **Wrap `ReadonlyHandler` + UI-thread drain (chosen)** — minimal new surface,
  no duplicated VT logic, and a single pty writer. Cost: replies travel through
  a queue with up-to-one-frame latency (imperceptible for DSR/DA), and the
  handler needs a stable pointer to the queue (satisfied because `Termio` is
  heap-allocated).
- **Write a full custom handler from scratch** — total control, but it would
  re-implement everything `ReadonlyHandler` already does and drift from upstream
  on every bump. Rejected: the faithful-port goal (CONTEXT.md) wants upstream to
  own state mutation; only the *response* surface is genuinely ours.
- **Write replies straight to the pty from the reader thread** — lower latency,
  but pty writes would then race keyboard input (which is written on the UI
  thread) and could interleave mid-sequence on a shared ConPTY input pipe.
  Rejected: serializing every pty write on one thread is simpler and correct
  without a write mutex or a ghostty-style mailbox.

## Consequences

- TUIs and shells that probe with DSR/DA/DECRQM/ENQ no longer hang; the terminal
  identifies as a VT220.
- The primary DA reply omits the `52` clipboard flag that ghostty advertises:
  OSC 52 write-back is not wired yet (#85), so claiming it would invite queries
  we cannot answer. The flag is added when OSC 52 lands.
- Replies still **deferred** (delegated to a no-op for now, tracked under #67):
  `xtversion`, size reports, and the kitty-keyboard query (#82); DSR
  color-scheme / OSC color queries (#83). ENQ replies with the empty string,
  which is ghostty's default `enquiry-response`.
- This is the foundation the rest of #67 builds on — every protocol that answers
  the program (kitty keyboard #82, OSC 4/10/11/12 dynamic colors #83, kitty
  graphics #84, OSC side-channels #85) routes its reply through the same
  `response` queue. It builds on [0002](0002-hybrid-architecture.md) (the VT core
  is libghostty-vt; the Windows layer owns only what upstream cannot).
