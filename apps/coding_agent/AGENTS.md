# CodingAgent App Guide

The main coding agent implementation for the Lemon AI assistant platform. This app provides a complete AI coding agent with 30+ tools, session management, budget tracking, extensions, WASM tool support, and context compaction.

## Dependencies

- `agent_core` - Core agent runtime, types, and event loop
- `ai` - AI model providers and LLM integration
- `lemon_core` - Shared primitives (sessions, storage, browser, bus, exec approvals)
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
│  │   └── CodingAgent.Session processes (temporary restart)                  │
│  ├── CodingAgent.SessionRegistry (via Registry)                             │
│  ├── CodingAgent.RunGraphServer (ETS + DETS persistence)                    │
│  ├── CodingAgent.TaskSupervisor (for async operations)                      │
│  ├── CodingAgent.ProcessStoreServer (background process tracking)           │
│  ├── CodingAgent.TaskStoreServer (async task tracking with DETS)            │
│  └── CodingAgent.LaneQueue (concurrency-capped subagent/background lanes)  │
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

### Tools

Tools are divided into two sets. `coding_tools/2` is the default set passed to sessions; `all_tools/2` includes extras not in the default set.

**Default `coding_tools/2`** (19 tools registered in `CodingAgent.Tools.coding_tools/2` and `@builtin_tools` in `ToolRegistry`):

| Category | Tools |
|----------|-------|
| **File Operations** | `read`, `write`, `edit`, `patch`, `hashline_edit`, `ls` |
| **Search** | `grep`, `find` |
| **Execution** | `bash`, `browser` |
| **Web** | `websearch`, `webfetch` |
| **Task/Agent** | `task`, `agent`, `todo` |
| **Social** | `post_to_x`, `get_x_mentions` |
| **System** | `tool_auth`, `extensions_status`, `memory_topic` |

**Additional tools** (exist as modules but NOT in default set — must be registered explicitly or accessed via `all_tools/2`):

| Tool | Module | Notes |
|------|--------|-------|
| `multiedit` | `Tools.MultiEdit` | Multiple sequential edits to one file |
| `exec` | `Tools.Exec` | Long-running background processes with poll/kill |
| `process` | `Tools.Process` | Control interface for `exec` background processes |
| `await` | `Tools.Await` | Block until background jobs complete |
| `webdownload` | `Tools.WebDownload` | Download binary content (images, PDFs) to disk |
| `truncate` | `Tools.Truncate` | Truncate long text with configurable strategies |
| `todoread` | `Tools.TodoRead` | Low-level todo read (used internally by `todo`) |
| `todowrite` | `Tools.TodoWrite` | Low-level todo write (used internally by `todo`) |
| `restart` | `Tools.Restart` | Restart the Lemon BEAM process (dev only) |
| `lsp_formatter` | `Tools.LspFormatter` | Format code via LSP |

**Internal helpers** (not exposed as tools): `Tools.Fuzzy` (fuzzy match used by `edit`), `Tools.Hashline` (used by `hashline_edit`), `Tools.WebCache`, `Tools.WebGuard`, `Tools.TodoStore`, `Tools.TodoStoreOwner`.

### Tool Infrastructure

| Module | Purpose |
|--------|---------|
| `CodingAgent.Tools` | Tool factory — `coding_tools/2`, `read_only_tools/2`, `all_tools/2`, `get_tool/3` |
| `CodingAgent.ToolRegistry` | Dynamic tool resolution (builtin → WASM → extension); ETS extension cache |
| `CodingAgent.ToolExecutor` | Approval-gated tool execution wrapper |
| `CodingAgent.ToolPolicy` | Tool allow/deny/approval policies; predefined profiles (`:full_access`, `:read_only`, `:safe_mode`, `:subagent_restricted`, `:no_external`, `:minimal_core`) |

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
| `CodingAgent.Workspace` | Bootstrap file loading (AGENTS.md, SOUL.md, etc.) from `~/.lemon/agent/workspace/` |
| `CodingAgent.SystemPrompt` | Builds the Lemon base system prompt (workspace files + skills) |
| `CodingAgent.PromptBuilder` | Higher-level prompt builder adding skills, commands, @mentions sections |
| `CodingAgent.ResourceLoader` | Loads CLAUDE.md/AGENTS.md from cwd up to filesystem root, then home dir |

### Extensions & WASM

| Module | Purpose |
|--------|---------|
| `CodingAgent.Extensions` | Extension loading and management |
| `CodingAgent.Extensions.Extension` | Behaviour for extensions |
| `CodingAgent.ExtensionLifecycle` | Extension lifecycle (load/reload at runtime) |
| `CodingAgent.Wasm.ToolFactory` | Build `AgentTool` structs from WASM modules |
| `CodingAgent.Wasm.SidecarSession` | Sidecar process for a WASM tool runtime |
| `CodingAgent.Wasm.SidecarSupervisor` | Supervisor for WASM sidecar sessions |
| `CodingAgent.Wasm.Policy` | WASM-specific tool approval policies |

### Concurrency & Background Work

| Module | Purpose |
|--------|---------|
| `CodingAgent.LaneQueue` | Lane-aware FIFO queue with per-lane concurrency caps |
| `CodingAgent.Coordinator` | Orchestrates concurrent subagent executions |
| `CodingAgent.ProcessManager` | DynamicSupervisor for background exec processes |
| `CodingAgent.ProcessSession` | GenServer for a single background process |
| `CodingAgent.ProcessStore` | ETS store for background process state |
| `CodingAgent.TaskStore` | ETS+DETS store for async task tool runs |
| `CodingAgent.TaskStoreServer` | Owns the TaskStore ETS/DETS tables |

`CodingAgent.Tools.Task` now emits lifecycle events (`:task_started`, `:task_completed`, `:task_error`, `:task_timeout`, `:task_aborted`) to both `LemonCore.Bus` (`run:*` topics) and `LemonCore.Introspection`, with run/parent/session/agent lineage metadata for monitoring UIs.

### Long-Running Harness Primitives

Lemon includes built-in harness primitives to support multi-step, long-lived implementation sessions:

- `CodingAgent.Tools.FeatureRequirements` persists `FEATURE_REQUIREMENTS.json` files in a workspace and reports requirement-level progress (`get_progress/1`, dependency-aware `get_next_features/1`).
- `CodingAgent.Tools.Todo` exposes higher-level progress actions (`action: "progress"`, `action: "actionable"`) on top of `TodoStore`.
- `CodingAgent.Tools.TodoStore` tracks dependency-aware todo progression and normalizes mixed key shapes (atom-key and JSON string-key todo maps).
- `CodingAgent.Checkpoint` snapshots/restores long-running session state and provides aggregate stats (`stats/1`) used by control-plane introspection.

## Tool System Architecture

### Adding a New Tool

1. **Create tool module** at `lib/coding_agent/tools/my_tool.ex`:

```elixir
defmodule CodingAgent.Tools.MyTool do
  @moduledoc "Description of what my tool does"

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias AgentCore.AbortSignal
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
      execute: fn tool_call_id, params, signal, on_update ->
        execute(tool_call_id, params, signal, on_update, cwd, opts)
      end
    }
  end

  defp execute(_tool_call_id, params, signal, _on_update, cwd, _opts) do
    if AbortSignal.aborted?(signal) do
      %AgentToolResult{content: [%TextContent{text: "Cancelled"}]}
    else
      result = do_something(params["param"], cwd)
      %AgentToolResult{
        content: [%TextContent{text: result}],
        details: %{param: params["param"]}
      }
    end
  end
end
```

2. **Register in `CodingAgent.ToolRegistry`** - Add `{:my_tool, Tools.MyTool}` to `@builtin_tools` list

3. **Register in `CodingAgent.Tools`** if it belongs in the default set - add to `coding_tools/2`, `all_tools/2`, and the module alias list

4. **Add tests** at `test/coding_agent/tools/my_tool_test.exs`

Note: `tool/2` receives `cwd` and `opts`. Capture `cwd`/`opts` in the `execute` closure rather than passing them as extra arguments to a named public function (see existing tools for the pattern).

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
# Under supervision (preferred — falls back to start_link if supervisor not running)
{:ok, session} = CodingAgent.start_session(
  cwd: "/path/to/project",
  model: Ai.Models.get_model(:anthropic, "claude-sonnet-4-20250514"),
  system_prompt: "Custom system prompt (optional)",
  prompt_template: "review",  # loads .lemon/prompts/review.md (optional)
  extra_tools: [],            # extra AgentTool structs appended to default toolset
  thinking_level: :medium     # :off | :minimal | :low | :medium | :high | :xhigh
)

# Guaranteed supervised (returns {:error, :not_started} if supervisor absent)
{:ok, session} = CodingAgent.start_supervised_session(opts)

# Direct (for tests)
{:ok, session} = CodingAgent.Session.start_link(
  cwd: "/path/to/project",
  model: model
)
```

### Session Interaction

```elixir
# Send a user prompt
:ok = CodingAgent.Session.prompt(session, "Help me fix the bug")
# Returns {:error, :already_streaming} if a prompt is already running

# Abort current operation
:ok = CodingAgent.Session.abort(session)

# Inject a mid-run steering message (interrupts after current tool finishes)
:ok = CodingAgent.Session.steer(session, "Focus on the auth module only")

# Queue a follow-up prompt (delivered after agent finishes current run)
:ok = CodingAgent.Session.follow_up(session, "Now run the tests")

# Get diagnostics
state = CodingAgent.Session.get_state(session)
stats = CodingAgent.Session.get_stats(session)
health = CodingAgent.Session.health_check(session)
report = CodingAgent.Session.get_extension_status_report(session)

# Reload extensions without restarting
:ok = CodingAgent.Session.reload_extensions(session)
```

### Session Events

```elixir
# Direct mode (default): events delivered via send/2
unsubscribe = CodingAgent.Session.subscribe(session)
receive do
  {:session_event, session_id, event} -> IO.inspect(event)
end
unsubscribe.()

# Stream mode: backpressure-aware EventStream
{:ok, stream_pid} = CodingAgent.Session.subscribe(session, mode: :stream)
stream_pid
|> AgentCore.EventStream.events()
|> Enum.each(fn {:session_event, _id, event} -> IO.inspect(event) end)
```

### Session Persistence

Sessions are persisted as JSONL files via `CodingAgent.SessionManager`:
- Format: Each line is a JSON entry
- First entry: `SessionHeader` with version, id, cwd
- Subsequent: `SessionEntry` with tree structure (id, parent_id)
- Entry types: `:message`, `:compaction`, `:branch_summary`, `:label`, etc.

Location: `~/.lemon/agent/sessions/{encoded-cwd}/{session_id}.jsonl`
(cwd is encoded with path separators replaced by `--`, e.g. `--home-user-project--`)

## Workspace Management

Bootstrap files loaded from `~/.lemon/agent/workspace/` (initialized from `priv/templates/workspace/`):

| File | Scope | Purpose |
|------|-------|---------|
| `AGENTS.md` | main + subagent | Project guidelines for AI agents |
| `SOUL.md` | main only | Agent personality/identity |
| `TOOLS.md` | main + subagent | Tool documentation |
| `IDENTITY.md` | main only | Identity configuration |
| `USER.md` | main only | User preferences |
| `HEARTBEAT.md` | main only | Health check configuration |
| `BOOTSTRAP.md` | main only | Startup instructions |
| `MEMORY.md` | main only | Persistent memory (optional, omitted if missing) |

Subagents only receive `AGENTS.md` and `TOOLS.md` from bootstrap files.

### Loading Workspace Files

```elixir
files = CodingAgent.Workspace.load_bootstrap_files(
  workspace_dir: "/path/to/workspace",
  session_scope: :main  # or :subagent
)

# Ensure workspace directory exists with template files
CodingAgent.Workspace.ensure_workspace()
```

### System Prompt Composition

The final system prompt is built in this order (later parts are appended):

1. `CodingAgent.SystemPrompt.build/2` — base Lemon prompt (workspace bootstrap + skills list)
2. Prompt template content (if `:prompt_template` option given — loaded from `.lemon/prompts/`, `.claude/prompts/`, `~/.lemon/agent/prompts/`)
3. Explicit `:system_prompt` option
4. `CodingAgent.ResourceLoader.load_instructions/1` — CLAUDE.md/AGENTS.md from cwd hierarchy

The composed prompt is refreshed before each user prompt to pick up edits to workspace/memory files.

## Budget Tracking

Budgets track token/cost resource usage per run with parent/child inheritance via `RunGraph`:

```elixir
# Create budget (inherits limits from parent if :parent_id given)
budget = CodingAgent.BudgetTracker.create_budget(
  max_tokens: 100_000,
  max_cost: 5.0,
  max_children: 10,
  parent_id: parent_run_id  # optional
)

# Record usage
CodingAgent.BudgetTracker.record_usage(run_id, tokens: 500, cost: 0.01)

# Check limits
CodingAgent.BudgetTracker.check_budget(run_id)
# Returns: :ok | {:warning, message} | {:exceeded, message}
```

`CodingAgent.BudgetEnforcer` wraps the tracker and raises on exceeded budgets during agent runs.

## Extension System

Extensions are discovered from:
- Global: `~/.lemon/agent/extensions/`
- Project: `<cwd>/.lemon/extensions/`

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
{:ok, extensions, load_errors, validation_errors} =
  CodingAgent.Extensions.load_extensions_with_errors(["/path/to/extensions"])

# Get tools and hooks
CodingAgent.Extensions.get_tools(extensions, cwd)
CodingAgent.Extensions.get_hooks(extensions)

# Prime ToolRegistry ETS cache (avoids repeated disk scans per request)
CodingAgent.ToolRegistry.prime_extension_cache(cwd, extension_paths, extensions, load_errors)
CodingAgent.ToolRegistry.invalidate_extension_cache()
```

## Compaction

When conversations grow too large, compaction summarizes older messages. Session handles this automatically via `auto_compaction` and `overflow_recovery` state machine fields.

```elixir
# Check if compaction needed
CodingAgent.Compaction.should_compact?(
  context_tokens,
  context_window,
  %{enabled: true, reserve_tokens: 16_384}
)
```

Compaction:
- Finds valid cut points (not mid-tool-call — only cuts at user/assistant/custom/bash_execution boundaries)
- Generates an LLM summary of compacted messages
- Preserves file operation context
- Overflow recovery is also attempted if context window is exhausted mid-run

Settings controlling compaction (in `SettingsManager`/`config.toml`):
- `compaction_enabled` (default: true)
- `reserve_tokens` (default: 16_384) — tokens reserved for model response
- `keep_recent_tokens` (default: 20_000) — min recent context retained after compaction

## Introspection Events

Session and EventHandler emit introspection events via `LemonCore.Introspection.record/3` for lifecycle observability. All events use `engine: "lemon"`.

### Session Events

| Event Type | When Emitted | Key Payload Fields |
|---|---|---|
| `:session_started` | `init/1` after state is built | `session_id`, `cwd`, `model`, `session_scope` |
| `:session_ended` | `terminate/2` | `session_id`, `turn_count` |
| `:compaction_triggered` | `apply_compaction_result/3` on success | `tokens_before`, `first_kept_entry_id` |

### EventHandler Events

| Event Type | When Emitted | Key Payload Fields |
|---|---|---|
| `:tool_call_dispatched` | `handle({:tool_execution_start, id, name, args})` | `tool_name`, `tool_call_id` |

## Slash Commands and @Mentions

### Slash Commands

User-defined prompts stored as markdown files with YAML frontmatter:
- Project: `.lemon/command/*.md`
- Global: `~/.lemon/agent/command/*.md`

Frontmatter fields: `description`, `model` (optional override), `subtask` (boolean).
Argument placeholders: `$1`, `$2`, ..., `$ARGUMENTS`.

```elixir
# List available commands
CodingAgent.Commands.list(cwd)
```

### @Mention Subagents

Subagents are lightweight personas invoked with `@name prompt` syntax.

Built-in subagents: `research`, `implement`, `review`, `test`.
Custom definitions: `.lemon/subagents.json` or `~/.lemon/agent/subagents.json` (JSON array of `{id, description, prompt}`).

```elixir
CodingAgent.Subagents.list(cwd)
CodingAgent.Mentions.parse("@research find auth endpoints", cwd)
# => {:ok, %{agent: "research", prompt: "find auth endpoints", ...}}
```

The `Task` tool uses `Subagents` to prepend the subagent's prompt when spawning sessions.

## Common Tasks

### Running Tests

```bash
# All tests
mix test apps/coding_agent

# Specific module
mix test apps/coding_agent/test/coding_agent/session_test.exs

# Specific test
mix test apps/coding_agent/test/coding_agent/tools/read_test.exs:123

# Include integration tests
mix test --include integration apps/coding_agent
```

### Adding a Subagent

Add an entry to `.lemon/subagents.json` or `~/.lemon/agent/subagents.json`:

```json
[{"id": "my-agent", "description": "Short description", "prompt": "System prompt prepended to task."}]
```

### Debugging a Session

```elixir
# Get session state
CodingAgent.Session.get_state(session_pid)
CodingAgent.Session.diagnostics(session_pid)

# Check run graph
CodingAgent.RunGraph.get(run_id)

# List active sessions
CodingAgent.SessionSupervisor.list_sessions()

# Health check all sessions
CodingAgent.SessionSupervisor.health_all()

# Look up session by ID
CodingAgent.lookup_session(session_id)
```

### Modifying Tool Policy

```elixir
# Using a predefined profile
policy = CodingAgent.ToolPolicy.from_profile(:safe_mode)
# Profiles: :full_access, :minimal_core, :read_only, :safe_mode, :subagent_restricted, :no_external

# Custom policy
policy = %{
  allow: :all,
  deny: [],
  require_approval: ["write", "edit", "bash"],
  approvals: %{},
  no_reply: false,
  profile: :custom
}

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
│   ├── coding_agent.ex                      # Main public API
│   ├── coding_agent/
│   │   ├── session.ex                       # Main GenServer orchestrator
│   │   ├── session/event_handler.ex         # Agent event → session state handler
│   │   ├── session_manager.ex               # JSONL persistence
│   │   ├── session_supervisor.ex            # DynamicSupervisor
│   │   ├── session_registry.ex              # Process registry
│   │   ├── session_root_supervisor.ex       # Top-level supervisor
│   │   ├── tool_executor.ex                 # Approval gating
│   │   ├── tool_registry.ex                 # Dynamic resolution + ETS extension cache
│   │   ├── tool_policy.ex                   # Policy profiles and checks
│   │   ├── tools.ex                         # Tool factory (coding_tools, read_only_tools, all_tools)
│   │   ├── tools/                           # Individual tool modules
│   │   │   ├── read.ex, write.ex, edit.ex, multiedit.ex
│   │   │   ├── patch.ex, hashline_edit.ex, hashline.ex
│   │   │   ├── bash.ex, exec.ex, process.ex, await.ex
│   │   │   ├── grep.ex, find.ex, ls.ex, fuzzy.ex
│   │   │   ├── browser.ex, webfetch.ex, websearch.ex, webdownload.ex
│   │   │   ├── web_cache.ex, web_guard.ex
│   │   │   ├── todo.ex, todoread.ex, todowrite.ex
│   │   │   ├── todo_store.ex, todo_store_owner.ex
│   │   │   ├── task.ex, agent.ex
│   │   │   ├── tool_auth.ex, extensions_status.ex
│   │   │   ├── memory_topic.ex, truncate.ex
│   │   │   ├── post_to_x.ex, get_x_mentions.ex
│   │   │   ├── lsp_formatter.ex, restart.ex
│   │   ├── budget_tracker.ex, budget_enforcer.ex
│   │   ├── run_graph.ex, run_graph_server.ex
│   │   ├── compaction.ex, compaction_hooks.ex
│   │   ├── extensions.ex
│   │   ├── extensions/extension.ex           # Behaviour
│   │   ├── extension_lifecycle.ex
│   │   ├── wasm/                             # WASM tool runtime
│   │   │   ├── builder.ex, config.ex, policy.ex
│   │   │   ├── protocol.ex, tool_factory.ex
│   │   │   ├── sidecar_session.ex, sidecar_supervisor.ex
│   │   ├── security/
│   │   │   ├── external_content.ex
│   │   │   └── untrusted_tool_boundary.ex
│   │   ├── workspace.ex                      # Bootstrap file loading
│   │   ├── system_prompt.ex                  # Lemon base system prompt builder
│   │   ├── prompt_builder.ex                 # Higher-level prompt builder
│   │   ├── resource_loader.ex                # CLAUDE.md/AGENTS.md hierarchy loader
│   │   ├── settings_manager.ex               # TOML config adapter
│   │   ├── config.ex                         # Path/env configuration
│   │   ├── subagents.ex, mentions.ex         # Subagent definitions and @mention parsing
│   │   ├── commands.ex                       # Slash command loading
│   │   ├── coordinator.ex                    # Concurrent subagent orchestration
│   │   ├── lane_queue.ex                     # Concurrency-capped lane queue
│   │   ├── process_manager.ex                # DynamicSupervisor for background processes
│   │   ├── process_session.ex, process_store.ex, process_store_server.ex
│   │   ├── task_store.ex, task_store_server.ex
│   │   ├── bash_executor.ex                  # Streaming shell execution
│   │   ├── messages.ex                       # Message types and LLM conversion
│   │   ├── ui.ex                             # Pluggable UI abstraction
│   │   ├── ui/                               # UI context helpers
│   │   ├── cli_runners/                      # CLI runner integrations
│   │   └── evals/harness.ex                  # Eval harness
│   └── mix/tasks/                            # Mix tasks
├── test/
│   ├── coding_agent/
│   │   ├── *_test.exs
│   │   └── tools/*_test.exs
│   └── support/
└── priv/templates/workspace/                 # Default workspace bootstrap templates
```

## Key Types

```elixir
# AgentTool from AgentCore — the core tool contract
%AgentCore.Types.AgentTool{
  name: "tool_name",          # used in LLM tool call
  description: "What it does",
  label: "Display Label",     # human-readable (UI)
  parameters: %{"type" => "object", "properties" => %{...}, "required" => [...]},
  execute: fn tool_call_id, params, signal, on_update -> result end
}

# AgentToolResult — returned by execute/4
%AgentCore.Types.AgentToolResult{
  content: [%Ai.Types.TextContent{text: "result"}],
  details: %{}   # structured metadata shown in UI (optional)
}

# SessionEntry — one node in the JSONL session tree
%CodingAgent.SessionManager.SessionEntry{
  id: "entry_id",
  parent_id: "parent_id" | nil,
  type: :message | :compaction | :branch_summary | :label,
  # ... type-specific fields
}

# SettingsManager — loaded from ~/.lemon/config.toml and <cwd>/.lemon/config.toml
%CodingAgent.SettingsManager{
  default_model: %{provider: "anthropic", model_id: "...", base_url: nil},
  default_thinking_level: :medium,
  compaction_enabled: true,
  reserve_tokens: 16_384,
  keep_recent_tokens: 20_000,
  shell_path: nil,
  extension_paths: []
  # ... more fields
}
```

## Settings and Configuration

Settings are loaded from TOML via `LemonCore.Config` and merged (global → project):

- Global: `~/.lemon/config.toml`
- Project: `<cwd>/.lemon/config.toml`

```elixir
settings = CodingAgent.load_settings(cwd)
# or directly:
settings = CodingAgent.SettingsManager.load(cwd)
```

Key config paths (via `CodingAgent.Config`):

| Function | Path |
|----------|------|
| `agent_dir/0` | `~/.lemon/agent` (override: `LEMON_AGENT_DIR`) |
| `sessions_dir/1` | `~/.lemon/agent/sessions/{encoded-cwd}/` |
| `extensions_dir/0` | `~/.lemon/agent/extensions/` |
| `workspace_dir/0` | `~/.lemon/agent/workspace/` |
| `project_extensions_dir/1` | `<cwd>/.lemon/extensions/` |

## Testing Guidelines

- Use `CodingAgent.Session.start_link/1` directly in tests (not supervised)
- Mock UI with `CodingAgent.UI.Context` test helpers
- Use temporary directories for file operations (clean up in `on_exit`)
- Clean up sessions with `Process.exit(session, :normal)`
- For tool tests: assert on both `content` and `details` in results
- Use `async: false` for tests that modify global state (extensions, ETS tables, ProcessManager)
- `await` and `exec`/`process` tools depend on `ProcessStore` being started; start `ProcessStoreServer` in test setup if needed
- `ToolRegistry` uses an ETS cache for extensions; call `ToolRegistry.invalidate_extension_cache()` in teardown if tests prime the cache
