# LemonAutomation

Elixir app for cron jobs, heartbeats, and automation tasks in the Lemon umbrella.

## Purpose and Responsibilities

LemonAutomation provides scheduled and triggered automation for agents:

- **Cron Jobs** - Schedule agent prompts with cron expressions
- **Heartbeats** - Periodic health checks with smart suppression
- **Wake** - Immediate manual triggering of scheduled jobs
- **Goal Continuation** - Supervised one-shot continuation runs for active session goals
- **Goal Loop Preview** - One supervised judge tick that continues, completes, or pauses a goal
- **Kanban Dispatch** - Supervised leasing/reclaim loop for durable board tasks
- **Portable Blueprints** - Preview and explicitly confirm profile-local skill bundles plus one agent cron job
- **Run Tracking** - Full lifecycle tracking of job executions

## Supervision Tree

```
LemonAutomation.Supervisor (one_for_one)
+-- LemonAutomation.TaskSupervisor  (Task.Supervisor)
+-- LemonAutomation.CronManager     (GenServer)
+-- LemonAutomation.HeartbeatManager (GenServer)
+-- LemonAutomation.GoalContinuationManager (GenServer)
+-- LemonAutomation.GoalLoopManager (GenServer)
+-- LemonAutomation.KanbanDispatcher (GenServer)
+-- LemonAutomation.SkillCuratorManager (GenServer)
```

## Cron System Architecture

```
CronManager (GenServer, ticks every 60s)
    |
    +- on tick: finds due jobs, claims scheduled run slots
    |
    +- execute_job/2
           |
           +- creates CronRun, persists or claims it in CronStore
           +- emits :cron_run_started on "cron" bus
           +- spawns Task via TaskSupervisor
                  |
                  +- RunCompletionWaiter.submit_and_wait/2
                         |
                         +- reads CronMemory, injects into prompt
                         +- pre-subscribes to Bus.run_topic(run_id)
                         +- forks session_key into sub-session
                         +- calls LemonRouter.submit(params)
                         +- calls RunCompletionWaiter.wait_already_subscribed/3
                                |
                                +- returns its result through the monitored Task ref
                                           |
                                           +- CronManager updates CronStore, emits :cron_run_completed
                                           +- For `agent:*:main` base sessions, CronManager forwards a synthetic
                                              `:run_completed` summary into the base main session topic/history
```

**Wake** is a separate module (not intermediary in the above flow). It creates runs with `triggered_by: :wake`, submits directly to `LemonRouter`, and sends `{:run_complete, ...}` back to `CronManager`.

**CronCommandRunner** is the operator-owned no-agent cron path. Jobs with
`command` instead of `prompt` run as supervised local shell commands under
`CronManager`, persist output/error in `CronRun`, and never create LemonRouter
runs or channel summaries. Prompt jobs still require `agent_id`, `session_key`,
and `prompt`; command jobs require only `name`, `schedule`, and `command`.

**GoalContinuationManager** runs one active persistent-goal continuation at a
time through `TaskSupervisor`. `GoalContinuation` submits normal
`LemonRouter` requests with `origin: :goal`, `queue_mode: :followup`, and goal
metadata, then records the returned run id in `LemonAgent.Workspace.GoalStore`.

**GoalLoopManager** runs goal-loop work through `TaskSupervisor`. `run_once/2`
performs one preview judge tick. `start_loop/2` starts one bounded autonomous
loop per session, waits for each submitted continuation to emit `:run_completed`,
and stops at `max_ticks`, failure, timeout, or a terminal judge verdict. Passing
`auto: true` persists opt-in auto scheduling in `LemonAgent.Workspace.GoalStore`; the
manager scheduler scans active goals and re-starts only persisted auto loops
when no loop for that session is already running. Focused tests cover that
persisted-auto path through the real goal loop and router judge runner.
Before each judge or continuation submission, the manager synchronously claims
the fixed router run id from `RunCompletionWaiter`. `stop_loop/2` defaults to
hard stop: it disables auto restart, aborts that owned router run once, kills
the loop task, and prevents another tick. The router serializes an abort
tombstone with submission acceptance, so a stop cannot miss a run between
acceptance and the later submitted callback. `mode: :graceful` disables auto
restart but lets the already bounded loop finish. The outer `run_once/2` call
timeout encloses the configured judge/continuation wait deadlines.

The hard-stop result reports a sanitized `router_abort` status. It sends the
abort exactly once: `:outcome_unknown` means the abort may already have taken
effect, so the manager does not retry it; arbitrary callback errors and
exceptions never enter stored goal metadata or returned diagnostics.

An ambiguous judge or continuation submission remains owned by its
caller-generated run ID while the waiter reconciles terminal events. If that
bounded wait also expires, the manager retains the loop in `reconciling` state
so another tick cannot overlap it. A durable terminal record releases that
guard into an error state requiring an explicit restart. A hard stop aborts
that exact run once; only a definite abort acceptance releases the guard, while
an ambiguous or unavailable abort keeps reconciliation ownership. Persisted
reconciliation and abort-attempt metadata restore that guard after a manager
restart without retrying the abort.

`GoalJudge` supports explicit verdicts, a pluggable `judge_runner` with
`judge_model` metadata, and deterministic fallback. `GoalJudge.RouterRunner`
is the dev/prod default runner; it submits isolated `:goal_judge` runs through
`LemonRouter`, waits for completion, and parses JSON verdicts. The focused
goal-loop tests prove this path through the real router, a router `RunProcess`,
and `RunCompletionWaiter` using a deterministic runtime. Set
`LEMON_GOAL_JUDGE_MODEL` to pin the model used for default judge runs. Judge
failures pause goals by default;
`judge_failure_policy: :continue_once` is the explicit fail-open path for one
continuation.

All automation paths that submit and then wait use
`RunCompletionWaiter.submit_and_wait/2`. It assigns a fixed run id and owns the
subscription from before router submission through terminal wait cleanup.
Goal loops also use its synchronous pre-submit ownership claim; a rejected
claim prevents the router call entirely.
Router run-id mismatches are explicit errors; callers never subscribe to a
replacement id after submission because a synchronous completion could already
have been lost. Cron, goal judge, autonomous goal continuation, timer heartbeat,
and Kanban worker paths share this lifecycle.

**KanbanDispatcher** is the first BEAM-native fleet-work supervisor. It scans
durable `LemonAgent.Workspace.KanbanStore` boards, reclaims expired leases, leases
dependency-unblocked tasks to a worker profile, runs a worker module through
`TaskSupervisor`, then records completion or failure back into the durable task.
Focused dispatcher tests cover bounded multi-worker leasing, completion,
explicit failure, crashed-worker failure marking, expired-lease reclaim, and a
production-shaped bounded-concurrency path through the real `KanbanRunWorker`
with router/waiter stubs. The default `KanbanRunWorker` submits leased tasks
through `LemonRouter` with `origin: :kanban`, board/task metadata, a blocked
`kanban` tool policy, and an isolated git worktree cwd when the board workspace
is a git repository. Worktrees are created under
`<repo>/.worktrees/kanban-<task_id>` on `lemon-kanban/<task_id>` branches, so
concurrent board workers do not edit the same checkout.
`stop_board/2` is a hard stop: owned worker pids are killed and their exact
lease IDs are reclaimed before return. Completion/failure writes are guarded by
lease ID, so late results cannot mutate a re-leased task. Starting a board also
reclaims unexpired leases left by the same dispatcher worker id after restart.

**HeartbeatManager** subscribes to the "cron" bus and auto-processes every `:cron_run_completed` event for suppression checks.

**SkillCuratorManager** is the idle-triggered background path for learned-skill
maintenance. It checks active router sessions every minute, waits for the
configured idle window, then calls `LemonAutomation.SkillCurator`. That module
delegates lifecycle transitions and prompt rendering to `LemonSkills.Curator`
and submits the review prompt to `LemonRouter` only when review is required.

**Blueprint** is the portable distribution boundary for a coherent skill plus
automation workflow. It reuses `LemonSkills.Bundle`, manifest/lint/audit, the
derived `LemonCore.ProfileStore` workspace, and `CronManager`; do not add a
second skill registry, profile store, or scheduler. A preview digest binds the
manifest, content hashes, target profile, exact job projection, and current
collision state. Activation replans under a lock, stages and re-audits exact
copied bytes, enables profile-local skills, and calls `CronManager.add_new/1`
last. The create-once manager/store path must never overwrite an existing
stable ID. Version 1 remains agent-prompt-only and rejects commands, archives,
symlinks, environment/cwd overrides, secret-like values, and non-UTC schedules.
`LemonAutomation.Blueprint.Catalog` is the shared caller boundary for Web and
control-plane clients: it derives the canonical catalog path from trusted
profile options, accepts only bounded bundle IDs, rejects traversal and
symlinked entries, enforces manifest/directory identity, and delegates all
inspection, validation, preview, and activation semantics to `Blueprint`.

## Key Flow Details

- `RunSubmitter` pre-subscribes to `Bus.run_topic(run_id)` BEFORE submitting to `LemonRouter` (avoids race condition)
- `RunSubmitter` passes `run_id` in params so the router uses the same ID it already subscribed to
- `RunSubmitter` executes each cron run in a forked `:sub:<id>` session for isolation; the originating base session is preserved in run metadata
- `RunSubmitter` adds a cron-run tool policy with `blocked_tools: ["cron"]`; scheduled runs may do the task work, but they cannot recursively manage cron jobs through a cron tool
- `RunSubmitter` reads `CronMemory` for the job and injects memory context into the prompt, then appends run results back to the memory file
- If the router returns a different `run_id`, submission fails explicitly; no late replacement-id subscription is attempted
- Output is truncated to 1000 chars before storage
- Jobs execute in monitored `TaskSupervisor.async_nolink/2` tasks owned by `CronManager`; task-start failure and `:DOWN` terminalize the run immediately. Unsupervised fallback exists only when the manager is started with explicit `standalone_mode: true`.
- For cron jobs created from `agent:*:main`, completion summaries are mirrored back into the base main session as synthetic `run_completed` entries (`meta.cron_forwarded_summary = true`)
- Scheduled ticks and `CronManager` restarts consult persisted active runs before launching; active runs older than the job timeout recover through the same monitor/delivery/retry terminalizer as normal completions.
- Scheduled runs use deterministic slot ids and `CronStore.claim_scheduled_run/3`, backed by `LemonCore.Store.put_new/3`, so competing dispatchers preserve the first claimant instead of overwriting a run.
- `scripts/live_cron_runtime_restart_smoke.exs` boots `:runtime_full` twice against one isolated durable store, then proves a scheduled run before restart, persisted job/run history after restart, and a fresh scheduled run after restart.
- `scripts/live_cron_channel_origin_smoke.exs` registers proof-only Telegram and Discord plugins, completes channel-peer cron runs through `CronManager`, and proves forwarded run history plus `LemonRouter.ChannelsDelivery` -> `LemonChannels` outbox delivery with redacted proof metadata.
- Scheduled failures/timeouts persist retry due time, attempt, source, and root lineage on the terminal source run. Restart reconstructs the timer, while a deterministic `{root, attempt}` retry-run ID and atomic claim prevent duplicate attempts. Manual and wake runs stay single-shot by default.
- Active cron runs can be aborted by cron run id. `CronManager.abort_run/1` calls the underlying router cancellation when possible, persists terminal `:aborted`, emits the normal completion event, and ignores late submitter completions.
- Cron lifecycle actions write durable operator audit events to `:cron_audit_events`. The audit stream covers job create/update/pause/resume/delete, manual run requests, run start/abort/retry/stale recovery, and scheduled-run claim/suppression decisions. Audit entries keep operator-useful IDs in the store; support-bundle diagnostics redact those IDs.
- `cron.status` reads the durable cron run and audit stores directly for operator-facing scheduler-health counters: active run locks, retry runs, suppressed scheduled slots, stale-run recoveries, scheduled retries, and next/last run timestamps.
- Portable bundle activation must remain preview-first and content-free at the
  Web/control-plane boundary. Keep arbitrary paths local-only;
  `Blueprint.Catalog` resolves a safe `bundleId` below `~/.lemon/bundles`,
  returns no prompt/skill/path/secret text,
  and requires the exact fresh `confirmationDigest` for mutation.
- Source and packaged `lemon blueprints` are thin clients of that RPC boundary.
  Do not move bundle loading or scheduler startup into the one-shot CLI VM;
  preview remains the bundle-ID shorthand and activation remains an explicit
  exact-digest request handled by the long-running `CronManager` runtime.

## Top-Level Facade

`LemonAutomation` module provides delegating functions:

```elixir
LemonAutomation.list_jobs()           # delegates to CronManager.list/0
LemonAutomation.add_job(params)       # delegates to CronManager.add/1
LemonAutomation.update_job(id, params) # delegates to CronManager.update/2
LemonAutomation.remove_job(id)        # delegates to CronManager.remove/1
LemonAutomation.run_now(id)           # delegates to CronManager.run_now/1
LemonAutomation.abort_run(run_id)     # delegates to CronManager.abort_run/1
LemonAutomation.runs(job_id, opts)    # delegates to CronManager.runs/2
LemonAutomation.wake(job_id)          # delegates to Wake.trigger/1
```

## How to Add a Cron Job

### Basic Job

```elixir
{:ok, job} = LemonAutomation.CronManager.add(%{
  name: "Daily Report",
  schedule: "0 9 * * *",        # 9 AM daily
  agent_id: "agent_abc",
  session_key: "agent:agent_abc:main",
  prompt: "Generate daily status report"
})
```

### Command Job

```elixir
{:ok, job} = LemonAutomation.CronManager.add(%{
  name: "Disk Usage Snapshot",
  schedule: "hourly",
  command: "df -h /",
  cwd: "/tmp"
})
```

### With Timezone and Jitter

```elixir
{:ok, job} = LemonAutomation.CronManager.add(%{
  name: "Hourly Check",
  schedule: "0 * * * *",
  agent_id: "agent_abc",
  session_key: "agent:agent_abc:main",
  prompt: "Check system status",
  timezone: "America/New_York",  # Default: "UTC"
  jitter_sec: 30,                # Random 0-30s delay before execution
  max_retries: 2,                # Scheduled failure/timeout retries
  retry_backoff_ms: 60_000       # Delay before each retry
})
```

### With Persistent Memory

```elixir
{:ok, job} = LemonAutomation.CronManager.add(%{
  name: "Weekly Summary",
  schedule: "0 9 * * 1",
  agent_id: "agent_abc",
  session_key: "agent:agent_abc:main",
  prompt: "Generate weekly summary using notes from previous runs",
  memory_file: "/path/to/custom/memory.md"  # Optional; auto-generated if omitted
})
```

### Required Fields

| Field | Description |
|-------|-------------|
| `name` | Human-readable identifier |
| `schedule` | Cron expression (5 fields) or supported shorthand |
| `agent_id` | Target agent for prompt jobs |
| `session_key` | Routing key for prompt jobs (e.g., `"agent:{id}:main"`) |
| `prompt` | Text sent to agent; mutually exclusive with `command` |
| `command` | Local shell command for no-agent operator jobs |

Updates preserve target type. Prompt jobs can update `prompt`; command jobs can
update `command`, `cwd`, and `env`; `agent_id` and `session_key` stay immutable.

### Optional Fields

| Field | Default | Description |
|-------|---------|-------------|
| `enabled` | `true` | Whether the job is active |
| `timezone` | `"UTC"` | Timezone for schedule interpretation |
| `jitter_sec` | `0` | Random delay spread in seconds |
| `timeout_ms` | `300_000` | Max execution time (5 minutes) |
| `max_retries` | `0` | Number of retries after scheduled failure/timeout |
| `retry_backoff_ms` | `30_000` | Delay before retry runs |
| `cwd` | runtime cwd | Command working directory |
| `env` | `%{}` | Command environment overrides |
| `memory_file` | auto | Path to persistent cross-run memory file |
| `meta` | `nil` | Arbitrary metadata map |

### Cron Expression Format

```
* * * * *
| | | | +-- Day of week (0-7, 0/7 = Sunday)
| | | +---- Month (1-12)
| | +------ Day of month (1-31)
| +-------- Hour (0-23)
+---------- Minute (0-59)
```

Supported cron syntax: `*`, `N`, `N-M` (range), `*/N` (step), `N,M,O` (list).

Supported shorthands are normalized into 5-field cron expressions before
storage. Interval shorthands must map cleanly to cron step fields, so minute
intervals divide 60 and hour intervals divide 24:

- `"every 30m"`, `"15 minutes"` -> `"*/30 * * * *"`, `"*/15 * * * *"`
- `"hourly"`, `"every 2h"` -> `"0 * * * *"`, `"0 */2 * * *"`
- `"daily at 9am"`, `"every day at 17:45"` -> `"0 9 * * *"`, `"45 17 * * *"`
- `"weekdays at 09:30"` -> `"30 9 * * 1-5"`
- `"weekly monday at 8am"`, `"fridays at 18:15"` -> `"0 8 * * 1"`, `"15 18 * * 5"`

Examples:
- `"*/15 * * * *"` - Every 15 minutes
- `"0 9 * * 1"` - Mondays at 9 AM
- `"0 */6 * * *"` - Every 6 hours

### Managing Jobs

```elixir
# List all jobs (sorted by created_at_ms desc)
LemonAutomation.CronManager.list()

# Update a job (agent_id and session_key are immutable; attempts return {:error, {:immutable_fields, [...]}})
LemonAutomation.CronManager.update(job.id, %{enabled: false})

# Remove a job (also clears heartbeat config if job has meta.heartbeat: true)
LemonAutomation.CronManager.remove(job.id)

# Run immediately (manual trigger, job must exist but disabled jobs still work)
LemonAutomation.CronManager.run_now(job.id)

# Get run history
# opts: limit (default 100), status (atom filter), since_ms (timestamp filter)
LemonAutomation.CronManager.runs(job.id, limit: 10)

# Force a tick cycle (for testing)
LemonAutomation.CronManager.tick()  # cast, returns :ok immediately
```

## CronJob Struct

```elixir
%LemonAutomation.CronJob{
  id: "cron_abc123",           # auto-generated via LemonCore.Id.cron_id()
  name: "Daily Report",
  schedule: "0 9 * * *",
  enabled: true,
  agent_id: "agent_abc",
  session_key: "agent:agent_abc:main",
  prompt: "Generate daily status report",
  memory_file: nil,            # auto-generated path if nil
  timezone: "UTC",
  jitter_sec: 0,
  timeout_ms: 300_000,
  max_retries: 0,
  retry_backoff_ms: 30_000,
  created_at_ms: 1739989200000,
  updated_at_ms: 1739989200000,
  last_run_at_ms: nil,
  next_run_at_ms: 1739989200000,
  meta: nil
}
```

Key functions: `CronJob.new/1`, `CronJob.update/2`, `CronJob.due?/1`, `CronJob.mark_run/2`, `CronJob.set_next_run/2`, `CronJob.to_map/1`, `CronJob.from_map/1`.

## CronRun Struct and State Machine

```elixir
%LemonAutomation.CronRun{
  id: "run_abc123",            # auto-generated via LemonCore.Id.run_id()
  job_id: "cron_xyz789",
  run_id: nil,                 # LemonRouter run ID (set after submission)
  status: :pending,            # :pending | :running | :completed | :failed | :timeout | :aborted
  triggered_by: :schedule,    # :schedule | :manual | :wake | :retry
  started_at_ms: nil,
  completed_at_ms: nil,
  duration_ms: nil,
  output: nil,                 # truncated to 1000 chars
  error: nil,
  suppressed: false,           # true if heartbeat with "HEARTBEAT_OK" response
  meta: nil
}
```

State transitions:
```
CronRun.new(job_id, triggered_by)    => status: :pending
CronRun.start(run, run_id \\ nil)   => status: :running
CronRun.complete(run, output)        => status: :completed
CronRun.fail(run, error)             => status: :failed
CronRun.timeout(run)                 => status: :timeout
CronRun.abort(run, reason)           => status: :aborted
CronRun.suppress(run)                => suppressed: true (can combine with any terminal state)
```

Helper predicates: `CronRun.active?/1` (pending or running), `CronRun.finished?/1`.

Scheduled failures and timeouts retry only when `max_retries > 0`. The terminal
source run persists `retry_due_at_ms`, `retry_next_attempt`, `retry_of`, and
`retry_root_id`; each claimed retry is a separate run with
`triggered_by: :retry`. Deterministic retry IDs make one root/attempt pair a
stable uniqueness slot across manager restarts. Manual and wake-triggered runs
do not retry by default.

## CronMemory (Persistent Cross-Run Memory)

Each cron job can have a persistent markdown memory file that accumulates context across runs:

- Default location: `~/.lemon/cron_memory/{job_id}.md`
- Configurable via `memory_file` field on the job or `meta.memory_file`/`meta.memoryFile`
- On each run, `RunSubmitter` reads the memory file and injects it into the prompt
- After each run, the result is appended to the memory file
- Auto-compaction kicks in at 24,000 chars: older content is summarized, recent 14,000 chars retained
- Prompt injection limited to 8,000 chars (tail of file)

## Heartbeat Management

Cron-backed heartbeats are special cron jobs for agent health checks; intervals
that cron cannot represent exactly use the timer path documented below.
Responses containing exactly `"HEARTBEAT_OK"` (trimmed) are suppressed from
channels but still logged.

### Identifying Heartbeat Jobs

A job is treated as a heartbeat if:
- Its `name` contains `"heartbeat"` (case-insensitive), OR
- Its `meta` has `heartbeat: true` (atom key only - string key `"heartbeat"` is NOT matched by `heartbeat?/1`)

### Creating a Heartbeat via CronManager

```elixir
{:ok, job} = LemonAutomation.CronManager.add(%{
  name: "heartbeat-agent-abc",   # name contains "heartbeat"
  schedule: "*/5 * * * *",
  agent_id: "agent_abc",
  session_key: "agent:agent_abc:heartbeat",
  prompt: "HEARTBEAT"
})
```

### HeartbeatManager API

```elixir
# Check if job is a heartbeat (checks name and meta[:heartbeat])
LemonAutomation.HeartbeatManager.heartbeat?(job)

# Check response health (exact "HEARTBEAT_OK" match after trimming)
LemonAutomation.HeartbeatManager.healthy_response?(response)

# Process a completed run's response - called automatically on :cron_run_completed events
# Returns {:ok, suppressed?}
LemonAutomation.HeartbeatManager.process_response(run, response)

# Get suppression stats (%{total_heartbeats, suppressed, alerts})
LemonAutomation.HeartbeatManager.stats()

# Get persisted heartbeat config for an agent (reads :heartbeat_config store)
LemonAutomation.HeartbeatManager.get_config(agent_id)

# Get last heartbeat result for an agent (reads :heartbeat_last store)
# Returns %{timestamp_ms, status: :ok | :alert, response, suppressed, run_id, job_id}
LemonAutomation.HeartbeatManager.get_last(agent_id)

# Update heartbeat configuration - called by set-heartbeats control plane method
# Creates/updates/disables a cron job for the agent
LemonAutomation.HeartbeatManager.update_config(agent_id, %{
  enabled: true,
  interval_ms: 300_000,
  prompt: "HEARTBEAT"
})
```

### Sub-Minute Heartbeats (Timer-Based)

Intervals that cannot be represented exactly by a five-field cron expression
use Erlang timers instead of cron jobs. This includes sub-minute values and
longer values such as 90 minutes or 5 hours. Timer heartbeats create synthetic
run IDs (`"timer-heartbeat-{agent_id}-{timestamp}"`), submit through the shared
race-free submit-and-wait lifecycle, and broadcast events on the "cron" bus.
They do NOT create `CronJob` or `CronRun` records in `CronStore`; terminal status,
router run id, response, and suppression state are persisted in
`HeartbeatStore`.

```elixir
LemonAutomation.HeartbeatManager.update_config("agent_abc", %{
  enabled: true,
  interval_ms: 30_000,  # 30 seconds - uses timers, not cron
  prompt: "HEARTBEAT"
})
```

### Heartbeat Schedule Selection

`HeartbeatManager` chooses cron only when the interval stays exact at UTC day
boundaries: minute intervals must divide 60, hour intervals must divide 24, and
24 hours maps to daily midnight UTC. Every other positive interval falls back
to an exact Erlang timer. Invalid non-positive intervals return
`{:error, :invalid_interval}`. Cron-to-timer transitions disable the cron job;
timer-to-cron transitions cancel the timer before enabling or updating the cron
job with mutable fields only.

Only one timer run may be in flight per agent. A tick that overlaps an active
run is skipped, increments `stats().skipped_overlap`, logs the skip, and records
`[:lemon, :heartbeat, :skipped]` telemetry with `reason: :overlap`.

### Heartbeat Suppression Behavior

- Suppressed responses: NOT broadcast to channels, ARE logged to run history, emit `:heartbeat_suppressed` event
- Non-OK responses: NOT suppressed, emit `:heartbeat_alert` event with `severity: :warning`
- After suppression check, `HeartbeatManager` stores result in `:heartbeat_last` store keyed by `agent_id`

## Wake Functionality

Wake triggers immediate job execution outside the normal schedule.

```elixir
# Trigger single job (must be enabled, returns {:error, :job_disabled} otherwise)
{:ok, run} = LemonAutomation.Wake.trigger("cron_abc123")

# Trigger with context (stored in run.meta.wake_context)
{:ok, run} = LemonAutomation.Wake.trigger("cron_abc123",
  context: %{reason: "incident response"}
)

# Skip if already running (checks CronStore.active_runs/1)
{:ok, run} = LemonAutomation.Wake.trigger("cron_abc123",
  skip_if_running: true
)
# Returns {:error, :already_running} if active runs exist

# Trigger multiple jobs (returns map of job_id => result)
results = LemonAutomation.Wake.trigger_many(["cron_abc", "cron_xyz"])

# Trigger by name pattern (case-insensitive substring match on enabled jobs)
results = LemonAutomation.Wake.trigger_matching("heartbeat")

# Trigger all enabled jobs for an agent
results = LemonAutomation.Wake.trigger_for_agent("agent_abc")
```

Wake runs use `triggered_by: :wake` and fire-and-forget: they return the `CronRun` immediately and completion is handled asynchronously by `CronManager`. Wake failures do not enter the scheduled retry path.

## Events

All events are broadcast on the `"cron"` bus topic as `%LemonCore.Event{}` structs.

### Event Types

| Event | Emitted By | When |
|-------|-----------|------|
| `:cron_tick` | `CronManager` | Every 60s tick |
| `:cron_job_created` | `CronManager` | Job added |
| `:cron_job_updated` | `CronManager` | Job updated |
| `:cron_job_deleted` | `CronManager` | Job removed |
| `:cron_run_started` | `CronManager`, `Wake`, `HeartbeatManager` | Run begins |
| `:cron_run_completed` | `CronManager`, `HeartbeatManager` | Run finishes |
| `:cron_lifecycle_action` | `CronManager` | Durable audit event recorded |
| `:heartbeat_suppressed` | `HeartbeatManager` | "HEARTBEAT_OK" response |
| `:heartbeat_alert` | `HeartbeatManager` | Non-OK heartbeat response |

### Subscribing to Events

```elixir
LemonCore.Bus.subscribe("cron")

receive do
  %LemonCore.Event{type: :cron_run_started, payload: payload} ->
    IO.puts("Run started: #{payload.run.id}")

  %LemonCore.Event{type: :cron_run_completed, payload: payload} ->
    IO.puts("Run completed: #{payload.run.status}, suppressed: #{payload.suppressed}")

  %LemonCore.Event{type: :cron_lifecycle_action, payload: payload} ->
    IO.puts("Audit action: #{payload.audit.action}")

  %LemonCore.Event{type: :heartbeat_suppressed, payload: payload} ->
    IO.puts("Heartbeat OK for job #{payload.job_id}")

  %LemonCore.Event{type: :heartbeat_alert, payload: payload} ->
    IO.puts("Heartbeat alert for agent #{payload.agent_id}: #{payload.response}")
end
```

## CronStore API

```elixir
# Jobs (tables: :cron_jobs)
CronStore.put_job(job)
CronStore.get_job(job_id)
CronStore.delete_job(job_id)
CronStore.list_jobs()           # all jobs, sorted by created_at_ms desc
CronStore.list_enabled_jobs()   # only enabled: true
CronStore.list_due_jobs()       # enabled and due?(job) == true

# Runs (table: :cron_runs)
CronStore.put_run(run)
CronStore.claim_run(run)
CronStore.claim_scheduled_run(job, scheduled_for_ms, router_run_id)
CronStore.claim_retry_run(job, source_run, router_run_id)
CronStore.retry_run_id(root_run_id, attempt)
CronStore.pending_retries()
CronStore.get_run(run_id)
CronStore.delete_run(run_id)
CronStore.list_runs(job_id, opts)    # opts: limit (100), status (atom), since_ms
CronStore.list_all_runs(opts)        # across all jobs
CronStore.active_runs(job_id)        # runs where status in [:pending, :running]
CronStore.cleanup_old_runs(keep_per_job \\ 100)

# Audit (table: :cron_audit_events)
CronStore.record_audit(action, attrs)
CronStore.list_audit_events(opts)    # opts: limit, job_id, run_id, action, since_ms
CronStore.delete_audit_event(id)
```

## CronSchedule API

```elixir
# Parse expression into structured map
{:ok, parsed} = CronSchedule.parse("*/15 * * * *")
# parsed = %{minute: [0,15,30,45], hour: [0..23], day: [1..31], month: [1..12], weekday: [0..6]}

# Get next run timestamp in milliseconds
CronSchedule.next_run_ms("0 9 * * *", "UTC")          # => integer ms | nil
CronSchedule.next_run_datetime("0 9 * * *", "UTC")     # => %DateTime{} | nil

# Get multiple future run times
CronSchedule.next_runs("*/15 * * * *", "UTC", count: 5)  # => [%DateTime{}, ...]

# Check if a DateTime matches an expression
CronSchedule.matches?("0 9 * * *", datetime)            # => boolean

# Validate expression
CronSchedule.valid?("0 9 * * *")                        # => boolean
```

## Common Tasks

### Check Job Status

```elixir
alias LemonAutomation.{CronStore, CronJob}

# Check if job is currently due
job = CronStore.get_job("cron_abc123")
CronJob.due?(job)

# Get active runs
active = CronStore.active_runs("cron_abc123")

# Get last run
[last | _] = CronStore.list_runs("cron_abc123", limit: 1)
```

### Clean Up Old Runs

```elixir
# Keep only last 50 runs per job (default: 100)
LemonAutomation.CronStore.cleanup_old_runs(50)
```

## Testing Guidance

### Test Structure

```
test/lemon_automation/
+-- cron_job_test.exs              # CronJob struct lifecycle
+-- cron_run_test.exs              # CronRun state transitions
+-- cron_schedule_test.exs         # Cron parsing, next_run computation
+-- cron_store_test.exs            # Persistence operations
+-- cron_manager_update_test.exs   # Immutable field rejection
+-- cron_manager_forwarding_test.exs # Summary forwarding to base sessions
+-- events_test.exs                # Event emission
+-- heartbeat_manager_test.exs     # Suppression logic
+-- heartbeat_scheduling_test.exs  # Cron-based heartbeats
+-- heartbeat_timer_test.exs       # Timer-based heartbeats
+-- run_completion_waiter_test.exs # Wait logic
+-- run_submitter_test.exs         # Router submission
+-- goal_loop_test.exs             # Goal loops and router judge proof
+-- goal_judge_router_live_test.exs # Opt-in provider-backed judge proof
+-- kanban_dispatcher_test.exs     # Dispatcher leasing/concurrency/failure proof
+-- kanban_dispatcher_live_test.exs # Opt-in provider-backed dispatcher proof
+-- kanban_run_worker_test.exs     # Router-backed kanban worker proof
+-- wake_test.exs                  # Wake triggering
```

### Running Tests

```bash
# All automation tests
mix test apps/lemon_automation

# Specific module
mix test apps/lemon_automation/test/lemon_automation/cron_schedule_test.exs

# Provider-backed goal-judge proof
ZAI_API_KEY="$(MIX_ENV=dev mix run --no-start -e 'Logger.configure(level: :emergency); Logger.remove_backend(:console); {:ok, _} = Application.ensure_all_started(:lemon_core); IO.write(LemonCore.Secrets.fetch_value("llm_zai_api_key") || "")')" \
LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1 \
LEMON_GOAL_JUDGE_MODEL="zai:glm-5-turbo" \
scripts/test path apps/lemon_automation/test/lemon_automation/goal_judge_router_live_test.exs --include integration --seed 1

# Provider-backed kanban dispatcher proof
secret_file=$(mktemp "${TMPDIR:-/tmp}/lemon-zai-secret.XXXXXX")
LEMON_SECRET_OUTPUT="$secret_file" MIX_ENV=dev mix run --no-start -e '
Logger.configure(level: :emergency)
Logger.remove_backend(:console)
{:ok, _} = Application.ensure_all_started(:lemon_core)
case LemonCore.Secrets.fetch_value("llm_zai_api_key") do
  value when is_binary(value) and value != "" -> File.write!(System.fetch_env!("LEMON_SECRET_OUTPUT"), value)
  _ -> System.halt(66)
end
' >/dev/null 2>&1
ZAI_API_KEY="$(cat "$secret_file")" \
LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1 \
LEMON_KANBAN_LIVE_MODEL="zai:glm-5-turbo" \
scripts/test path apps/lemon_automation/test/lemon_automation/kanban_dispatcher_live_test.exs --include integration --seed 1
rc=$?
rm -f "$secret_file"
exit "$rc"

# With coverage
mix test --cover apps/lemon_automation

# Portable bundle policy, rollback, exact confirmation, and replay
mix test apps/lemon_automation/test/lemon_automation/blueprint_test.exs --seed 1

# Booted control-plane activation proof (disabled job; cleans up after itself)
MIX_ENV=dev mix run --no-start scripts/live_skill_automation_blueprint_smoke.exs

# Source and assembled minimal-runtime CLI proof uses an isolated catalog,
# profile, control-plane port, and store, then replays activation once.
scripts/live_blueprint_cli_smoke
```

### Key Testing Patterns

**Mock the Router:**

```elixir
test "submits to router", %{job: job, run: run} do
  defmodule MockRouter do
    def submit(params) do
      send(self(), {:submitted, params})
      {:ok, "run_123"}
    end
  end

  result = RunSubmitter.submit(job, run,
    router_mod: MockRouter,
    waiter_mod: MockWaiter
  )
end
```

**Test Cron Parsing:**

```elixir
test "parses valid cron expressions" do
  assert {:ok, parsed} = CronSchedule.parse("*/15 * * * *")
  assert parsed.minute == [0, 15, 30, 45]
end
```

**Test Heartbeat Suppression:**

```elixir
test "suppresses exact HEARTBEAT_OK" do
  # Exact match and whitespace-trimmed variants are suppressed
  assert HeartbeatManager.healthy_response?("HEARTBEAT_OK")
  assert HeartbeatManager.healthy_response?("  HEARTBEAT_OK  ")
  assert HeartbeatManager.healthy_response?("HEARTBEAT_OK\n")
  # Any other string is NOT suppressed
  refute HeartbeatManager.healthy_response?("Status: OK")
  refute HeartbeatManager.healthy_response?("HEARTBEAT_OK extra")
  refute HeartbeatManager.healthy_response?(nil)
end
```

**Test State Transitions:**

```elixir
test "run state transitions" do
  run = CronRun.new("job_1", :schedule)
  assert run.status == :pending

  run = CronRun.start(run)
  assert run.status == :running

  run = CronRun.complete(run, "output")
  assert run.status == :completed

  run = CronRun.suppress(run)
  assert run.suppressed == true
end
```

**Force a Tick:**

```elixir
# Cast-based tick (returns immediately, execution is async)
LemonAutomation.CronManager.tick()
```

## Dependencies

- `lemon_core` - Store, Bus, Clock, Id generation
- `lemon_router` - Run submission via `LemonRouter.submit/1`
- `jason` - JSON serialization

## Key Modules Reference

| Module | Purpose |
|--------|---------|
| `LemonAutomation` | Top-level facade with delegating functions |
| `LemonAutomation.Application` | OTP supervisor (TaskSupervisor, CronManager, HeartbeatManager, SkillCuratorManager) |
| `LemonAutomation.Blueprint` | Portable manifest validation, exact preview confirmation, profile-local skill activation, and idempotent cron claim |
| `LemonAutomation.CronManager` | Scheduling GenServer; owns job state in-memory + persists to CronStore |
| `LemonAutomation.CronJob` | Job struct, CRUD ops, `due?/1` predicate |
| `LemonAutomation.CronRun` | Run struct, state machine transitions |
| `LemonAutomation.CronSchedule` | Cron parsing, next-run computation, `valid?/1`, `matches?/2` |
| `LemonAutomation.CronStore` | Persistence via LemonCore.Store (tables: `:cron_jobs`, `:cron_runs`) |
| `LemonAutomation.CronMemory` | Persistent markdown-based cross-run memory; auto-compaction |
| `LemonAutomation.HeartbeatManager` | Heartbeat suppression GenServer; manages timer and cron heartbeats |
| `LemonAutomation.SkillCurator` | Idle/config gates plus background submission for learned-skill curator prompts with a learning-only default tool policy |
| `LemonAutomation.SkillCuratorManager` | Periodic idle scheduler for `SkillCurator.run_once/1` |
| `LemonAutomation.Wake` | Manual immediate triggering (fire-and-forget, enabled jobs only) |
| `LemonAutomation.RunCompletionWaiter` | Owns race-free fixed-id submit/wait subscriptions and parses terminal events |
| `LemonAutomation.RunSubmitter` | Builds params, pre-subscribes to bus, submits to LemonRouter, manages CronMemory |
| `LemonAutomation.Events` | Event emission helpers for all automation events |
