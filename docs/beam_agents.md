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
Session notifications use `{:session_event, session_id, event}`.

`CodingAgent.Session.Notifier` owns subscriber bookkeeping. It has two deliberately
different paths:

| Subscription | Delivery | Limit |
| --- | --- | --- |
| Direct | Fire-and-forget `send/2` | No mailbox backpressure; trusted consumers must keep up |
| EventStream | Bounded stream with configured drop/timeout policy | Queue bounds do not guarantee lossless replay |

Prefer the stream path for consumers that may fall behind. Stream owner death
cancels its attached task. Subscriber monitoring removes dead direct listeners
and cancels/demonitors owned streams. Every terminal/error path must release
subscriptions and resources without inventing a successful result.

## Failure and mutation semantics

A tool failure is a result, not a reason to rerun all other tools in the batch.
Unexpected owner-process bugs should reach OTP supervision rather than return
fabricated empty/unchanged state. Boundary code distinguishes definite rejection
from an unknown mutation outcome: a timeout or exit can happen after acceptance.
Retain fixed run identity and reconcile unknown outcomes; do not duplicate work.

Session direct fanout remains fire-and-forget and events are not batched. There
is no universal lossless replay protocol for transient subscribers. Supervision
recovers a process, not arbitrary in-flight remote effects. Durable lifecycle
stores and explicit idempotency/lease contracts provide those guarantees where
implemented.

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

`LemonCore.MutationLock` owns reentrant multi-key in-VM mutations; callers use
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
