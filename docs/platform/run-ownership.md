# Run Ownership

Who owns what when a prompt is executed: the logical run, the execution
attempt and the agent session are three state machines with three owners,
and every transition, timeout, retry and terminal result has exactly one of
them. This is the deliverable of Phase 4 of the
[September 2026 architecture review](../architecture/review-2026-09.md),
as revised in its section 7: the router and the gateway are not merged, and
only the overlap that the code demonstrated was removed.

The rule, in one line: **the router owns what the user asked for, the
execution runtime owns one attempt to do it, the agent owns the
conversation with the model.** A component may observe another level's
state; it may not decide its transitions.

## The three levels

| Level | Identity | Owner | Lifetime |
| --- | --- | --- | --- |
| Logical run | `run_id` in `LemonCore.RunRequest` | `lemon_router`: `LemonRouter.SessionCoordinator` (one per conversation) decides when the run may start and how it queues; `LemonRouter.RunProcess` (one per run) drives it to a terminal result | From acceptance by `LemonRouter.RunOrchestrator` to the terminal `:run_completed` (or `:run_failed`) on `run:<run_id>` |
| Execution attempt | the same `run_id`, carried by `LemonCore.ExecutionCommand` → `LemonGateway.ExecutionRequest` | `lemon_gateway`: `LemonGateway.Scheduler` (global slots), `LemonGateway.ThreadWorker` (one per thread key: start order and start attempts), `LemonGateway.Run` (one per attempt: engine lock, executor control, event relay, attempt record) | From the router's accepted `submit_execution/1` to `LemonGateway.Run`'s finalize |
| Agent session | executor `run_ref` and the `CodingAgent.Session` id | `coding_agent`: `CodingAgent.Executor` starts `CodingAgent.Executor.SessionRunner` (one per attempt, linked to the `Run`), which drives `CodingAgent.Session` and translates its events with `CodingAgent.Session.RunTranslator` | The attempt's lifetime; a crash takes the `Run` with it and the router synthesizes the failure |

The seam between the first two levels is `LemonCore.EngineRuntime`
(`submit_execution/1`, `cancel_by_run_id/2`, `run_pid/1`, `available?/0`),
implemented by `LemonGateway.Runtime`; between the last two it is
`LemonGateway.Executor` (`start_run/3`, `cancel/1`, `steer/2`,
`redirect/2`) with its event sink. An execution-only host driven by another
node is a real consumer of the second seam without the first, which is why
the levels stay separate.

## One owner per transition

| Transition | Owner | How |
| --- | --- | --- |
| Accept or reject a request | `LemonRouter.RunOrchestrator` | Builds the submission, refuses a run id with an abort tombstone, subscribes the control plane's event bridge |
| Queue, promote, start | `LemonRouter.SessionCoordinator` | Pure reducer (`SessionTransitions`, `SessionState`) over queue modes `:collect`, `:followup`, `:steer`, `:steer_backlog`, `:redirect`, `:interrupt`; single flight per session through `SessionRegistry`; starts the `RunProcess` through `RunStarter` under the `LemonRouter.RunSupervisor` dynamic supervisor |
| Phases before the engine runs | `LemonRouter.PhasePublisher` | The only publisher of `:run_phase_changed` (`:accepted`, `:waiting_for_slot`, `:queued_in_session`, `:aborted`). The gateway does not model the phase graph |
| Hand the run to the runtime | `LemonRouter.RunProcess` | Retries `submit_execution/1` with backoff (100 ms doubling to 2 s) until accepted or the 30 s deadline, then ends the run itself with `failure_stage: :runtime_submission` |
| Grant a slot, order attempts per thread | `LemonGateway.Scheduler`, `LemonGateway.ThreadWorker` | Slot request times out after 30 s; at most 3 start attempts, then one synthetic failure with `failure_stage: :run_start` |
| Start the engine | `LemonGateway.Run` | Acquires the engine lock, starts the executor, emits `:run_started`; the `RunProcess` monitors the run pid from that event on |
| Stream and act | `LemonGateway.Run` | Relays the executor's events to `run:<run_id>` as the public structs (`:delta`, `:engine_action`) |
| Steer, redirect | `LemonRouter.SessionCoordinator` dispatches; `LemonGateway.Run` accepts or rejects | The coordinator reconciles its pending steers from the answer; the attempt decides what it can still take |
| Cancel | `LemonRouter` (coordinator or `RunProcess.abort/2`) → `EngineRuntime.cancel_by_run_id/2` → `LemonGateway.Run` | The attempt cancels the executor and emits the real completion (`ok: false`). If the run never bound to an engine process, the `RunProcess` ends it after a 150 ms grace |
| Complete | `LemonGateway.Run` | The one real `:run_completed`: release the engine lock, emit, `LemonCore.RunStore.finalize/3`, release the slot, notify the worker |
| End a run whose result will never come | `LemonRouter.SyntheticCompletion` | The engine process died, went missing after start, was aborted before binding, the submission deadline passed, or the watchdog gave up. One constructor, `LemonCore.Events.RunCompleted.failure/2`, and `meta.synthetic: true` |
| Give up on idle | `LemonRouter.RunProcess.Watchdog` | 2 h idle, 5 min confirmation, then cancel through the runtime and a synthetic completion |
| Retry | `LemonRouter.RunProcess.RetryHandler` (one zero-answer retry) and `LemonGateway.ThreadWorker` (three start attempts) | Different failures at different levels: an empty answer is a logical-run decision, a start that did not take is an attempt-level one |
| Persist the attempt | `LemonGateway.Run` | The run record and the finalize hooks (run history, memory ingest) through `LemonCore.RunStore` |
| Persist the conversation | `LemonRouter.RunProcess.CompactionTrigger` | Resume token, chat state, pending compaction: what the next run in the conversation needs |
| Rebroadcast to the conversation | `LemonRouter.RunProcess` | Every run event is republished unchanged on `session:<session_key>` |
| Crash of the logical run | `LemonRouter.RunProcess.terminate/2` | `:run_failed` on the run topic, coordinator told, runtime cancelled |

## What happens when a process dies

| Process | Consequence |
| --- | --- |
| `SessionCoordinator` | The queue and pending steers of that conversation are lost; the active `RunProcess` continues unmonitored and the session registry entry is cleared when it ends |
| `RunProcess` | `:run_failed` is published, the coordinator is notified, the runtime is asked to cancel the attempt |
| `Scheduler` | Slot accounting is lost; workers retry after 30 s; `available?/0` is false and new runs are parked until it returns |
| `ThreadWorker` | Queued attempts for that thread are lost; the scheduler frees the slot on `:DOWN` |
| `Run` | The router sees `:DOWN` and ends the logical run synthetically after a grace period; the worker frees the slot; the engine lock is released with the linked process |
| `SessionRunner` / `Session` | Linked to the `Run`, so the attempt dies with them and the case above applies |

Four monitors hold this together: scheduler → worker, worker → run,
`RunProcess` → run pid, coordinator → `RunProcess`. Each is a different
owner watching the level below it, not duplicated supervision.

## The public execution-event contract

Everything a consumer outside the execution path needs is on the bus topic
`run:<run_id>` as `LemonCore.Event` structs whose payloads are the
`LemonCore.Events` structs, republished unchanged on
`session:<session_key>` by the router:

| Event | Payload | Emitted by |
| --- | --- | --- |
| `:run_phase_changed` | `LemonCore.Events.RunPhaseChanged` | `LemonRouter.PhasePublisher` |
| `:run_started` | `LemonCore.Events.RunStarted` | `LemonGateway.Run` |
| `:delta` | `LemonCore.Events.Delta` (`seq` monotonic per run) | `LemonGateway.Run` |
| `:engine_action` | `LemonCore.Events.EngineAction` | `LemonGateway.Run` |
| `:run_completed` | `LemonCore.Events.RunCompleted` with a `LemonCore.Events.Completion` | `LemonGateway.Run` for a result; `LemonRouter.SyntheticCompletion` and `LemonGateway.ThreadWorker` for a run that never got one |
| `:run_failed` | `LemonCore.Events.RunFailed` | `LemonRouter.RunProcess.terminate/2` |

Event meta always carries `run_id` and `session_key`; a fabricated terminal
event carries `synthetic: true` and, where known, `failure_stage`
(`:runtime_submission`, `:run_start`). A consumer sees one terminal event
per run.

Representations that are allowed to differ, because they belong to one
level and are not the contract:

- the agent loop's tuples inside `coding_agent` and the `{:session_event,
  id, event}` fan-out of `CodingAgent.Session`;
- the executor sink protocol between `LemonGateway.Run` and its executor,
  `{:engine_event, ref, event}` and `{:engine_delta, ref, text}`, whose
  events are the tagged maps of `LemonGateway.Event`. `LemonGateway.Run`
  converts them to the public structs at the boundary, once;
- the delivery side: `LemonCore.DeliveryIntent` built by the router's
  coalescers and surfaces, rendered by channels into
  `LemonChannels.OutboundPayload`.

## What this phase changed

- `LemonRouter.RunSupervisor` the module was dead: the application starts
  a plain `DynamicSupervisor` under that name and `RunStarter` used it
  directly. The module is gone; the supervisor stays.
- Six copies of "build a failed completion and broadcast it" in the router
  (`RunProcess` ×4, `Watchdog`, `SessionCoordinator`) became
  `LemonRouter.SyntheticCompletion.broadcast/4`; the gateway's start-failure
  completion uses the same `RunCompleted.failure/2` constructor.
- `LemonGateway.Run` tracked and validated run phases against the phase
  graph without publishing them, in parallel with the router's publisher.
  The tracking is gone; the router owns the phase graph.
- A delta was encoded twice on its way to the bus (a gateway struct, then
  the public struct). It is built once; `LemonGateway.Event.Delta` is gone.

## What stays, and why

- Two per-conversation queues, in `SessionCoordinator` and `ThreadWorker`,
  because they order different things: which logical run may start next
  under a queue mode, and in which order attempts on one thread key take a
  slot.
- Two registries and two dynamic supervisors, one per level, because a
  logical run and an attempt have different lifetimes.
- Two retry loops, because an empty answer and a start that did not take
  are decided at different levels.

Still open, for the next pass: the executor protocol's tagged maps are a
second encoding of the public structs and could be replaced by them; the
`notify_pid` completion message the worker and the run exchange is a third
representation of the same terminal result.
