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

- `LemonRouter.AgentDirectory` - Session discovery and listing
- `LemonRouter.AgentProfiles` - Agent configuration (engine, model, tool_policy)
- `LemonRouter.AgentEndpoints` - Endpoint aliases for routing
- `LemonRouter.AgentInbox` - BEAM-local inbox API

### Common Operations

```elixir
# List all known agents with stats
LemonRouter.list_agent_directory()
# => [%{agent_id: "...", name: "...", active_session_count: 1, ...}]

# List sessions for an agent
LemonRouter.AgentDirectory.list_sessions(agent_id: "my_agent")

# Get latest session
LemonRouter.AgentDirectory.latest_session("my_agent")

# List known targets (for UI discovery)
LemonRouter.list_agent_targets(query: "group name")

# Send to agent inbox
LemonRouter.send_to_agent("my_agent", "Hello", session: :latest)
LemonRouter.send_to_agent("my_agent", "Hello", session: :new, to: "tg:chat_id")
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

`LemonRouter.SmartRouting` classifies message complexity:

```elixir
LemonRouter.SmartRouting.classify_message("What is 2+2?")
# => :simple

LemonRouter.SmartRouting.classify_message("Implement a distributed consensus algorithm...")
# => :complex
```

Classification uses keywords, message length, and code block detection.

### Model Selection

`LemonRouter.ModelSelection` resolves models with precedence:

```elixir
# Precedence (highest to lowest):
# 1. Request-level explicit model
# 2. Meta model from request
# 3. Session model from policy
# 4. Profile model from agent config
# 5. Router default model

LemonRouter.ModelSelection.resolve(%{
  explicit_model: "claude-3-opus",
  session_model: "gpt-4",
  profile_model: "claude-3-sonnet",
  default_model: "gpt-3.5"
})
# => %{model: "claude-3-opus", engine_id: "claude", ...}
```

### Sticky Engine Affinity

`LemonRouter.StickyEngine` extracts engine preferences from prompts:

```elixir
# User says: "use codex to refactor this"
LemonRouter.StickyEngine.extract_from_prompt("use codex to refactor this")
# => {:ok, "codex"}
```

The engine preference is persisted to session policy and used for subsequent runs.

### Policy Resolution

`LemonRouter.Policy` merges tool policies from multiple sources:

```elixir
# Merge order: agent → channel → session → runtime (later wins)
policy = LemonRouter.Policy.resolve_for_run(%{
  agent_id: "my_agent",
  session_key: session_key,
  origin: :channel,
  channel_context: %{...}
})
```

Policy fields:
- `approvals` - Approval requirements per tool (`:always`, `:dangerous`, `:never`)
- `blocked_tools` - List of blocked tool names
- `allowed_commands`/`blocked_commands` - Command whitelist/blacklist
- `sandbox` - Sandbox mode boolean

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
# :collect - Queue behind existing runs (default for channels)
# :followup - Start immediately, replaceable
# :steer - High priority, replaces queued runs
# :steer_backlog - Steer but preserve backlog
# :interrupt - Cancel active run and start immediately

LemonRouter.submit(%{queue_mode: :steer, ...})
```

### Handle Resume Tokens

```elixir
# RunOrchestrator extracts resume tokens from prompts
{resume, stripped_prompt} = LemonRouter.RunOrchestrator.extract_resume_and_strip_prompt(
  "codex resume abc123",
  meta
)
# resume => %{engine: "codex", value: "abc123"}
# stripped_prompt => ""
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
  
  # Wait for completion
  assert_receive %LemonCore.Event{type: :run_completed}, 5000
end
```

**Testing with Mock Engine:**

```elixir
# Configure test to use Echo engine
Application.put_env(:lemon_router, :default_model, "echo")
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
| `agent_directory_test.exs` | Session discovery, filtering |
| `agent_inbox_test.exs` | Inbox API, selectors, fanout |
| `policy_test.exs` | Policy merging, resolution |
| `model_selection_test.exs` | Model/engine resolution |
| `sticky_engine_test.exs` | Engine extraction, affinity |

### Debugging Tips

**Enable debug logging:**

```elixir
# In test or iex
require Logger
Logger.configure(level: :debug)
```

**Inspect registry state:**

```elixir
Registry.select(LemonRouter.RunRegistry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}}])
Registry.select(LemonRouter.SessionRegistry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}}])
```

**Check coalescer state:**

```elixir
:sys.get_state({:via, Registry, {LemonRouter.CoalescerRegistry, {session_key, "telegram"}}})
```

## Dependencies

**Umbrella deps:**
- `lemon_core` - Core types, SessionKey, Store, Bus, Telemetry
- `lemon_gateway` - Gateway scheduler, engines, runtime
- `lemon_channels` - Channel delivery, Telegram outbox
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
