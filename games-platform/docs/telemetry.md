# Telemetry Events Reference

This document provides a comprehensive reference of all telemetry events emitted by the Lemon agent runtime.

## Overview

Lemon uses Erlang's `:telemetry` library for observability. Events are emitted at key points in the system to enable monitoring, debugging, and performance analysis.

## Introspection Storage Contract (M1)

Telemetry events can be normalized into a canonical introspection envelope via `LemonCore.Introspection` and persisted through `LemonCore.Store`.

Canonical fields:

- `event_id` - unique event identifier
- `event_type` - taxonomy event name
- `ts_ms` - timestamp in milliseconds
- `run_id`, `session_key`, `agent_id`, `parent_run_id`, `engine`
- `provenance` - `:direct | :inferred | :unavailable`
- `payload` - redacted event payload

APIs:

- `LemonCore.Introspection.record/3` - build + persist canonical events
- `LemonCore.Introspection.list/1` - list events with filters (`run_id`, `session_key`, `agent_id`, `event_type`, `since_ms`, `until_ms`, `limit`)
- `LemonCore.Store.append_introspection_event/1` - low-level append
- `LemonCore.Store.list_introspection_events/1` - low-level filtered query

Retention:

- `LemonCore.Store` applies periodic retention sweep for `:introspection_log` (default: 7 days).

## Introspection Event Taxonomy

All event atoms passed as the first argument to `LemonCore.Introspection.record/3`. Grouped by the component that emits them.

### Lemon-Native Events (M2) — `engine: "lemon"`, `provenance: :direct`

#### RunProcess (`LemonRouter.RunProcess`)

| Event Type | When |
|---|---|
| `:run_started` | Run process initialised |
| `:run_completed` | Run finished (ok or error) |
| `:run_failed` | Run process terminated abnormally |

#### RunOrchestrator (`LemonRouter.RunOrchestrator`)

| Event Type | When |
|---|---|
| `:orchestration_started` | Submit received, run_id generated |
| `:orchestration_resolved` | Engine and model resolved, run process started |
| `:orchestration_failed` | Engine/model resolution failed |

#### ThreadWorker (`LemonGateway.ThreadWorker`)

| Event Type | When |
|---|---|
| `:thread_started` | Thread worker initialised |
| `:thread_message_dispatched` | Job enqueued to thread |
| `:thread_terminated` | Thread worker stopped |

#### Scheduler (`LemonGateway.Scheduler`)

| Event Type | When |
|---|---|
| `:scheduled_job_triggered` | Job submitted to in-flight pool |
| `:scheduled_job_completed` | Slot released after job completion |

#### Session (`CodingAgent.Session`)

| Event Type | When |
|---|---|
| `:session_started` | Session GenServer initialised |
| `:session_ended` | Session terminated |
| `:compaction_triggered` | Context compaction applied |

#### EventHandler (`CodingAgent.Session.EventHandler`)

| Event Type | When |
|---|---|
| `:tool_call_dispatched` | Tool call start event observed |

### Agent Loop Events (M3) — `AgentCore.Agent`

| Event Type | Provenance | When |
|---|---|---|
| `:agent_loop_started` | `:direct` | Agent loop begins |
| `:agent_turn_observed` | `:inferred` | Each agent turn completes (streaming end) |
| `:agent_loop_ended` | `:direct` | Agent loop finishes (idle transition) |

### JSONL Runner Events (M3) — `AgentCore.CliRunners.JsonlRunner`

| Event Type | Provenance | When |
|---|---|---|
| `:jsonl_stream_started` | `:direct` | CLI subprocess stream begins |
| `:tool_use_observed` | `:inferred` | Tool call detected in engine output |
| `:assistant_turn_observed` | `:inferred` | Assistant text turn detected |
| `:jsonl_stream_ended` | `:direct` | CLI subprocess stream ends |

### CLI Runner Engine Events (M3) — `provenance: :inferred`

Emitted by each engine-specific runner (Codex, Claude, Kimi, OpenCode, Pi).

| Event Type | Engines | When |
|---|---|---|
| `:engine_subprocess_started` | codex, claude, kimi, opencode, pi | Engine session/subprocess initialised |
| `:engine_output_observed` | codex, kimi, opencode, pi | Engine produces a final answer or output |
| `:engine_subprocess_exited` | codex, claude, kimi, opencode, pi | Engine subprocess exits with error |

## Attaching Handlers

```elixir
# Attach a handler for all agent_core events
:telemetry.attach_many(
  "my-handler",
  [
    [:agent_core, :loop, :start],
    [:agent_core, :loop, :end],
    [:agent_core, :tool_task, :start],
    [:agent_core, :tool_task, :end],
    [:agent_core, :tool_result, :emit]
  ],
  &MyModule.handle_event/4,
  %{my_config: true}
)

# Handler function
def handle_event(event, measurements, metadata, config) do
  IO.inspect({event, measurements, metadata}, label: "Telemetry")
end
```

## AgentCore Events

### Agent Loop Events

#### [:agent_core, :loop, :start]

Emitted when an agent loop begins execution.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `system_time` | integer | System time in native units |
| **Metadata** | | |
| `loop_type` | `:main` \| `:continue` | Type of loop being started |

#### [:agent_core, :loop, :end]

Emitted when an agent loop completes.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `duration` | integer | Duration in native time units |
| **Metadata** | | |
| `loop_type` | `:main` \| `:continue` | Type of loop that completed |
| `reason` | atom | Completion reason |

#### [:agent_core, :loop, :exception]

Emitted when an agent loop encounters an exception.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `system_time` | integer | When the exception occurred |
| **Metadata** | | |
| `kind` | atom | Exception kind (`:error`, `:throw`, `:exit`) |
| `reason` | term | Exception reason/value |

#### [:agent_core, :loop, :task_start_failed]

Emitted when the loop task fails to start.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `system_time` | integer | When the failure occurred |
| **Metadata** | | |
| `reason` | term | Failure reason |

### Tool Task Events

#### [:agent_core, :tool_task, :start]

Emitted when a tool task begins execution.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `system_time` | integer | Start time |
| **Metadata** | | |
| `tool_name` | string | Name of the tool |
| `tool_call_id` | string | Unique tool call identifier |

#### [:agent_core, :tool_task, :end]

Emitted when a tool task completes successfully.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `duration` | integer | Execution duration |
| **Metadata** | | |
| `tool_name` | string | Name of the tool |
| `tool_call_id` | string | Unique tool call identifier |
| `is_error` | boolean | Whether result was an error |

#### [:agent_core, :tool_task, :error]

Emitted when a tool task fails or is aborted.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `system_time` | integer | Error time |
| `duration` | integer | Time until error |
| **Metadata** | | |
| `tool_name` | string | Name of the tool |
| `tool_call_id` | string | Unique tool call identifier |
| `reason` | term | Error reason |

### Tool Result Events

#### [:agent_core, :tool_result, :emit]

Emitted when a tool result message is appended to context.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `system_time` | integer | Emit time (native units) |
| **Metadata** | | |
| `tool_name` | string | Name of the tool |
| `tool_call_id` | string | Unique tool call identifier |
| `is_error` | boolean | Whether the result is an error |
| `trust` | `:trusted` \| `:untrusted` | Normalized trust level for the emitted tool result |

`trust` comes from tool result trust normalization in the tool-call loop. Only `:untrusted` is emitted as untrusted; all other values are emitted as `:trusted`.

### Context Events

#### [:agent_core, :context, :size]

Emitted when context size is measured.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `char_count` | integer | Total characters in context |
| `message_count` | integer | Number of messages |
| **Metadata** | | |
| `has_system_prompt` | boolean | Whether system prompt was included |

#### [:agent_core, :context, :warning]

Emitted when context exceeds warning threshold.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `char_count` | integer | Current character count |
| `threshold` | integer | Threshold that was exceeded |
| **Metadata** | | |
| `level` | `:warning` \| `:critical` | Severity level |

#### [:agent_core, :context, :truncated]

Emitted when context is truncated.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `dropped_count` | integer | Messages dropped |
| `remaining_count` | integer | Messages remaining |
| **Metadata** | | |
| `strategy` | atom | Truncation strategy used |

### EventStream Events

#### [:agent_core, :event_stream, :queue_depth]

Emitted on each push to track queue depth.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `depth` | integer | Current queue depth |
| **Metadata** | | |
| `stream_id` | reference | Stream identifier |

#### [:agent_core, :event_stream, :dropped]

Emitted when events are dropped due to backpressure.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `count` | integer | Number of events dropped |
| **Metadata** | | |
| `stream_id` | reference | Stream identifier |
| `strategy` | atom | Drop strategy (`:drop_oldest`, `:drop_newest`) |

### Subagent Events

#### [:agent_core, :subagent, :spawn]

Emitted when a subagent is spawned.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `system_time` | integer | Spawn time |
| **Metadata** | | |
| `subagent_id` | term | Subagent identifier |
| `parent_session` | string | Parent session ID |

#### [:agent_core, :subagent, :end]

Emitted when a subagent completes.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `duration` | integer | Total execution time |
| **Metadata** | | |
| `subagent_id` | term | Subagent identifier |
| `reason` | atom | Completion reason |

### Agent Events

#### [:agent_core, :agent, :loop_error]

Emitted when the agent loop encounters an error.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `system_time` | integer | Error time |
| **Metadata** | | |
| `error` | term | Error details |

## CodingAgent Events

### Session Events

#### [:coding_agent, :session, :event_stream, :broadcast]

Emitted when events are broadcast to subscribers.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `subscriber_count` | integer | Total subscribers |
| `direct_count` | integer | Direct (legacy) subscribers |
| `stream_count` | integer | Stream subscribers |
| **Metadata** | | |
| `session_id` | string | Session identifier |

#### [:coding_agent, :session, :error]

Emitted when a session encounters an error.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `system_time` | integer | Error time |
| **Metadata** | | |
| `session_id` | string | Session identifier |
| `error` | term | Error details |

## AI Provider Events

### Dispatcher Events

#### [:ai, :dispatcher, :queue_depth]

Emitted to track dispatcher queue depth.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `depth` | integer | Current queue depth |
| **Metadata** | | |
| `provider` | atom | Provider name |

#### [:ai, :dispatcher, :rejected]

Emitted when a request is rejected (rate limit or circuit open).

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `system_time` | integer | Rejection time |
| **Metadata** | | |
| `provider` | atom | Provider name |
| `reason` | atom | `:rate_limited` \| `:circuit_open` |

#### [:ai, :dispatcher, :retry]

Emitted when a request is being retried.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `attempt` | integer | Current attempt number |
| `delay` | integer | Delay before retry (ms) |
| **Metadata** | | |
| `provider` | atom | Provider name |
| `error_type` | atom | Type of error that caused retry |

### Stream Events

#### [:ai, :stream, :error]

Emitted when a streaming error occurs.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `system_time` | integer | Error time |
| **Metadata** | | |
| `provider` | atom | Provider that failed |
| `error` | term | Error details |

## Example: Monitoring Dashboard

```elixir
defmodule MyApp.TelemetryHandler do
  require Logger

  def setup do
    events = [
      [:agent_core, :loop, :start],
      [:agent_core, :loop, :end],
      [:agent_core, :tool_task, :start],
      [:agent_core, :tool_task, :end],
      [:agent_core, :tool_result, :emit],
      [:agent_core, :tool_task, :error],
      [:agent_core, :context, :warning],
      [:coding_agent, :session, :event_stream, :broadcast],
      [:ai, :dispatcher, :rejected]
    ]

    :telemetry.attach_many("my-app-handler", events, &handle_event/4, nil)
  end

  def handle_event([:agent_core, :loop, :start], _measurements, metadata, _config) do
    Logger.info("Loop started: #{inspect(metadata.loop_type)}")
  end

  def handle_event([:agent_core, :loop, :end], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    Logger.info("Loop completed in #{duration_ms}ms: #{inspect(metadata.reason)}")
  end

  def handle_event([:agent_core, :tool_task, :end], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    Logger.info("Tool #{metadata.tool_name} completed in #{duration_ms}ms")
  end

  def handle_event([:agent_core, :tool_task, :error], _measurements, metadata, _config) do
    Logger.error("Tool #{metadata.tool_name} failed: #{inspect(metadata.reason)}")
  end

  def handle_event([:agent_core, :tool_result, :emit], _measurements, metadata, _config) do
    Logger.info(
      "Tool result #{metadata.tool_name} emitted " <>
        "(trust=#{metadata.trust}, error=#{metadata.is_error})"
    )
  end

  def handle_event([:agent_core, :context, :warning], measurements, metadata, _config) do
    Logger.warning(
      "Context #{metadata.level}: #{measurements.char_count} chars " <>
      "(threshold: #{measurements.threshold})"
    )
  end

  def handle_event([:ai, :dispatcher, :rejected], _measurements, metadata, _config) do
    Logger.warning("Request rejected: #{metadata.provider} - #{metadata.reason}")
  end

  def handle_event(event, measurements, metadata, _config) do
    Logger.debug("Telemetry: #{inspect(event)} #{inspect(measurements)} #{inspect(metadata)}")
  end
end
```

## Using with :telemetry_poller

The `AgentCore.TelemetryPoller` emits periodic VM stats:

```elixir
# These are emitted every 10 seconds by default:
# - [:vm, :memory]
# - [:vm, :total_run_queue_lengths]
# - [:vm, :system_counts]
```

To customize:

```elixir
# In your application config
config :telemetry_poller, :default,
  period: :timer.seconds(30),
  measurements: [
    {MyApp.Metrics, :dispatch_metrics, []}
  ]
```

## Performance Considerations

- Telemetry handlers run synchronously - keep them fast
- Use `:telemetry.span/3` for automatic start/end events
- Consider sampling high-frequency events in production
- Use `:telemetry_metrics` for aggregation

---

## Agent Introspection

Agent introspection is a higher-level persistence layer built on top of `:telemetry`. It captures a canonical event envelope for every meaningful agent lifecycle transition and persists it to `LemonCore.Store` for later query by operators.

### What Introspection Events Are

Introspection events are structured records that capture agent execution context at key moments: when a run starts or ends, when a session is created, when a tool executes, when a subprocess (subagent) is spawned, and similar lifecycle transitions. Unlike raw telemetry (which is fire-and-forget), introspection events are **persisted** and **queryable**.

Events are retained for 7 days by default and can be queried with filters for run ID, session key, agent ID, event type, and time range.

### Event Schema

Every introspection event has the following fields:

| Field | Type | Description |
|-------|------|-------------|
| `event_id` | `string` | Stable unique identifier (prefixed `evt_`) |
| `event_type` | `atom` or `string` | Event taxonomy name (see taxonomy below) |
| `ts_ms` | `integer` | Wall-clock timestamp in milliseconds since Unix epoch |
| `run_id` | `string` or `nil` | Run identifier |
| `session_key` | `string` or `nil` | Session identifier |
| `agent_id` | `string` or `nil` | Agent identifier |
| `parent_run_id` | `string` or `nil` | Lineage link to parent run when available |
| `engine` | `string` or `nil` | Engine name (e.g. `"claude"`, `"codex"`, `"lemon"`) |
| `provenance` | `:direct` or `:inferred` or `:unavailable` | How the context fields were resolved |
| `payload` | `map` | Event-specific metadata, redacted of secrets |

#### Provenance Values

- `:direct` — context fields (run_id, session_key, etc.) were provided directly by the emitting code.
- `:inferred` — context fields were derived from surrounding state (e.g. process dictionary or ETS).
- `:unavailable` — context could not be determined at emit time.

#### Redaction Defaults

The following payload fields are always removed before persistence:

- `api_key`, `apikey`, `authorization`, `password`, `private_key`
- `prompt`, `response`, `secret`, `secrets`, `stderr`, `stdout`, `token`

Tool argument fields (`arguments`, `input`, `tool_arguments`) are redacted by default. Pass `capture_tool_args: true` to `LemonCore.Introspection.record/3` to retain them.

Result preview fields (`preview`, `result_preview`) are kept by default and truncated to 256 bytes. Pass `capture_result_preview: false` to suppress them.

All other string values are truncated to 4096 bytes.

### Event Taxonomy

Events are organized into three categories:

#### Run Lifecycle

| Event Type | When Emitted |
|-----------|--------------|
| `run_started` | A run is accepted and begins processing |
| `run_completed` | A run finishes successfully |
| `run_aborted` | A run is aborted (user request or error) |
| `run_queued` | A run enters the queue awaiting a slot |
| `run_followup` | A follow-up run is submitted to an active session |

#### Session Lifecycle

| Event Type | When Emitted |
|-----------|--------------|
| `session_created` | A new session is established |
| `session_expired` | A session is cleaned up after TTL expiry |
| `session_policy_applied` | A policy is applied to a session |

#### Engine / Subprocess Events

| Event Type | When Emitted |
|-----------|--------------|
| `tool_started` | A tool begins execution within an agent loop |
| `tool_completed` | A tool finishes (success or error result) |
| `subagent_spawned` | A subprocess agent is spawned |
| `subagent_completed` | A subprocess agent finishes |
| `engine_loop_started` | An engine's main agent loop iteration begins |
| `engine_loop_completed` | An engine's main agent loop iteration ends |

### Querying via IEx

Start an IEx session against a running node (or directly with `iex -S mix`) and use `LemonCore.Introspection.list/1`:

```elixir
# All recent events (default limit: 100)
LemonCore.Introspection.list([])

# Filter by run ID
LemonCore.Introspection.list(run_id: "run_abc123", limit: 50)

# Filter by session key
LemonCore.Introspection.list(session_key: "agent:default:main", limit: 20)

# Filter by event type
LemonCore.Introspection.list(event_type: :tool_completed, limit: 30)

# Filter by agent
LemonCore.Introspection.list(agent_id: "my_agent", limit: 50)

# Time range (ms since Unix epoch)
now_ms = System.system_time(:millisecond)
one_hour_ago = now_ms - 60 * 60 * 1000
LemonCore.Introspection.list(since_ms: one_hour_ago, limit: 200)

# Combine filters
LemonCore.Introspection.list(
  run_id: "run_abc123",
  event_type: :tool_completed,
  limit: 10
)
```

Results are returned newest-first as a list of maps. Each map has the fields described in the schema table above.

### Querying via the Mix Task

The `mix lemon.introspection` task provides a human-readable table view for operators:

```bash
# Show the 20 most recent events (default)
mix lemon.introspection

# Increase limit
mix lemon.introspection --limit 100

# Filter by run ID
mix lemon.introspection --run-id run_abc123

# Filter by session key
mix lemon.introspection --session-key "agent:default:main"

# Filter by event type
mix lemon.introspection --event-type tool_completed

# Filter by agent
mix lemon.introspection --agent-id my_agent

# Relative time window (events in the last hour)
mix lemon.introspection --since 1h

# Relative time window (last 30 minutes)
mix lemon.introspection --since 30m

# Absolute time window (ISO 8601)
mix lemon.introspection --since 2026-02-23T00:00:00Z

# Combine filters
mix lemon.introspection --run-id run_abc123 --event-type tool_completed --limit 50
```

The task outputs a table with columns: `Timestamp`, `Event Type`, `Run ID`, `Session Key`, `Agent ID`, `Engine`, `Provenance`. Long identifiers are truncated with a `~` suffix.

### Emitting Introspection Events

Use `LemonCore.Introspection.record/3` to persist an event from any application in the umbrella:

```elixir
# Basic usage
LemonCore.Introspection.record(:run_started, %{origin: "telegram"}, run_id: run_id, session_key: session_key)

# With engine and agent context
LemonCore.Introspection.record(
  :tool_completed,
  %{tool_name: "exec", result_preview: "ok"},
  run_id: run_id,
  session_key: session_key,
  agent_id: "default",
  engine: "codex"
)

# With custom provenance
LemonCore.Introspection.record(
  :run_aborted,
  %{reason: "user_requested"},
  run_id: run_id,
  session_key: session_key,
  provenance: :inferred
)
```

### Disabling Introspection

To disable persistence of introspection events (events are silently dropped), add to your config:

```elixir
# config/config.exs or config/prod.exs
config :lemon_core, :introspection, enabled: false
```

When disabled, `LemonCore.Introspection.record/3` returns `:ok` immediately without touching the store. The `LemonCore.Introspection.enabled?/0` function reflects the current setting.

### Retention

The store applies a periodic retention sweep to the `:introspection_log` table. By default, events older than **7 days** are pruned. This sweep runs at the same interval as the chat-state sweep (every 5 minutes).
