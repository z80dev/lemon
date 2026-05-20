# LemonAutomation

Cron scheduling, heartbeat health checks, and automation orchestration for agents in the Lemon umbrella project. This OTP application manages the full lifecycle of scheduled and manually triggered prompt or operator-command runs, from cron expression parsing through job execution, completion tracking, and event broadcasting.

## Architecture Overview

LemonAutomation is built around supervised cron, heartbeat, goal-loop, kanban,
and skill-curation workers managed by a `one_for_one` supervisor:

```
LemonAutomation.Supervisor
  |-- Task.Supervisor (LemonAutomation.TaskSupervisor)
  |-- CronManager     (GenServer - scheduling engine)
  |-- HeartbeatManager (GenServer - health check suppression)
  |-- GoalContinuationManager (GenServer - supervised one-shot goal continuation)
  |-- GoalLoopManager (GenServer - preview goal judge loop tick)
  |-- SkillCuratorManager (GenServer - idle learned-skill maintenance)
```

### Execution Flow

The CronManager ticks every 60 seconds, identifies due jobs, and spawns supervised tasks that submit prompt runs to `LemonRouter` or run operator-owned local commands directly:

```
CronManager (tick every 60s)
    |
    +-- finds due jobs via CronJob.due?/1
    +-- applies jitter delay if configured
    +-- atomically claims scheduled CronRun slot in CronStore
    +-- emits :cron_run_started event
    +-- spawns Task via TaskSupervisor
            |
            +-- RunSubmitter.submit/2
                    |
                    +-- pre-subscribes to Bus.run_topic(run_id)
                    +-- forks session key into sub-session for isolation
                    +-- reads/injects CronMemory context into prompt
                    +-- calls LemonRouter.submit(params)
                    +-- RunCompletionWaiter.wait_already_subscribed/3
                            |
                            +-- sends {:run_complete, run_id, result} to CronManager
                                    |
                                    +-- updates CronStore
                                    +-- emits :cron_run_completed
                                    +-- forwards prompt-job summary to base session and, for channel_peer origins,
                                        bridges channel delivery through LemonRouter.ChannelsDelivery into LemonChannels
```

Before a scheduled launch, CronManager checks the persisted run table for
pending/running runs for the same job, then claims a deterministic scheduled-run
slot through `LemonCore.Store.put_new/3`. It skips duplicate scheduled starts
while an active run exists, and competing dispatchers claiming the same scheduled
slot preserve the first persisted run instead of overwriting it. Active runs
older than the job's `timeout_ms` are recovered as `:timeout` so a crashed
runtime cannot leave the job locked forever. On `CronManager` restart, persisted
jobs are reloaded and the same active-run recovery path runs during
initialization, so a manager crash cannot immediately double-submit a scheduled
job that already has a pending/running persisted run. The opt-in
`scripts/live_cron_runtime_restart_smoke.exs` proof boots the full runtime twice
against the same durable store and verifies that scheduled run history survives
the restart and a fresh scheduled run fires after restart.
`scripts/live_cron_channel_origin_smoke.exs` registers proof-only Telegram and
Discord plugins, completes channel-peer cron runs through `CronManager`, and
proves forwarded run history plus outbox delivery without exposing raw channel,
peer, session, or cron IDs in the proof artifact.
Scheduled failures and timeouts can retry when `max_retries` is greater than
zero. Retries are separate `CronRun` records with `triggered_by: :retry` and
redacted lineage metadata; manual and wake runs do not retry by default.
Operators can abort an active cron run by cron run id. The abort path calls the
underlying LemonRouter run cancellation when the router run is still active,
persists the cron run as `:aborted`, emits the normal completion event, and
ignores late submitter completions.
Cron lifecycle actions also record durable audit events in `:cron_audit_events`
through `CronStore.record_audit/2`. The audit stream covers job lifecycle
changes, manual run requests, run start/abort/retry/stale recovery, and
scheduled-run claim/suppression decisions. Operator APIs can read raw IDs from
`CronStore.list_audit_events/1`; support diagnostics redact audit IDs, job/run
IDs, and reasons.

**Wake** provides immediate out-of-schedule triggering. It creates runs with `triggered_by: :wake`, submits directly to LemonRouter, and routes completion back through CronManager.

**GoalContinuationManager** is the preview persistent-goal runner. It accepts one
active session goal at a time, starts the work through `TaskSupervisor`, submits
a `LemonRouter` request with `origin: :goal` and `queue_mode: :followup`, then
records the router run id back into `LemonCore.GoalStore`.

**GoalLoopManager** runs conservative goal loops. `run_once/2` performs one
preview judge tick. `start_loop/2` starts one bounded supervised loop per
session, waits for each submitted continuation to emit `:run_completed`, and
stops at `max_ticks`, failure, timeout, or a terminal judge verdict. Passing
`auto: true` persists opt-in auto-loop intent in `LemonCore.GoalStore`; the
manager scheduler scans active goals and re-starts only those persisted loops
when no loop for that session is already running. Loop status and auto state are
stored in `LemonCore.GoalStore` and emitted as redacted goal events.

`GoalJudge` supports explicit verdicts for tests/manual control, a pluggable
`judge_runner` route with `judge_model` metadata, and deterministic fallback
behavior. The persisted-auto scheduler is tested through the real goal loop and
router judge path. Dev and prod default `goal_judge_runner` to
`GoalJudge.RouterRunner`, the production-shaped route: it submits an isolated
`:goal_judge` run through `LemonRouter`, waits for completion, parses a JSON
verdict, and feeds it through the normalizer. Tests cover that route through
the real router, a router `RunProcess`, and `RunCompletionWaiter` with a
deterministic runtime. Set `LEMON_GOAL_JUDGE_MODEL` to pin the judge run model.
Judge failures pause the goal by default, with an explicit `:continue_once`
policy for fail-open one-shot continuation.

**KanbanDispatcher** is the first supervised fleet-work layer for durable boards.
It scans `LemonCore.KanbanStore` boards, reclaims expired leases, leases
dependency-unblocked tasks, runs a worker module under `TaskSupervisor`, and
records task completion or failure back into durable state. Focused dispatcher
coverage proves bounded multi-worker leasing, completion, explicit worker
failure, crashed-worker failure marking, expired-lease reclaim, and a
production-shaped bounded-concurrency path through the real `KanbanRunWorker`
with router/waiter stubs. The default `KanbanRunWorker` submits leased work
through `LemonRouter` with `origin: :kanban`, board/task metadata, a blocked
`kanban` tool policy, and an isolated git worktree cwd when the board workspace
is a git repository. The worktree layer creates
`<repo>/.worktrees/kanban-<task_id>` on a
`lemon-kanban/<task_id>` branch before submitting the router run, so broad
multi-agent execution does not share one mutable checkout.

**HeartbeatManager** subscribes to the `"cron"` bus and auto-processes every `:cron_run_completed` event, checking for the exact `"HEARTBEAT_OK"` response to decide suppression.

**SkillCuratorManager** runs Lemon's learned-skill curator after the runtime has
been idle long enough and the persisted curator interval gate is due. It asks
`LemonSkills.Curator` to apply conservative stale/archive/reactivation
transitions, then submits the generated review prompt to `LemonRouter` only when
agent-authored skills require a consolidation pass. Curator review runs default
to a learning-only tool policy that exposes `read_skill`, `skill_manage`,
`search_memory`, and `memory_topic`; override it with `tool_policy` in the
curator config when an operator needs a narrower or broader surface. When a
review is submitted, the curator report is updated with the router run id so the
automatic pass and model review can be audited together.

### Session Isolation

Each cron run executes in a forked sub-session (e.g., `agent:abc:main:sub:cron_12345`) to prevent cron activity from polluting the originating session's conversation history. Completion summaries are forwarded back to the base session as synthetic `run_completed` entries with `meta.cron_forwarded_summary = true`. For `channel_peer` base sessions, the forwarded summary is also delivered through the `LemonRouter.ChannelsDelivery` -> `LemonChannels` path so channel-origin cron jobs are visible even when no process is subscribed to the session topic.

### Persistent Cross-Run Memory

The `CronMemory` module gives each cron job a markdown file that accumulates run results across executions. On each run, the prompt is augmented with the memory file's contents so the agent has context from prior runs. The memory file auto-compacts when it exceeds 24,000 characters, retaining the most recent 14,000 characters and summarizing older content.

## Module Inventory

| Module | File | Purpose |
|--------|------|---------|
| `LemonAutomation` | `lib/lemon_automation.ex` | Top-level facade with `defdelegate` functions |
| `LemonAutomation.Application` | `lib/lemon_automation/application.ex` | OTP application and supervisor setup |
| `LemonAutomation.CronManager` | `lib/lemon_automation/cron_manager.ex` | Core scheduling GenServer; owns in-memory job state, persists to CronStore, handles ticks, execution, and completion |
| `LemonAutomation.CronJob` | `lib/lemon_automation/cron_job.ex` | Job struct with CRUD operations, `due?/1` predicate, serialization |
| `LemonAutomation.CronRun` | `lib/lemon_automation/cron_run.ex` | Run struct with state machine transitions (pending -> running -> completed/failed/timeout/aborted) |
| `LemonAutomation.CronSchedule` | `lib/lemon_automation/cron_schedule.ex` | Cron expression parser and next-run time computation |
| `LemonAutomation.CronStore` | `lib/lemon_automation/cron_store.ex` | Persistence layer using `LemonCore.Store` (tables: `:cron_jobs`, `:cron_runs`) |
| `LemonAutomation.CronMemory` | `lib/lemon_automation/cron_memory.ex` | Persistent markdown-based cross-run memory for cron jobs |
| `LemonAutomation.CronCommandRunner` | `lib/lemon_automation/cron_command_runner.ex` | Supervised no-agent local shell command runner for operator-created command cron jobs |
| `LemonCore.Doctor.CronDiagnostics` | `apps/lemon_core/lib/lemon_core/doctor/cron_diagnostics.ex` | Core-owned redacted support-bundle diagnostics for cron jobs and runs |
| `LemonAutomation.HeartbeatManager` | `lib/lemon_automation/heartbeat_manager.ex` | Heartbeat suppression GenServer; manages both cron-based and timer-based heartbeats |
| `LemonAutomation.GoalContinuation` | `lib/lemon_automation/goal_continuation.ex` | Builds and submits one persistent-goal continuation run through LemonRouter |
| `LemonAutomation.GoalContinuationManager` | `lib/lemon_automation/goal_continuation_manager.ex` | Supervised task entrypoint for one-shot goal continuation |
| `LemonAutomation.GoalJudge` | `lib/lemon_automation/goal_judge.ex` | Normalizes preview goal-loop verdicts |
| `LemonAutomation.GoalLoop` | `lib/lemon_automation/goal_loop.ex` | Applies one judge verdict to submit, complete, or pause a durable goal |
| `LemonAutomation.GoalLoopManager` | `lib/lemon_automation/goal_loop_manager.ex` | Supervised goal-loop entrypoint with opt-in persisted auto scheduling |
| `LemonAutomation.SkillCurator` | `lib/lemon_automation/skill_curator.ex` | Applies idle/config gates and submits learned-skill curator prompts |
| `LemonAutomation.SkillCuratorManager` | `lib/lemon_automation/skill_curator_manager.ex` | Periodic idle scheduler for background skill curation |
| `LemonAutomation.KanbanDispatcher` | `lib/lemon_automation/kanban_dispatcher.ex` | Supervised durable-board task leasing, execution, completion, and failure marking |
| `LemonAutomation.KanbanRunWorker` | `lib/lemon_automation/kanban_run_worker.ex` | Converts leased kanban tasks into router runs with board/task provenance and recursive-kanban blocking |
| `LemonAutomation.KanbanWorktree` | `lib/lemon_automation/kanban_worktree.ex` | Creates per-task git worktrees under `.worktrees/` for isolated kanban worker execution |
| `LemonAutomation.Wake` | `lib/lemon_automation/wake.ex` | Manual immediate job triggering with batch and pattern-matching support |
| `LemonAutomation.RunSubmitter` | `lib/lemon_automation/run_submitter.ex` | Builds run params, pre-subscribes to bus, submits to LemonRouter, appends to CronMemory |
| `LemonAutomation.RunCompletionWaiter` | `lib/lemon_automation/run_completion_waiter.ex` | Waits on Bus for `:run_completed` events; handles multiple payload formats |
| `LemonAutomation.Events` | `lib/lemon_automation/events.ex` | Event emission helpers for all automation events |

## Configuration

LemonAutomation behavior is controlled through cron job fields plus a small application-level curator config:

- **Tick interval**: Hardcoded at 60,000ms (`@tick_interval_ms` in CronManager)
- **Default timeout**: 300,000ms (5 minutes) per job, overridable per-job via `timeout_ms`
- **Retry policy**: `max_retries` defaults to `0`; `retry_backoff_ms` defaults to `30_000` and applies to scheduled failure/timeout retries
- **Output truncation**: Run output capped at 1,000 characters in CronStore; forwarded summaries capped at 12,000 bytes
- **Memory file limits**: 24,000 chars max per memory file, 8,000 chars injected into prompts, 2,000 chars per run result entry
- **Memory file location**: Defaults to `~/.lemon/cron_memory/{job_id}.md`, overridable via `memory_file` field on the job or in `meta`
- **Goal judge runner**: dev/prod default to `LemonAutomation.GoalJudge.RouterRunner`; set `LEMON_GOAL_JUDGE_MODEL` or pass `judge_model` from the control plane/TUI to choose a specific judge model
- **Goal loop scheduler**: `goal.loop.start` with `auto: true` persists per-goal auto scheduling; `goal.loop.stop` disables it. `:goal_loop_scheduler_interval_ms` defaults to 30,000 and `:goal_loop_scan_limit` defaults to 50.
- **Skill curator**: `config :lemon_automation, :skill_curator, enabled: true, agent_id: "default", interval_hours: 168, min_idle_hours: 2, tool_policy: %{allow: ["read_skill", "skill_manage", "search_memory", "memory_topic"]}`

## Usage

### Creating a Cron Job

```elixir
{:ok, job} = LemonAutomation.add_job(%{
  name: "Daily Report",
  schedule: "0 9 * * *",
  agent_id: "agent_abc",
  session_key: "agent:agent_abc:main",
  prompt: "Generate daily status report"
})
```

### With Timezone and Jitter

```elixir
{:ok, job} = LemonAutomation.add_job(%{
  name: "Hourly Check",
  schedule: "0 * * * *",
  agent_id: "agent_abc",
  session_key: "agent:agent_abc:main",
  prompt: "Check system status",
  timezone: "America/New_York",
  jitter_sec: 30,
  max_retries: 2,
  retry_backoff_ms: 60_000
})
```

### Operator Command Job

Control-plane operators can create no-agent command jobs with `command` instead
of `agent_id`/`session_key`/`prompt`. Command jobs run under the
`CronManager` supervised task path, store output in cron run history, do not
create LemonRouter runs, and do not forward channel summaries.

```elixir
{:ok, job} = LemonAutomation.add_job(%{
  name: "Disk Usage Snapshot",
  schedule: "hourly",
  command: "df -h /",
  cwd: "/tmp"
})
```

### Required Fields

All jobs require `name` and `schedule`. Prompt jobs also require `agent_id`,
`session_key`, and `prompt`; no-agent command jobs require `command` instead.
Updates preserve the job target type: prompt jobs can update `prompt`, command
jobs can update `command`, `cwd`, and `env`, and routing fields remain
immutable.

| Field | Description |
|-------|-------------|
| `name` | Human-readable job identifier |
| `schedule` | Cron expression or supported shorthand |
| `agent_id` | Target agent ID for prompt jobs |
| `session_key` | Routing key for prompt jobs (e.g., `"agent:{id}:main"`) |
| `prompt` | Text sent to the agent on each run |
| `command` | Local shell command for no-agent operator jobs; mutually exclusive with `prompt` |

### Optional Fields

| Field | Default | Description |
|-------|---------|-------------|
| `enabled` | `true` | Whether the job is active |
| `timezone` | `"UTC"` | Timezone for schedule interpretation |
| `jitter_sec` | `0` | Random delay spread in seconds |
| `timeout_ms` | `300_000` | Max execution time (5 minutes) |
| `max_retries` | `0` | Number of retries after scheduled failure/timeout |
| `retry_backoff_ms` | `30_000` | Delay before retry runs |
| `cwd` | current runtime cwd | Working directory for command jobs |
| `env` | `%{}` | Environment overrides for command jobs |
| `memory_file` | auto-generated | Path to persistent cross-run memory file |
| `meta` | `nil` | Arbitrary metadata map |

### Cron Expression Format

```
* * * * *
| | | | +-- Day of week (0-7, 0 and 7 are Sunday)
| | | +---- Month (1-12)
| | +------ Day of month (1-31)
| +-------- Hour (0-23)
+---------- Minute (0-59)
```

Supported cron syntax: `*` (every), `N` (specific), `N-M` (range), `*/N` (step), `N,M,O` (list). Lists and ranges can be combined (e.g., `0,30 9-12,18 * * *`).

Supported schedule shorthands are normalized into 5-field cron expressions before
storage. Interval shorthands must map cleanly to cron step fields, so minute
intervals divide 60 and hour intervals divide 24:

| Shorthand | Stored cron |
|-----------|-------------|
| `every 30m`, `15 minutes` | `*/30 * * * *`, `*/15 * * * *` |
| `hourly`, `every 2h` | `0 * * * *`, `0 */2 * * *` |
| `daily at 9am`, `every day at 17:45` | `0 9 * * *`, `45 17 * * *` |
| `weekdays at 09:30` | `30 9 * * 1-5` |
| `weekly monday at 8am`, `fridays at 18:15` | `0 8 * * 1`, `15 18 * * 5` |

### Managing Jobs

```elixir
# List all jobs (sorted by created_at_ms descending)
LemonAutomation.list_jobs()

# Update a job (agent_id and session_key are immutable)
LemonAutomation.update_job(job.id, %{enabled: false})

# Remove a job
LemonAutomation.remove_job(job.id)

# Run a job immediately (manual trigger)
LemonAutomation.run_now(job.id)

# Get run history (opts: limit, status, since_ms)
LemonAutomation.runs(job.id, limit: 10)
```

### Wake (Immediate Triggering)

```elixir
# Trigger a single job (must be enabled)
{:ok, run} = LemonAutomation.Wake.trigger("cron_abc123")

# Trigger with context metadata
{:ok, run} = LemonAutomation.Wake.trigger("cron_abc123",
  context: %{reason: "incident response"})

# Skip if already running
{:ok, run} = LemonAutomation.Wake.trigger("cron_abc123",
  skip_if_running: true)

# Trigger by name pattern (case-insensitive)
results = LemonAutomation.Wake.trigger_matching("heartbeat")

# Trigger all enabled jobs for an agent
results = LemonAutomation.Wake.trigger_for_agent("agent_abc")
```

### Heartbeat Jobs

Heartbeats are cron jobs for agent health checks. A job is treated as a heartbeat if its name contains `"heartbeat"` (case-insensitive) or its `meta` has `heartbeat: true` (atom key).

```elixir
# Create a heartbeat job
{:ok, job} = LemonAutomation.add_job(%{
  name: "heartbeat-agent-abc",
  schedule: "*/5 * * * *",
  agent_id: "agent_abc",
  session_key: "agent:agent_abc:heartbeat",
  prompt: "HEARTBEAT"
})

# Configure heartbeat via HeartbeatManager (creates/updates cron job automatically)
LemonAutomation.HeartbeatManager.update_config("agent_abc", %{
  enabled: true,
  interval_ms: 300_000,
  prompt: "HEARTBEAT"
})

# Sub-minute heartbeats use Erlang timers instead of cron
LemonAutomation.HeartbeatManager.update_config("agent_abc", %{
  enabled: true,
  interval_ms: 30_000,
  prompt: "HEARTBEAT"
})

# Query heartbeat state
LemonAutomation.HeartbeatManager.get_config("agent_abc")
LemonAutomation.HeartbeatManager.get_last("agent_abc")
LemonAutomation.HeartbeatManager.stats()
```

**Suppression rules**: Only responses that trim to exactly `"HEARTBEAT_OK"` are suppressed. Suppressed responses are not broadcast to channels but are logged in run history and emit `:heartbeat_suppressed` events. Any other response emits `:heartbeat_alert` with `severity: :warning`.

### Events

All events are broadcast on the `"cron"` bus topic as `%LemonCore.Event{}` structs:

| Event | Emitted By | When |
|-------|-----------|------|
| `:cron_tick` | CronManager | Every 60s tick |
| `:cron_job_created` | CronManager | Job added |
| `:cron_job_updated` | CronManager | Job updated |
| `:cron_job_deleted` | CronManager | Job removed |
| `:cron_run_started` | CronManager, Wake, HeartbeatManager | Run begins |
| `:cron_run_completed` | CronManager, HeartbeatManager | Run finishes |
| `:heartbeat_suppressed` | HeartbeatManager | "HEARTBEAT_OK" response |
| `:heartbeat_alert` | HeartbeatManager | Non-OK heartbeat response |

```elixir
LemonCore.Bus.subscribe("cron")

receive do
  %LemonCore.Event{type: :cron_run_completed, payload: payload} ->
    IO.puts("Run #{payload.cron_run_id}: #{payload.status}")
end
```

### CronSchedule API

```elixir
# Parse and validate
{:ok, parsed} = LemonAutomation.CronSchedule.parse("*/15 * * * *")
LemonAutomation.CronSchedule.valid?("0 9 * * *")

# Next run computation
next_ms = LemonAutomation.CronSchedule.next_run_ms("0 9 * * *", "UTC")
next_dt = LemonAutomation.CronSchedule.next_run_datetime("0 9 * * *", "UTC")
times = LemonAutomation.CronSchedule.next_runs("*/15 * * * *", "UTC", count: 5)

# Check if a DateTime matches
LemonAutomation.CronSchedule.matches?("0 9 * * *", datetime)
```

### CronStore API

```elixir
# Jobs
CronStore.put_job(job)
CronStore.get_job(job_id)
CronStore.delete_job(job_id)
CronStore.list_jobs()
CronStore.list_enabled_jobs()
CronStore.list_due_jobs()

# Runs
CronStore.put_run(run)
CronStore.claim_run(run)
CronStore.claim_scheduled_run(job, scheduled_for_ms, router_run_id)
CronStore.get_run(run_id)
CronStore.list_runs(job_id, limit: 10, status: :completed, since_ms: timestamp)
CronStore.list_all_runs(limit: 50)
CronStore.active_runs(job_id)
CronStore.cleanup_old_runs(50)  # keep last 50 per job
```

## CronRun State Machine

```
CronRun.new(job_id, triggered_by)  => :pending
CronRun.start(run, run_id)        => :running
CronRun.complete(run, output)     => :completed
CronRun.fail(run, error)          => :failed
CronRun.timeout(run)              => :timeout
CronRun.suppress(run)             => suppressed: true (combinable with any terminal state)
```

Predicates: `CronRun.active?/1` (pending or running), `CronRun.finished?/1` (completed, failed, or timeout). Retry attempts use `triggered_by: :retry` and carry `retry_attempt`, `retry_of`, and `retry_root_id` in run metadata.

## Dependencies

| Dependency | Type | Purpose |
|-----------|------|---------|
| `lemon_core` | Umbrella | Store, Bus, Clock, Id generation, SessionKey, Event |
| `lemon_router` | Umbrella | Run submission via `LemonRouter.submit/1` |
| `jason` | Hex | JSON serialization |

## Testing

```bash
# All automation tests
mix test apps/lemon_automation

# Specific test file
mix test apps/lemon_automation/test/lemon_automation/cron_schedule_test.exs

# Focused cron diagnostics/support proof
MIX_ENV=test mix test \
  apps/lemon_core/test/lemon_core/doctor/cron_diagnostics_test.exs \
  apps/lemon_core/test/lemon_core/doctor/support_bundle_test.exs \
  --seed 1

# Focused cron automation/control-plane/gateway lane
MIX_ENV=test mix test \
  apps/lemon_automation/test/lemon_automation/cron_job_test.exs \
  apps/lemon_automation/test/lemon_automation/cron_schedule_test.exs \
  apps/lemon_automation/test/lemon_automation/cron_store_test.exs \
  apps/lemon_automation/test/lemon_automation/cron_run_test.exs \
  apps/lemon_automation/test/lemon_automation/cron_manager_retry_test.exs \
  apps/lemon_automation/test/lemon_automation/cron_manager_scheduler_lock_test.exs \
  apps/lemon_automation/test/lemon_automation/cron_manager_update_test.exs \
  apps/lemon_automation/test/lemon_automation/cron_manager_forwarding_test.exs \
  apps/lemon_automation/test/lemon_automation/cron_manager_unavailable_test.exs \
  apps/lemon_control_plane/test/lemon_control_plane/methods/cron_methods_test.exs \
  apps/lemon_gateway/test/tools/cron_test.exs \
  --seed 1

# Redacted cron support-bundle smoke
MIX_ENV=test mix run scripts/live_cron_diagnostics_smoke.exs

# Telegram/Discord channel-origin cron delivery proof
MIX_ENV=test mix run scripts/live_cron_channel_origin_smoke.exs

# Full-runtime cron restart smoke (boots runtime_full twice; minute-granularity)
MIX_ENV=dev mix run --no-start scripts/live_cron_runtime_restart_smoke.exs

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
```

### Test Files

| Test File | Coverage |
|-----------|----------|
| `cron_job_test.exs` | CronJob struct creation, update, due?, serialization |
| `cron_run_test.exs` | CronRun state transitions, duration computation, serialization |
| `cron_schedule_test.exs` | Cron parsing, next_run computation, matches?, common patterns |
| `cron_store_test.exs` | Persistence CRUD, filtering, ordering, cleanup_old_runs |
| `cron_manager_retry_test.exs` | Scheduled failure retry/backoff and manual no-retry behavior |
| `cron_manager_scheduler_lock_test.exs` | Scheduled ticks and manager restarts skip duplicate launches when a persisted active run exists and recover stale active runs as timeouts |
| `cron_manager_update_test.exs` | Immutable field rejection, mutable field updates |
| `cron_manager_forwarding_test.exs` | Summary forwarding to main/channel_peer sessions and channel outbox delivery |
| `events_test.exs` | Event emission for all event types |
| `heartbeat_manager_test.exs` | Suppression logic, heartbeat? detection |
| `heartbeat_scheduling_test.exs` | Cron-based heartbeat scheduling and interval conversion |
| `heartbeat_timer_test.exs` | Timer-based sub-minute heartbeats |
| `run_completion_waiter_test.exs` | Bus-based completion waiting, output truncation |
| `run_submitter_test.exs` | Router submission, session key forking, error handling, memory file writes |
| `goal_loop_test.exs` | Goal loop verdicts, bounded loops, auto scheduling, router judge proof |
| `goal_judge_router_live_test.exs` | Opt-in provider-backed router judge proof; passed locally on 2026-05-15 with Z.ai `glm-5-turbo` |
| `kanban_dispatcher_test.exs` | Durable kanban task leasing, bounded concurrency, real-worker dispatch proof, completion, failure, crash marking, and lease reclaim |
| `kanban_dispatcher_live_test.exs` | Opt-in provider-backed dispatcher proof; passed locally on 2026-05-15 with Z.ai `glm-5-turbo` |
| `kanban_run_worker_test.exs` | Router request construction, run wait behavior, and failure return for leased kanban tasks |
| `wake_test.exs` | Wake triggering, batch operations, pattern matching, agent filtering |

### Key Testing Patterns

Tests use injectable modules for `router_mod`, `waiter_mod`, `bus_mod`, and `memory_mod` to isolate units from LemonRouter and LemonCore.Bus. The `CronManager.tick()` cast forces a tick cycle for deterministic testing. Store tables are cleared in `setup` blocks for `async: false` tests.
