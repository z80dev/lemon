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
  the corresponding tool result without crashing unrelated sessions. A tool
  never outlives its loop: a per-batch reaper owns the tasks and their per-tool
  deadline, and when the loop exits for any reason (including a kill or a
  stopped `Loop.stream/4` consumer) it aborts the run signal, gives cooperative
  tools a short grace and terminates the rest. Runs started without a signal
  get one, so cancellation always reaches pending tools.
- Subagents are discoverable and supervised. Coordinators track their children
  and cancel outstanding work on timeout or parent termination.
- Abort is cooperative and best-effort for external work. The loop checks the
  abort signal at safe points, and tools must honor it. A task can remain active
  briefly during scheduler/NIF/external-process cleanup.
- Context truncation preserves chronological history and tool-call/result units.
  Session persistence and prompt projection are separate: a model-facing safety
  transform must not silently rewrite the user's stored transcript.

Operational work uses capped task supervisors through
`LemonCore.TaskSupervisor`. The default 1024-task limit is caller policy, not a
measured throughput claim; a child can set `max_children`, or deployments can
set `:lemon_core, :task_supervisor_max_children` by registered supervisor name.
Capacity and absent-supervisor refusals map to `:task_capacity_reached` and
`:task_supervisor_unavailable`. They never launch a fallback task. Temporary
tasks are not restarted, and uncertain admissions must not be replayed.

Proxy requests remain attached to their event stream while supervised:
cancellation shuts down the request and socket even before response headers.
Honcho uploads and process-exit callbacks are best-effort supervised work;
admission refusal skips them rather than silently bypassing the cap. ACP
permission prompts fail closed if their worker cannot start.

The exact path/count exceptions for raw process creation live in
[`RawProcessArchitectureTest`](../apps/lemon_core/test/lemon_core/raw_process_architecture_test.exs).
They are lifecycle primitives, not a general permission to launch work:
cleanup/approval guardians survive forced owner death; cancellation reapers
finish after their stream or caller exits; VM-drain failsafes survive app-tree
shutdown; `Bus.Delivery` is bounded and creator/consumer-monitored.
A documentation-only latch example is counted explicitly too. Remaining
channel attachment/webhook tasks belong
to #580/#581 and voice tasks to #588. No compaction, proxy or upload fallback is
allowlisted. Changing to another unsupervised spawn primitive is not a fix.

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

Successful replay pages contain `status: "ok"`, `sessionKey`, `entries`, `cursor`,
and `hasMore`. Each entry contains its `cursor`, `eventId`, and projected `events`
array (which may be empty while still advancing the cursor). `cursor_expired`
returns empty `entries`, a null `cursor`, and `hasMore: false`. The method schema
in `protocol/schemas.ex` validates request parameters; the method's response uses
these camel-case wire fields, not the native provider's `events`/`has_more` page.

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

## Lock conventions

An in-VM mutex uses
`:global.trans({resource_key, self()}, callback, [node()], retries)`. The first
element is the shared resource; the second is the requesting process, not a
constant or a path. Otherwise independent callers can be mistaken for one
reentrant requester. These locks coordinate only this VM, never named execution
nodes or independent runtimes sharing files.

All source calls specify `[node()]` and finite non-negative integer retries.
The ordinary caller policy is three acquisition retries, matching the existing
provider-management configuration lock. This is a bounded contention policy,
not a measured latency target or a callback execution deadline. The webhook
maintenance sweep uses zero retries because another sweep already doing the
work is sufficient; it must not delay ingress waiting for that owner.
`Lemon.Reload` also defaults to zero (fail fast), but callers may explicitly
choose another finite non-negative retry count.

Exhaustion returns `:aborted` before the callback runs. Translate it at the owning
boundary into its existing safe error shape (`:lock_aborted` for kanban,
`:idempotency_unavailable` for webhook admission, or the service's unavailable
error). Registry APIs whose contract is `:ok` raise on failed acquisition rather
than claim registration succeeded. Do not run the callback without the lock,
fabricate success, or retry a callback's `:outcome_unknown` result. Retrying lock
acquisition is not permission to repeat a side effect.

`CodingAgent.MutationLock` owns reentrant multi-key in-VM mutations; callers use
its bounded acquisition and sorted key ordering rather than composing ad-hoc
nested locks. Cross-process file mutations use `LemonCore.Service.Lock`;
`LemonCore.Secrets.Lock` retains the secret-store transaction boundary.
The source rule is checked structurally, including macro-generated calls, by
`apps/lemon_core/test/lemon_core/quality/global_trans_contract_test.exs`.

## Verification

Use [the canonical test lanes](testing.md) from the umbrella root. For runtime
changes exercise normal completion, tool crash, abort during tools, owner death,
slow/dead subscribers, restart and cross-session isolation. Assert observable
results and terminal cleanup; do not pin copied supervisor trees or module
existence. Live provider tests are separate opt-in checks, not implied by unit
coverage.
