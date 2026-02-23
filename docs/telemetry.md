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
