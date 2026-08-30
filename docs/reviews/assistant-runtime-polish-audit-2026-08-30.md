# Assistant Runtime Polish Audit

Last reviewed: 2026-08-30

This review focuses on Lemon as an assistant runtime: skills, turns, background
work, native tasks, delegated agents, async followups, and the state surfaces
that let a parent session observe or join work.

## Outcome of this pass

Four low-risk correctness and noise fixes were small enough to land directly:

1. Native async task launch now checks `Task.Supervisor.start_child/2`. A failed
   launch returns an error and terminalizes `TaskStore`, `RunGraph`, budget,
   lifecycle-event, and progress-binding state instead of returning a receipt
   that remains queued forever.
2. Async delegated-agent runs now register their router run ids in `RunGraph`.
   Their completion watcher advances both `RunGraph` and `TaskStore`, so
   `agent action=join` waits for production-path work instead of treating a
   missing graph entry as terminal.
3. Explicit agent joins suppress automatic completion followups, and task/agent
   followup dispatch contains process exits after terminal state is recorded.
4. `LaneQueue` consumes a completed task monitor before removing its index
   entry, eliminating the duplicate normal `:DOWN` warning and lookup pass for
   every successful lane job.

Regression coverage exercises failed supervised launches, production-path
agent joins, followup suppression, exit containment, and successful lane
monitor cleanup.

## Follow-up state-consistency pass

The task-state stores now enforce the single-writer boundaries assumed by the
tool lifecycle:

- `TaskStoreServer` serializes record updates, bounded event appends, explicit
  join suppression, and lifecycle transitions. Terminal status and payload are
  first-writer-wins, repeated completion is idempotent, and late running
  updates cannot revive a terminal task.
- `RunGraphServer` loads DETS synchronously during `init/1` and serializes
  initial inserts and deletes. No caller can observe readiness or enqueue a
  live write that a later startup fold overwrites.
- `BudgetTracker` performs token/cost increments inside one serialized
  RunGraph mutation. Child ids reserve `max_children` capacity atomically, and
  completion releases/aggregates each child once even when callbacks race.
- Native task execution treats a failed child reservation as a launch failure;
  the preflight capacity check remains advisory, while the reservation is the
  admission authority.

Barrier-based regressions cover exact event retention, finish/fail/suppression
interleavings, exact high-concurrency token and cost sums, `max_children: 1`,
idempotent completion aggregation, and DETS-load/live-write ordering.

## Coordination and local scheduling follow-up

- Parent-question creation and terminal transitions now use a serialized
  owner. Exact parent session plus agent authorization replaces nil/wildcard
  matching, and concurrent answer/timeout/cancel races emit one terminal event.
- `Session.deliver_parent_question/2` starts idle parent turns. Matching task or
  agent joins poll the question store and yield `needs_parent_answer`, avoiding
  a parent/child clarification deadlock while preserving the visible question.
- Join followup suppression is a transient reservation until the outcome is
  known. `wait_any` keeps only the completed winner suppressed; aborted,
  failed, unknown, and clarification-interrupted joins release reservations.
- `LaneQueue` monitors queued callers, removes abandoned jobs, and contains
  task-supervisor admission failures. `ProcessManager` catches queue call exits
  before taking its direct-execution fallback.
- A delegated completion watcher timeout now records `tracking_lost` locally,
  leaves a still-running router run authoritative, and performs bounded
  reconciliation so a late success can still become terminal.

## Independent chaos-review findings

Two additional state races were confirmed and fixed:

- Kanban task leasing and lease-guarded terminal transitions previously used a
  store read followed by a separate store write. In a 64-contender barrier
  probe against one task, 10 repeated rounds produced between 1 and 31
  successful leases for that single task. Board-scoped mutation locks now make
  lease selection, lease validation, reclaim, completion, failure, comments,
  and task updates one serialized read-modify-write boundary. A deterministic
  64-contender regression asserts exactly one lease winner.
- Explicit task/agent joins previously persisted transient suppression tokens
  without associating them with the joining process. A crashed joiner, or a
  store restart that reloaded its token, could suppress the automatic terminal
  followup forever. `TaskStoreServer` now owns join reservations atomically,
  monitors their owners, releases them on `:DOWN`, and discards stale
  reservations during DETS recovery. Both join tools also release reservations
  in `after` blocks. A process-death regression verifies cleanup.

One cross-owner race remains open because its complete fix belongs at the
router run-ownership boundary:

- A hard GoalLoop stop can land after the router accepted a run but before
  `RunCompletionWaiter` invokes `on_submitted`. At that point
  `GoalLoopManager` still has `active_run: nil`; it kills the loop task and
  records `stopped` without calling `abort_run/2`, while the accepted router
  run remains live. A deterministic probe used a loop module that reported
  router acceptance and paused immediately before `on_submitted`. The observed
  result was `active_run_id: nil`, `abort_result: :no_abort`, and a successful
  hard-stop reply. The production sequence has the same window:
  `router.submit/1` returns `{:ok, run_id}` before `notify(on_submitted, run_id)`
  records the ID in the manager. Closing it requires an abort tombstone or an
  atomic submit/ownership handshake in the router lifecycle, so an abort that
  arrives before ownership publication also cancels a just-accepted run.

## Next high-value improvements

### 1. Make async lifecycle ownership reusable

`CodingAgent.Tools.Task.Async` and `CodingAgent.Tools.Agent` both coordinate a
task record, run-graph record, supervised worker or watcher, terminal result,
and optional parent followup. Their implementations have already drifted in
launch-error handling, join registration, suppression, and exit containment.

The store now owns monotonic transitions, idempotent terminalization, and
followup suppression. A remaining extraction could centralize launch receipts
and supervised-start normalization without moving the serialized state rules
back into either tool. Task execution and router-delegated execution can remain
separate adapters.

### 2. Reconcile persisted work after a node restart

`TaskStore` and `RunGraph` persist records, but the processes that finish them
do not. A restarted node can therefore reload `queued` or `running` records
without recreating an agent completion watcher or native task worker. Agent
polling can sometimes promote a terminal router-store summary, but joins and
automatic followups are not systematically recovered.

Add a bounded boot reconciler that inspects non-terminal records, checks the
authoritative router/run store, terminalizes completed work, and marks
unrecoverable native workers as `lost`. Keep recovery idempotent and emit the
same lifecycle events as live completion.

### 3. Use one admission authority for subagent execution

Native async tasks currently acquire `CodingAgent.TaskSemaphore` and then wait
inside the `:subagent` `LaneQueue`. The effective concurrency is the lower of
two independently configured limits, and tasks can hold a semaphore slot while
waiting for a lane slot. This makes capacity and fairness difficult to reason
about.

Prefer `LaneQueue` as the single scheduling authority for interactive and
background lanes. Retain `Parallel.Semaphore` for standalone batch helpers that
do not enter a lane. Before removal, add a concurrency test that covers queue
ordering, cancellation, and separate lane progress.

### 4. Add an explicit caller-selected join timeout

Task and agent joins now poll the abort signal while waiting, reject unknown run
ids explicitly, and yield when a child clarification opens. They still have no
caller-selected timeout parameter. Add one with a documented default; timeout
must stop waiting and release transient followup reservations without changing
the child run's state.

### 5. Centralize the policy for background-task startup failure

Coordinator, compaction, cron, heartbeat, synthesis, and skill-curation paths
use similar supervised-start wrappers. Several silently fall back to
`Task.start/1` when their supervisor is missing. That keeps work moving but
also removes lifecycle ownership precisely when the supervision tree is
unhealthy.

Create one helper with an explicit policy per caller: `:fail`, `:degrade`, or
`:unsupervised_fallback`. Record fallback telemetry and reserve unsupervised
execution for work that is safe to abandon during shutdown or restart.

## Smaller cleanup opportunities

- The main `CodingAgent.SystemPrompt` uses cached skill relevance reads, while
  the older `CodingAgent.PromptBuilder` forces a project skill rescan for every
  non-empty context. Move refreshes to skill mutation and explicit reload
  boundaries, then make prompt construction consistently cache-first.
- Turn the repeated task/run/followup log fields into structured telemetry and
  lower per-job success logging to debug. This preserves diagnostics without
  making normal async throughput look anomalous.
- Add restart and cancellation contract tests spanning `TaskStore`,
  `RunGraph`, router `Store`, and the parent-session followup surface. Current
  unit tests are strong within each component but do not fully prove recovery
  across those persistence boundaries.
- Separate focused app test commands during local audits. Starting the full
  umbrella for a combined multi-path test run creates noisy automation timers,
  skill discovery logs, and shared test-resource contention that can obscure
  assistant-runtime regressions.

## Suggested sequence

1. Extract the shared lifecycle transition helper behind existing behavior.
2. Add restart reconciliation and recovery contract tests.
3. Remove the duplicate task semaphore after lane-level fairness tests pass.
4. Add abort-aware, bounded joins.
5. Consolidate background-start policy and skill refresh boundaries.

This sequence keeps the next changes independently reviewable and makes the
durable state model explicit before changing scheduling or cancellation.
