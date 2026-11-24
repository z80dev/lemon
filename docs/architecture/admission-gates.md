# ADR: one conversation owner, one gateway permit authority

Status: accepted, option **b2** in [#574](https://github.com/z80dev/lemon/issues/574).
Implementation: [#610](https://github.com/z80dev/lemon/issues/610),
[#611](https://github.com/z80dev/lemon/issues/611),
[#612](https://github.com/z80dev/lemon/issues/612), and
[#613](https://github.com/z80dev/lemon/issues/613).

## Decision

`SessionCoordinator` is the only owner of per-conversation ordering. Gateway
retains one global execution-slot authority, `LemonGateway.Slots`, whose FIFO
waiters are live `Run` processes. `Runtime.submit_execution/1` starts a temporary
Run directly under `RunSupervisor`; success acknowledges child existence, not
executor start. A Run claims its engine session through `EngineSessionClaim`,
checks the durable terminal fence, requests a permit, then rechecks terminal and
cancellation state before invoking the executor. Claims fail immediately with
`:session_in_use`, before capacity is consumed. Release is idempotent, and owner
death releases Registry ownership and monitored permits.

The old ThreadWorker, its supervisor/registry, Scheduler generation queue, and
EngineLock FIFO are removed. The [architecture boundary](../architecture_boundaries.md)
does not move: router owns conversations; gateway owns execution capacity and
native lifecycle. The global capacity setting remains `[gateway].max_concurrent_runs`
(default 2), with `LEMON_GATEWAY_MAX_CONCURRENT_RUNS` precedence. Invalid capacity
fails startup rather than silently selecting 10. Lock enable/timeout settings
and their environment variables are removed, without aliases.

Supported product submissions go through `RouterBridge` with `RunRequest`, then
through the configured `EngineRuntime` with `ExecutionCommand`. Gateway's direct
execution APIs are `Runtime.submit_execution/1` and `LemonGateway.submit/1`.
Direct callers must provide resolved commands and do not gain router ordering,
durable admission receipts or router population limits. Private request structs,
RunSupervisor calls, and the removed `Runtime.submit/1` are not public ingress.

## Alternatives considered

- **a: retain and document all layers.** Low migration risk, but keeps duplicate
  ordering, cancellation paths and a global slot held during engine-lock waiting.
- **b1: count-only supervisor capacity.** Smaller implementation, but full capacity
  becomes rejection/retry polling; FIFO fairness and queued cancellation are lost.
- **b2: Run-owned permit waiting (chosen).** Keeps FIFO without an extra process
  per conversation or a second conversation queue; claims preserve exclusivity
  for shared native sessions without waiting while holding a global permit.
- **c: move global capacity into router.** Could reduce gateway admission further,
  but changes the runtime boundary and configuration owner and must redefine the
  interaction with router's separate run-process cap. Not selected.

## Admission inventory

This is the canonical inventory for the router-to-native-executor path, including
its executor-internal and named-node gates. Counts are per VM unless stated
otherwise. A process cap, execution cap, queue bound and uniqueness fence serve
separate purposes; none should be described as a substitute for the others.

| Gate / owner | Key | Default / population | Saturation behavior and purpose |
| --- | --- | --- | --- |
| `RunOrchestrator` admission mailbox and durable identity | Global mailbox; fixed `run_id` identity | One GenServer; mailbox has no admission count cap | Serializes submissions; identical retries replay the original receipt, conflicting reuse is rejected. Durable uncertainty is not retry permission. |
| Session lifecycle fence (`LemonCore.LifecycleFenceStore`, owned by `RunOrchestrator`) | `session_key` | One durable row per session; `"held"` while `sessions.reset`/`sessions.delete` or one `sessions.prune` deletion runs | Taken through the admission mailbox by an owner process scoped to the one operation (never the caller), so prior admissions are visible to the operation's idle proof (`LemonRouter.run_presence/1`); a busy session refuses the operation. While held, every router admission mode, idle native follow-ups, remote `coding_agent.run` dispatch and direct `LemonGateway.submit/1` are refused with `:session_lifecycle_in_progress`; the unadmitted paths register in `LemonCore.SessionActivity` for their lifetime under their own presence identity and count as active presence. `SessionActivity` serves each snapshot, and each live-to-unresolved transition, through one serialized process that rebuilds surviving registrations from their owners before serving anything after a restart. A router run executed on a named node (`RemoteSessionRunner`) registers its invocation as session activity at dispatch, so the session stays busy after the router run's terminal summary: a cancelled, timed-out or abandoned remote run stays present until the node's terminal result, which the worker sends only after the execution process exits (a worker that never acknowledges keeps it busy); a lost node connection leaves durable unresolved presence until a terminal result for that invocation, or the node's post-barrier active-invocation report (`node.invoke.active`) from a later connection omits it. A reconnect alone clears nothing. Unresolved rows written before the raw `node.invoke` RPC was removed are honoured the same way. While the router still tracks the run, its activity registration is counted once with it. No operator RPC starts `coding_agent.run` on a node outside router admission. The row survives orchestrator restart (owners are re-monitored) and every reset/delete mutation requires its generation. A timed-out acquire is cancelled by its acquisition id. A fence left by a failed release or dead owner is released only after the owner exits and a reconcile barrier on the Store and run-history owners passes: removed when the operation had finished, otherwise left as an `"outcome_unknown"` row. Fences never expire by time. Definite pre-dispatch rejections are recorded as terminal `rejected` admissions, never as unresolved work. |
| `SessionCoordinator` / `SessionTransitions` | Explicit resume: `{:resume, engine, token}`; otherwise `{:session, session_key}` | One active run; pending backlog 128 submissions, 1 MiB prompt text, 16 MiB encoded image data | `:session_queue_full` without queue mutation or interrupting the active run. Owns collect/followup/steer/interrupt semantics. |
| `SessionCoordinatorSupervisor` | Distinct conversation key | Uncapped population; no idle-stop path | Coordinators are never stopped merely because idle. Processes accumulate per distinct conversation for the VM lifetime; bounded individual backlogs do not bound total memory. |
| Router `RunSupervisor` | Global | `:lemon_router, :run_process_limit`, 500 | Supervisor `:max_children` becomes `:run_capacity_reached`; includes RunProcesses waiting for gateway capacity, not just executing runs. |
| Router `RunProcess` / `SessionRegistry` | `session_key` | One live owner per session | `:session_busy`; coordinator retains/requeues work behind the surviving owner. Process death releases the name. |
| Gateway `RunSupervisor` / `RunRegistry` | Global population; unique `run_id` | Uncapped supervisor; one live Run per run ID | Duplicate live submission acknowledges the existing child, not another executor. Waiting Runs count as children. Direct callers bypass router's 500-process cap. |
| Gateway `EngineSessionClaim` | `{:engine_session, {:resume, token}}`, otherwise `{:engine_session, {:session, session_key}}` | One owner per key, including while waiting for capacity | Fail-fast `:session_in_use`; no queue or timeout, no permit held by the refused Run. |
| Gateway `Slots` | Global permits; waiter identity `run_id` and Run pid | 2 executing Runs; FIFO waiter population and duration have no independent cap | Wait asynchronously until grant/cancel/death. Normal routed waiters are indirectly bounded by router RunProcesses; direct runtime waiters are not. A run blocked on its own `agent` children (sync run or join) lends its permit with `suspend/2` and re-enters at the front of the queue on `resume/3`, so delegation depth and fan-in cannot stall admission. ETS stats expose `in_flight` (lent permits excluded), `waitq`, `max`. |
| `CodingAgent.LaneQueue` | Lane | `:coding_agent, :lane_caps`: background_exec launch cap (the only lane) | FIFO within each lane. This executor-internal capacity is independent of gateway top-level permits. |
| Background lane admission / `ProcessManager` | Background execution identity | Pending limit 32, admission deadline 5,000 ms by default | Background admission rejects overload and expires pending launches; these are separate from gateway waiters. See [background process settings](../config.md). |
| `CodingAgent.TaskSemaphore` / `Parallel.Semaphore` | Global task work | `:coding_agent, :task_max_concurrency`, 8 | Blocks FIFO until a semaphore slot is released; in-process subagents do not each consume gateway top-level permits. |
| `BudgetTracker` / `BudgetEnforcer` | Parent run | Default delegated-child budget 5 (`LEMON_BUDGET_MAX_CHILDREN`); inherited authority can narrow it | `:max_children_exceeded` rejects a child; budget admission is separate from task scheduling capacity. |
| `LemonAi.CallDispatcher.Slots` | Provider | 10 requests per provider; queue timeout 120,000 ms | FIFO; `:max_concurrency` on expiry (0 timeout is fail-fast), `:admission_unavailable` when authority is unavailable. There is no dispatcher-global concurrency slot. |
| Named-node `ExecutionNode.Worker` | Destination-local `run_id` | One live invocation per run ID | `:run_already_active` rejects a duplicate invocation. The controller Run takes exactly one gateway permit; destination task/provider limits remain local. |

The provider dispatcher also checks circuit state and provider rate limits; their
`:circuit_open` and `:rate_limited` failures are not gateway-capacity failures.
Tool-specific resource limits are not additional top-level conversation queues.

Source anchors for review (paths relative to the repository root):

- `apps/lemon_router/lib/lemon_router/{run_orchestrator,session_coordinator,session_transitions,session_coordinator_supervisor,run_starter,run_process,application}.ex`
- `apps/lemon_gateway/lib/lemon_gateway/{runtime,run,run_supervisor,slots,engine_session_claim}.ex`
- `apps/lemon_core/lib/lemon_core/config/gateway.ex`
- `apps/coding_agent/lib/coding_agent/{application,lane_queue,parallel,budget_tracker,budget_enforcer,process_manager}.ex`
- `apps/coding_agent/lib/coding_agent/execution_node/worker.ex`
- `apps/lemon_ai/lib/lemon_ai/call_dispatcher.ex` and `call_dispatcher/slots.ex`

## Acceptance, cancellation and named nodes

- **#78 acceptance:** router's durable receipt remains the acceptance authority.
  A started gateway child is not proof that its executor ran. Accepted work that
  never executes still receives a terminal receipt.
- **#79 idempotency:** router retains the durable fixed-ID request identity;
  gateway RunRegistry prevents simultaneous duplicate execution. The RunStore
  terminal fence prevents a late child from executing already-terminal work.
- **#80 queued cancellation:** cancel the exact Run and remove its waiter. A late
  permit grant is fenced before executor start. Running cancellation retains
  capacity until executor termination/drain, rather than oversubscribing tools.
- **#81 unknown outcomes:** the worker enqueue acknowledgement is gone. Router
  retries only runtime unavailability within its pre-start deadline; definite
  rejection terminalizes once. Durable admission/store uncertainty and external
  executor effects still cannot be treated as definite non-execution. An
  unknown submit outcome adopts the Run under its fixed ID; the router monitors
  the Run from acceptance, so one that exits while waiting for a permit is
  terminalized once rather than holding its conversation (#641).
- **Named nodes:** a remote run still has one controller Run and one permit.
  Destination-local invocation uniqueness remains separate. Shared resume tokens
  across different session keys are protected by the fail-fast claim, not a
  second ordering queue.

## Evidence and measurement status

The implementation issues attribute the static baseline to integration commit
`c05d858e0`: Scheduler 604 lines, ThreadWorker 691, EngineLock 203,
ThreadWorkerSupervisor 18 and RunSupervisor 34: **1,550 lines total**.
The three main modules alone total **1,498**, not 1,550. Counts include comments
and blank lines; they measure source size, not runtime cost. The analysis's
approximately 240-line replacement estimate is a design estimate, not a measured
post-change result.

Code inspection showed the old Run acquired an execution slot before waiting up
to 60 seconds in EngineLock. With two permits, one such waiter occupies half of
configured capacity. This is an inference from ordering and configuration, not
an observed latency distribution. Likewise, the redundant worker FIFO being
normally empty follows from upstream single-flight; it was not load-measured.

No before/after latency benchmark, post-change LOC total, or performance gain is
claimed here. This documentation change ran no tests, builds or formatters.
Integration must report its exact tested revision and actual command results;
the issue's quality/docs acceptance is not established by this ADR alone.

## Measurement methodology

Use the same host, OTP/Elixir versions, storage backend, configuration and workload
for both revisions. Record exact revision, dirty-tree state, commands, warm-up,
sample count, executor duration, and machine/filesystem details. Count physical
lines over the same module scope (include the supervisors in both totals), and
report code moved into Run/Runtime separately rather than claiming it vanished.

For latency, saturate two slots with independently controlled executions and
submit a third conversation. Repeat enough trials to report sample count and
p50/p95 for orchestrator submit, coordinator submit, permit wait, child start,
and cancel-to-terminal. Use monotonic timestamps at those boundaries; child
start acknowledgement is not executor start, and queue time must not be hidden
inside executor duration. Separate queued cancellation from running cancellation,
record failures/timeouts, and verify exactly one terminal receipt and zero
executor invocations for canceled waiters.

Sample live router RunProcesses, coordinators, gateway Runs and permit counters
throughout. Before cutover also count ThreadWorkers; after cutover do not infer
zero processes from a missing telemetry family alone. Exercise both repeated
conversation keys and continually new keys to expose coordinator population
growth. Include direct runtime submissions separately because they bypass router
limits. Add duplicate fixed-ID, shared-token contention, terminal-before-start,
owner-death and named-node trials; check one controller permit per remote run.

`Slots.stats/0` is an ETS snapshot, not a per-run wait histogram. The removed
scheduler telemetry is not emitted by Slots. Instrument the boundaries in a
controlled measurement harness if wait distributions are needed; do not invent
percentiles from aggregate snapshots. Never include prompts, resume tokens or
credentials in measurement artifacts.
