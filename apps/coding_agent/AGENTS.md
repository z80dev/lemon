# CodingAgent App Guide

The main coding agent implementation for the Lemon AI assistant platform. This app provides a complete AI coding agent with 30+ tools, session management, budget tracking, extensions, and compaction.

## Dependencies

- `agent_core` - Core agent runtime and types
- `ai` - AI model providers and LLM integration
- `lemon_core` - Shared primitives (sessions, storage, exec approvals)
- `lemon_skills` - Skill discovery and loading

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           CodingAgent.Session                                │
│  (Main GenServer - orchestrates agent loop, events, steering, follow-ups)   │
└────────────────────┬────────────────────────────────────────────────────────┘
                     │
    ┌────────────────┼────────────────┬───────────────┬────────────────┐
    │                │                │               │                │
    ▼                ▼                ▼               ▼                ▼
┌─────────┐   ┌────────────┐  ┌────────────┐  ┌────────────┐  ┌──────────────┐
│ Session │   │  Settings  │  │   Tools    │  │ Workspace  │  │   Prompt     │
│ Manager │   │   Manager  │  │  (30+)     │  │  (bootstrap│  │   Builder    │
│(JSONL)  │   │  (TOML)    │  │            │  │   files)   │  │              │
└─────────┘   └────────────┘  └────────────┘  └────────────┘  └──────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                        Session Supervision Tree                              │
├─────────────────────────────────────────────────────────────────────────────┤
│  CodingAgent.SessionRootSupervisor (permanent)                               │
│  ├── CodingAgent.SessionSupervisor (dynamic, one_for_one)                   │
│  │   └── CodingAgent.Session processes (temporary, :transient in tests)     │
│  ├── CodingAgent.SessionRegistry (via Registry)                             │
│  ├── CodingAgent.RunGraphServer (ETS + DETS persistence)                    │
│  ├── CodingAgent.TaskSupervisor (for async operations)                      │
│  └── CodingAgent.ProcessStoreServer (subagent process tracking)             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Key Modules

### Session Management

| Module | Purpose |
|--------|---------|
| `CodingAgent.Session` | Main GenServer orchestrating the agent loop |
| `CodingAgent.SessionManager` | JSONL persistence with tree structure |
| `CodingAgent.SessionSupervisor` | DynamicSupervisor for session processes |
| `CodingAgent.SessionRegistry` | Registry for session lookup by ID |
| `CodingAgent.SessionRootSupervisor` | Top-level supervisor for all session infra |

### Tools (30+ tools)

| Category | Tools |
|----------|-------|
| **File Operations** | `read`, `write`, `edit`, `multiedit`, `patch`, `ls`, `glob`, `hashline_edit` |
| **Search** | `grep`, `find`, `fuzzy` |
| **Execution** | `bash`, `exec`, `lsp_formatter`, `browser` |
| **Web** | `websearch`, `webfetch`, `webdownload` |
| **Task Management** | `task`, `agent`, `todo`, `todoread`, `todowrite` |
| **Process** | `process`, `poll_jobs`, `restart` |
| **Social** | `post_to_x`, `get_x_mentions` |
| **System** | `tool_auth`, `extensions_status`, `memory_topic`, `truncate` |

### Tool Infrastructure

| Module | Purpose |
|--------|---------|
| `CodingAgent.Tools` | Tool factory and registry access |
| `CodingAgent.ToolRegistry` | Dynamic tool resolution (builtin → WASM → extension) |
| `CodingAgent.ToolExecutor` | Approval-gated tool execution wrapper |
| `CodingAgent.ToolPolicy` | Tool enablement/disablement policies |

### Budget & Resource Management

| Module | Purpose |
|--------|---------|
| `CodingAgent.BudgetTracker` | Token/cost budget tracking per run |
| `CodingAgent.BudgetEnforcer` | Budget limit enforcement |
| `CodingAgent.RunGraph` | ETS-backed parent/child run relationships |
| `CodingAgent.RunGraphServer` | DETS persistence for run graph |

### Memory & Context

| Module | Purpose |
|--------|---------|
| `CodingAgent.Compaction` | Context compaction when conversations grow large |
| `CodingAgent.CompactionHooks` | Hooks for compaction events |
| `CodingAgent.Workspace` | Bootstrap file loading (AGENTS.md, SOUL.md, etc.) |
| `CodingAgent.PromptBuilder` | Dynamic system prompt construction |

### Extensions

| Module | Purpose |
|--------|---------|
| `CodingAgent.Extensions` | Extension loading and management |
| `CodingAgent.Extensions.Extension` | Behaviour for extensions |
| `CodingAgent.ExtensionLifecycle` | Extension lifecycle (load/reload) |
| `CodingAgent.ToolRegistry` | Extension tool integration |

## Tool System Architecture

### Adding a New Tool

1. **Create tool module** at `lib/coding_agent/tools/my_tool.ex`:

```elixir
defmodule CodingAgent.Tools.MyTool do
  @moduledoc "Description of what my tool does"
  
  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.TextContent
  
  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    %AgentTool{
      name: "my_tool",
      description: "What this tool does",
      label: "My Tool",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "param" => %{
            "type" => "string",
            "description" => "Parameter description"
          }
        },
        "required" => ["param"]
      },
      execute: &execute(&1, &2, &3, &4, cwd, opts)
    }
  end
  
  @spec execute(String.t(), map(), reference() | nil, function() | nil, String.t(), keyword()) ::
          AgentToolResult.t() | {:error, term()}
  def execute(tool_call_id, params, signal, on_update, cwd, opts) do
    # Check abort signal
    if signal && AgentCore.AbortSignal.aborted?(signal) do
      %AgentToolResult{content: [%TextContent{text: "Cancelled"}]}
    else
      # Execute tool logic
      result = do_something(params, cwd)
      
      %AgentToolResult{
        content: [%TextContent{text: result}],
        details: %{param: params["param"]}
      }
    end
  end
end
```

2. **Register in `CodingAgent.Tools`** - Add to `coding_tools/2`, `all_tools/2`, and imports

3. **Register in `CodingAgent.ToolRegistry`** - Add to `@builtin_tools` list

4. **Add tests** at `test/coding_agent/tools/my_tool_test.exs`

### Tool Precedence

Tools are resolved in this order (later shadows earlier):

1. Built-in tools (`CodingAgent.Tools.*`)
2. WASM tools (from `.lemon/wasm/`)
3. Extension tools (from `.lemon/extensions/`)

### Tool Execution Flow

```
LLM requests tool
       │
       ▼
┌──────────────┐
│ ToolRegistry │ ──► Resolves tool by name (builtin/WASM/extension)
└──────┬───────┘
       │
       ▼
┌──────────────┐
│ ToolExecutor │ ──► Checks ToolPolicy for approval requirement
└──────┬───────┘
       │
       ▼
┌──────────────┐
│  Tool Module │ ──► Executes tool logic with abort signal support
└──────────────┘
```

## Session Lifecycle

### Starting a Session

```elixir
# Under supervision (preferred)
{:ok, session} = CodingAgent.start_session(
  cwd: "/path/to/project",
  model: Ai.Models.get_model(:anthropic, "claude-sonnet-4-20250514"),
  system_prompt: "Custom system prompt (optional)"
)

# Direct (for testing)
{:ok, session} = CodingAgent.Session.start_link(
  cwd: "/path/to/project",
  model: model
)
```

### Session Events

```elixir
# Subscribe to events
unsubscribe = CodingAgent.Session.subscribe(session)

# Events are sent as:
# {:session_event, session_id, event}

# Unsubscribe when done
unsubscribe.()
```

### Session Persistence

Sessions are persisted as JSONL files:
- Format: Each line is a JSON entry
- First entry: `SessionHeader` with version, id, cwd
- Subsequent: `SessionEntry` with tree structure (id, parent_id)
- Entry types: `:message`, `:compaction`, `:branch_summary`, `:label`, etc.

Location: `~/.lemon/sessions/{session_id}.jsonl`

## Workspace Management

Bootstrap files loaded from `~/.lemon/agent/workspace/`:

| File | Purpose |
|------|---------|
| `AGENTS.md` | Project guidelines for AI agents |
| `SOUL.md` | Agent personality/identity |
| `TOOLS.md` | Tool documentation |
| `IDENTITY.md` | Identity configuration |
| `USER.md` | User preferences |
| `HEARTBEAT.md` | Health check configuration |
| `BOOTSTRAP.md` | Startup instructions |
| `MEMORY.md` | Persistent memory (main sessions only) |

### Loading Workspace Files

```elixir
files = CodingAgent.Workspace.load_bootstrap_files(
  workspace_dir: "/path/to/workspace",
  session_scope: :main  # or :subagent
)
```

## Budget Tracking

Budgets track resource usage per run with parent/child inheritance:

```elixir
# Create budget
budget = CodingAgent.BudgetTracker.create_budget(
  max_tokens: 100_000,
  max_cost: 5.0,
  max_children: 10
)

# Record usage
CodingAgent.BudgetTracker.record_usage(run_id, tokens: 500, cost: 0.01)

# Check limits
CodingAgent.BudgetTracker.check_budget(run_id)
# Returns: :ok | {:warning, message} | {:exceeded, message}

# Subagent inherits from parent
subagent_budget = CodingAgent.BudgetTracker.create_subagent_budget(
  parent_id,
  max_tokens: 50_000  # Stricter than parent
)
```

## Extension System

### Extension Behaviour

Extensions implement `CodingAgent.Extensions.Extension`:

```elixir
defmodule MyExtension do
  @behaviour CodingAgent.Extensions.Extension
  
  @impl true
  def name, do: "my-extension"
  
  @impl true
  def version, do: "1.0.0"
  
  @impl true
  def tools(cwd) do
    [%AgentCore.Types.AgentTool{name: "my_tool", ...}]
  end
  
  @impl true
  def hooks do
    [
      on_turn_start: fn -> Logger.info("Turn started") end,
      on_tool_execution_end: fn id, name, result, is_error -> ... end
    ]
  end
  
  @impl true
  def capabilities, do: [:tools, :hooks]
  
  @impl true
  def config_schema, do: %{"type" => "object", ...}
  
  @impl true
  def providers do
    [%{type: :model, name: :my_model, module: MyModel, config: %{}}]
  end
end
```

### Available Hooks

- `:on_agent_start` - `fn -> :ok`
- `:on_agent_end` - `fn messages -> :ok`
- `:on_turn_start` - `fn -> :ok`
- `:on_turn_end` - `fn message, tool_results -> :ok`
- `:on_message_start` - `fn message -> :ok`
- `:on_message_end` - `fn message -> :ok`
- `:on_tool_execution_start` - `fn id, name, args -> :ok`
- `:on_tool_execution_end` - `fn id, name, result, is_error -> :ok`

### Loading Extensions

```elixir
# Load from paths
{:ok, extensions} = CodingAgent.Extensions.load_extensions([
  "/path/to/extensions"
])

# Get tools
CodingAgent.Extensions.get_tools(extensions, cwd)

# Get hooks
CodingAgent.Extensions.get_hooks(extensions)
```

## Compaction

When conversations grow too large, compaction summarizes older messages:

```elixir
# Check if compaction needed
CodingAgent.Compaction.should_compact?(
  context_tokens,
  context_window,
  %{enabled: true, reserve_tokens: 16_384}
)

# Perform compaction
{:ok, summary} = CodingAgent.Compaction.compact(
  entries,
  current_entry_id,
  settings
)
```

Compaction:
- Finds valid cut points (not mid-tool-call)
- Generates summary of compacted messages
- Preserves file operation context

## Common Tasks

### Running Tests

```bash
# All tests
mix test

# Specific module
mix test apps/coding_agent/test/coding_agent/session_test.exs

# Specific test
mix test apps/coding_agent/test/coding_agent/tools/read_test.exs:123

# Include integration tests
mix test --include integration
```

### Adding a Subagent

Subagents are defined via `@mention` syntax in prompts. See `CodingAgent.Subagents`.

### Debugging a Session

```elixir
# Get session state
:sys.get_state(session_pid)

# Check run graph
CodingAgent.RunGraph.get(run_id)

# List active sessions
CodingAgent.SessionSupervisor.list_sessions()

# Health check
CodingAgent.SessionSupervisor.health_all()
```

### Modifying Tool Policy

```elixir
# Tools requiring approval
policy = %{
  require_approval: ["write", "edit", "bash"],
  disabled: []
}

# Passed to session on start
CodingAgent.start_session(
  cwd: cwd,
  model: model,
  tool_policy: policy
)
```

## File Structure

```
apps/coding_agent/
├── lib/
│   ├── coding_agent.ex                 # Main API
│   ├── coding_agent/
│   │   ├── session.ex                  # Main orchestrator
│   │   ├── session_manager.ex          # JSONL persistence
│   │   ├── session_supervisor.ex       # DynamicSupervisor
│   │   ├── session_registry.ex         # Process registry
│   │   ├── tool_executor.ex            # Approval gating
│   │   ├── tool_registry.ex            # Dynamic resolution
│   │   ├── tools.ex                    # Tool factory
│   │   ├── tools/                      # Individual tools
│   │   │   ├── read.ex
│   │   │   ├── write.ex
│   │   │   ├── bash.ex
│   │   │   └── ... (30+ tools)
│   │   ├── budget_tracker.ex
│   │   ├── budget_enforcer.ex
│   │   ├── compaction.ex
│   │   ├── run_graph.ex
│   │   ├── extensions.ex
│   │   ├── extensions/extension.ex     # Behaviour
│   │   ├── workspace.ex
│   │   └── prompt_builder.ex
│   └── mix/tasks/                      # Mix tasks
├── test/
│   ├── coding_agent/
│   │   ├── *_test.exs
│   │   └── tools/*_test.exs
│   └── support/
└── priv/templates/workspace/           # Bootstrap templates
```

## Key Types

```elixir
# AgentTool from AgentCore
%AgentCore.Types.AgentTool{
  name: "tool_name",
  description: "What it does",
  label: "Display Label",
  parameters: %{"type" => "object", ...},
  execute: fn tool_call_id, params, signal, on_update -> result end
}

# AgentToolResult
%AgentCore.Types.AgentToolResult{
  content: [%TextContent{text: "result"}],
  details: %{}
}

# SessionEntry
%CodingAgent.SessionManager.SessionEntry{
  id: "entry_id",
  parent_id: "parent_id" | nil,
  type: :message | :compaction | :branch_summary | ...,
  # ... type-specific fields
}
```

## Testing Guidelines

- Use `CodingAgent.Session.start_link/1` directly in tests (not supervised)
- Mock UI with `CodingAgent.UI.Context` test helpers
- Use temporary directories for file operations
- Clean up sessions with `Process.exit(session, :normal)`
- For tool tests: assert on both `content` and `details` in results
- Use `async: false` for tests that modify global state (extensions, ETS tables)
