# LemonRouter - Agent Context

## Quick Orientation

LemonRouter is the central routing and orchestration layer in the Lemon umbrella project. It connects inbound channels (Telegram, Discord, HTTP) to AI engine backends via `LemonGateway`. Every user message that reaches an agent flows through this app.

**What it does:**
- Receives inbound messages from channels and resolves which agent session they belong to
- Submits runs to AI engines via the gateway with the correct model, engine, tool policy, and context
- Manages per-run lifecycle (start, streaming deltas, tool actions, completion, retry, compaction)
- Coalesces streaming output into efficient channel deliveries (buffered text, editable messages)
- Tracks tool/action status in a separate editable message surface
- Provides agent/session discovery, endpoint aliases, and inbox APIs

**What it does NOT do:**
- Does not implement channel protocols (that is `lemon_channels`)
- Does not run AI inference (that is `lemon_gateway`)
- Does not manage agent tool execution (that is `agent_core`)
- Does not handle session history persistence (that is `coding_agent`)

## Key Files and Purposes

### Entry Points

- **`lib/lemon_router.ex`** - Public API facade. All external callers use this module. Delegates to `RunOrchestrator`, `Router`, `AgentInbox`, `AgentDirectory`, `AgentEndpoints`. Start here to understand the public surface area.

- **`lib/lemon_router/router.ex`** - Main inbound message handler. `handle_inbound/1` is the primary entry point for channel messages. Also handles `handle_control_agent/2` for control plane messages, `abort/2`, `abort_run/2`, `keep_run_alive/2`. Resolves session keys from explicit metadata or computed from channel/peer identity. Consumes pending compaction markers with a 12-hour TTL and guards against double-compaction via the `auto_compacted` flag.

- **`lib/lemon_router/application.ex`** - OTP application startup. Defines the supervision tree: `AgentProfiles` GenServer, four registries (`RunRegistry`, `SessionRegistry`, `CoalescerRegistry`, `ToolStatusRegistry`), three DynamicSupervisors (`RunSupervisor`, `CoalescerSupervisor`, `ToolStatusSupervisor`), `RunCountTracker`, `RunOrchestrator`, optional Bandit health server. Configures `RouterBridge` after startup for cross-app communication.

### Run Lifecycle (most commonly modified)

- **`lib/lemon_router/run_orchestrator.ex`** - GenServer handling run submission. This is where agent profile resolution, model/engine selection, tool policy merging, sticky engine detection, and resume token handling all converge to build a `LemonGateway.Types.Job`. If you need to change what goes into a run, start here. Provides `counts/0` for active/queued/completed_today metrics. Also handles `extract_resume_and_strip_prompt/2` for resume token handling from prompts and reply-to text.

- **`lib/lemon_router/run_process.ex`** - Per-run GenServer owning the lifecycle of a single run. Registers in `RunRegistry` (by run_id) and `SessionRegistry` (by session_key). Subscribes to `LemonCore.Bus` for run events (`:run_started`, `:delta`, `:engine_action`, `:run_completed`). Monitors the gateway process and synthesizes failure on unexpected death. Delegates to four submodules:

  - **`lib/lemon_router/run_process/watchdog.ex`** - Idle-run watchdog timer (default 2 hours, configurable via `:run_process_idle_watchdog_timeout_ms`). Resets on any run activity. For Telegram sessions, sends interactive keepalive confirmation with "Keep Waiting" / "Stop Run" inline buttons and a 5-minute confirmation window before forced cancellation.

  - **`lib/lemon_router/run_process/compaction_trigger.ex`** - Detects context overflow from error marker strings in completion events. Preemptively triggers compaction when token usage approaches context window limit (default ratio 0.9). Extracts token usage from completion events; falls back to char-based estimation (~4 chars/token) from job prompt when usage data is missing. On overflow, clears resume state and marks `:pending_compaction` in Store.

  - **`lib/lemon_router/run_process/retry_handler.ex`** - Zero-answer auto-retry (max 1 attempt). Only retries `assistant_error` with empty answer text. Does not retry context overflow, user abort, timeout, or interrupt errors. Builds a context-aware retry prompt prefix.

  - **`lib/lemon_router/run_process/output_tracker.ex`** - Central output dispatcher. Ingests deltas to `StreamCoalescer`, emits final output for non-streaming runs, finalizes streams with resume tokens, finalizes tool status, delivers fanout to secondary routes, and tracks generated image paths for auto-send at completion.

- **`lib/lemon_router/run_supervisor.ex`** - DynamicSupervisor wrapper for `RunProcess` children with lifecycle logging. Default `max_children: 500`.

- **`lib/lemon_router/run_count_tracker.ex`** - Telemetry-based run counters (active, queued, completed_today) using `:counters` for concurrent writes. Resets at midnight UTC daily.

### Streaming and Output

- **`lib/lemon_router/stream_coalescer.ex`** - GenServer that buffers streaming deltas and flushes to channels. Each session+channel pair gets its own coalescer under `CoalescerSupervisor`. Configurable thresholds: `min_chars: 48` (minimum chars before flush), `idle_ms: 400` (flush after idle), `max_latency_ms: 1200` (forced flush ceiling). Full text capped at 100,000 chars. Delegates channel-specific output to `ChannelAdapter`. Tracks `answer_create_ref` for deferred edits and `pending_resume_indices` for Telegram resume token tracking.

- **`lib/lemon_router/tool_status_coalescer.ex`** - Separate from `StreamCoalescer`. Coalesces tool/action lifecycle events (started/updated/completed) into an editable "Tool calls" message. Max 40 tracked actions. Normalizes action events, filtering by allowed kinds (`tool`, `command`, `file_change`, `web_search`, `subagent`), skipping `:note` kind and events missing an id. Uses `ToolStatusRenderer` for text formatting and `ChannelAdapter` for output delivery.

- **`lib/lemon_router/tool_status_renderer.ex`** - Renders "Tool calls:" text with `[running]`/`[ok]`/`[err]` labels. Result previews truncated to 140 chars, titles to 80 chars. Delegates action ordering and limits to `ChannelAdapter.limit_order/1` and extra metadata to `ChannelAdapter.format_action_extra/2`.

- **`lib/lemon_router/tool_preview.ex`** - Normalizes tool results to human-readable text. Handles `AgentCore.Types.AgentToolResult`, `Ai.Types.TextContent`, lists, maps, and inspected struct strings.

### Channel Adapters

- **`lib/lemon_router/channel_adapter.ex`** - Behaviour defining channel-specific output strategies. The `for/1` function dispatches: `"telegram"` prefix maps to Telegram adapter, everything else to Generic. Key callbacks:
  - `emit_stream_output/1` - Emit buffered text to channel
  - `finalize_stream/2` - Final stream output (edit with full text)
  - `emit_tool_status/2` - Emit tool status text
  - `handle_delivery_ack/3` - Process delivery confirmation (for message_id tracking)
  - `truncate/2` - Channel-specific text truncation
  - `batch_files/2` - Group files for delivery (media groups)
  - `tool_status_reply_markup/1` - Inline keyboard for tool status messages
  - `skip_non_streaming_final_emit?/1` - Whether to skip final emit for non-streaming runs
  - `should_finalize_stream?/1` - Whether adapter needs stream finalization
  - `auto_send_config/1` - Config for auto-sending generated files
  - `files_max_download_bytes/0` - Max file download size
  - `limit_order/1` - Limit displayed actions
  - `format_action_extra/2` - Additional per-action display metadata

- **`lib/lemon_router/channel_adapter/generic.ex`** - Default adapter. No truncation, no file batching, no reply markup, no stream finalization. Uses `ChannelsDelivery.enqueue/1` for output.

- **`lib/lemon_router/channel_adapter/telegram.ex`** - Telegram-specific adapter implementing dual-message model:
  - **Progress message**: Tool status with cancel button inline keyboard
  - **Answer message**: Streaming answer created on first flush, edited on subsequent flushes
  - Resume token tracking via `pending_resume_indices` with exponential backoff cleanup
  - Media group batching (max 10 files per group)
  - Message truncation via `LemonChannels.Telegram.Truncate`
  - Recent action display limit of 5
  - Auto-send generated files at run completion
  - Delivery acknowledgement handling to track `answer_msg_id` and `status_msg_id`

- **`lib/lemon_router/channels_delivery.ex`** - Wraps `LemonChannels.Outbox` enqueueing with telemetry on failure. Provides `enqueue/1`, `telegram_enqueue/1`, and `telegram_enqueue_with_notify/2` (sends `{:outbox_delivered, ref, result}` back to caller for message_id tracking).

- **`lib/lemon_router/channel_context.ex`** - Session key parsing (`parse_session_key/1`), channel_id extraction (`channel_id_from_session_key/1`), channel edit support detection (`channel_supports_edit?/1`), `compact_meta/1` for stripping transient keys, `coalescer_meta_from_job/1` for extracting coalescer-relevant metadata from a job.

### Agent Discovery and Endpoints

- **`lib/lemon_router/agent_directory.ex`** - Session/agent discovery phonebook. Merges active sessions from `SessionRegistry` with durable metadata from `LemonCore.Store` (`:sessions_index`). Key functions: `list_sessions/1` (with optional agent_id filter), `latest_session/2`, `latest_route_session/2` (channel_peer sessions only), `list_agents/0`, `list_targets/1`. Route filtering by channel_id, account_id, peer_kind, peer_id, thread_id. Also reads known Telegram targets from `:telegram_known_targets` store.

- **`lib/lemon_router/agent_profiles.ex`** - GenServer loading agent profiles from TOML config (`LemonCore.Config`). Caches profiles in state. Functions: `get/1`, `exists?/1`, `list/0`, `reload/0`. Default profile has engine `"lemon"`.

- **`lib/lemon_router/agent_endpoints.ex`** - Persistent endpoint aliases mapping friendly names to route maps. CRUD: `list/1`, `get/2`, `put/4`, `delete/2`. Resolution via `resolve/3` supports alias names, Telegram shorthand (`tg:<chat_id>`, `tg:<chat_id>/<topic_id>`, `tg:<account>@<chat_id>/<topic_id>`), and raw route maps.

- **`lib/lemon_router/agent_inbox.ex`** - BEAM-local inbox API with session selectors: `:latest` (most recent session), `:new` (create new session), explicit session key. Primary target resolution from `to`/`endpoint`/`route` options. Fanout target resolution via `deliver_to` option with dedup. Queue modes: `:collect` (append to queue), `:followup` (immediate, replaceable), `:steer` (high priority, replaces queued), `:steer_backlog` (steer preserving backlog), `:interrupt` (cancel active and start).

### Model, Engine, and Policy

- **`lib/lemon_router/model_selection.ex`** - Independent model + engine resolution with two precedence chains. Model: request > meta > session > profile > default. Engine: resume > explicit > model-implied > profile default. Warns on engine/model mismatch when explicit engine conflicts with model-implied engine.

- **`lib/lemon_router/smart_routing.ex`** - Complexity classification for model routing. Categorizes prompts as `:simple` (greetings, short questions), `:moderate`, or `:complex` (multi-step reasoning, code review) using keyword lists and pattern matching. `route/4` selects cheap vs primary model. `uncertain_response?/1` detects uncertain output for cascade escalation. Stats tracking via Agent.

- **`lib/lemon_router/sticky_engine.ex`** - Extracts engine preference from prompt text. Matches: "use <engine>", "switch to <engine>", "with <engine>". Only accepts engines registered in `LemonChannels.EngineRegistry`. `resolve/1` combines explicit request > prompt directive > session preference, returning `{effective_engine_id, session_updates}`.

- **`lib/lemon_router/policy.ex`** - Tool policy merging from multiple sources. Merge order: agent -> channel -> session -> runtime (later overrides earlier). Group channels get stricter defaults (`bash`, `write`, `process` require `:always` approval). Key fields: `approvals`, `blocked_tools`, `allowed_commands`/`blocked_commands`, `max_file_size`, `sandbox`. Helpers: `approval_required?/3`, `tool_blocked?/2`, `command_allowed?/2`.

### Health

- **`lib/lemon_router/health.ex`** - Health check logic. Checks: supervisor alive, orchestrator alive, run_supervisor alive. Includes run counts in response.
- **`lib/lemon_router/health/router.ex`** - Plug router for `GET /healthz`. Returns JSON with status and checks. HTTP 200 on success, 503 on failure. Runs on port 4043 (configurable via `:health_port`). Disable with `config :lemon_router, health_enabled: false`.

## How to Modify Routing Logic

### Adding a new engine or model

1. Register the engine in `LemonChannels.EngineRegistry` (in the `lemon_channels` app).
2. If the engine has a distinct model namespace, add model-to-engine mapping in `LemonRouter.ModelSelection.engine_for_model/1`.
3. Sticky engine support (natural language switching) works automatically for any engine in `EngineRegistry`.

### Changing model selection precedence

Edit `LemonRouter.ModelSelection.resolve/1`. The function checks sources in order and returns the first non-nil result. To add a new precedence level, insert a new clause in the `cond` chain.

### Changing tool policy behavior

Edit `LemonRouter.Policy`. The `merge/1` function takes a list of policy sources and merges them. To add a new policy source, include it in the list built by `RunOrchestrator.build_tool_policy/3`. To change group restrictions, edit `group_defaults/0`.

### Adding a new channel adapter

1. Create a new module implementing the `LemonRouter.ChannelAdapter` behaviour (see `channel_adapter.ex` for the full callback list).
2. Add a clause to `ChannelAdapter.for/1` to dispatch your channel_id pattern to the new adapter.
3. The adapter controls: stream output format, tool status format, file batching, truncation, reply markup, finalization behavior, and auto-send config.

### Modifying stream coalescing thresholds

The defaults are module attributes in `LemonRouter.StreamCoalescer`:
- `@default_min_chars 48`
- `@default_idle_ms 400`
- `@default_max_latency_ms 1200`

These can be overridden per-coalescer via `start_link/1` opts. To make them configurable per-agent or per-channel, pass them through from `RunOrchestrator` or `OutputTracker`.

### Adding a new run event handler

In `LemonRouter.RunProcess`, the `handle_info/2` clause matching `%{type: event_type}` events dispatches run events. To handle a new event type:
1. Add a pattern match in `handle_info/2`.
2. If it involves output, delegate to `OutputTracker`.
3. If it involves lifecycle, handle it directly in `RunProcess`.

### Modifying compaction behavior

Edit `LemonRouter.RunProcess.CompactionTrigger`. Key functions:
- `check_context_overflow/2` - Detects overflow from error markers
- `check_preemptive_compaction/2` - Triggers compaction based on usage ratio (default 0.9)
- Token usage extraction from completion events with fallback to char-based estimation
- The compaction prompt is built in `LemonRouter.Router.build_compaction_prompt/2`

### Adding a new queue mode

In `LemonRouter.AgentInbox`, queue modes control how messages are submitted:
1. Add a new atom to the queue mode matching in `submit_to_session/3`.
2. Define the behavior (does it interrupt? append? steer?).
3. Update any callers that should use the new mode.

## Testing Guidance

### Test Setup

The test helper at `test/test_helper.exs` configures the test environment:
- Sets gateway implementation to a mock module
- Sets channels implementation to a mock module
- Stops and restarts dependent applications to pick up test config
- Starts ExUnit with `async: false` (tests share global state via registries)

### Running Tests

```bash
# Run all lemon_router tests
cd apps/lemon_router && mix test

# Run a specific test file
cd apps/lemon_router && mix test test/lemon_router/router_test.exs

# Run from umbrella root
mix cmd --app lemon_router mix test

# Run with trace output
mix test apps/lemon_router --trace
```

### Test Structure and Patterns

**RunOrchestratorStub**: Many tests use a stub pattern for `RunOrchestrator` to isolate the module under test from actual run submission. The stub captures calls and returns configurable responses.

**Registry-based assertions**: Tests check process registration in `RunRegistry` or `SessionRegistry` to verify lifecycle correctness.

**Telemetry assertions**: `RunCountTracker` tests emit telemetry events and verify counter updates.

**Channel adapter testing**: Adapter tests verify output format (text chunks vs edits, truncation, file batching) for different channel types by calling adapter functions directly with snapshot maps.

**Coalescer testing**: Start a coalescer directly and call `ingest_delta`/`ingest_action`, then assert on delivered output.

### Key Test Files

| File | Coverage |
|------|----------|
| `router_test.exs` | `handle_inbound`, `handle_control_agent`, `abort`, session key resolution |
| `router_pending_compaction_test.exs` | Generic pending-compaction consumer, marker lifecycle, auto_compacted guard |
| `run_orchestrator_test.exs` | Submit flows, cwd/tool_policy overrides, model selection, resume handling, sticky engine, admission control, agent profile defaults, counts |
| `run_process_test.exs` | Run lifecycle, event handling, abort, cleanup |
| `run_process/watchdog_test.exs` | Idle timeout, keepalive confirmation |
| `run_process/compaction_trigger_test.exs` | Context overflow detection, preemptive compaction |
| `run_process/retry_handler_test.exs` | Zero-answer retry logic |
| `run_process/output_tracker_test.exs` | Delta ingestion, final output, fanout |
| `stream_coalescer_test.exs` | Buffer thresholds, flush timing, finalization |
| `tool_status_coalescer_test.exs` | Action upsert, rendering, finalization |
| `tool_status_renderer_test.exs` | Status text formatting |
| `tool_preview_test.exs` | Tool result text normalization |
| `channel_adapter_test.exs` | Adapter dispatch, generic/telegram behavior |
| `model_selection_test.exs` | Model/engine precedence resolution |
| `smart_routing_test.exs` | Complexity classification, model routing |
| `sticky_engine_test.exs` | Prompt directive extraction, engine affinity |
| `policy_test.exs` | Policy merging helpers |
| `policy_resolution_test.exs` | End-to-end policy resolution |
| `agent_directory_test.exs` | Session discovery, route filtering |
| `agent_profiles_test.exs` | Profile loading, existence checks |
| `agent_endpoints_test.exs` | Endpoint CRUD, Telegram shorthand resolution |
| `agent_inbox_test.exs` | Session selection, target resolution, queue modes |
| `channel_context_test.exs` | Session key parsing, meta compaction |
| `channels_delivery_test.exs` | Outbox enqueueing |
| `session_key_test.exs` | SessionKey construction and parsing |
| `session_key_atom_exhaustion_test.exs` | Atom exhaustion safety |
| `run_count_tracker_test.exs` | Counter lifecycle, midnight reset |
| `health_test.exs` | Health endpoint responses |

### Writing New Tests

1. Follow the existing `async: false` pattern (shared registries).
2. Use the test helper's mock gateway and channels.
3. For run lifecycle tests, start a `RunProcess` under the test-configured `RunSupervisor` and emit events via `LemonCore.Bus`.
4. For coalescer tests, start a coalescer directly and call `ingest_delta`/`ingest_action` then assert on delivered output.
5. For adapter tests, call adapter functions directly with snapshot maps.
6. For registry operations, check `RunRegistry` and `SessionRegistry` lookups to verify correctness.

### Debugging Tips

```elixir
# Enable debug logging
require Logger
Logger.configure(level: :debug)

# Inspect registry state
Registry.select(LemonRouter.RunRegistry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
Registry.select(LemonRouter.SessionRegistry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])

# Check coalescer state
:sys.get_state({:via, Registry, {LemonRouter.CoalescerRegistry, {session_key, "telegram"}}})

# Check active run counts
LemonRouter.RunOrchestrator.counts()
# => %{active: 5, queued: 0, completed_today: 47}

# List children of run supervisor
DynamicSupervisor.which_children(LemonRouter.RunSupervisor)

# Reload agent profiles
LemonRouter.AgentProfiles.reload()
```

## Connections to Other Apps

### lemon_core (shared infrastructure)

- **`LemonCore.Bus`** - PubSub for run events. `RunProcess` subscribes to run topics; `StreamCoalescer` broadcasts `:coalesced_output` to session topics.
- **`LemonCore.Store`** - Persistent key-value store. Used by `AgentDirectory` (`:sessions_index`, `:telegram_known_targets`), `AgentEndpoints` (`:endpoints`), `CompactionTrigger` (`:pending_compaction` markers).
- **`LemonCore.Store.ReadCache`** - Cached reads for store-backed directory/listing queries to avoid repeated full-table scans.
- **`LemonCore.Config`** - TOML configuration. Used by `AgentProfiles` to load agent configs from `~/.lemon/config.toml` and project `.lemon/config.toml`.
- **`LemonCore.Types.InboundMessage`** - The canonical inbound message struct that `Router.handle_inbound/1` processes.
- **`LemonCore.SessionKey`** - Session key construction and parsing utilities.
- **`LemonCore.RouterBridge`** - Cross-app bridge configured in `Application.after_start/0` to allow channels to call into the router without circular dependencies. Do not call `RouterBridge.configure/1` manually in tests.
- **`LemonCore.Introspection`** - Lifecycle observability. `RunProcess` and `RunOrchestrator` emit introspection events for monitoring.
- **`LemonCore.Telemetry`** - Telemetry events consumed by `RunCountTracker`.

### lemon_gateway (AI engine interface)

- **`LemonGateway.submit/1`** - Called by `RunProcess` to start a run. Takes a `LemonGateway.Types.Job`.
- **`LemonGateway.abort/1`** - Called by `RunProcess` to abort a running job.
- **`LemonGateway.Types.Job`** - The job struct built by `RunOrchestrator`. Contains prompt, model, engine, tool_policy, cwd, resume tokens, system prompt, meta, etc.
- **Run events** - The gateway emits events (`:run_started`, `:delta`, `:engine_action`, `:run_completed`) via `LemonCore.Bus` that `RunProcess` consumes.

### lemon_channels (channel integrations)

- **`LemonChannels.Outbox`** - Message delivery queue. `ChannelsDelivery` enqueues outbound messages here.
- **`LemonChannels.EngineRegistry`** - Registry of known engines. Used by `StickyEngine` for validation.
- **`LemonChannels.Telegram.Truncate`** - Telegram message truncation. Used by the Telegram adapter.
- **`LemonChannels.GatewayConfig`** - Gateway configuration used during run setup.
- **`LemonChannels.RouterBridge`** - The channels side of the RouterBridge that calls back into the router.

### coding_agent (session management)

- **`CodingAgent.Session`** - Session history and context. Used by `RunOrchestrator` for cwd resolution and resume token extraction.
- **`CodingAgent.Session.History`** - Provides run history for compaction prompt building in `Router`.

### agent_core (agent types)

- **`AgentCore.Types.AgentToolResult`** - Tool result struct. Used by `ToolPreview` for text normalization.
- **`AgentCore.Types`** - Various shared type definitions used across the routing layer.

## Session Key Anatomy

Understanding session keys is critical for debugging routing issues:

```
agent:<agent_id>:main
  - Control plane session (no specific channel)

agent:<agent_id>:<channel_id>:<account_id>:<peer_kind>:<peer_id>
  - Channel-specific session
  - channel_id: "telegram", "discord", etc.
  - account_id: bot account identifier
  - peer_kind: "user", "group", "supergroup", "channel" (or "dm" shorthand)
  - peer_id: platform-specific peer identifier

agent:<agent_id>:<channel_id>:<account_id>:<peer_kind>:<peer_id>:thread:<thread_id>
  - Thread-specific session (e.g., Telegram forum topic)

agent:<agent_id>:<channel_id>:<account_id>:<peer_kind>:<peer_id>:sub:<sub_id>
  - Sub-session for parallel conversations within same peer
```

Use `LemonCore.SessionKey.parse/1` to decompose a session key. Use `LemonRouter.ChannelContext.channel_id_from_session_key/1` to extract the channel type.

## Common Debugging Scenarios

### "Message not reaching the agent"
1. Check `Router.handle_inbound/1` - is the session key resolving correctly?
2. Check `RunOrchestrator.submit/1` - is the agent profile found? Is admission control (`max_children`) blocking?
3. Check `RunProcess` registration - is there already an active run for this session key blocking new submissions?

### "Streaming output not appearing"
1. Check `StreamCoalescer` - is it receiving deltas? Look for the coalescer in `CoalescerRegistry`.
2. Check `ChannelAdapter` - is the adapter returning `:skip` or `{:ok, updates}`?
3. Check `ChannelsDelivery` - are messages being enqueued to the outbox?
4. For Telegram: check `answer_create_ref` - is the answer message creation still pending?

### "Tool status not updating"
1. Check `ToolStatusCoalescer` - is the action event being normalized correctly? `normalize_action_event/1` skips `:note` kind and events without an id.
2. Check `ToolStatusRenderer` - is the render output different from `last_text`? Identical renders are skipped.
3. Check `ChannelAdapter.limit_order/1` - is the adapter limiting displayed actions?

### "Run stuck / not completing"
1. Check `RunProcess` - is the gateway process still alive? The process is monitored; unexpected death triggers synthetic failure after 200ms grace.
2. Check `Watchdog` - has the idle timeout fired? Look for keepalive confirmation messages in Telegram.
3. Check `CompactionTrigger` - did context overflow trigger compaction instead of completion?
4. Check `RetryHandler` - is a retry in progress (max 1 attempt)?

### "Wrong model or engine selected"
1. Trace through `ModelSelection.resolve/1` - which precedence level is winning?
2. Check `StickyEngine.resolve/1` - is a prompt directive ("use codex", "switch to claude") overriding the selection?
3. Check the agent profile via `AgentProfiles.get/1` - what are the profile defaults?
4. Check session policy in `LemonCore.Store` - is there a stored `preferred_engine`?

## Introspection Events

RunProcess and RunOrchestrator emit introspection events via `LemonCore.Introspection.record/3` for lifecycle observability. All events use `engine: "lemon"` and pass `run_id:`, `session_key:`, `agent_id:` where available.

### RunProcess Events

| Event Type | When Emitted | Key Payload Fields |
|---|---|---|
| `:run_started` | `init/1` after state is built | `engine_id`, `queue_mode` |
| `:run_completed` | `handle_info(:run_completed)` | `ok`, `error`, `duration_ms`, `saw_delta` |
| `:run_failed` | `terminate/2` on abnormal exit | `reason` |

### RunOrchestrator Events

| Event Type | When Emitted | Key Payload Fields |
|---|---|---|
| `:orchestration_started` | `do_submit/2` after run_id generation | `origin`, `agent_id`, `queue_mode`, `engine_id` |
| `:orchestration_resolved` | Successful `start_run_process` | `engine_id`, `model` |
| `:orchestration_failed` | Failed `start_run_process` | `reason` |

## Configuration

```elixir
# config/config.exs or config/runtime.exs
config :lemon_router,
  default_model: "claude-3-sonnet",
  health_enabled: true,
  health_port: 4043,
  run_process_limit: 500,
  run_process_idle_watchdog_timeout_ms: 7_200_000,        # 2 hours
  run_process_idle_watchdog_confirm_timeout_ms: 300_000    # 5 minutes

# Agent profiles are loaded from LemonCore.Config
# (global ~/.lemon/config.toml + project .lemon/config.toml)
```

## Dependencies

**Umbrella deps:**
- `lemon_core` - Core types, SessionKey, Store, Bus, Telemetry, EventBridge, RouterBridge, Introspection
- `lemon_gateway` - Gateway scheduler, engines, runtime, RunRegistry, Types.Job
- `lemon_channels` - Channel delivery, Telegram outbox, EngineRegistry, GatewayConfig, Truncate
- `coding_agent` - Coding agent session management and history
- `agent_core` - Agent types and tool result structures

**External deps:**
- `bandit` - HTTP server for health checks
- `plug` - HTTP routing for health endpoint
- `jason` - JSON encoding for health responses

## Startup and RouterBridge

On startup (`LemonRouter.Application`), after supervisor children are running, the app registers itself with `LemonCore.RouterBridge`:

```elixir
LemonCore.RouterBridge.configure_guarded(
  run_orchestrator: LemonRouter.RunOrchestrator,
  router: LemonRouter.Router
)
```

This lets other umbrella apps (e.g., channels) call into the router without a hard dependency on `lemon_router`. Do not call `RouterBridge.configure/1` manually in tests.
