# LemonAutomation

Elixir app for cron jobs, heartbeats, and automation tasks in the Lemon umbrella.

## Purpose and Responsibilities

LemonAutomation provides scheduled and triggered automation for agents:

- **Cron Jobs** - Schedule agent prompts with cron expressions
- **Heartbeats** - Periodic health checks with smart suppression
- **Wake** - Immediate manual triggering of scheduled jobs
- **Run Tracking** - Full lifecycle tracking of job executions

## Cron System Architecture

```
┌─────────────────┐     tick      ┌─────────────┐
│  CronManager    │ ─────────────>│    Wake     │
│   (GenServer)   │               │   (trigger) │
└────────┬────────┘               └──────┬──────┘
         │                               │
         │                               v
    ┌────┴────┐                  ┌──────────────┐
    │CronStore│                  │ RunSubmitter │
    │(persist)│                  │  (router)    │
    └────┬────┘                  └──────────────┘
         │
         v
┌─────────────────┐
│ HeartbeatManager│
│ (suppress OK)   │
└─────────────────┘
```

**Key Flow:**
1. `CronManager` ticks every 60s, checks for due jobs
2. Due jobs are executed via `RunSubmitter.submit/2`
3. `RunSubmitter` submits to `LemonRouter` and waits for completion
4. `HeartbeatManager` processes responses, suppressing "HEARTBEAT_OK"
5. All activities emit events on the `"cron"` bus topic

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
  jitter_sec: 30                 # Random 0-30s delay
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

### Cron Expression Format

```
* * * * *
│ │ │ │ └── Day of week (0-7, 0/7 = Sunday)
│ │ │ └──── Month (1-12)
│ │ └────── Day of month (1-31)
│ └──────── Hour (0-23)
└────────── Minute (0-59)
```

Examples:
- `"*/15 * * * *"` - Every 15 minutes
- `"0 9 * * 1"` - Mondays at 9 AM
- `"0 */6 * * *"` - Every 6 hours

### Managing Jobs

```elixir
# List all jobs
LemonAutomation.CronManager.list()

# Update a job
LemonAutomation.CronManager.update(job.id, %{enabled: false})

# Remove a job
LemonAutomation.CronManager.remove(job.id)

# Run immediately (manual trigger)
LemonAutomation.CronManager.run_now(job.id)

# Get run history
LemonAutomation.CronManager.runs(job.id, limit: 10)
```

## Heartbeat Management

Heartbeats are special cron jobs for health checks. Responses containing exactly `"HEARTBEAT_OK"` are suppressed from channels.

### Creating a Heartbeat

A job is a heartbeat if:
- Name contains "heartbeat" (case-insensitive), OR
- `meta: %{heartbeat: true}`

```elixir
{:ok, job} = LemonAutomation.CronManager.add(%{
  name: "heartbeat-agent-abc",
  schedule: "*/5 * * * *",  # Every 5 minutes
  agent_id: "agent_abc",
  session_key: "agent:agent_abc:heartbeat",
  prompt: "HEARTBEAT"
})
```

### HeartbeatManager API

```elixir
# Check if job is a heartbeat
LemonAutomation.HeartbeatManager.heartbeat?(job)

# Check response health (exact "HEARTBEAT_OK" match)
LemonAutomation.HeartbeatManager.healthy_response?(response)

# Get suppression stats
LemonAutomation.HeartbeatManager.stats()

# Update heartbeat config (for set-heartbeats control plane method)
LemonAutomation.HeartbeatManager.update_config(agent_id, %{
  enabled: true,
  interval_ms: 300_000,
  prompt: "HEARTBEAT"
})
```

### Sub-Minute Heartbeats

For intervals < 60s, `HeartbeatManager` uses timer-based scheduling:

```elixir
LemonAutomation.HeartbeatManager.update_config("agent_abc", %{
  enabled: true,
  interval_ms: 30_000,  # 30 seconds (uses timers, not cron)
  prompt: "HEARTBEAT"
})
```

## Wake Functionality

Wake triggers immediate job execution outside the normal schedule.

```elixir
# Trigger single job
{:ok, run} = LemonAutomation.Wake.trigger("cron_abc123")

# Trigger with context
{:ok, run} = LemonAutomation.Wake.trigger("cron_abc123", 
  context: %{reason: "incident response"}
)

# Skip if already running
{:ok, run} = LemonAutomation.Wake.trigger("cron_abc123", 
  skip_if_running: true
)

# Trigger multiple jobs
results = LemonAutomation.Wake.trigger_many(["cron_abc", "cron_xyz"])

# Trigger by name pattern
results = LemonAutomation.Wake.trigger_matching("heartbeat")

# Trigger all jobs for an agent
results = LemonAutomation.Wake.trigger_for_agent("agent_abc")
```

## Run Completion Flow

```
┌─────────────┐     submit      ┌─────────────┐
│  CronManager│ ───────────────>│ RunSubmitter│
└─────────────┘                 └──────┬──────┘
                                       │
                    ┌──────────────────┼──────────────────┐
                    │                  │                  │
                    v                  v                  v
            ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
            │  Bus Sub    │    │LemonRouter  │    │  Wait Loop  │
            │ (pre-sub)   │    │   submit    │    │ (completion)│
            └─────────────┘    └─────────────┘    └──────┬──────┘
                                                         │
                    ┌────────────────────────────────────┘
                    v
            ┌─────────────┐     result      ┌─────────────┐
            │RunCompletion│────────────────>│ CronManager │
            │   Waiter    │   {:run_complete│  (update)   │
            └─────────────┘                 └─────────────┘
```

**Key Points:**
- `RunSubmitter` pre-subscribes to bus BEFORE submitting to avoid race conditions
- Uses `LemonCore.Bus.run_topic(run_id)` for per-run events
- `RunCompletionWaiter` handles multiple message formats for backward compatibility
- Output truncated to 1000 chars for storage

## Common Tasks and Examples

### Subscribe to Cron Events

```elixir
LemonCore.Bus.subscribe("cron")

receive do
  %LemonCore.Event{type: :cron_run_started, payload: payload} ->
    IO.puts("Run started: #{payload.run.id}")
    
  %LemonCore.Event{type: :cron_run_completed, payload: payload} ->
    IO.puts("Run completed: #{payload.run.status}")
    
  %LemonCore.Event{type: :heartbeat_suppressed} ->
    IO.puts("Heartbeat OK (suppressed)")
end
```

### Check Job Status

```elixir
alias LemonAutomation.CronStore

# Get active runs
active = CronStore.active_runs("cron_abc123")

# Check if job is due
job = CronStore.get_job("cron_abc123")
LemonAutomation.CronJob.due?(job)

# Get last run
runs = CronStore.list_runs("cron_abc123", limit: 1)
```

### Clean Up Old Runs

```elixir
# Keep only last 50 runs per job
LemonAutomation.CronStore.cleanup_old_runs(50)
```

### Validate Cron Expression

```elixir
LemonAutomation.CronSchedule.valid?("0 9 * * *")
# => true

LemonAutomation.CronSchedule.next_run_ms("0 9 * * *", "UTC")
# => 1739989200000
```

### Force a Tick (Testing)

```elixir
LemonAutomation.CronManager.tick()
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
  assert HeartbeatManager.healthy_response?("HEARTBEAT_OK")
  refute HeartbeatManager.healthy_response?("HEARTBEAT_OK\n")  # Extra newline = not suppressed
  refute HeartbeatManager.healthy_response?("Status: OK")
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
end
```

## Dependencies

- `lemon_core` - Store, Bus, Clock, Id generation
- `lemon_router` - Run submission
- `jason` - JSON serialization

## Key Modules Reference

| Module | Purpose |
|--------|---------|
| `LemonAutomation` | Main API facade |
| `LemonAutomation.Application` | OTP supervisor |
| `LemonAutomation.CronManager` | Scheduling GenServer |
| `LemonAutomation.CronJob` | Job struct, CRUD ops |
| `LemonAutomation.CronRun` | Run struct, state machine |
| `LemonAutomation.CronSchedule` | Cron parsing, next-run calc |
| `LemonAutomation.CronStore` | Persistence via LemonCore.Store |
| `LemonAutomation.HeartbeatManager` | Heartbeat suppression |
| `LemonAutomation.Wake` | Manual triggering |
| `LemonAutomation.RunCompletionWaiter` | Wait for run completion |
| `LemonAutomation.RunSubmitter` | Router submission |
| `LemonAutomation.Events` | Event emission |
