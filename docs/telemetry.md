# Telemetry

Every event in this document was verified against its emit site on **2026-08-10**. Where
an event name exists in code but nothing calls it, it is listed under
[Known gaps](#known-gaps-and-inconsistencies) rather than in the catalog — a catalog entry
here means the event actually fires.

`:telemetry ~> 1.0` (declared in `apps/lemon_core/mix.exs`) is the only observability
dependency in the tree. There is no `telemetry_metrics`, `telemetry_poller`, or
`phoenix_live_dashboard` anywhere, so the consumer example below uses plain
`:telemetry.attach_many/4`.

Two layers coexist and are easy to confuse:

- **Telemetry** (this document) is fire-and-forget. Handlers run synchronously in the
  emitting process; nothing is stored.
- **Introspection** ([below](#introspection-the-persisted-layer)) is a separate, persisted,
  queryable envelope written through `LemonCore.Store`. It has its own event taxonomy and is
  *not* derived from the telemetry events here.

## Conventions

### Naming

Three prefix families coexist. This is descriptive, not a recommendation — see
[Known gaps](#known-gaps-and-inconsistencies).

| Prefix | Meaning | Emitted via |
|---|---|---|
| `[:lemon, ...]` | Cross-cutting platform concerns: runs, channels, approvals, memory, scheduler, reload, WASM | `LemonCore.Telemetry.emit/3` and its named helpers |
| `[:lemon_agent, ...]`, `[:coding_agent, ...]`, `[:lemon_ai, ...]` | App-local concerns, prefixed by OTP app | `LemonCore.Telemetry.emit/3` or `:telemetry.execute/3` directly |
| `[:lemon_skills, ...]`, `[:lemon_sim_ui, ...]` | App-local, full app name as prefix | app-local helper module |

`LemonCore.Telemetry.emit/3` is a direct pass-through to `:telemetry.execute/3`
([`telemetry.ex`](../apps/lemon_core/lib/lemon_core/telemetry.ex)); attaching does not
depend on which one an emitter used.

### Span shape

Events ending in `:start` / `:stop` / `:exception` follow the `:telemetry.span/3` convention
by hand — none of them actually call `:telemetry.span/3`. The practical consequence is that
`:stop` is **not** guaranteed to follow every `:start`: if the emitting process is killed
between them, no `:stop` or `:exception` arrives. Consumers that pair them need their own
timeout.

### Measurement units are not uniform

There is no single duration convention. When writing a consumer, check the table for the
event you are attaching to:

| Unit | Used by |
|---|---|
| `duration` in **native** units | `[:lemon, :channels, :deliver, :stop]`, `[:lemon_agent, :loop, :end]`, `[:lemon_ai, :dispatcher, :rejected]` |
| `duration_us` | `[:coding_agent, :extension, :tool, ...]`, `[:coding_agent, :wasm, :tool, ...]`, `[:lemon, :memory, :ingest, ...]` |
| `duration_ms` | `[:lemon, :reload, ...]`, `[:lemon, :run, :stop]`, `[:lemon, :wasm, :*, :stop]`, `[:coding_agent, :python_repl, ...]` |
| both `duration` (native) and `duration_ms` | `[:lemon, :config, :reload, :stop]` and `:exception` — `duration` is a real monotonic native reading and `duration_ms` is derived from it via `System.convert_time_unit/3` |

`LemonCore.Telemetry`'s moduledoc records the intended convention for **new** emitters:
`duration` in native units, with `duration_ms` derived only for logs. Existing `duration_us`
/ `duration_ms` events predate it and are not renamed, because renaming is a breaking change
for any attached consumer.

`system_time` measurements are `System.system_time()` in native units and are timestamps,
not durations.

## Run lifecycle

The sequence below is the common path for a message arriving on a channel and producing a
reply. Not every step fires for every run: engine execution varies, and the tool block
repeats once per tool-calling turn.

```mermaid
sequenceDiagram
    participant Ch as Channel adapter
    participant R as LemonRouter
    participant S as Gateway Scheduler
    participant L as LemonAgent.Loop
    participant P as LemonAi.CallDispatcher
    participant M as LemonMemory.Ingest
    participant O as Channels Outbox

    Ch->>R: inbound message
    Note over Ch: [:lemon, :channels, :inbound]
    Note over R: [:lemon, :run, :submit]
    R->>S: request execution slot
    Note over S: [:lemon, :gateway, :scheduler, :slot_queued]<br/>then :slot_granted
    S->>L: run accepted
    Note over L: [:lemon_agent, :loop, :start]<br/>[:lemon_agent, :tool_schema_snapshot, :created]

    loop each turn
        L->>P: provider call
        Note over P: [:lemon_ai, :dispatcher, :dispatch]<br/>or [:lemon_ai, :dispatcher, :rejected]
        Note over L: [:lemon_agent, :tool_task, :start]<br/>[:lemon_agent, :tool_task, :end] or :error<br/>[:lemon_agent, :tool_result, :emit]
    end

    Note over L: [:lemon_agent, :loop, :end]
    L->>S: release slot
    Note over S: [:lemon, :gateway, :scheduler, :slot_released]
    L->>M: finalize run
    Note over M: [:lemon, :memory, :ingest, :ok] or :failure
    R->>O: enqueue reply
    Note over O: [:lemon, :channels, :outbox, :queue]<br/>[:lemon, :channels, :deliver, :start]<br/>[:lemon, :channels, :deliver, :stop]
    O->>Ch: delivered
```

**The end-to-end run span is emitted from the gateway run process.**
`[:lemon, :run, :start]`, `[:lemon, :run, :first_token]`, and `[:lemon, :run, :stop]` all
fire from `LemonGateway.Run`, dispatched through `LemonGateway.DependencyManager.emit_telemetry/2`
(an `apply/3` on `LemonCore.Telemetry`). Because that dispatch is dynamic, a literal-name grep
for the helpers turns up no callers even though the span fires — this is why an earlier
revision of this file wrongly listed them as dead. `[:lemon, :run, :stop]` carries
`duration_ms` and an `ok` boolean, so whole-run latency and success/failure are both readable
from telemetry alone. The introspection layer's `:run_started` / `:run_completed` records
remain available as a persisted, queryable alternative.

## Event catalog

### Run lifecycle — `[:lemon, :run, ...]`

| Event | Measurements | Metadata | Emitter |
|---|---|---|---|
| `[:lemon, :run, :submit]` | `count: 1` | `session_key`, `origin`, `engine` | `LemonCore.Telemetry.run_submit/3`, called from [`run_orchestrator.ex:211`](../apps/lemon_router/lib/lemon_router/run_orchestrator.ex) when a submission is accepted |
| `[:lemon, :run, :start]` | `ts_ms` | `run_id`, `session_key`, `engine`, `origin` | [`run.ex:259`](../apps/lemon_gateway/lib/lemon_gateway/run.ex) via `DependencyManager.emit_telemetry(:run_start, ...)`, when the gateway starts the engine run |
| `[:lemon, :run, :first_token]` | `latency_ms` | `run_id` | [`run.ex:428`](../apps/lemon_gateway/lib/lemon_gateway/run.ex), on the first engine delta of the run |
| `[:lemon, :run, :stop]` | `duration_ms`, `ok` (boolean) | `run_id` | [`run.ex:611`](../apps/lemon_gateway/lib/lemon_gateway/run.ex), at finalize; `ok` distinguishes success from `{:error, _}`. Not emitted if the run process crashes before finalize |
| `[:lemon, :router, :run_abort_tombstone, :registered]` | `count: 1` | bounded `reason` label | `LemonRouter.RunOrchestrator`, when a fixed run ID is marked aborted at the serialized submission boundary |
| `[:lemon, :router, :run_abort_tombstone, :submission_rejected]` | `count: 1` | bounded `reason` label | `LemonRouter.RunOrchestrator`, when a later submission is rejected by that tombstone |

### Cron — `[:lemon, :cron, ...]`

| Event | Measurements | Metadata | Emitter |
|---|---|---|---|
| `[:lemon, :cron, :tick]` | `job_count` | `%{}` (empty) | `LemonCore.Telemetry.cron_tick/1`, called from [`cron_manager.ex`](../apps/lemon_automation/lib/lemon_automation/cron_manager.ex) once per scheduler tick as a liveness heartbeat with the count of registered jobs |

Cron terminalization, retry reconstruction, and Kanban hard-stop lease reclaim
do not add telemetry events. Their restart-safe
evidence is durable state/audit plus Bus lifecycle events: CronManager writes
terminal runs and retry lineage before emitting `:cron_run_completed`, Kanban
guards terminal writes by lease ID, and GoalLoopManager stores the authoritative
router run ID in goal-loop status. Goal-loop hard stops additionally expose the
router tombstone counters above, but operators should use persisted goal state
for exact lifecycle counts; `[:lemon, :cron, :tick]` remains only a liveness signal.

### Heartbeats — `[:lemon, :heartbeat, ...]`

| Event | Measurements | Metadata | Emitter |
|---|---|---|---|
| `[:lemon, :heartbeat, :skipped]` | `count: 1` | `agent_id`, `reason: :overlap` | `LemonAutomation.HeartbeatManager`, when a timer tick arrives while the prior timer heartbeat for that agent is still in flight |

### Channels — `[:lemon, :channels, ...]`

| Event | Measurements | Metadata | Emitter |
|---|---|---|---|
| `[:lemon, :channels, :inbound]` | `count: 1` | `channel_id`, `account_id`, `peer_kind`, `agent_id` | [`channels/runtime.ex:113`](../apps/lemon_channels/lib/lemon_channels/runtime.ex) and [`router.ex:92`](../apps/lemon_router/lib/lemon_router/router.ex), on each normalized inbound message |
| `[:lemon, :channels, :dispatch]` | `count: 1`, `duration` (native) | `channel_id`, `account_id`, `kind`, `intent_id`, `run_id`, `session_key`, `ok` (boolean) | [`dispatcher.ex`](../apps/lemon_channels/lib/lemon_channels/dispatcher.ex), after every `LemonChannels.Dispatcher.dispatch/1` — fires for both success and `{:error, _}`, check `ok`. Its bus twin is the `:channel_delivery` event on the `channels` topic (see `docs/platform/bus-events.md` §10) |
| `[:lemon, :channels, :outbox, :queue]` | `depth`, `max_queue_size`, `count: 1` | caller map plus `event` (`:enqueued`, and other queue transitions) | [`outbox.ex:742`](../apps/lemon_channels/lib/lemon_channels/outbox.ex) |
| `[:lemon, :channels, :outbox, :rejected]` | `count: 1`, `queue_depth`, `max_queue_size` | `reason: :queue_full`, `channel_id`, `account_id`, `chunk_count` | [`outbox.ex:97`](../apps/lemon_channels/lib/lemon_channels/outbox.ex), when the bounded queue refuses work |
| `[:lemon, :channels, :deliver, :start]` | `system_time` | `channel_id`, `account_id`, `chunk_index` | [`outbox.ex:574`](../apps/lemon_channels/lib/lemon_channels/outbox.ex) |
| `[:lemon, :channels, :deliver, :stop]` | `duration` (native) | delivery meta plus `ok` (boolean) | [`outbox.ex:608`](../apps/lemon_channels/lib/lemon_channels/outbox.ex); fires for both success and `{:error, _}` — check `ok` |
| `[:lemon, :channels, :deliver, :exception]` | `duration` (native) | delivery meta plus `kind: :exception`, `reason`, `stacktrace` | [`outbox.ex:591`](../apps/lemon_channels/lib/lemon_channels/outbox.ex), only when the plugin raises |

### Engine scheduling — `[:lemon, :gateway, :scheduler, ...]`

Last segment is built at runtime from an atom argument
([`scheduler.ex:477`](../apps/lemon_gateway/lib/lemon_gateway/scheduler.ex)). Values:
`:slot_granted`, `:slot_queued`, `:slot_released`.

| Event | Measurements | Metadata |
|---|---|---|
| `[:lemon, :gateway, :scheduler, :slot_granted]` | `in_flight`, `max`, `waitq`, `wait_ms`, `count: 1` | `%{}` (empty) |
| `[:lemon, :gateway, :scheduler, :slot_queued]` | `in_flight`, `max`, `waitq`, `count: 1` | `%{}` (empty) |
| `[:lemon, :gateway, :scheduler, :slot_released]` | `in_flight`, `max`, `waitq`, `count: 1` | `%{}` (empty) |

These are the clearest saturation signal in the system: `waitq > 0` means runs are waiting
for an engine slot. The empty metadata means they cannot be correlated to a run or session.

### Engine-lock observation — `[:lemon, :gateway, :engine_lock, ...]`

| Event | Measurements | Metadata |
|---|---|---|
| `[:lemon, :gateway, :engine_lock, :over_age_live_owner]` | `count: 1`, `age_ms`, `threshold_ms` | redacted `thread_key` and owner process representations |

This event is observational: it means an exclusive owner is still alive beyond
the configured age threshold. The sweep does not release or transfer the lock;
ownership changes only on explicit release or confirmed owner death.

### Agent loop — `[:lemon_agent, ...]`

| Event | Measurements | Metadata | Emitter |
|---|---|---|---|
| `[:lemon_agent, :loop, :start]` | `system_time` | `prompt_count`, `message_count`, `tool_count`, `model` | [`loop.ex:305`](../apps/lemon_agent/lib/lemon_agent/loop.ex) (fresh loop) and `:352` (continue loop; `prompt_count` is always 0 there) |
| `[:lemon_agent, :loop, :end]` | `duration` (native, **may be `nil`**), `system_time` | `message_count`, `model`, `status` (`:completed` \| `:early_exit`) | [`loop.ex:807`](../apps/lemon_agent/lib/lemon_agent/loop.ex) |
| `[:lemon_agent, :loop, :state_transition]` | `system_time` | caller map plus `from`, `to` | [`loop.ex:754`](../apps/lemon_agent/lib/lemon_agent/loop.ex) |
| `[:lemon_agent, :tool_schema_snapshot, :created]` | `system_time` | `snapshot_id`, `fingerprint`, `tool_count`, `tool_names` | [`loop.ex:399`](../apps/lemon_agent/lib/lemon_agent/loop.ex) |
| `[:lemon_agent, :tool_task, :start]` | `system_time` | `tool_name`, `tool_call_id` | [`tool_calls.ex:551`](../apps/lemon_agent/lib/lemon_agent/loop/tool_calls.ex) |
| `[:lemon_agent, :tool_task, :end]` | `system_time` | `tool_name`, `tool_call_id`, `is_error` | [`tool_calls.ex:211`](../apps/lemon_agent/lib/lemon_agent/loop/tool_calls.ex) |
| `[:lemon_agent, :tool_task, :error]` | `system_time` | `tool_name`, `tool_call_id`, `reason` | six sites in [`tool_calls.ex`](../apps/lemon_agent/lib/lemon_agent/loop/tool_calls.ex) — `:137`/`:152` (`reason: :aborted`), `:309` (task crash), `:389` (`:timeout`), `:586` (`{:start_failed, reason}`), `:601` (prepare failure) |
| `[:lemon_agent, :tool_result, :emit]` | `system_time` | `tool_name`, `tool_call_id`, `is_error`, `trust` | [`tool_calls.ex:692`](../apps/lemon_agent/lib/lemon_agent/loop/tool_calls.ex). `trust` is normalized: only `:untrusted` stays untrusted, everything else becomes `:trusted` |
| `[:lemon_agent, :tool_call, :name_normalized]` | `system_time` | `original_name`, `matched_tool_name` | [`tool_calls.ex:747`](../apps/lemon_agent/lib/lemon_agent/loop/tool_calls.ex), when a model-supplied tool name needed fuzzy matching |
| `[:lemon_agent, :context, :size]` | `char_count`, `message_count` | `has_system_prompt` | [`context.ex:113`](../apps/lemon_agent/lib/lemon_agent/context.ex), on every `estimate_size/2` call |
| `[:lemon_agent, :context, :warning]` | `char_count`, `threshold` | `level` (`:warning` \| `:critical`) | [`context.ex:206`](../apps/lemon_agent/lib/lemon_agent/context.ex) (critical) and `:222` (warning) |
| `[:lemon_agent, :context, :truncated]` | `dropped_count`, `remaining_count` | `strategy` | [`context.ex:287`](../apps/lemon_agent/lib/lemon_agent/context.ex) |
| `[:lemon_agent, :subagent, :spawn]` | `system_time` | `pid`, `registry_key`, `has_registry_key` | [`subagent_supervisor.ex:99`](../apps/lemon_agent/lib/lemon_agent/subagent_supervisor.ex) |
| `[:lemon_agent, :subagent, :end]` | `system_time` | `pid`, `reason: :stopped` | [`subagent_supervisor.ex:150`](../apps/lemon_agent/lib/lemon_agent/subagent_supervisor.ex). Only fires on explicit stop — a crashed subagent emits nothing |

### Providers — `[:lemon_ai, ...]`

| Event | Measurements | Metadata | Emitter |
|---|---|---|---|
| `[:lemon_ai, :dispatcher, :dispatch]` | `system_time` | `provider` | [`call_dispatcher.ex:79`](../apps/lemon_ai/lib/lemon_ai/call_dispatcher.ex), before breaker and rate-limit checks |
| `[:lemon_ai, :dispatcher, :rejected]` | `duration`, `system_time` | `provider`, `reason`, `retry_after_ms` (circuit-open only) | [`call_dispatcher.ex:94`](../apps/lemon_ai/lib/lemon_ai/call_dispatcher.ex) (`:circuit_open`), `:127` (`:rate_limited`), `:140` (`:max_concurrency`) |
| `[:lemon_ai, :circuit_breaker, :opened]` | `system_time` | `provider`, `failure_count`, `failure_threshold`, `reason` | [`circuit_breaker.ex:291`](../apps/lemon_ai/lib/lemon_ai/circuit_breaker.ex) |
| `[:lemon_ai, :circuit_breaker, :closed]` | `system_time` | `provider` | [`circuit_breaker.ex:258`](../apps/lemon_ai/lib/lemon_ai/circuit_breaker.ex), recovery confirmed |
| `[:lemon_ai, :circuit_breaker, :half_opened]` | `system_time` | `provider`, `recovery_timeout` | [`circuit_breaker.ex:370`](../apps/lemon_ai/lib/lemon_ai/circuit_breaker.ex) |
| `[:lemon_ai, :circuit_breaker, :reopened]` | `system_time` | `provider`, `reason` | [`circuit_breaker.ex:317`](../apps/lemon_ai/lib/lemon_ai/circuit_breaker.ex), probe failed during half-open |
| `[:lemon_ai, :compacting_client, <event>]` | varies by call site | varies | [`compacting_client.ex:233`](../apps/lemon_ai/lib/lemon_ai/compacting_client.ex). Runtime suffix: `:request_started`, `:request_succeeded`, `:request_failed`, `:compaction_retry` |
| `[:lemon_ai, :context_compactor, <event>]` | `system_time` | varies | [`context_compactor.ex:370`](../apps/lemon_ai/lib/lemon_ai/context_compactor.ex). Runtime suffix: `:compaction_started`, `:compaction_succeeded`, `:compaction_failed` |
| `[:lemon_ai, :prompt_diagnostics, :llm_call]` | `system_time` | `data`, `engine: "ai"`, `session_key`, `agent_id`, `run_id` | [`prompt_diagnostics.ex:158`](../apps/lemon_ai/lib/lemon_ai/prompt_diagnostics.ex). Correlation fields come from `x-lemon-*` request headers and are `nil` when absent |

### Memory — `[:lemon, :memory, ...]`

| Event | Measurements | Metadata | Emitter |
|---|---|---|---|
| `[:lemon, :memory, :ingest, :ok]` | `duration_us` | `run_id`, `session_key`, `agent_id` | [`ingest.ex:114`](../apps/lemon_memory/lib/lemon_memory/ingest.ex) |
| `[:lemon, :memory, :ingest, :failure]` | `count: 1`, `duration_us` | `run_id`, `error` (message string) | [`ingest.ex:129`](../apps/lemon_memory/lib/lemon_memory/ingest.ex) |

### Approvals — `[:lemon, :approvals, ...]`

| Event | Measurements | Metadata | Emitter |
|---|---|---|---|
| `[:lemon, :approvals, :requested]` | `count: 1` | `approval_id`, `tool`, `run_id`, `session_id`, `session_key`, `agent_id` | [`exec_approvals.ex:101`](../apps/lemon_core/lib/lemon_core/exec_approvals.ex) |
| `[:lemon, :approvals, :resolved]` | `count: 1` | `approval_id`, `decision`, `tool`, `run_id` | [`exec_approvals.ex:161`](../apps/lemon_core/lib/lemon_core/exec_approvals.ex) (user decision) and `:373` (`decision: :timeout`) |

### Control plane fan-out — `[:lemon, :control_plane, ...]`

| Event | Measurements | Metadata | Emitter |
|---|---|---|---|
| `[:lemon, :control_plane, :event_bridge, :broadcast]` | `count: 1`, `recipients` | `event`, `recipients` | [`event_bridge.ex:290`](../apps/lemon_control_plane/lib/lemon_control_plane/event_bridge.ex) |
| `[:lemon, :control_plane, :event_bridge, :dropped]` | `count: 1`, `recipients` | `event`, `reason` (inspected, truncated to 80 chars) | [`event_bridge.ex:328`](../apps/lemon_control_plane/lib/lemon_control_plane/event_bridge.ex) |

### Configuration and hot reload — `[:lemon, :config | :reload, ...]`

| Event | Measurements | Metadata | Emitter |
|---|---|---|---|
| `[:lemon, :config, :reload, :start]` | `system_time` | reload context | [`config_reloader.ex:178`](../apps/lemon_core/lib/lemon_core/config_reloader.ex) |
| `[:lemon, :config, :reload, :stop]` | `duration`, `duration_ms` | context plus `changed_count`, `actions_count` | [`config_reloader.ex:212`](../apps/lemon_core/lib/lemon_core/config_reloader.ex) (no-change path, `changed_count: 0`) and `:273` |
| `[:lemon, :config, :reload, :exception]` | `duration`, `duration_ms` | context plus `kind`, `reason`, `stacktrace` | [`config_reloader.ex:301`](../apps/lemon_core/lib/lemon_core/config_reloader.ex) |
| `[:lemon, :reload, :start]` | `system_time` | reload context | [`reload.ex:463`](../apps/lemon_core/lib/lemon_core/reload.ex) |
| `[:lemon, :reload, :stop]` | `duration_ms` | context plus `status` | [`reload.ex:471`](../apps/lemon_core/lib/lemon_core/reload.ex) |
| `[:lemon, :reload, :exception]` | `duration_ms` | context plus `error`, `stacktrace` | [`reload.ex:482`](../apps/lemon_core/lib/lemon_core/reload.ex) (rescue) and `:493` (catch) |

### Extension and WASM tools — `[:coding_agent, ...]` and `[:lemon, :wasm, ...]`

| Event | Measurements | Metadata | Emitter |
|---|---|---|---|
| `[:coding_agent, :extension, :tool, :start]` | `count: 1` | tool identity | [`tool_registry.ex:392`](../apps/coding_agent/lib/coding_agent/tool_registry.ex) |
| `[:coding_agent, :extension, :tool, :stop]` | `count: 1`, `duration_us` | tool identity plus `status` | [`tool_registry.ex:399`](../apps/coding_agent/lib/coding_agent/tool_registry.ex) |
| `[:coding_agent, :extension, :tool, :exception]` | `count: 1`, `duration_us` | tool identity plus `kind`, `error_type` | [`tool_registry.ex:410`](../apps/coding_agent/lib/coding_agent/tool_registry.ex) (rescue) and `:423` (catch); both re-raise |
| `[:coding_agent, :wasm, :tool, :start]` | `count: 1` | tool identity | [`wasm/tool_factory.ex:58`](../apps/coding_agent/lib/coding_agent/wasm/tool_factory.ex) |
| `[:coding_agent, :wasm, :tool, :stop]` | `count: 1`, `duration_us` | tool identity plus `status` | [`wasm/tool_factory.ex:113`](../apps/coding_agent/lib/coding_agent/wasm/tool_factory.ex) |
| `[:coding_agent, :wasm, :tool, :exception]` | `count: 1`, `duration_us` | tool identity plus `kind`, `error_type` | [`wasm/tool_factory.ex:121`](../apps/coding_agent/lib/coding_agent/wasm/tool_factory.ex) |
| `[:coding_agent, :tool_call, :name_normalized]` | `system_time` | `original_name`, `matched_tool_name` | [`tool_registry.ex:148`](../apps/coding_agent/lib/coding_agent/tool_registry.ex). Shares its metadata keys with the `[:lemon_agent, ...]` event of the same leaf name |
| `[:lemon, :wasm, :discover, :start]` | `count: 1` | `host: :wasm`, `session_hash`, `cwd_hash` | [`wasm/sidecar_session.ex:191`](../apps/coding_agent/lib/coding_agent/wasm/sidecar_session.ex) |
| `[:lemon, :wasm, :discover, :stop]` | `duration_ms`, `ok` | `host: :wasm`, `session_hash`, `cwd_hash` | [`wasm/sidecar_session.ex:376`](../apps/coding_agent/lib/coding_agent/wasm/sidecar_session.ex) |
| `[:lemon, :wasm, :invoke, :start]` | `count: 1` | `host: :wasm`, `session_hash`, `cwd_hash`, `tool_hash` | [`wasm/sidecar_session.ex:220`](../apps/coding_agent/lib/coding_agent/wasm/sidecar_session.ex) |
| `[:lemon, :wasm, :invoke, :stop]` | `duration_ms`, `ok` | `host: :wasm`, `session_hash`, `cwd_hash`, `tool_hash` | [`wasm/sidecar_session.ex:408`](../apps/coding_agent/lib/coding_agent/wasm/sidecar_session.ex) |

Session and cwd identifiers in the WASM events are hashed, not raw.

### Execute code and persistent Python kernels — `[:coding_agent, :execute_code | :python_repl, ...]`

The `execute_code` per-call path emits one event from
[`execute_code.ex`](../apps/coding_agent/lib/coding_agent/tools/execute_code.ex)
(`LemonCore.Telemetry.emit/3`):

| Event | Measurements | Metadata |
|---|---|---|
| `[:coding_agent, :execute_code, :stop]` | `count: 1`, `duration_us` | `rpc_calls`, `rpc_denied`, `exit_code` (integer or `nil`) |

The persistent-kernel subsystem (`kernel_mode = "session"`; see
[`docs/tools/execute-code.md`](tools/execute-code.md)) emits the
`[:coding_agent, :python_repl, ...]` families below. Measurements carry only bounded
counts, capacities, and durations; metadata is a strict allowlist of categorical atoms.
These events **never** include code, output, traceback text, bridge tokens, bridge or
workspace paths, cwd, interpreter paths, PIDs, key digests, or raw errors.

| Event | Measurements | Metadata |
|---|---|---|
| `[:coding_agent, :python_repl, :session, :start]` | `count: 1`, `live_kernels`, `capacity` | `%{}` |
| `[:coding_agent, :python_repl, :session, :stop]` | `count: 1`, `duration_ms`, `live_kernels`, `capacity` | `reason` |
| `[:coding_agent, :python_repl, :session, :crash]` | `count: 1`, `duration_ms`, `live_kernels`, `capacity` | `reason` |
| `[:coding_agent, :python_repl, :session, :reap]` | `count: 1`, `idle_ms`, `live_kernels`, `capacity` | `reason` |
| `[:coding_agent, :python_repl, :cell, :start]` | `count: 1`, `queue_depth`, `queue_capacity` | `%{}` |
| `[:coding_agent, :python_repl, :cell, :stop]` | `count: 1`, `duration_ms` | `outcome` |
| `[:coding_agent, :python_repl, :cell, :cancel]` | `count: 1`, `duration_ms` | `cause` |
| `[:coding_agent, :python_repl, :fallback]` | `count: 1` | `reason` (`:missing_session_scope` \| `:registry_unavailable` \| `:capacity_exhausted` \| `:startup_failed` \| `:stop_failed`) |
| `[:coding_agent, :python_repl, :bridge, :deny]` | `count: 1` | `reason: :authentication` |

Each of these is also recorded best-effort through `LemonCore.Introspection` as a redacted
`:python_repl_lifecycle_observed` summary containing only the event atom plus the same
bounded measurements and categorical metadata — no run/session/key identity or payload.
`CodingAgent.PythonRepl.snapshot/0` exposes only aggregate state (live/capacity counts,
per-phase counts, owner and fork counts, reap settings). There is no control-plane API
for kernel management.

### Session recovery and rate limiting — `[:coding_agent, ...]`

All four families build the last segment at runtime.

| Event | Suffix values | Measurements | Metadata |
|---|---|---|---|
| `[:coding_agent, :rate_limit_pause, <event>]` | `:paused`, `:resumed` | `retry_after_ms`, `time_to_resume` | `session_id` and pause context ([`rate_limit_pause.ex:265`](../apps/coding_agent/lib/coding_agent/rate_limit_pause.ex)) |
| `[:coding_agent, :rate_limit_healer, <event>]` | `:probe_attempt`, `:probe_success`, `:probe_rate_limited`, `:probe_error`, `:healed`, `:failed`, `:stopped` | caller-supplied | `session_id`, `provider`, `model`, `healing_state`, `probe_count` ([`rate_limit_healer.ex:566`](../apps/coding_agent/lib/coding_agent/rate_limit_healer.ex)) |
| `[:coding_agent, :session_fork, <event>]` | `:fork_completed`, `:fork_failed`, `:original_terminated` | `%{}` (empty) | caller map plus `original_session_id`, `timestamp` ([`session_fork.ex:175`](../apps/coding_agent/lib/coding_agent/session_fork.ex)) |
| `[:coding_agent, :session, :overflow_recovery, <stage>]` | `:attempt`, `:success`, `:failure` | `count: 1` | recovery context including `duration_ms` ([`session/compaction_manager.ex:209`](../apps/coding_agent/lib/coding_agent/session/compaction_manager.ex)) |

### Skills — `[:lemon_skills, :skill, ...]`

All three carry `count: 1` and `system_time` measurements and are emitted through
[`lemon_skills/telemetry.ex:61`](../apps/lemon_skills/lib/lemon_skills/telemetry.ex), which
drops `nil` metadata values before emitting. Bodies of skills and file contents are never
included.

| Event | Fires when | Key metadata |
|---|---|---|
| `[:lemon_skills, :skill, :load]` | `read_skill` returns a skill or a not-found result | `result` (`ok` \| `not_found`), `key`, `name`, `source`, `path`, `view`, `section`, `file_path`, `tool_call_id`, `run_id`, `session_key`, `session_id`, `agent_id`, `cwd` |
| `[:lemon_skills, :skill, :write]` | `skill_manage` accepts or rejects a write | `result`, `action` (`create` \| `edit` \| `patch` \| `delete` \| `write_file` \| `remove_file`), `name`, `scope`, `path`, `audit_status`, `replacements`, `reason`, plus correlation fields |
| `[:lemon_skills, :skill, :prompt_render]` | prompt composition renders a skills block | `surface` (`available` \| `relevant`), `skill_count`, `skill_keys`, `active_count`, `not_ready_count`, `missing_count`, plus correlation fields |

`LemonSkills.Application` attaches an introspection bridge at boot that projects these three
into persisted `:skill_load_observed`, `:skill_write_observed`, and
`:skill_prompt_render_observed` records, and updates `LemonSkills.Usage` counters.

At session end, missed-skill introspection compares the exact relevance keys cached in the
session for that turn with successful `read_skill` load observations. It does not parse
turn-specific XML from the system prompt; no relevance block is added to that cacheable
prompt or to the persisted conversation.

### Hosted sim rooms — `[:lemon_sim_ui, :hosted_werewolf, ...]`

Emitted through `LemonSimUi.HostedGame.emit/3`
([`hosted_game.ex:771`](../apps/lemon_sim_ui/lib/lemon_sim_ui/hosted_game.ex)), all with
`count: 1` and a `room_id`. Runtime suffix values: `:seat_claimed`, `:player_connected`,
`:player_disconnected`, `:command_accepted`, `:command_rejected`, `:turn_timeout`,
`:game_started`, `:game_stopped`, `:game_completed`, `:ai_error`, `:room_failed`,
`:persistence_error`. The `hosted_werewolf` segment is historical; the module now backs all
hosted room types.

## Attaching a consumer

This is the whole integration surface. Handlers run **synchronously in the emitting
process**, so they must be fast and must not raise — a raising handler is detached by
`:telemetry` and stops receiving events.

```elixir
defmodule MyApp.TelemetryLogger do
  @moduledoc "Logs the saturation and failure signals worth paging on."

  require Logger

  @events [
    [:lemon, :channels, :outbox, :rejected],
    [:lemon, :gateway, :scheduler, :slot_queued],
    [:lemon_ai, :dispatcher, :rejected],
    [:lemon_ai, :circuit_breaker, :opened],
    [:lemon_agent, :tool_task, :error],
    [:lemon_agent, :context, :warning],
    [:lemon, :memory, :ingest, :failure]
  ]

  def attach do
    :telemetry.attach_many(
      "my-app-telemetry-logger",
      @events,
      &__MODULE__.handle_event/4,
      %{}
    )
  end

  def handle_event([:lemon, :channels, :outbox, :rejected], m, meta, _config) do
    Logger.warning(
      "outbox rejected channel=#{meta.channel_id} reason=#{meta.reason} " <>
        "depth=#{m.queue_depth}/#{m.max_queue_size}"
    )
  end

  def handle_event([:lemon, :gateway, :scheduler, :slot_queued], m, _meta, _config) do
    Logger.warning("engine slots saturated in_flight=#{m.in_flight}/#{m.max} waitq=#{m.waitq}")
  end

  def handle_event([:lemon_ai, :dispatcher, :rejected], _m, meta, _config) do
    Logger.warning("provider rejected provider=#{meta.provider} reason=#{meta.reason}")
  end

  def handle_event([:lemon_ai, :circuit_breaker, :opened], _m, meta, _config) do
    Logger.error(
      "circuit opened provider=#{meta.provider} " <>
        "failures=#{meta.failure_count}/#{meta.failure_threshold}"
    )
  end

  def handle_event([:lemon_agent, :tool_task, :error], _m, meta, _config) do
    Logger.error("tool failed tool=#{meta.tool_name} reason=#{inspect(meta.reason)}")
  end

  def handle_event([:lemon_agent, :context, :warning], m, meta, _config) do
    Logger.warning("context #{meta.level}: #{m.char_count} chars (threshold #{m.threshold})")
  end

  def handle_event([:lemon, :memory, :ingest, :failure], m, meta, _config) do
    Logger.error("memory ingest failed run=#{meta.run_id} after #{m.duration_us}us: #{meta.error}")
  end
end
```

Call `MyApp.TelemetryLogger.attach()` once at application start, after `:telemetry` is
running.

### Verifying an attachment without a full runtime

`mix run --no-start` does not start the `:telemetry` application, so `attach_many/4` will
exit with `no process`. Start it explicitly and drive a real emit path:

```elixir
{:ok, _} = Application.ensure_all_started(:telemetry)

:telemetry.attach_many(
  "probe",
  [[:lemon_agent, :context, :size], [:lemon_agent, :context, :warning]],
  fn event, measurements, metadata, _ ->
    IO.inspect({event, measurements, metadata})
  end,
  %{}
)

messages = [%{role: :user, content: "hello world"}, %{role: :assistant, content: "hi"}]
LemonAgent.Context.estimate_size(messages, "you are a test")
LemonAgent.Context.check_size(messages, nil, warning_threshold: 1, critical_threshold: 2, log: false)
```

Running that under `mix run --no-start` produces:

```
{[:lemon_agent, :context, :size], %{char_count: 27, message_count: 2}, %{has_system_prompt: true}}
{[:lemon_agent, :context, :size], %{char_count: 13, message_count: 2}, %{has_system_prompt: false}}
{[:lemon_agent, :context, :warning], %{threshold: 2, char_count: 13}, %{level: :critical}}
```

`LemonAgent.Context` is a good probe target because it emits from a pure function with no
supervision tree, no store, and no network.

### Aggregating into metrics

**`telemetry_metrics` is not a dependency of this repo**, and neither is
`telemetry_metrics_prometheus` or `phoenix_live_dashboard`. Nothing here aggregates,
samples, or exports — the runtime emits, and what happens next is the host application's
choice. This section is what wiring it up looks like *if you add those deps to your own
project*; it is not describing something that ships.

```elixir
# in your own app's mix.exs:
#   {:telemetry_metrics, "~> 1.0"},
#   {:telemetry_metrics_prometheus, "~> 1.1"}

import Telemetry.Metrics

def metrics do
  [
    # Saturation: the two signals that mean "shed load or add capacity".
    last_value("lemon.gateway.scheduler.waitq", tags: []),
    counter("lemon.channels.outbox.rejected.count", tags: [:channel_id, :reason]),

    # Provider health.
    counter("ai.dispatcher.rejected.duration", tags: [:provider, :reason]),
    counter("ai.circuit_breaker.opened.system_time", tags: [:provider]),

    # Tool reliability.
    counter("agent_core.tool_task.error.system_time", tags: [:tool_name, :reason]),

    # Latency. Note the three different units — see "Measurement units are not uniform".
    distribution("lemon.channels.deliver.stop.duration",
      unit: {:native, :millisecond},
      tags: [:channel_id, :ok]
    ),
    distribution("lemon.memory.ingest.ok.duration_us",
      unit: {:microsecond, :millisecond},
      tags: []
    ),
    distribution("coding_agent.extension.tool.stop.duration_us",
      unit: {:microsecond, :millisecond},
      tags: [:status]
    )
  ]
end
```

Three things bite when you do this, all of them consequences of items in
[Known gaps](#known-gaps-and-inconsistencies):

- **Pick the unit per event, not per dashboard.** `duration` is native, `duration_us` is
  microseconds, `duration_ms` is milliseconds, and `[:lemon, :config, :reload, :stop]`
  reports both `duration` and `duration_ms` where the former is synthesized from the latter.
  A single `unit: {:native, :millisecond}` applied across the board silently produces
  numbers that are wrong by six orders of magnitude on the `_us` events.
- **`counter/2` still needs a measurement key that exists.**
  `[:coding_agent, :tool_call, :name_normalized]` and `[:coding_agent, :session_fork, _]`
  emit empty measurement maps, so they cannot be counted without first adding a measurement
  at the emit site.
- **Runtime-suffixed events cannot be declared with a wildcard.** `Telemetry.Metrics` needs
  a concrete event name, so each value of the nine dynamic families has to be listed
  individually; the known values are in the catalog above.

For an interactive view instead of a scrape endpoint, `phoenix_live_dashboard` consumes the
same `metrics/0` list through its `:metrics` option. Neither path requires changing any
emit site.

## Known gaps and inconsistencies

These are recorded, not fixed. Renaming events is a breaking change for any attached
consumer and belongs in its own change.

**Events that exist as code but never fire.**
`CodingAgent.RateLimitRecovery.emit_recovery_telemetry/3`
([`rate_limit_recovery.ex:217`](../apps/coding_agent/lib/coding_agent/rate_limit_recovery.ex))
is public with no callers, so `[:coding_agent, :rate_limit_recovery, _]` never fires. This is
the last remaining dead emitter. (The run-span helpers `run_start` / `run_first_token` /
`run_stop` and `cron_tick` were previously listed here as dead; they are in fact live — see
their catalog entries above — and the genuinely dead `run_exception/3` helper was removed.)

**Eight families build their final segment at runtime**, so they cannot be discovered by
searching for a literal event name, and `attach_many/4` requires knowing every value in
advance: `[:lemon, :gateway, :scheduler, _]`, `[:lemon_ai, :compacting_client, _]`,
`[:lemon_ai, :context_compactor, _]`, `[:coding_agent, :rate_limit_pause, _]`,
`[:coding_agent, :rate_limit_healer, _]`, `[:coding_agent, :rate_limit_recovery, _]`,
`[:coding_agent, :session_fork, _]`, `[:coding_agent, :session, :overflow_recovery, _]`, and
`[:lemon_sim_ui, :hosted_werewolf, _]`. The known values are listed in the catalog above.

**Measurement gaps.** `[:coding_agent, :session_fork, _]` emits an empty measurement map, so
it cannot drive a counter without a synthetic measurement. `[:lemon_agent, :loop, :end]`
reports `duration: nil` when the process-dictionary start time is missing. The scheduler
family emits empty metadata, so slot pressure cannot be attributed to a run, session, or
engine.

**Coverage gaps.** `[:lemon_agent, :subagent, :end]` fires only on explicit stop, so a
crashed subagent produces a `:spawn` with no matching `:end`. There is no telemetry on the
store, the Bus, or the router's session-coordinator queue transitions.

**Previously documented events that do not exist.** An earlier revision of this file
described ten events that were never in the code: `[:lemon_agent, :loop, :exception]`,
`[:lemon_agent, :loop, :task_start_failed]`, `[:lemon_agent, :event_stream, :queue_depth]`,
`[:lemon_agent, :event_stream, :dropped]`, `[:lemon_agent, :agent, :loop_error]`,
`[:coding_agent, :session, :event_stream, :broadcast]`, `[:coding_agent, :session, :error]`,
`[:lemon_ai, :dispatcher, :queue_depth]`, `[:lemon_ai, :dispatcher, :retry]`, and
`[:lemon_ai, :stream, :error]`. It also described an `LemonAgent.TelemetryPoller` emitting periodic
`[:vm, _]` stats; no such module exists and `telemetry_poller` is not a dependency. They are
listed here so they are not reintroduced from memory. The same revision documented
`loop_type` / `reason` metadata on the agent loop events and `duration` measurements on the
tool-task events; the real shapes are in the catalog above.

## Introspection: the persisted layer

Introspection is a higher-level layer built beside `:telemetry`, not on top of it. It
captures a canonical envelope for agent lifecycle transitions and persists it through
`LemonCore.Store` for later query. Unlike telemetry, these records are **stored** and
**queryable**.

### Envelope

| Field | Type | Description |
|---|---|---|
| `event_id` | string | Stable unique identifier (prefixed `evt_`) |
| `event_type` | atom or string | Taxonomy name (below) |
| `ts_ms` | integer | Wall-clock milliseconds since the Unix epoch |
| `run_id` | string or nil | Run identifier |
| `session_key` | string or nil | Session identifier |
| `agent_id` | string or nil | Agent identifier |
| `parent_run_id` | string or nil | Lineage link when available |
| `engine` | string or nil | Engine name, e.g. `"claude"`, `"codex"`, `"lemon"` |
| `provenance` | `:direct` \| `:inferred` \| `:unavailable` | How context fields were resolved |
| `payload` | map | Event-specific metadata, redacted |

`:direct` means the emitter supplied the context fields; `:inferred` means they were derived
from surrounding state; `:unavailable` means they could not be determined.

### Redaction

`api_key`, `apikey`, `authorization`, `password`, `private_key`, `prompt`, `response`,
`secret`, `secrets`, `stderr`, `stdout`, and `token` are always removed. Tool argument
fields (`arguments`, `input`, `tool_arguments`) are redacted unless
`capture_tool_args: true` is passed. Result previews are kept and truncated to 256 bytes
unless `capture_result_preview: false` is passed. All other string values are truncated to
4096 bytes. See [`introspection.ex`](../apps/lemon_core/lib/lemon_core/introspection.ex).

### Taxonomy

Every atom below appears in a live `LemonCore.Introspection.record/3` call.

| Emitter | Event types |
|---|---|
| `LemonRouter.RunProcess` | `:run_started`, `:run_completed`, `:run_failed` |
| `LemonRouter.RunOrchestrator` | `:orchestration_started`, `:orchestration_resolved`, `:orchestration_failed` |
| Router answer finalization | `:answer_finalize_started`, `:answer_finalize_dispatch`, `:answer_finalize_completed`, `:answer_artifact_finalize_failed`, `:answer_media_jobs_record_failed` |
| `LemonGateway.ThreadWorker` | `:thread_started`, `:thread_message_dispatched`, `:thread_terminated` |
| `LemonGateway.Scheduler` | `:scheduled_job_triggered`, `:scheduled_job_completed` |
| `CodingAgent.Session` | `:session_started`, `:session_ended`, `:compaction_triggered` |
| `CodingAgent.Session.EventHandler` | `:tool_call_dispatched`, `:engine_event_ignored` |
| `LemonAgent.Agent` | `:agent_loop_started`, `:agent_turn_observed` (inferred), `:agent_loop_ended`, `:agent_progress_snapshot` |
| Skills bridge / session-end audit | `:skill_load_observed`, `:skill_write_observed`, `:skill_prompt_render_observed`, `:missed_skill_observed`, `:missed_learning_observed` |

### Querying

```elixir
LemonCore.Introspection.list([])
LemonCore.Introspection.list(run_id: "run_abc123", limit: 50)
LemonCore.Introspection.list(session_key: "agent:default:main", limit: 20)
LemonCore.Introspection.list(event_type: :run_completed, limit: 30)

now_ms = System.system_time(:millisecond)
LemonCore.Introspection.list(since_ms: now_ms - 60 * 60 * 1000, limit: 200)
```

Results are newest-first. The same filters are available from the shell through
[`mix lemon.introspection`](../apps/lemon_core/lib/mix/tasks/lemon.introspection.ex), which
prints a table of timestamp, event type, run ID, session key, agent ID, engine, and
provenance:

```bash
mix lemon.introspection --limit 100
mix lemon.introspection --run-id run_abc123 --event-type run_completed
mix lemon.introspection --since 1h
mix lemon.introspection --since 2026-08-01T00:00:00Z
```

### Recording, disabling, retention

```elixir
LemonCore.Introspection.record(:run_started, %{origin: "telegram"},
  run_id: run_id,
  session_key: session_key
)
```

Set `config :lemon_core, :introspection, enabled: false` to drop events silently;
`LemonCore.Introspection.enabled?/0` reflects the setting. The store sweeps
`:introspection_log` periodically, pruning records older than 7 days by default.

## Related

- [beam_agents.md](beam_agents.md) — supervision trees and the process-level invariants these
  events observe
- [why-beam-for-agents.md](why-beam-for-agents.md) — why the runtime makes this kind of
  per-process observability cheap
