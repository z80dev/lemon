# Rate Limit Auto-Resume Feature

## Overview

The Rate Limit Auto-Resume feature allows Lemon coding agent runs to automatically pause when hitting provider rate limits and resume execution after the rate limit reset window expires. This eliminates the need for manual intervention when long-running sessions encounter rate limits.

## Architecture

```
┌─────────────────┐     rate limit      ┌──────────────────┐
│   AI Provider   │ ◄────────────────── │  Coding Agent    │
│  (Anthropic,    │   (429 response)    │   Runtime        │
│   OpenAI, etc)  │                     └────────┬─────────┘
└─────────────────┘                              │
                                                 │ pause_for_limit
                                                 ▼
┌─────────────────┐                     ┌──────────────────┐
│  ResumeScheduler│ ◄────────────────── │    RunGraph      │
│   (GenServer)   │   periodic check    │  (state machine) │
└────────┬────────┘                     └──────────────────┘
         │
         │ resume
         ▼
┌─────────────────┐
│  RateLimitPause │ ◄── ETS-backed pause tracking
│   (ETS table)   │
└─────────────────┘
```

## Components

### 1. RateLimitPause

ETS-backed module for tracking pause state.

**Key Functions:**
- `create/4` - Creates a new pause record
- `get/1` - Retrieves a pause by ID
- `resume/1` - Marks a pause as resumed
- `ready_to_resume?/1` - Checks if pause window has elapsed
- `list_pending/1` - Lists active pauses for a session
- `stats/0` - Returns aggregate statistics

**Example:**
```elixir
# Create a pause
{:ok, pause} = CodingAgent.RateLimitPause.create(
  "session_123",
  :anthropic,
  60_000,  # 60 second retry-after
  metadata: %{error: "Rate limit exceeded"}
)

# Check if ready
if CodingAgent.RateLimitPause.ready_to_resume?(pause.id) do
  {:ok, resumed} = CodingAgent.RateLimitPause.resume(pause.id)
end
```

### 2. ResumeScheduler

GenServer that periodically checks for pauses ready to resume and triggers resumption.

**Configuration:**
```elixir
config :coding_agent, :rate_limit_resume,
  enabled: true,
  check_interval_ms: 30_000,
  max_concurrent_resumes: 5
```

**Manual Check:**
```elixir
{:ok, count} = CodingAgent.ResumeScheduler.check_and_resume()
```

### 3. RunGraph Integration

RunGraph supports the `paused_for_limit` state with:
- `pause_for_limit/2` - Transitions run to paused state
- `resume_from_limit/1` - Resumes run from paused state

**State Transitions:**
```
running ──pause_for_limit──► paused_for_limit ──resume_from_limit──► running
```

## Configuration

### Application Config

Add to `config/config.exs` or `~/.lemon/config.toml`:

```elixir
config :coding_agent, :rate_limit_auto_resume,
  enabled: true,                    # Enable auto-resume
  default_retry_after_ms: 60_000,   # Default wait when no retry-after header
  max_retry_attempts: 3             # Max retries per run

config :coding_agent, :rate_limit_resume,
  enabled: true,                    # Enable scheduler
  check_interval_ms: 30_000,        # Check every 30 seconds
  max_concurrent_resumes: 5         # Limit concurrent resumes
```

### Environment Variables

```bash
# Disable auto-resume
LEMON_RATE_LIMIT_AUTO_RESUME_ENABLED=false

# Customize check interval (milliseconds)
LEMON_RATE_LIMIT_RESUME_CHECK_INTERVAL_MS=60000
```

## Telemetry Events

The following telemetry events are emitted:

| Event | Description | Measurements | Metadata |
|-------|-------------|--------------|----------|
| `[:coding_agent, :rate_limit_pause, :paused]` | Run paused for rate limit | `retry_after_ms`, `time_to_resume` | `session_id`, `provider`, `pause_id` |
| `[:coding_agent, :rate_limit_pause, :resumed]` | Run resumed from pause | `retry_after_ms`, `time_to_resume` | `session_id`, `provider`, `pause_id` |

**Example Handler:**
```elixir
:telemetry.attach(
  "rate-limit-handler",
  [:coding_agent, :rate_limit_pause, :paused],
  fn event, measurements, metadata, _config ->
    Logger.info("Run paused: #{metadata.session_id} on #{metadata.provider}")
  end,
  nil
)
```

## API Methods

### rate_limit_pause.list

List all pauses for a session.

```json
{
  "jsonrpc": "2.0",
  "method": "rate_limit_pause.list",
  "params": {"session_id": "session_123"},
  "id": 1
}
```

### rate_limit_pause.get

Get details of a specific pause.

```json
{
  "jsonrpc": "2.0",
  "method": "rate_limit_pause.get",
  "params": {"pause_id": "rlp_abc123"},
  "id": 1
}
```

### rate_limit_pause.stats

Get aggregate statistics.

```json
{
  "jsonrpc": "2.0",
  "method": "rate_limit_pause.stats",
  "params": {},
  "id": 1
}
```

## User Notifications

When a run enters the `paused_for_limit` state, a PubSub event is emitted:

```elixir
LemonCore.PubSub.publish(
  "run:#{run_id}",
  {:run_paused_for_limit, %{run_id: run_id, pause_id: pause_id, resume_at: resume_at}}
)
```

Channel adapters can subscribe to these events to notify users.

## Testing

### Unit Tests

```bash
mix test apps/coding_agent/test/coding_agent/rate_limit_pause_test.exs
mix test apps/coding_agent/test/coding_agent/resume_scheduler_test.exs
```

### Integration Tests

```bash
mix test apps/coding_agent/test/coding_agent/rate_limit_auto_resume_integration_test.exs
```

### Manual Testing

1. Start the scheduler:
```elixir
CodingAgent.ResumeScheduler.start_link([])
```

2. Create a test pause:
```elixir
{:ok, pause} = CodingAgent.RateLimitPause.create(
  "test_session",
  :test_provider,
  5_000  # 5 seconds
)
```

3. Wait for automatic resume or trigger manually:
```elixir
CodingAgent.ResumeScheduler.resume_pause(pause.id)
```

## Troubleshooting

### Pauses not resuming automatically

1. Check if scheduler is running:
```elixir
Process.whereis(CodingAgent.ResumeScheduler)
```

2. Verify configuration:
```elixir
Application.get_env(:coding_agent, :rate_limit_resume)
```

3. Check scheduler stats:
```elixir
CodingAgent.ResumeScheduler.stats()
```

### Run stuck in paused_for_limit state

1. Check pause status:
```elixir
CodingAgent.RateLimitPause.get(pause_id)
```

2. Verify run state:
```elixir
CodingAgent.RunGraph.get_run(run_id)
```

3. Manual resume:
```elixir
CodingAgent.RunGraph.resume_from_limit(run_id)
```

## Implementation Notes

- Pause records are stored in ETS for fast access and automatic cleanup on node restart
- The scheduler uses a polling model with configurable interval (default 30s)
- Resume timing is based on the `retry_after_ms` value from the provider response
- Paused runs are not counted as active for concurrency limits
- Old pause records are automatically cleaned up after 24 hours
