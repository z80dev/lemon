# BEAM Agent Architecture and Invariants

Lemon uses OTP processes for agent/session ownership and supervised tasks for
model/tool work. This page records lifecycle guarantees and limits; the
[architecture overview](architecture/overview.md) explains app boundaries,
[telemetry reference](telemetry.md) owns event names, and the
[agent guide](../apps/lemon_agent/AGENTS.md) owns contributor gotchas.

## Supervision and isolation

`LemonAgent.Supervisor` owns the abort-signal table owner, agent registry,
subagent supervisor, loop task supervisor and tool task supervisor.
`CodingAgent` separately owns native sessions, persistence and coordination.
Supervision does not mean replaying a side effect: crashed tool tasks report
errors and are not automatically restarted/retried.

- Agent loops run under `LemonAgent.LoopTaskSupervisor`.
- Tools run under `LemonAgent.ToolTaskSupervisor`; monitors connect crashes to
  the corresponding tool result without crashing unrelated sessions.
- Subagents are discoverable and supervised. Coordinators track their children
  and cancel outstanding work on timeout or parent termination.
- Abort is cooperative and best-effort for external work. The loop checks the
  abort signal at safe points, and tools must honor it. A task can remain active
  briefly during scheduler/NIF/external-process cleanup.
- Context truncation preserves chronological history and tool-call/result units.
  Session persistence and prompt projection are separate: a model-facing safety
  transform must not silently rewrite the user's stored transcript.

## Event flow

```text
provider stream → agent loop → coding session → runtime bus
                     │              │              │
                 tool tasks     subscribers     router/client
```

The agent emits turn/message/tool events and a terminal result. The terminal
`agent_end` carries newly produced messages, not the entire conversation.
Session notifications use `{:session_event, session_id, event, cursor}`.

`CodingAgent.Session.Notifier` assigns one gap-free per-session `seq` at the
broadcast point, before fanout. Its session-owned protected ETS `ordered_set`
retains events under both count and encoded-term byte budgets (caller policy:
1,000 events / 1 MiB by default, `:event_log_max_count` / `:event_log_max_bytes`).
An oversized event is delivered live but evicts its own replay entry; replay
never silently skips it.

Version-1 cursors contain `sessionId`, opaque `streamId`, and `seq`. The stream
identifies an owner/selected-branch epoch, not a global or run-local order. The
stable event identity is `streamId:seq`, shared by live delivery and replay.
Run IDs remain run identity; the existing chat delta `seq` remains run-local.
Branch selection/reset rotates the stream and expires old cursors without
reusing the session sequence. Owner death destroys the ring, so restart requires
snapshot recovery, not automatic side-effect replay. Unsupported cursor
versions are rejected explicitly.

| Subscription | Delivery | Limit |
| --- | --- | --- |
| Direct | Nonblocking `Bus.Delivery` admission | Count/byte admission fences overflow |
| EventStream | Bounded subscriber queue | Overflow fence, then cursor recovery |

The authenticated `sessions.events` method returns ordered batches strictly
after a cursor, or explicit `cursor_expired`. Authorization is checked again for
each replay, including after reading the owner. The TUI deduplicates the same
canonical `session.event` batches live and on reconnect, fetching missed pages
from its cursor and falling back to `sessions.snapshot` only on expiry. Snapshot
collection includes the native cursor so replacement text and later deltas have
an explicit boundary. Failed reads never imply an empty/idle session.

Subscriber monitoring removes dead listeners and cancels/demonitors owned
streams. Fences are transport control messages, not sequenced session events.
Every terminal/error path releases subscriptions without inventing success.

`LemonAgent.EventStream` still serves non-session/provider streams with no native
session cursor. Its bounded overflow fence/retirement buffer is therefore retained
here, not treated as a second replay authority. Session clients no longer need
it to replay missed events; the EventStream unification owner can remove the
session-specific resync buffering once the generic fence/terminal contract is
preserved for cursorless consumers.

## Failure and mutation semantics

A tool failure is a result, not a reason to rerun all other tools in the batch.
Unexpected owner-process bugs should reach OTP supervision rather than return
fabricated empty/unchanged state. Boundary code distinguishes definite rejection
from an unknown mutation outcome: a timeout or exit can happen after acceptance.
Retain fixed run identity and reconcile unknown outcomes; do not duplicate work.

Supervision recovers a process, not arbitrary in-flight remote effects. Cursor
replay recovers transient session observation only within a live ring window.
Durable lifecycle stores and explicit idempotency/lease contracts provide
cross-restart and side-effect guarantees where implemented.

## Verification

Use [the canonical test lanes](testing.md) from the umbrella root. For runtime
changes exercise normal completion, tool crash, abort during tools, owner death,
slow/dead subscribers, restart and cross-session isolation. Assert observable
results and terminal cleanup; do not pin copied supervisor trees or module
existence. Live provider tests are separate opt-in checks, not implied by unit
coverage.
