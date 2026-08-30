# Code Duplication Analysis: Sim/Automation/Misc Apps

## Executive Summary

Analyzed 8 apps (lemon_sim, lemon_sim_ui, lemon_automation, lemon_control_plane, market_intel, agent_core, lemon_skills, lemon_mcp) and identified major duplication patterns across process management, event handling, streaming/decoding, and game logic.

---

## 1. PROCESS MANAGEMENT DUPLICATION (GenServer/Agent/Task Patterns)

### Pattern: Manager/Scheduler GenServers with Periodic Ticking

**Files:**
- `apps/lemon_automation/lib/lemon_automation/cron_manager.ex`
- `apps/market_intel/lib/market_intel/scheduler.ex`
- `apps/lemon_sim_ui/lib/lemon_sim_ui/sim_manager.ex`

**Duplicated Code:**
```elixir
# CRON_MANAGER pattern
use GenServer

def start_link(opts \\ []) do
  GenServer.start_link(__MODULE__, opts, name: __MODULE__)
end

@impl true
def init(_opts) do
  schedule_tick()
  {:ok, initial_state}
end

@impl true
def handle_info(:tick, state) do
  # Process work...
  schedule_tick()
  {:noreply, updated_state}
end

defp schedule_tick do
  Process.send_after(self(), :tick, @tick_interval_ms)
end

# SCHEDULER pattern (identical structure)
use GenServer

def start_link(opts) do
  GenServer.start_link(__MODULE__, opts, name: __MODULE__)
end

@impl true
def init(_opts) do
  schedule_regular()
  schedule_deep_analysis()
  {:ok, %{last_regular: nil, last_deep: nil}}
end

@impl true
def handle_info(:regular_commentary, state) do
  # Process work...
  schedule_regular()
  {:noreply, updated_state}
end

defp schedule_regular do
  Process.send_after(self(), :regular_commentary, :timer.minutes(30))
end
```

**Suggestion for Extraction:**
Create `LemonCore.GenServerHelpers.PeriodicManager` or similar:
```elixir
defmodule GenServerHelpers.PeriodicManager do
  defmacro __using__(opts) do
    quote do
      use GenServer

      def start_link(opts \\ []) do
        GenServer.start_link(__MODULE__, opts, name: __MODULE__)
      end

      def schedule_task(name, interval_ms) do
        Process.send_after(self(), {:task, name}, interval_ms)
      end
    end
  end
end
```

---

## 2. EVENT HANDLING DUPLICATION (apply_event Pattern)

### Pattern: State Machine with Event Normalization and Dispatch

**Files:**
All game updaters follow identical structure:
- `apps/lemon_sim/lib/lemon_sim/examples/werewolf/updater.ex`
- `apps/lemon_sim/lib/lemon_sim/examples/survivor/updater.ex`
- `apps/lemon_sim/lib/lemon_sim/examples/auction/updater.ex`
- `apps/lemon_sim/lib/lemon_sim/examples/courtroom/updater.ex`
- `apps/lemon_sim/lib/lemon_sim/examples/diplomacy/updater.ex`
- `apps/lemon_sim/lib/lemon_sim/examples/dungeon_crawl/updater.ex`
- `apps/lemon_sim/lib/lemon_sim/examples/intel_network/updater.ex`
- `apps/lemon_sim/lib/lemon_sim/examples/legislature/updater.ex`
- `apps/lemon_sim/lib/lemon_sim/examples/murder_mystery/updater.ex`
- `apps/lemon_sim/lib/lemon_sim/examples/pandemic/updater.ex`
- `apps/lemon_sim/lib/lemon_sim/examples/skirmish/updater.ex`
- `apps/lemon_sim/lib/lemon_sim/examples/space_station/updater.ex`
- `apps/lemon_sim/lib/lemon_sim/examples/startup_incubator/updater.ex`
- `apps/lemon_sim/lib/lemon_sim/examples/stock_market/updater.ex`
- `apps/lemon_sim/lib/lemon_sim/examples/supply_chain/updater.ex`
- `apps/lemon_sim/lib/lemon_sim/examples/vending_bench/updater.ex`
- `apps/lemon_sim/lib/lemon_sim/examples/tic_tac_toe/updater.ex`

**Duplicated Code:**
```elixir
@impl true
def apply_event(%State{} = state, raw_event, _opts) do
  event = Events.normalize(raw_event)
  state = maybe_store_thought(state, event)

  case event.kind do
    "action_1" -> apply_action_1(state, event)
    "action_2" -> apply_action_2(state, event)
    "action_3" -> apply_action_3(state, event)
    _ -> {:error, {:invalid_event_kind, event.kind}}
  end
end

defp apply_action_1(%State{} = state, event) do
  player_id = fetch(event.payload, :player_id, "player_id")
  players = get(state.world, :players, %{})

  with :ok <- ensure_in_progress(state.world),
       :ok <- ensure_phase(state.world, "phase_name"),
       :ok <- ensure_active_actor(state.world, player_id),
       :ok <- ensure_living(players, player_id) do
    # ... apply changes ...
    {:ok, next_state, signal}
  else
    {:error, reason} ->
      reject_action(state, event, player_id, reason)
  end
end

# INTERNAL DUPLICATION: many updaters define their own maybe_store_thought
# instead of using LemonSim.GameHelpers.UpdaterHelpers.maybe_store_thought
defp maybe_store_thought(state, event) do
  thought = Map.get(event.payload, "thought") || Map.get(event.payload, :thought)
  player_id = Map.get(event.payload, "player_id") || Map.get(event.payload, :player_id)

  if is_binary(thought) and thought != "" and is_binary(player_id) do
    journals = get(state.world, :journals, %{})
    player_journal = Map.get(journals, player_id, [])

    entry = %{
      round: get(state.world, :round, nil) || get(state.world, :episode, nil) || ...
      phase: get(state.world, :phase),
      thought: thought
    }

    new_journals = Map.put(journals, player_id, player_journal ++ [entry])
    State.put_world(state, world_updates(state.world, %{journals: new_journals}))
  else
    state
  end
end
```

**Issue:**
- `LemonSim.GameHelpers.UpdaterHelpers` already defines `maybe_store_thought/2`, but 3+ updaters (werewolf, space_station) define their own versions
- The custom versions have slight logic differences (day_number vs round vs episode)
- Werewolf excludes `import LemonSim.GameHelpers.UpdaterHelpers, except: [maybe_store_thought: 2]` to use its own

**Suggestion for Extraction:**
1. Consolidate all `maybe_store_thought` implementations into a single configurable version in `UpdaterHelpers`
2. All game updaters should `import LemonSim.GameHelpers.UpdaterHelpers` without exceptions
3. Create a generic event dispatcher behavior to reduce case/5 duplication:

```elixir
defmodule LemonSim.EventDispatcher do
  @callback event_handlers() :: %{String.t() => atom()}

  defmacro __using__(_opts) do
    quote do
      @behaviour LemonSim.EventDispatcher

      def apply_event(%State{} = state, raw_event, _opts) do
        event = Events.normalize(raw_event)
        state = maybe_store_thought(state, event)

        case Map.get(event_handlers(), event.kind) do
          nil -> {:error, {:invalid_event_kind, event.kind}}
          handler -> apply(__MODULE__, handler, [state, event])
        end
      end
    end
  end
end

# In each game's Updater:
defmodule LemonSim.Examples.Werewolf.Updater do
  use LemonSim.EventDispatcher

  @impl true
  def event_handlers do
    %{
      "choose_victim" => :apply_choose_victim,
      "investigate_player" => :apply_investigate_player,
      # ...
    }
  end
end
```

---

## 3. CLI RUNNER DUPLICATION (agent_core)

### Pattern: Identical init_state and build_command Boilerplate

**Files:**
- `apps/agent_core/lib/agent_core/cli_runners/claude_runner.ex`
- `apps/agent_core/lib/agent_core/cli_runners/codex_runner.ex`
- `apps/agent_core/lib/agent_core/cli_runners/opencode_runner.ex`
- `apps/agent_core/lib/agent_core/cli_runners/kimi_runner.ex`
- `apps/agent_core/lib/agent_core/cli_runners/pi_runner.ex`

**Duplicated Code:**
All 5 runners define nearly identical stub methods:

```elixir
# PATTERN 1: engine definition (identical across all runners)
@engine "claude"

def engine, do: @engine

# PATTERN 2: init_state overloads (identical signatures)
def init_state(_prompt, _resume) do
  %RunnerState{factory: EventFactory.new("claude"), ...}
end

def init_state(_prompt, _resume, cwd) do
  RunnerState.new(resume, cwd, LemonConfig.load(cwd))
end

def init_state(_prompt, _resume, cwd, opts) do
  # ... similar initialization
end

# PATTERN 3: build_command shell building (similar pattern)
def build_command(prompt, resume, state) do
  args = ["run", "--format", "json"]
  args = case resume do
    %ResumeToken{value: session_id} -> args ++ ["--session", session_id]
    nil -> args
  end
  # ...
  {"runner_name", args ++ ["--", prompt]}
end
```

**Issue:**
- `JsonlRunner` module exists as a base behavior but runners still duplicate 50+ lines each
- All have identical `RunnerState` struct with same fields
- All follow same initialization pattern

**Suggestion for Extraction:**
Leverage the existing `JsonlRunner` base more effectively:

```elixir
defmodule AgentCore.CliRunners.JsonlRunner do
  # Current behavior definition
  defmacro __using__(_opts) do
    quote do
      use GenServer

      # Provide default implementations that submodules can override

      def init_state(_prompt, resume, cwd) do
        RunnerState.new(resume, cwd, LemonConfig.load(cwd))
      end

      def init_state(_prompt, resume, cwd, _opts) do
        init_state(nil, resume, cwd)
      end

      defoverridable(init_state: 2, init_state: 3, init_state: 4)
    end
  end
end

# Then each runner just implements build_command and event handling logic
defmodule AgentCore.CliRunners.ClaudeRunner do
  use AgentCore.CliRunners.JsonlRunner

  @engine "claude"
  def engine, do: @engine

  @impl true
  def build_command(prompt, resume, _state) do
    args = ["run", "-p", "--output-format", "stream-json"]
    args = if resume, do: args ++ ["--resume", resume.value], else: args
    {"claude", args ++ ["--", prompt]}
  end
end
```

---

## 4. MCP PROTOCOL DUPLICATION

### Pattern: JSON-RPC Handler Boilerplate

**Files:**
- `apps/lemon_mcp/lib/lemon_mcp/protocol.ex`
- `apps/lemon_mcp/lib/lemon_mcp/server/handler.ex`

**Duplicated Code:**
```elixir
def decode(json) when is_binary(json) do
  case Jason.decode(json) do
    {:ok, data} -> decode_map(data)
    {:error, _} -> {:error, :parse_error}
  end
end

def parse_request(%{"jsonrpc" => "2.0"} = payload) do
  request = %JSONRPCRequest{jsonrpc: "2.0", method: method, ...}
  {:ok, request}
end

def handle_request(%Protocol.JSONRPCRequest{} = request, server) do
  case request.method do
    "initialize" -> handle_initialize(request, server)
    "initialized" -> handle_initialized(request, server)
    "tools/list" -> handle_tools_list(request, server)
    "tools/call" -> handle_tools_call(request, server)
    _ -> Protocol.create_error_response(...)
  end
end
```

**Observation:**
This pattern is specific to MCP and doesn't have high cross-app duplication, but could benefit from pattern extraction.

**Suggestion:**
Create a routing helper in Protocol module:
```elixir
defmodule LemonMCP.Protocol.Router do
  def route(request, handlers) when is_map(handlers) do
    case Map.get(handlers, request.method) do
      nil -> create_error_response(request.id, :method_not_found, "...")
      handler_fn -> handler_fn.(request)
    end
  end
end
```

---

## 5. SKILL PATTERNS & SOURCES (lemon_skills)

### Pattern: Source Module Boilerplate

**Files:**
- `apps/lemon_skills/lib/lemon_skills/sources/builtin.ex`
- `apps/lemon_skills/lib/lemon_skills/sources/git.ex`
- `apps/lemon_skills/lib/lemon_skills/sources/github.ex`
- `apps/lemon_skills/lib/lemon_skills/sources/local.ex`
- `apps/lemon_skills/lib/lemon_skills/sources/registry.ex`

**Observed:** Each source implements `@behaviour LemonSkills.Source` with:
- `discover/1` - find skills
- `fetch/2` - get skill details
- Error handling patterns
- Caching logic

**Issue:** While these follow a behavior, there's likely duplication in:
- Error handling/wrapping
- HTTP client usage
- Cache key generation

**Suggestion:**
Create a `SourceBase` helper module to standardize:
- Error wrapping patterns
- HTTP client initialization
- Cache key/TTL management
- Manifest parsing

---

## 6. GAME LOGIC DUPLICATION (lemon_sim Game Helpers)

### Pattern: Duplicated Tool Builders

**Files:**
- `apps/lemon_sim/lib/lemon_sim/game_helpers/tools.ex`

**Duplicated Code within single file:**
```elixir
# All three tools follow near-identical pattern
def statement_tool(actor_id, opts \\ []) do
  description = Keyword.get(opts, :description, "default...")

  %AgentTool{
    name: "make_statement",
    description: description,
    parameters: %{
      "type" => "object",
      "properties" => %{"statement" => %{"type" => "string", ...}},
      "required" => ["statement"],
      "additionalProperties" => false
    },
    label: "Make Statement",
    execute: fn _tool_call_id, params, _signal, _on_update ->
      statement = Map.get(params, "statement", Map.get(params, :statement, ""))
      event = Event.new("make_statement", %{"player_id" => actor_id, "statement" => statement})
      {:ok, %AgentToolResult{content: [...], details: %{"event" => event}, trust: :trusted}}
    end
  }
end

def vote_tool(actor_id, valid_targets, opts \\ []) do
  # ... nearly identical structure, just different field names ...
  execute: fn _tool_call_id, params, _signal, _on_update ->
    target_id = Map.get(params, "target_id", ...)
    event = Event.new("cast_vote", %{"player_id" => actor_id, "target_id" => target_id})
    {:ok, %AgentToolResult{...}}
  end
end

def whisper_tool(actor_id, valid_targets, opts \\ []) do
  # ... identical pattern again ...
end
```

**Internal Duplication:** These 3 tools have 70%+ identical code

**Suggestion:**
Create a `game_helpers/tool_factory.ex`:

```elixir
defmodule LemonSim.GameHelpers.ToolFactory do
  def build_tool(name, actor_id, event_type, fields, opts \\ []) do
    description = Keyword.get(opts, :description, "")

    %AgentTool{
      name: name,
      description: description,
      parameters: build_parameters(fields),
      execute: fn _tool_call_id, params, _signal, _on_update ->
        payload = Enum.into(fields, %{"player_id" => actor_id},
          fn {key, _} -> {to_string(key), Map.get(params, key)} end)
        event = Event.new(event_type, payload)
        {:ok, %AgentToolResult{...}}
      end
    }
  end

  defp build_parameters(fields) do
    # Common parameter structure builder
  end
end
```

---

## 7. STREAMING/DECODING DUPLICATION (agent_core)

### Pattern: Schema Decode Functions

**Files:**
- `apps/agent_core/lib/agent_core/cli_runners/claude_schema.ex`
- `apps/agent_core/lib/agent_core/cli_runners/codex_schema.ex`
- `apps/agent_core/lib/agent_core/cli_runners/opencode_schema.ex`
- `apps/agent_core/lib/agent_core/cli_runners/kimi_schema.ex`
- `apps/agent_core/lib/agent_core/cli_runners/pi_schema.ex`

**Duplicated Pattern:**
```elixir
def decode_event(json) when is_binary(json) do
  case Jason.decode(json) do
    {:ok, data} -> decode_event_map(data)
    {:error, _} -> {:error, :parse_error}
  end
end

def decode_event_map(%{"type" => type} = data) when is_binary(type) do
  case type do
    "message" -> {:ok, decode_message(data)}
    "error" -> {:ok, decode_error(data)}
    _ -> {:ok, %Unknown{raw: data}}
  end
end

def decode_event_map(_), do: {:error, :invalid_event}
```

**Issue:**
- All 5 schema modules repeat the JSON parsing and error handling
- Dispatch logic is identical

**Suggestion:**
Create `CliRunners.SchemaBase` behavior:

```elixir
defmodule AgentCore.CliRunners.SchemaBase do
  @callback decode_typed(String.t(), map()) :: {:ok, struct()} | {:error, term()}

  def decode_event(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, data} -> decode_event_map(data)
      {:error, _} -> {:error, :parse_error}
    end
  end

  def decode_event_map(%{"type" => type} = data) when is_binary(type) do
    case decode_typed(type, data) do
      {:ok, _} = result -> result
      :unknown -> {:ok, %Unknown{raw: data}}
      error -> error
    end
  end
end
```

---

## 8. UI PATTERNS (lemon_sim_ui)

### Pattern: Board Component Duplication

**Files:**
All game board components:
- `apps/lemon_sim_ui/lib/lemon_sim_ui/live/components/auction_board.ex`
- `apps/lemon_sim_ui/lib/lemon_sim_ui/live/components/werewolf_board.ex`
- `apps/lemon_sim_ui/lib/lemon_sim_ui/live/components/survivor_board.ex`
- ... (18+ board components)

**Pattern:** Each board component:
1. Renders game state
2. Hooks into LiveView events
3. Renders player list, action log, game state
4. Similar layout structure

**Suggestion:**
Create a `BoardComponent` framework with pluggable renderers:

```elixir
defmodule LemonSimUi.Live.Components.BaseBoard do
  defmacro __using__(_opts) do
    quote do
      use Phoenix.LiveComponent

      # Standard board structure with callbacks for game-specific rendering
      def render(assigns) do
        ~H"""
        <div class="game-board">
          <%= render_game_state(assigns) %>
          <%= render_players(assigns) %>
          <%= render_action_log(assigns) %>
        </div>
        """
      end

      def render_game_state(assigns), do: raise "implement in game module"
      def render_players(assigns), do: raise "implement in game module"
      def render_action_log(assigns), do: raise "implement in game module"
    end
  end
end
```

---

## CROSS-APP DUPLICATION FINDINGS

### 1. Error Handling Patterns
- `coding_agent`, `ai`, `agent_core` all define similar `:ok | {:error, reason}` patterns
- No centralized error type definition

**Suggestion:** Create `LemonCore.Error` module with standard error codes

### 2. HTTP Client Wrappers
- `lemon_skills/http_client.ex`
- `market_intel/ingestion/http_client.ex`
- `agent_core` (uses Httpc directly)

**Suggestion:** Centralize in `LemonCore.HttpClient` with retries/timeouts

### 3. Configuration Loading
- `LemonConfig.load(cwd)` used in agent_core cli_runners
- `LemonSim.GameHelpers.Config` for sim config
- `MarketIntel.Config` for market intel

**Suggestion:** Unify under `LemonCore.Config` with app-specific overrides

### 4. Event Emission Patterns
- `LemonCore.Bus.publish` (event publishing)
- `market_intel/commentary/pipeline.ex` (trigger-based)
- `lemon_automation/events.ex` (custom events)

**Suggestion:** Create unified `LemonCore.EventBus` with subscribers

---

## PRIORITY EXTRACTION TARGETS (Highest ROI)

1. **Game Updater Dispatch** (17 files affected)
   - Consolidate event handler dispatching
   - Remove `maybe_store_thought` duplication
   - Lines of code to be removed: ~200-300

2. **CLI Runner Initialization** (5 files affected)
   - Reduce JsonlRunner boilerplate
   - Implement `defoverridable` patterns
   - Lines of code to be removed: ~150-200

3. **GenServer Manager Pattern** (3+ files affected)
   - Extract periodic manager base
   - Standardize init/tick pattern
   - Lines of code to be removed: ~100-150

4. **Tool Builders** (1 file, high internal duplication)
   - Create ToolFactory for statement/vote/whisper
   - Lines of code to be removed: ~100

5. **Schema Decode Pattern** (5 files affected)
   - Extract SchemaBase behavior
   - Standardize JSON parsing
   - Lines of code to be removed: ~75-100

---

## SUMMARY TABLE

| Pattern | Files | Type | LOC Est. | Priority |
|---------|-------|------|----------|----------|
| Event Handler Dispatch | 17 games | Game Logic | 300 | HIGH |
| CLI Runner Init | 5 runners | agent_core | 200 | HIGH |
| GenServer Periodic Mgr | 3+ | Process Mgmt | 150 | HIGH |
| Tool Builders | 1 | Game Logic | 100 | MEDIUM |
| Schema Decode | 5 | Streaming | 100 | MEDIUM |
| Source Modules | 5 | Skills | 75 | MEDIUM |
| Board Components | 18 | UI | 200+ | MEDIUM |

**Total estimated LOC reduction: 1,200-1,500**
