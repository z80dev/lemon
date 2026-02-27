# LemonAutomation

Cron scheduling, heartbeat health checks, and automation orchestration for agents in the Lemon umbrella project. This OTP application manages the full lifecycle of scheduled and manually triggered agent runs, from cron expression parsing through job execution, completion tracking, and event broadcasting.

## Architecture Overview

LemonAutomation is built around three GenServer processes managed by a `one_for_one` supervisor:

```
LemonAutomation.Supervisor
  |-- Task.Supervisor (LemonAutomation.TaskSupervisor)
  |-- CronManager     (GenServer - scheduling engine)
  |-- HeartbeatManager (GenServer - health check suppression)
```

### Execution Flow

The CronManager ticks every 60 seconds, identifies due jobs, and spawns supervised tasks that submit runs to `LemonRouter`:

```
CronManager (tick every 60s)
    |
    +-- finds due jobs via CronJob.due?/1
    +-- applies jitter delay if configured
    +-- creates CronRun, persists to CronStore
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
                                    +-- forwards summary to base session (if applicable)
```

**Wake** provides immediate out-of-schedule triggering. It creates runs with `triggered_by: :wake`, submits directly to LemonRouter, and routes completion back through CronManager.

**HeartbeatManager** subscribes to the `"cron"` bus and auto-processes every `:cron_run_completed` event, checking for the exact `"HEARTBEAT_OK"` response to decide suppression.

### Session Isolation

Each cron run executes in a forked sub-session (e.g., `agent:abc:main:sub:cron_12345`) to prevent cron activity from polluting the originating session's conversation history. Completion summaries are forwarded back to the base session as synthetic `run_completed` entries with `meta.cron_forwarded_summary = true`.

### Persistent Cross-Run Memory

The `CronMemory` module gives each cron job a markdown file that accumulates run results across executions. On each run, the prompt is augmented with the memory file's contents so the agent has context from prior runs. The memory file auto-compacts when it exceeds 24,000 characters, retaining the most recent 14,000 characters and summarizing older content.

## Module Inventory

| Module | File | Purpose |
|--------|------|---------|
| `LemonAutomation` | `lib/lemon_automation.ex` | Top-level facade with `defdelegate` functions |
| `LemonAutomation.Application` | `lib/lemon_automation/application.ex` | OTP application and supervisor setup |
| `LemonAutomation.CronManager` | `lib/lemon_automation/cron_manager.ex` | Core scheduling GenServer; owns in-memory job state, persists to CronStore, handles ticks, execution, and completion |
| `LemonAutomation.CronJob` | `lib/lemon_automation/cron_job.ex` | Job struct with CRUD operations, `due?/1` predicate, serialization |
| `LemonAutomation.CronRun` | `lib/lemon_automation/cron_run.ex` | Run struct with state machine transitions (pending -> running -> completed/failed/timeout) |
| `LemonAutomation.CronSchedule` | `lib/lemon_automation/cron_schedule.ex` | Cron expression parser and next-run time computation |
| `LemonAutomation.CronStore` | `lib/lemon_automation/cron_store.ex` | Persistence layer using `LemonCore.Store` (tables: `:cron_jobs`, `:cron_runs`) |
| `LemonAutomation.CronMemory` | `lib/lemon_automation/cron_memory.ex` | Persistent markdown-based cross-run memory for cron jobs |
| `LemonAutomation.HeartbeatManager` | `lib/lemon_automation/heartbeat_manager.ex` | Heartbeat suppression GenServer; manages both cron-based and timer-based heartbeats |
| `LemonAutomation.Wake` | `lib/lemon_automation/wake.ex` | Manual immediate job triggering with batch and pattern-matching support |
| `LemonAutomation.RunSubmitter` | `lib/lemon_automation/run_submitter.ex` | Builds run params, pre-subscribes to bus, submits to LemonRouter, appends to CronMemory |
| `LemonAutomation.RunCompletionWaiter` | `lib/lemon_automation/run_completion_waiter.ex` | Waits on Bus for `:run_completed` events; handles multiple payload formats |
| `LemonAutomation.Events` | `lib/lemon_automation/events.ex` | Event emission helpers for all automation events |

## Configuration

LemonAutomation has no application-level configuration keys. Behavior is controlled through:

- **Tick interval**: Hardcoded at 60,000ms (`@tick_interval_ms` in CronManager)
- **Default timeout**: 300,000ms (5 minutes) per job, overridable per-job via `timeout_ms`
- **Output truncation**: Run output capped at 1,000 characters in CronStore; forwarded summaries capped at 12,000 bytes
- **Memory file limits**: 24,000 chars max per memory file, 8,000 chars injected into prompts, 2,000 chars per run result entry
- **Memory file location**: Defaults to `~/.lemon/cron_memory/{job_id}.md`, overridable via `memory_file` field on the job or in `meta`

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
  jitter_sec: 30
})
```

### Required Fields

| Field | Description |
|-------|-------------|
| `name` | Human-readable job identifier |
| `schedule` | Cron expression (5 fields: minute hour day month weekday) |
| `agent_id` | Target agent ID |
| `session_key` | Routing key (e.g., `"agent:{id}:main"`) |
| `prompt` | Text sent to the agent on each run |

### Optional Fields

| Field | Default | Description |
|-------|---------|-------------|
| `enabled` | `true` | Whether the job is active |
| `timezone` | `"UTC"` | Timezone for schedule interpretation |
| `jitter_sec` | `0` | Random delay spread in seconds |
| `timeout_ms` | `300_000` | Max execution time (5 minutes) |
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

Supported syntax: `*` (every), `N` (specific), `N-M` (range), `*/N` (step), `N,M,O` (list). Lists and ranges can be combined (e.g., `0,30 9-12,18 * * *`).

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

Predicates: `CronRun.active?/1` (pending or running), `CronRun.finished?/1` (completed, failed, or timeout).

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
| `cron_manager_update_test.exs` | Immutable field rejection, mutable field updates |
| `cron_manager_forwarding_test.exs` | Summary forwarding to main and channel_peer sessions |
| `events_test.exs` | Event emission for all event types |
| `heartbeat_manager_test.exs` | Suppression logic, heartbeat? detection |
| `heartbeat_scheduling_test.exs` | Cron-based heartbeat scheduling and interval conversion |
| `heartbeat_timer_test.exs` | Timer-based sub-minute heartbeats |
| `run_completion_waiter_test.exs` | Bus-based completion waiting, output truncation |
| `run_submitter_test.exs` | Router submission, session key forking, error handling, memory file writes |
| `wake_test.exs` | Wake triggering, batch operations, pattern matching, agent filtering |

### Key Testing Patterns

Tests use injectable modules for `router_mod`, `waiter_mod`, `bus_mod`, and `memory_mod` to isolate units from LemonRouter and LemonCore.Bus. The `CronManager.tick()` cast forces a tick cycle for deterministic testing. Store tables are cleared in `setup` blocks for `async: false` tests.
