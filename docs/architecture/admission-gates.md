# ADR: one conversation owner, one execution permit authority

Status: accepted, option **b2** in [#574](https://github.com/z80dev/lemon/issues/574).
Implementation: [#610](https://github.com/z80dev/lemon/issues/610),
[#611](https://github.com/z80dev/lemon/issues/611),
[#612](https://github.com/z80dev/lemon/issues/612), and
[#613](https://github.com/z80dev/lemon/issues/613).
Amended by [#728](https://github.com/z80dev/lemon/issues/728): execution ownership
and the permit authority now live in the router.

## Decision

`SessionCoordinator` alone orders conversations. `LemonRouter.RunProcess` owns
execution, and live run owners wait FIFO at the single global permit authority,
`LemonRouter.Slots`. Before requesting a permit, the owner claims its engine
session via `EngineSessionClaim` and checks the durable terminal fence. A busy
session returns `:session_in_use` and is retried within the 30-second submission
deadline without consuming a permit. After grant the owner rechecks terminal
and cancellation state before starting the executor. Owner death releases
Registry ownership and monitored permits.

Capacity remains `[gateway].max_concurrent_runs` (default 2), with
`LEMON_GATEWAY_MAX_CONCURRENT_RUNS` precedence. Invalid capacity fails startup.
Engine-session ownership has no configurable wait or timeout.

Product submissions use `LemonCore.RouterBridge` with `RunRequest`. The router
passes a resolved `ExecutionCommand` directly to the native executor after
admission. There is no direct gateway execution API or unadmitted gateway waiter.

## Alternatives considered

- **a: retain and document all layers.** Low migration risk, but keeps duplicate
  ordering, cancellation paths and a global slot held during engine-lock waiting.
- **b1: count-only supervisor capacity.** Smaller implementation, but full capacity
  becomes rejection/retry polling; FIFO fairness and queued cancellation are lost.
- **b2: Run-owned permit waiting (chosen).** Keeps FIFO without an extra process
  per conversation or a second conversation queue; claims preserve exclusivity
  for shared native sessions without waiting while holding a global permit.
- **c: move global capacity into router.** Not selected in #574. #728 moves the
  authority with the run owner, preserving option b2's FIFO and keeping the
  execution-permit limit separate from the run-process cap.

## Admission inventory

This is the canonical inventory for the router-to-native-executor path, including
its executor-internal and named-node gates. Counts are per VM unless stated
otherwise. A process cap, execution cap, queue bound and uniqueness fence serve
separate purposes; none should be described as a substitute for the others.

| Gate / owner | Key | Default / population | Saturation behavior and purpose |
| --- | --- | --- | --- |
| `RunOrchestrator` admission mailbox and durable identity | Global mailbox; fixed `run_id` identity | One GenServer; mailbox has no admission count cap; one 20 s call window for submit, abort, native follow-up, lifecycle-fence and presence calls | Serializes submissions; identical retries replay the original receipt, conflicting reuse is rejected. The caller fixes the run ID before calling; a call that outlasts the window returns `:outcome_unknown` for that request only. Native follow-up issuer callbacks, durable-receipt compaction and presence table reads run outside the mailbox. Durable uncertainty is not retry permission. |
| Session lifecycle fence (`LemonCore.LifecycleFenceStore`, owned by `RunOrchestrator`) | `session_key` | One durable row per session; `"held"` while `sessions.reset`/`sessions.delete` or one `sessions.prune` deletion runs | Taken through the admission mailbox by an owner scoped to the operation, not the caller, so earlier admissions are visible to `LemonRouter.run_presence/1`. A busy session refuses the operation. While held, every router admission mode, idle native follow-ups and remote `coding_agent.run` dispatch are refused with `:session_lifecycle_in_progress`; paths outside router admission register in `LemonCore.SessionActivity` for their lifetime. |
| `SessionCoordinator` / `SessionTransitions` | Explicit resume: `{:resume, engine, token}`; otherwise `{:session, session_key}` | One active run; pending backlog 128 submissions, 1 MiB prompt text, 16 MiB encoded image data | `:session_queue_full` without queue mutation or interrupting the active run. Owns collect/followup/steer/interrupt semantics. |
| `SessionCoordinatorSupervisor` | Distinct conversation key | Uncapped population; no idle-stop path | Coordinators are never stopped merely because idle. Processes accumulate per distinct conversation for the VM lifetime; bounded individual backlogs do not bound total memory. |
| Router `RunSupervisor` / `RunRegistry` | Global; unique `run_id` | `:lemon_router, :run_process_limit`, 500; one live owner per run ID | Supervisor `:max_children` becomes `:run_capacity_reached`. Includes owners waiting for permits, not just executing runs. |
| Router `RunProcess` / `SessionRegistry` | `session_key` | One live owner per session | `:session_busy`; coordinator retains/requeues work behind the surviving owner. Process death releases the name. |
| Router output coalescers (`CoalescerSupervisor` / `CoalescerRegistry`, `ToolStatusSupervisor` / `ToolStatusRegistry`) | `{session_key, channel_id}` answer stream; `{session_key, channel_id}` status and `{session_key, channel_id, {:status_task, action_id}}` task surfaces | Started lazily by the first delta or action, never just to finalize; a process lives while its run streams plus a 5,000 ms idle retirement grace (`:lemon_router, :coalescer_retire_after_ms`) | A coalescer stops normally once idle for the grace and its run is finalized, never started, or has no live `RunProcess` (task surfaces: no live async subscriber), so the population is bounded by live runs and their task surfaces, not by conversations seen. An unreadable producer registry keeps the coalescer (fail closed). Finalizing drops the run's text and actions. Per process: mailbox 256 messages, 65,536 encoded bytes per admitted message, retained answer tail capped at that same per-message budget, at most 64 retained status actions per segment with only rendering/failure detail kept. |
| Router `EngineSessionClaim` / `EngineSessionRegistry` | `{:engine_session, {:resume, token}}`, otherwise `{:engine_session, {:session, session_key}}` | One owner per key, including while waiting for capacity | Fail-fast `:session_in_use`; no claim queue or timeout and no permit held by a contender. |
| Router `Slots` | Global permits; waiter identity `run_id` and owner pid | 2 executing runs; FIFO waiters are bounded by the run-process cap, with no separate duration cap | Wait asynchronously until grant/cancel/death. A run blocked on its own `agent` children (sync run or join) lends its permit with `suspend/2` and re-enters at the front on `resume/3`. ETS stats expose `in_flight` (lent permits excluded), `waitq`, `max`. |
| `CodingAgent.LaneQueue` | Lane | `:coding_agent, :lane_caps`: background_exec launch cap (the only lane) | FIFO within each lane. This executor-internal capacity is independent of top-level permits. |
| Background lane admission / `ProcessManager` | Background execution identity | Pending limit 32, admission deadline 5,000 ms by default | Rejects overload and expires pending launches; separate from router permit waiting. See [background process settings](../config.md). |
| `CodingAgent.TaskSemaphore` / `Parallel.Semaphore` | Global task work | `:coding_agent, :task_max_concurrency`, 8 | Blocks FIFO until a semaphore slot is released; in-process subagents do not each consume a top-level permit. |
| `BudgetTracker` / `BudgetEnforcer` | Parent run | Default delegated-child budget 5 (`LEMON_BUDGET_MAX_CHILDREN`); inherited authority can narrow it | `:max_children_exceeded` rejects a child; budget admission is separate from task scheduling capacity. |
| `LemonAi.CallDispatcher.Slots` | Provider | 10 requests per provider; queue timeout 120,000 ms | FIFO; `:max_concurrency` on expiry (0 timeout is fail-fast), `:admission_unavailable` when authority is unavailable. There is no dispatcher-global concurrency slot. |
| Named-node `ExecutionNode.Worker` | Destination-local `run_id` | One live invocation per run ID | `:run_already_active` rejects a duplicate invocation. The controller run takes exactly one router permit; destination task/provider limits remain local. |

The provider dispatcher also checks circuit state and provider rate limits; their
`:circuit_open` and `:rate_limited` failures are not execution-capacity failures.
Tool-specific resource limits are not additional top-level conversation queues.

Source anchors for review (paths relative to the repository root):

- `apps/lemon_router/lib/lemon_router/{run_orchestrator,session_coordinator,session_transitions,session_coordinator_supervisor,run_starter,run_process,application}.ex`
- `apps/lemon_router/lib/lemon_router/{coalescer_ingress,stream_coalescer,tool_status_coalescer}.ex`
- `apps/lemon_router/lib/lemon_router/{slots,engine_session_claim,run_completion}.ex`
- `apps/lemon_core/lib/lemon_core/config/gateway.ex`
- `apps/coding_agent/lib/coding_agent/{application,lane_queue,parallel,budget_tracker,budget_enforcer,process_manager}.ex`
- `apps/coding_agent/lib/coding_agent/execution_node/worker.ex`
- `apps/lemon_ai/lib/lemon_ai/call_dispatcher.ex` and `call_dispatcher/slots.ex`

## Acceptance, cancellation and named nodes

- **#78 acceptance:** router's durable receipt remains the acceptance authority.
  Starting a run owner is not proof that its executor ran. Accepted work that
  never executes still receives a terminal receipt.
- **#79 idempotency:** router retains the durable fixed-ID request identity;
  its `RunRegistry` prevents simultaneous duplicate owners. The `RunStore`
  terminal fence prevents late execution of already-terminal work.
- **#80 queued cancellation:** cancel the exact Run and remove its waiter. A late
  permit grant is fenced before executor start. Running cancellation retains
  capacity until executor termination/drain, rather than oversubscribing tools.
- **#81 unknown outcomes:** durable admission/store uncertainty and external
  executor effects cannot be treated as definite non-execution. Adopt an owner
  found under the fixed run ID after ambiguous startup. An owner that exits
  while waiting for a permit still terminalizes once and releases its conversation.
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
report moved code separately rather than claiming it vanished.

For latency, saturate two slots with independently controlled executions and
submit a third conversation. Repeat enough trials to report sample count and
p50/p95 for orchestrator submit, coordinator submit, permit wait, child start,
and cancel-to-terminal. Use monotonic timestamps at those boundaries; child
start acknowledgement is not executor start, and queue time must not be hidden
inside executor duration. Separate queued cancellation from running cancellation,
record failures/timeouts, and verify exactly one terminal receipt and zero
executor invocations for canceled waiters.

Sample live run owners, coordinators and permit counters throughout. When
comparing historical revisions, also count their gateway run and worker
processes. Exercise repeated and continually new conversation keys to expose
coordinator population growth. Add duplicate fixed-ID, shared-token contention,
terminal-before-start, owner-death and named-node trials; check one controller
permit per remote run.

`Slots.stats/0` is an ETS snapshot, not a per-run wait histogram. The removed
scheduler telemetry is not emitted by Slots. Instrument the boundaries in a
controlled measurement harness if wait distributions are needed; do not invent
percentiles from aggregate snapshots. Never include prompts, resume tokens or
credentials in measurement artifacts.
