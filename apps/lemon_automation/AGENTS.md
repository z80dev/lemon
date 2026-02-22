# LemonAutomation

Elixir app for cron jobs, heartbeats, and automation tasks in the Lemon umbrella.

## Purpose and Responsibilities

LemonAutomation provides scheduled and triggered automation for agents:

- **Cron Jobs** - Schedule agent prompts with cron expressions
- **Heartbeats** - Periodic health checks with smart suppression
- **Wake** - Immediate manual triggering of scheduled jobs
- **Run Tracking** - Full lifecycle tracking of job executions

## Supervision Tree

```
LemonAutomation.Supervisor (one_for_one)
├── LemonAutomation.TaskSupervisor  (Task.Supervisor)
├── LemonAutomation.CronManager     (GenServer)
└── LemonAutomation.HeartbeatManager (GenServer)
```

## Cron System Architecture

```
CronManager (GenServer, ticks every 60s)
    │
    ├─ on tick: finds due jobs, calls execute_job/2
    │
    └─ execute_job/2
           │
           ├─ creates CronRun, persists to CronStore
           ├─ emits :cron_run_started on "cron" bus
           └─ spawns Task via TaskSupervisor
                  │
                  └─ RunSubmitter.submit/2
                         │
                         ├─ pre-subscribes to Bus.run_topic(run_id)
                         ├─ calls LemonRouter.submit(params)
                         └─ RunCompletionWaiter.wait_already_subscribed/3
                                │
                                └─ sends {:run_complete, run_id, result} to CronManager
                                           │
                                           └─ CronManager updates CronStore, emits :cron_run_completed
```

**Wake** is a separate module (not intermediary in the above flow). It creates runs with `triggered_by: :wake`, submits directly to `LemonRouter`, and sends `{:run_complete, ...}` back to `CronManager`.

**HeartbeatManager** subscribes to the "cron" bus and auto-processes every `:cron_run_completed` event for suppression checks.

## Key Flow Details

- `RunSubmitter` pre-subscribes to `Bus.run_topic(run_id)` BEFORE submitting to `LemonRouter` (avoids race condition)
- `RunSubmitter` passes `run_id` in params so the router uses the same ID it already subscribed to
- If the router returns a different `run_id`, `RunSubmitter` falls back to `RunCompletionWaiter.wait/3`
- Output is truncated to 1000 chars before storage
- Jobs execute in supervised tasks; fallback to `Task.start/1` if supervisor is unavailable

## Top-Level Facade

`LemonAutomation` module provides delegating functions:

```elixir
LemonAutomation.list_jobs()           # delegates to CronManager.list/0
LemonAutomation.add_job(params)       # delegates to CronManager.add/1
LemonAutomation.update_job(id, params) # delegates to CronManager.update/2
LemonAutomation.remove_job(id)        # delegates to CronManager.remove/1
LemonAutomation.run_now(id)           # delegates to CronManager.run_now/1
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

### With Timezone and Jitter

```elixir
{:ok, job} = LemonAutomation.CronManager.add(%{
  name: "Hourly Check",
  schedule: "0 * * * *",
  agent_id: "agent_abc",
  session_key: "agent:agent_abc:main",
  prompt: "Check system status",
  timezone: "America/New_York",  # Default: "UTC"
  jitter_sec: 30                 # Random 0-30s delay before execution
})
```

### Required Fields

| Field | Description |
|-------|-------------|
| `name` | Human-readable identifier |
| `schedule` | Cron expression (5 fields) |
| `agent_id` | Target agent |
| `session_key` | Routing key (e.g., `"agent:{id}:main"`) |
| `prompt` | Text sent to agent |

### Optional Fields

| Field | Default | Description |
|-------|---------|-------------|
| `enabled` | `true` | Whether the job is active |
| `timezone` | `"UTC"` | Timezone for schedule interpretation |
| `jitter_sec` | `0` | Random delay spread in seconds |
| `timeout_ms` | `300_000` | Max execution time (5 minutes) |
| `meta` | `nil` | Arbitrary metadata map |

### Cron Expression Format

```
* * * * *
│ │ │ │ └── Day of week (0-7, 0/7 = Sunday)
│ │ │ └──── Month (1-12)
│ │ └────── Day of month (1-31)
│ └──────── Hour (0-23)
└────────── Minute (0-59)
```

Supported syntax: `*`, `N`, `N-M` (range), `*/N` (step), `N,M,O` (list).

Examples:
- `"*/15 * * * *"` - Every 15 minutes
- `"0 9 * * 1"` - Mondays at 9 AM
- `"0 */6 * * *"` - Every 6 hours

### Managing Jobs

```elixir
# List all jobs (sorted by created_at_ms desc)
LemonAutomation.CronManager.list()

# Update a job (agent_id and session_key cannot be changed via update)
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
  timezone: "UTC",
  jitter_sec: 0,
  timeout_ms: 300_000,
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
  status: :pending,            # :pending | :running | :completed | :failed | :timeout
  triggered_by: :schedule,    # :schedule | :manual | :wake
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
CronRun.suppress(run)                => suppressed: true (can combine with any terminal state)
```

Helper predicates: `CronRun.active?/1` (pending or running), `CronRun.finished?/1`.

## Heartbeat Management

Heartbeats are special cron jobs for agent health checks. Responses containing exactly `"HEARTBEAT_OK"` (trimmed) are suppressed from channels but still logged.

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

For `interval_ms < 60_000`, `HeartbeatManager` uses Erlang timers instead of cron jobs. These create synthetic run IDs (`"timer-heartbeat-{agent_id}-{timestamp}"`), submit directly to `LemonRouter`, and broadcast events on the "cron" bus. They do NOT create `CronJob` records in `CronStore`.

```elixir
LemonAutomation.HeartbeatManager.update_config("agent_abc", %{
  enabled: true,
  interval_ms: 30_000,  # 30 seconds - uses timers, not cron
  prompt: "HEARTBEAT"
})
```

### Heartbeat Cron Schedule Conversion

For `interval_ms >= 60_000`, `HeartbeatManager` auto-generates a cron schedule:
- `>= 3_600_000` (1 hour): `"0 */N * * *"` (every N hours)
- `>= 60_000` (1 minute): `"*/N * * * *"` (every N minutes, rounded to nearest minute)

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

Wake runs use `triggered_by: :wake` and fire-and-forget: they return the `CronRun` immediately and completion is handled asynchronously by `CronManager`.

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
CronStore.get_run(run_id)
CronStore.delete_run(run_id)
CronStore.list_runs(job_id, opts)    # opts: limit (100), status (atom), since_ms
CronStore.list_all_runs(opts)        # across all jobs
CronStore.active_runs(job_id)        # runs where status in [:pending, :running]
CronStore.cleanup_old_runs(keep_per_job \\ 100)
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
├── cron_job_test.exs              # CronJob struct lifecycle
├── cron_run_test.exs              # CronRun state transitions
├── cron_schedule_test.exs         # Cron parsing, next_run computation
├── cron_store_test.exs            # Persistence operations
├── events_test.exs                # Event emission
├── heartbeat_manager_test.exs     # Suppression logic
├── heartbeat_scheduling_test.exs  # Cron-based heartbeats
├── heartbeat_timer_test.exs       # Timer-based heartbeats
├── run_completion_waiter_test.exs # Wait logic
├── run_submitter_test.exs         # Router submission
└── wake_test.exs                  # Wake triggering
```

### Running Tests

```bash
# All automation tests
mix test apps/lemon_automation

# Specific module
mix test apps/lemon_automation/test/lemon_automation/cron_schedule_test.exs

# With coverage
mix test --cover apps/lemon_automation
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
| `LemonAutomation.Application` | OTP supervisor (TaskSupervisor, CronManager, HeartbeatManager) |
| `LemonAutomation.CronManager` | Scheduling GenServer; owns job state in-memory + persists to CronStore |
| `LemonAutomation.CronJob` | Job struct, CRUD ops, `due?/1` predicate |
| `LemonAutomation.CronRun` | Run struct, state machine transitions |
| `LemonAutomation.CronSchedule` | Cron parsing, next-run computation, `valid?/1`, `matches?/2` |
| `LemonAutomation.CronStore` | Persistence via LemonCore.Store (tables: `:cron_jobs`, `:cron_runs`) |
| `LemonAutomation.HeartbeatManager` | Heartbeat suppression GenServer; manages timer and cron heartbeats |
| `LemonAutomation.Wake` | Manual immediate triggering (fire-and-forget, enabled jobs only) |
| `LemonAutomation.RunCompletionWaiter` | Waits on Bus for `:run_completed` event; handles multiple payload formats |
| `LemonAutomation.RunSubmitter` | Builds params, pre-subscribes to bus, submits to LemonRouter |
| `LemonAutomation.Events` | Event emission helpers for all automation events |
