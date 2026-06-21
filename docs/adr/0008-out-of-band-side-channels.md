# Out-of-Band Terminal Side Channels: Capture, Don't Reply

[ADR 0006](0006-vt-response-write-back.md) added the *reply* path: terminal
queries (DSR / DA / DECRQM / kitty-keyboard query) generate bytes the terminal
owes the pty, queued on the reader thread and drained to the pty on the UI
thread. But a second class of terminal events owes the pty **nothing** — instead
the *application* must act on the host:

- **BEL** (`\x07`) — ring the bell (flash the window / beep).
- **OSC 7** — the shell reports its working directory (used later for the window
  title #89 and new-window inheritance #87).
- **OSC 9 / OSC 777** — raise a desktop notification.
- **OSC 9;4** — drive the taskbar progress bar.

libghostty-vt's `ReadonlyHandler` drops all of these: they have no
terminal-*modifying* effect, so the readonly stream (built for replay tooling)
ignores them. whostty has to surface them itself, and the surfacing is an OS
action that must run on the **UI thread** (window flash, clipboard, toast),
while the VT bytes are parsed on the **reader thread**. This records how those
events cross that boundary (#85).

## Decision

- **Capture into a `SideChannel` struct owned by `Termio`.** The `ResponseHandler`
  (already wrapping `ReadonlyHandler`) gains arms for `bell` / `report_pwd` /
  `show_desktop_notification` / `progress_report` that write the captured value
  into `Termio.side`. These writes happen on the reader thread but *under
  `Termio.mutex`*, because `process()` locks the mutex around `stream.nextSlice`,
  which is what runs the handler. The UI thread reads via thread-safe accessors
  that take the same mutex — so the side channel reuses the one lock that already
  guards the grid; no new synchronization.
- **Drain semantics match each signal's nature.** An *edge* (bell, notification)
  is take-and-clear: `takeBellCount` returns the count since the last call then
  resets; `takeNotification` transfers ownership of the latest notification and
  clears it (latest-wins — an undrained notification is overwritten, since only
  the most recent matters). A *level* (progress) is a persistent getter:
  `progressReport()` returns the current state without clearing, because a
  progress bar is a state the app mirrors, not an event it consumes once. The
  cwd is a latest-value with the OSC-7 empty-url *reset* (ghostty's "forget the
  pwd") clearing it.
- **The app acts on the UI thread, next to the existing drains.** Each frame, after
  draining VT replies and the OSC 52 clipboard write, the main loop drains the
  side channel: a non-zero bell count flashes the window (`FlashWindowEx`, a
  visual bell that no-ops when the window already has focus); a notification is
  logged. The OS *surfacing* of notifications (Windows toast / tray) and progress
  (taskbar via `ITaskbarList3`) needs a real window + COM/WinRT and is deferred to
  the windows-host work (#43); the capture + plumbing here is the reusable core.
- **The one query that *does* reply stays on the reply path.** `kitty_keyboard_query`
  (`CSI ? u`) owes the pty `CSI ? <flags> u`, so it routes through the ADR 0006
  response queue, not the side channel — it is a reply, not a host action.

## Considered Options

- **Capture in a `SideChannel`, drain on the UI thread (chosen)** — one owner,
  one lock (shared with the grid), and the app acts where OS calls are legal.
  Cost: a per-frame drain (cheap; usually all-empty) and a small struct on
  `Termio`.
- **Direct callback from the handler to the app** — the handler would invoke an
  app closure when it sees a bell/notification. Rejected: the handler runs on the
  reader thread, but flashing the window, writing the clipboard, and raising a
  toast must happen on the UI thread; a callback would either cross threads
  unsafely or need its own queue — which is exactly the `SideChannel`.
- **Route everything through the reply queue** — reuse ADR 0006's byte queue for
  these too. Rejected: these events produce no pty bytes; they are typed host
  actions (flash, toast, cwd string, progress state), not a byte stream.

## Consequences

- Bell, cwd, notifications, and progress are all captured and unit-tested at the
  VT layer; the bell is fully wired (visual flash). The only deferred piece is the
  OS *surfacing* of notifications/progress, which is inherently host-only (#43),
  plus the cwd's downstream consumers (title #89, new-window #87).
- The side channel shares `Termio.mutex` with the grid, so a frame's drain and the
  reader's capture never race, and there is no second lock to reason about.
- The kitty-keyboard *query* is answered and kitty-form key *output* is wired
  (#82): when an app enables the protocol, printable and special keys alike route
  through the encoder (deriving the unshifted codepoint + typed text via the Win32
  keyboard APIs) and are emitted as CSI-u sequences; when it is off, legacy WM_CHAR
  typing is byte-identical. Full Alt-as-Meta under kitty (Alt+printable as
  `CSI …;3u`) stays deferred with the WM_SYSKEYDOWN forwarding work. The kitty
  *graphics* protocol is blocked at the dependency layer — see
  [0009](0009-kitty-graphics-dependency-constraint.md).
