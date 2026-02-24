# LemonRouter

Elixir OTP app for message routing, agent directory management, and run orchestration.

## Purpose and Responsibilities

LemonRouter sits at the center of the Lemon architecture, bridging channels (Telegram, etc.) with the gateway and engines:

```
[Channels] → [Router] → [Gateway] → [Engine]
     ↑           |
     └──── [StreamCoalescer]
```

**Core responsibilities:**

- **Message routing** - Route inbound messages to appropriate agents and sessions
- **Agent directory** - Maintain a discoverable "phonebook" of agents and sessions
- **Run orchestration** - Manage the full lifecycle of agent runs
- **Smart routing** - Classify task complexity and route to appropriate models
- **Model selection** - Resolve models and engines with precedence rules
- **Sticky engine affinity** - Persist engine preferences per session
- **Stream coalescing** - Aggregate streaming deltas for efficient channel output
- **Tool status tracking** - Coalesce tool/action lifecycle events into status surfaces
- **Policy enforcement** - Merge tool policies from multiple sources

## Routing Flow and Architecture

### Session Keys

Session keys provide stable identifiers for routing and state:

```elixir
# Main session for an agent
"agent:my_agent:main"

# Channel peer session
"agent:my_agent:telegram:my_account:dm:12345678"
"agent:my_agent:telegram:my_account:group:-1001234567890:thread:42"
```

Use `LemonCore.SessionKey` for parsing and construction:

```elixir
alias LemonCore.SessionKey

SessionKey.main("my_agent")
# => "agent:my_agent:main"

SessionKey.channel_peer(%{
  agent_id: "my_agent",
  channel_id: "telegram",
  account_id: "default",
  peer_kind: :dm,
  peer_id: "12345678"
})

SessionKey.parse(session_key)
# => %{agent_id: "my_agent", kind: :main, ...}
```

### Inbound Message Flow

```
1. Channel receives message
   ↓
2. Router.handle_inbound/1 normalizes to %RunRequest{}
   ↓
3. RunOrchestrator.submit/1 resolves config and starts RunProcess
   ↓
4. RunProcess submits job to Gateway.Scheduler
   ↓
5. Gateway executes run, emits events to Bus
   ↓
6. RunProcess receives events, coalesces output to channels
```

### Control Plane Flow

For API/web requests:

```elixir
LemonRouter.Router.handle_control_agent(params, ctx)
# Returns {:ok, %{run_id: "...", session_key: "..."}}
```

## Agent Directory System

The directory merges active sessions from `SessionRegistry` with durable metadata from `LemonCore.Store`.

### Key Modules

- `LemonRouter.AgentDirectory` - Session discovery and listing (merges Store index + active registry)
- `LemonRouter.AgentProfiles` - Agent configuration GenServer (engine, model, tool_policy, system_prompt)
- `LemonRouter.AgentEndpoints` - Endpoint alias CRUD and shorthand resolution (e.g. `tg:<chat_id>`)
- `LemonRouter.AgentInbox` - BEAM-local inbox API with fanout support

### Common Operations

```elixir
# List all known agents with stats
LemonRouter.list_agent_directory()
# => [%{agent_id: "...", name: "...", active_session_count: 1, route_count: 2, ...}]

# List sessions for an agent
LemonRouter.AgentDirectory.list_sessions(agent_id: "my_agent")

# Get latest session (returns {:ok, session_entry} | {:error, :not_found})
LemonRouter.AgentDirectory.latest_session("my_agent")

# Get latest route-backed (channel_peer) session
LemonRouter.AgentDirectory.latest_route_session("my_agent")

# List known targets (for UI discovery)
LemonRouter.list_agent_targets(query: "group name")

# Send to agent inbox
# Returns {:ok, %{run_id, session_key, selector, fanout_count}} | {:error, term()}
LemonRouter.send_to_agent("my_agent", "Hello", session: :latest)
LemonRouter.send_to_agent("my_agent", "Hello", session: :new, to: "tg:chat_id")
# Fanout to multiple destinations
LemonRouter.send_to_agent("my_agent", "Hello", to: "tg:111", deliver_to: ["standup", "tg:222"])
```

### Endpoint Aliases

```elixir
# Set an alias
LemonRouter.set_agent_endpoint("my_agent", "standup", "tg:-1001234567890/42")

# Use the alias
LemonRouter.send_to_agent("my_agent", "status?", to: "standup")
```

## Run Orchestration Lifecycle

### Components

- `LemonRouter.RunOrchestrator` - GenServer that submits runs
- `LemonRouter.RunProcess` - Per-run process that owns lifecycle
- `LemonRouter.RunSupervisor` - DynamicSupervisor for run processes

### Run States

```
:submit → :run_started → [:delta | :engine_action]* → :run_completed
```

### Starting a Run

```elixir
alias LemonCore.RunRequest

request = RunRequest.new(%{
  origin: :channel,           # :channel, :control_plane, :cron, :node
  session_key: session_key,
  agent_id: "my_agent",
  prompt: "Hello",
  queue_mode: :collect,       # :collect, :followup, :steer, :interrupt
  engine_id: nil,             # Optional override
  model: nil,                 # Optional override
  cwd: nil,                   # Optional working directory
  tool_policy: nil,           # Optional policy override
  meta: %{}                   # Additional metadata
})

{:ok, run_id} = LemonRouter.submit(request)
```

### Aborting Runs

```elixir
# Abort by session (all runs for session)
LemonRouter.abort(session_key, :user_requested)

# Abort specific run
LemonRouter.abort_run(run_id, :user_requested)

# Via Router module
LemonRouter.Router.abort(session_key)
LemonRouter.Router.abort_run(run_id)
```

### Registry Lookup

```elixir
# Find run process by run_id
Registry.lookup(LemonRouter.RunRegistry, run_id)

# Find active run for session
Registry.lookup(LemonRouter.SessionRegistry, session_key)
```

## Smart Routing and Model Selection

### Smart Routing

`LemonRouter.SmartRouting` classifies message complexity and can route to cheap vs primary models:

```elixir
LemonRouter.SmartRouting.classify_message("What is 2+2?")
# => :simple

LemonRouter.SmartRouting.classify_message("Implement a distributed consensus algorithm...")
# => :complex
# Returns :simple | :moderate | :complex
```

Classification uses keywords, message length, and code block detection. `:moderate` messages
route to the cheap model. Use `route/4` to select a model based on complexity:

```elixir
{:ok, model, complexity} = LemonRouter.SmartRouting.route(message, primary_model, cheap_model)
```

Also provides `uncertain_response?/1` to detect uncertain engine output for cascade escalation.

### Model Selection

`LemonRouter.ModelSelection` resolves models with two independent precedence chains:

```elixir
# Model precedence (highest to lowest):
# 1. explicit_model (request-level)
# 2. meta_model (from run meta)
# 3. session_model (from session policy)
# 4. profile_model (from agent profile config)
# 5. default_model (router application config)

# Engine precedence (highest to lowest):
# 1. resume_engine (from resume token)
# 2. explicit_engine_id (from StickyEngine resolution)
# 3. model-implied engine (inferred from model name prefix, e.g. "claude:..." => "claude")
# 4. profile_default_engine (from agent profile)

LemonRouter.ModelSelection.resolve(%{
  explicit_model: "claude-3-opus",
  session_model: "gpt-4",
  profile_model: "claude-3-sonnet",
  default_model: "gpt-3.5",
  explicit_engine_id: nil,
  profile_default_engine: nil,
  resume_engine: nil
})
# => %{model: "claude-3-opus", engine_id: nil, model_engine: nil, warning: nil}
```

If `explicit_engine_id` conflicts with a model-implied engine, the explicit engine wins and a
`warning` string is populated in the result.

### Sticky Engine Affinity

`LemonRouter.StickyEngine` extracts and persists engine preferences. Two public functions:

```elixir
# Low-level: extract engine from a prompt string
LemonRouter.StickyEngine.extract_from_prompt("use codex to refactor this")
# => {:ok, "codex"} | :none
# Patterns matched: "use <engine>", "switch to <engine>", "with <engine>"
# Only matches engines known to LemonChannels.EngineRegistry

# High-level: used by RunOrchestrator - resolves sticky engine for a run
{effective_engine_id, session_updates} = LemonRouter.StickyEngine.resolve(%{
  explicit_engine_id: nil,   # from run request
  prompt: "use codex for this",
  session_preferred_engine: "claude"  # from session policy
})
# => {"codex", %{preferred_engine: "codex"}}
# Priority: explicit request engine > prompt directive > session sticky preference
```

Engine preferences are persisted to session policy via `LemonCore.Store` and used for all
subsequent runs on that session until a different engine is requested.

### Policy Resolution

`LemonRouter.Policy` merges tool policies from multiple sources:

```elixir
# Merge order: agent → channel → session → runtime (later wins)
policy = LemonRouter.Policy.resolve_for_run(%{
  agent_id: "my_agent",
  session_key: session_key,
  origin: :channel,
  channel_context: %{channel_id: "telegram", peer_kind: :group}
})
```

Policy fields:
- `approvals` - Approval requirements per tool (`:always`, `:dangerous`, `:never`)
- `blocked_tools` - List of blocked tool names
- `allowed_commands`/`blocked_commands` - Command whitelist/blacklist
- `max_file_size` - Max bytes for write operations
- `sandbox` - Sandbox mode boolean

Policy also exposes helpers:

```elixir
LemonRouter.Policy.approval_required?(policy, "bash")   # => :always | :dangerous | :never | :default
LemonRouter.Policy.tool_blocked?(policy, "exec_raw")    # => boolean
LemonRouter.Policy.command_allowed?(policy, "git push") # => boolean
LemonRouter.Policy.merge(policy_a, policy_b)            # => merged map
```

Note: Channel context `:group`/`:supergroup`/`:channel` peer kinds automatically apply
stricter approval defaults (`bash`, `write`, `process` => `:always`).

## Stream Coalescing

`LemonRouter.StreamCoalescer` buffers streaming deltas for efficient channel output.

### Configuration

```elixir
# Default thresholds
min_chars: 48      # Minimum characters before flushing
idle_ms: 400       # Flush after idle time
max_latency_ms: 1200  # Maximum time before forced flush
```

### Usage

```elixir
# Ingest a delta
LemonRouter.StreamCoalescer.ingest_delta(
  session_key,
  "telegram",
  run_id,
  seq,
  "text chunk",
  meta: %{progress_msg_id: 123}
)

# Finalize a run
LemonRouter.StreamCoalescer.finalize_run(session_key, "telegram", run_id)

# Force flush
LemonRouter.StreamCoalescer.flush(session_key, "telegram")
```

### Telegram-Specific Behavior

For Telegram, the coalescer creates separate messages:
- **Progress message** - Tool status (via ToolStatusCoalescer)
- **Answer message** - Streaming answer output

This separation allows tool status to remain visible while the answer streams.

## Tool Status Tracking

`LemonRouter.ToolStatusCoalescer` manages the "Tool calls" status surface.

### Ingesting Actions

```elixir
LemonRouter.ToolStatusCoalescer.ingest_action(
  session_key,
  "telegram",
  run_id,
  %{
    action: %{id: "1", kind: "tool", title: "bash"},
    phase: :started
  }
)
```

### Finalizing

```elixir
# Marks still-running actions as completed
LemonRouter.ToolStatusCoalescer.finalize_run(
  session_key,
  "telegram",
  run_id,
  true  # ok?
)
```

### Rendering

`LemonRouter.ToolStatusRenderer` formats the status message:

```
Running…

1. bash [running]
2. read [done]
3. web_search [done]
```

### Cancel Button

Active runs show an inline "cancel" button in Telegram. The callback data is:

```
lemon:cancel:<run_id>
```

## Common Tasks and Examples

### Submit a Run from Tests

```elixir
# In test_helper.exs, ensure router is started
{:ok, _} = Application.ensure_all_started(:lemon_router)

# Submit a run
{:ok, run_id} = LemonRouter.submit(%{
  origin: :channel,
  session_key: "agent:test:main",
  agent_id: "test",
  prompt: "Hello"
})
```

### Custom Queue Mode

```elixir
# :collect      - Queue behind existing runs (default for channel inbound)
# :followup     - Start immediately, replaceable (default for AgentInbox.send/3)
# :steer        - High priority, replaces queued runs
# :steer_backlog - Steer but preserve backlog
# :interrupt    - Cancel active run and start immediately

LemonRouter.submit(%{queue_mode: :steer, ...})
```

### Handle Resume Tokens

```elixir
# RunOrchestrator extracts resume tokens from prompts (or from reply_to_text in meta)
{resume, stripped_prompt} = LemonRouter.RunOrchestrator.extract_resume_and_strip_prompt(
  "codex resume abc123",
  meta  # may contain :reply_to_text for Telegram reply context
)
# resume => %LemonChannels.Types.ResumeToken{engine: "codex", value: "abc123"} | nil
# stripped_prompt => "" (resume lines stripped; "Continue." substituted if empty)
```

### Listen to Run Events

```elixir
alias LemonCore.Bus

# Subscribe to run events
Bus.subscribe(Bus.run_topic(run_id))

# Subscribe to session events
Bus.subscribe(Bus.session_topic(session_key))

# Receive events
receive do
  %LemonCore.Event{type: :delta, payload: delta} ->
    # Handle streaming delta
    
  %LemonCore.Event{type: :run_completed, payload: payload} ->
    # Handle completion
end
```

### Check Active Runs

```elixir
# Get counts
LemonRouter.RunOrchestrator.counts()
# => %{active: 5, queued: 0, completed_today: 0}

# List children of run supervisor
DynamicSupervisor.which_children(LemonRouter.RunSupervisor)
```

### Reload Agent Profiles

```elixir
LemonRouter.AgentProfiles.reload()
```

## Testing Guidance

### Running Tests

```bash
# Run all router tests
mix test apps/lemon_router

# Run specific test file
mix test apps/lemon_router/test/lemon_router/run_orchestrator_test.exs

# Run with debug output
mix test apps/lemon_router --trace
```

### Test Structure

Tests use the umbrella test helper which ensures required apps are started:

```elixir
# test/my_module_test.exs
defmodule LemonRouter.MyModuleTest do
  use ExUnit.Case
  
  alias LemonRouter.MyModule
  
  setup do
    # Tests run with router, gateway, and channels started
    :ok
  end
  
  test "something" do
    # Test code
  end
end
```

### Test Patterns

**Testing RunProcess:**

```elixir
test "run completes successfully" do
  {:ok, run_id} = LemonRouter.submit(%{
    origin: :test,
    session_key: "agent:test:main",
    agent_id: "test",
    prompt: "echo hello"
  })

  # Subscribe to run events before submitting, or subscribe to session topic
  Bus.subscribe(Bus.run_topic(run_id))
  assert_receive %LemonCore.Event{type: :run_completed}, 5000
end
```

**Testing with Mock Engine:**

```elixir
# Configure test to use Echo engine
Application.put_env(:lemon_router, :default_model, "echo")
```

**Bypassing gateway in unit tests:**

```elixir
# Start RunProcess without submitting to gateway
{:ok, pid} = LemonRouter.RunProcess.start_link(
  run_id: run_id,
  session_key: session_key,
  job: job,
  submit_to_gateway?: false
)
```

**Testing Registry Operations:**

```elixir
test "session registry tracks active runs" do
  session_key = "agent:test:main"
  
  # Before submit
  assert Registry.lookup(LemonRouter.SessionRegistry, session_key) == []
  
  {:ok, run_id} = LemonRouter.submit(%{session_key: session_key, ...})
  
  # After run_started event
  assert_receive %LemonCore.Event{type: :run_started}
  
  # Registry should have entry
  assert [{pid, %{run_id: ^run_id}}] = 
    Registry.lookup(LemonRouter.SessionRegistry, session_key)
end
```

### Key Test Files

| File | Coverage |
|------|----------|
| `run_orchestrator_test.exs` | Submit flows, model selection, resume handling |
| `run_process_test.exs` | Lifecycle, abort, event handling |
| `stream_coalescer_test.exs` | Delta aggregation, flushing |
| `tool_status_coalescer_test.exs` | Action coalescing, finalization |
| `tool_status_renderer_test.exs` | Status message formatting |
| `tool_preview_test.exs` | Tool result text normalization |
| `agent_directory_test.exs` | Session discovery, filtering |
| `agent_inbox_test.exs` | Inbox API, selectors, fanout |
| `agent_endpoints_test.exs` | Endpoint alias CRUD, resolution |
| `agent_profiles_test.exs` | Profile loading, existence checks |
| `policy_test.exs` | Policy merging helpers |
| `policy_resolution_test.exs` | End-to-end policy resolution |
| `model_selection_test.exs` | Model/engine resolution |
| `smart_routing_test.exs` | Complexity classification, routing |
| `sticky_engine_test.exs` | Engine extraction, affinity |
| `router_test.exs` | Inbound message handling, control plane |
| `channel_context_test.exs` | Session key parsing, channel context |
| `session_key_test.exs` | SessionKey construction and parsing |
| `session_key_atom_exhaustion_test.exs` | Atom exhaustion safety |
| `health_test.exs` | Health endpoint responses |

### Debugging Tips

**Enable debug logging:**

```elixir
# In test or iex
require Logger
Logger.configure(level: :debug)
```

**Inspect registry state:**

```elixir
Registry.select(LemonRouter.RunRegistry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
Registry.select(LemonRouter.SessionRegistry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
```

**Check coalescer state:**

```elixir
:sys.get_state({:via, Registry, {LemonRouter.CoalescerRegistry, {session_key, "telegram"}}})
```

## Internal Helper Modules

These modules are not part of the public API but are used throughout:

- `LemonRouter.ChannelContext` - Session key parsing utilities, coalescer meta extraction, channel edit-support detection
- `LemonRouter.ChannelsDelivery` - Wraps `LemonChannels` outbox enqueueing; used by RunProcess and StreamCoalescer for output delivery
- `LemonRouter.ToolPreview` - Normalizes tool result values (structs, lists, maps) to human-readable text for channel rendering

## Startup and RouterBridge

On startup (`LemonRouter.Application`), after supervisor children are running, the app
registers itself with `LemonCore.RouterBridge`:

```elixir
LemonCore.RouterBridge.configure_guarded(
  run_orchestrator: LemonRouter.RunOrchestrator,
  router: LemonRouter.Router
)
```

This lets other umbrella apps (e.g., channels) call into the router without a hard dep on
`lemon_router`. Do not call `RouterBridge.configure/1` manually in tests.

## RunProcess Resilience Features

Beyond the basic lifecycle, RunProcess handles several edge cases:

- **Gateway retry** - Retries `submit_to_gateway` with exponential backoff if the gateway scheduler is not yet available (100ms base, 2s max)
- **SessionRegistry single-flight** - If another run is still registered for the session when `:run_started` arrives, retries registration with backoff (25ms–250ms) rather than dropping the run
- **Gateway process monitoring** - Monitors the gateway run PID; if it dies without a `:run_completed` event, synthesizes a failure completion event (with a 200ms grace window for normal exits)
- **Run watchdog timeout** - Starts a per-run inactivity watchdog on `:run_started` (default 2 hours, configurable via `:lemon_router, :run_process_idle_watchdog_timeout_ms`; legacy key `:run_process_watchdog_timeout_ms` still supported). Watchdog is reset by run activity (`:delta`, `:engine_action`, other run events). For Telegram channel sessions, idle timeout first sends an inline keepalive prompt (`Keep Waiting` / `Stop Run`) and waits a confirmation window (`:run_process_idle_watchdog_confirm_timeout_ms`, default 5 minutes) before forced cancellation.
- **Zero-answer auto-retry** - If a run fails with an `assistant_error` and returns an empty answer, automatically retries once with a context-aware prompt prefix (not for context overflow, user abort, timeout, or interrupt errors)
- **Context overflow handling** - On context-length errors, clears resume state, marks `:pending_compaction` in Store, resets Telegram-specific chat state
- **Preemptive compaction** - After successful runs, checks token usage against context window; if near the limit, marks `:pending_compaction` for proactive context management
- **Auto file sending** - Tracks generated image paths and requested send files during a run; sends them to Telegram at run completion

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

## Dependencies

**Umbrella deps:**
- `lemon_core` - Core types, SessionKey, Store, Bus, Telemetry, EventBridge, RouterBridge
- `lemon_gateway` - Gateway scheduler, engines, runtime, RunRegistry
- `lemon_channels` - Channel delivery, Telegram outbox, EngineRegistry, GatewayConfig
- `coding_agent` - Coding agent types
- `agent_core` - CLI resume types

**External deps:**
- `bandit` - HTTP server for health checks
- `plug` - HTTP routing
- `jason` - JSON encoding

## Health Checks

HTTP health server runs on port 4043 (configurable via `:health_port`):

```
GET /health → 200 OK {"status":"healthy"}
GET /ready  → 200/503 depending on run capacity
```

Disable with `config :lemon_router, health_enabled: false`.

## Configuration

```elixir
# config/config.exs
config :lemon_router,
  default_model: "claude-3-sonnet",
  health_enabled: true,
  health_port: 4043,
  run_process_limit: 500

# Agent profiles are loaded from LemonCore.Config
# (global ~/.lemon/config.toml + project .lemon/config.toml)
```
