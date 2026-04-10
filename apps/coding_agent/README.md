# CodingAgent

A full-featured AI coding agent runtime built on top of `AgentCore`. This OTP application provides session management, 30+ tools, JSONL persistence with branching, budget tracking, context compaction, WASM tool support, extensions, and subagent orchestration for building interactive coding workflows.

## Overview

CodingAgent is an umbrella app within the Lemon AI assistant platform. It turns the lower-level `AgentCore` event loop into a complete coding assistant by adding:

- **Session lifecycle management** -- GenServer sessions with persistence, branching, steering, and follow-up queues
- **Tool execution pipeline** -- Registry with precedence resolution (builtin > WASM > extension), approval gating, and policy profiles
- **Context compaction** -- Automatic summarization when conversations exceed the model's context window, with overflow recovery
- **Budget enforcement** -- Token and cost tracking per run with parent/child inheritance via a persistent run graph
- **Extension system** -- Dynamic tool and hook injection from Elixir modules or WASM sidecars
- **Subagent orchestration** -- Concurrent subagent sessions via a Coordinator with timeout management
- **Workspace and prompt composition** -- Layered system prompt from bootstrap files, skills, commands, @mentions, and project-local CLAUDE.md/AGENTS.md

## Architecture

```
                          User / Frontend
                               |
                               v
                      +------------------+
                      |   CodingAgent    |   Public API: start_session, coding_tools, load_settings
                      +--------+---------+
                               |
                 +-------------+-------------+
                 |                           |
                 v                           v
      +-------------------+       +--------------------+
      | Session (GenServer)|       | SessionSupervisor  |
      | - agent loop       |       | (DynamicSupervisor)|
      | - events           |       +--------------------+
      | - steering queue   |
      | - follow-up queue  |
      +---------+----------+
                |
    +-----------+-----------+------------------+
    |           |           |                  |
    v           v           v                  v
+--------+ +----------+ +-----------+  +-------------+
| Tools  | | Session  | | Compaction|  | Budget      |
| (30+)  | | Manager  | | Manager   |  | Tracker     |
+--------+ | (JSONL)  | +-----------+  +------+------+
           +----------+                       |
                                              v
                                        +----------+
                                        | RunGraph |
                                        | (ETS+DETS)|
                                        +----------+
```

### Supervision Tree

```
CodingAgent.Supervisor (one_for_one)
  +-- Registry (SessionRegistry)
  +-- Registry (ProcessRegistry)
  +-- TodoStoreOwner
  +-- SessionSupervisor (DynamicSupervisor for Session processes)
  +-- Wasm.SidecarSupervisor
  +-- TaskSupervisor (Task.Supervisor for async ops)
  +-- TaskStoreServer (DETS-backed async task tracking)
  +-- ParentQuestionStoreServer (DETS-backed child-to-parent question tracking)
  +-- RunGraphServer (ETS+DETS persistent run graph)
  +-- ProcessStoreServer (background process state)
  +-- ProcessManager (DynamicSupervisor for exec processes)
  +-- LaneQueue (concurrency-capped lane FIFO)
  +-- Parallel.Semaphore (task concurrency limit)
  +-- CompactionHooks
```

## Module Inventory

### Public API

| Module | Description |
|--------|-------------|
| `CodingAgent` | Top-level facade -- `start_session/1`, `start_supervised_session/1`, `lookup_session/1`, `coding_tools/2`, `read_only_tools/2`, `load_settings/1` |
| `CodingAgent.Application` | OTP application callback; starts the full supervision tree and optionally a primary session |
| `CodingAgent.ParentQuestions` | DETS-backed store and lifecycle helpers for child-to-parent clarification requests |
| `CodingAgent.ParentQuestionStoreServer` | Owns the parent-question ETS/DETS tables and TTL cleanup |

### Session Management

| Module | Description |
|--------|-------------|
| `CodingAgent.Session` | Main GenServer orchestrating the agent loop, event dispatch, steering, follow-ups, compaction, and persistence |
| `CodingAgent.Session.EventHandler` | Translates `AgentCore` events into session state updates, triggers compaction, and fires extension hooks |
| `CodingAgent.Session.CompactionManager` | Auto-compaction scheduling, overflow recovery state machine, and compaction result application |
| `CodingAgent.Session.MessageSerialization` | Serializes/deserializes messages between session and agent core formats |
| `CodingAgent.Session.ModelResolver` | Resolves model structs from string specs, maps, or settings; handles API key lookup via env vars and secrets with OAuth refresh |
| `CodingAgent.Session.PromptComposer` | Composes the final system prompt by layering base prompt, prompt templates, explicit system prompt, and resource loader instructions |
| `CodingAgent.Session.WasmBridge` | Bridges WASM sidecar tools into the session tool set |
| `CodingAgent.SessionManager` | JSONL persistence engine with tree-structured entries (branching, compaction, labels), atomic writes, append-only incremental saves, and version migrations (v1-v3) |
| `CodingAgent.SessionSupervisor` | DynamicSupervisor for session processes with health check and list capabilities |
| `CodingAgent.SessionRegistry` | Registry wrapper for session lookup by ID |
| `CodingAgent.SessionRootSupervisor` | Top-level supervisor for all session infrastructure (currently delegated into `Application`) |

### Tool System

| Module | Description |
|--------|-------------|
| `CodingAgent.Tools` | Tool factory -- `coding_tools/2` (19 default tools), `read_only_tools/2`, `all_tools/2`, `get_tool/3` |
| `CodingAgent.ToolRegistry` | Dynamic tool resolution with precedence (builtin > WASM > extension), ETS extension cache, conflict reporting |
| `CodingAgent.ToolExecutor` | Approval-gated tool execution wrapper; integrates with `LemonCore.ExecApprovals` |
| `CodingAgent.ToolPolicy` | Policy profiles (`full_access`, `read_only`, `safe_mode`, `subagent_restricted`, `no_external`, `minimal_core`) with allow/deny lists and router-style approval maps |

### Built-in Tools

**Default set (coding_tools/2):**

| Category | Tools |
|----------|-------|
| File I/O | `read`, `write`, `edit`, `hashline_edit`, `patch`, `ls` |
| Search | `grep`, `find` |
| Execution | `bash` |
| Web | `websearch`, `webfetch` |
| Task / Agent | `task`, `agent`, `parent_question`, `todo` |
| Social | `post_to_x`, `get_x_mentions` |
| System | `tool_auth`, `extensions_status` |

**Additional tools (not in default set):**

| Tool | Module | Notes |
|------|--------|-------|
| `multiedit` | `Tools.MultiEdit` | Multiple sequential edits to one file |
| `exec` | `Tools.Exec` | Long-running background processes with poll/kill |
| `process` | `Tools.Process` | Control interface for `exec` processes |
| `await` | `Tools.Await` | Block until background jobs complete |
| `webdownload` | `Tools.WebDownload` | Download binary content to disk |
| `truncate` | `Tools.Truncate` | Truncate long text with configurable strategies |
| `todoread` / `todowrite` | `Tools.TodoRead` / `Tools.TodoWrite` | Low-level todo primitives |
| `restart` | `Tools.Restart` | Restart the Lemon BEAM process (dev) |
| `memory_topic` | `Tools.MemoryTopic` | Persistent memory topics for cross-session knowledge |
| `glob` | `Tools.Glob` | File pattern matching |
| `lsp_formatter` | `Tools.LspFormatter` | Format code via LSP |
| `ask_parent` | `Tools.AskParent` | Child-only extra tool injected into eligible task-spawned sessions |

**Internal helpers (not exposed as tools):** `Tools.Fuzzy`, `Tools.Hashline`, `Tools.WebCache`, `Tools.WebGuard`, `Tools.TodoStore`, `Tools.TodoStoreOwner`.

Pure text-only external `codex`/`claude` tasks with no explicit `cwd` and no role may skip the CLI entirely and call the provider directly instead. Tasks that explicitly ask to use tools such as `bash`, `read`, or `grep` stay on the normal runner path so they cannot silently bypass tool execution. Internal task runs also infer a restrictive `tool_policy` and verification guardrail when the prompt says `use ... tools only`, so tool-constrained subtasks have to verify against tool output instead of guessing. The fast path also keeps compatible model hints such as `haiku`, `sonnet`, and direct provider model specs off the slow CLI startup path. For internal bash-only tasks, the fast path now accepts both backticked commands and plain phrasings like `Run this exact command and return the output: ...`, which keeps provider-generated shell subtasks off the slower child-session path.

### Budget and Resource Management

| Module | Description |
|--------|-------------|
| `CodingAgent.BudgetTracker` | Token/cost budget tracking per run with parent/child inheritance |
| `CodingAgent.BudgetEnforcer` | Raises on exceeded budgets during agent runs |
| `CodingAgent.ParentQuestions` | ETS+DETS-backed child-to-parent clarification request store with lifecycle events |
| `CodingAgent.RunGraph` | ETS-backed parent/child run graph with monotonic state machine (`queued -> running -> completed/error/killed/cancelled/lost`); await via PubSub |
| `CodingAgent.RunGraphServer` | GenServer owning the RunGraph ETS table with DETS persistence, atomic transitions, and TTL-based cleanup |

### Memory and Context

| Module | Description |
|--------|-------------|
| `CodingAgent.Compaction` | Context compaction engine -- finds valid cut points, generates LLM summaries, preserves file context |
| `CodingAgent.CompactionHooks` | Hooks for compaction lifecycle events |
| `CodingAgent.Workspace` | Loads bootstrap files (AGENTS.md, SOUL.md, TOOLS.md, IDENTITY.md, USER.md, HEARTBEAT.md, BOOTSTRAP.md, MEMORY.md) from the assistant home at `~/.lemon/agent/workspace/` |
| `CodingAgent.SystemPrompt` | Builds the Lemon base system prompt (assistant-home bootstrap files + skills list + memory workflow + runtime metadata) |
| `CodingAgent.PromptBuilder` | Higher-level prompt builder adding skills, commands, @mention sections |
| `CodingAgent.ResourceLoader` | Loads CLAUDE.md/AGENTS.md from cwd hierarchy up to root, then home directory; also loads prompts, themes, and skills |

### Extensions and WASM

| Module | Description |
|--------|-------------|
| `CodingAgent.Extensions` | Extension loading, validation, tool/hook extraction from `~/.lemon/agent/extensions/` and `<cwd>/.lemon/extensions/` |
| `CodingAgent.Extensions.Extension` | Behaviour defining `name/0`, `version/0`, `tools/1`, `hooks/0`, `capabilities/0`, `config_schema/0`, `providers/0` |
| `CodingAgent.ExtensionLifecycle` | Runtime extension load/reload without session restart |
| `CodingAgent.Wasm.ToolFactory` | Builds `AgentTool` structs from WASM modules |
| `CodingAgent.Wasm.SidecarSession` | GenServer managing a single WASM sidecar process |
| `CodingAgent.Wasm.SidecarSupervisor` | Supervisor for WASM sidecar sessions |
| `CodingAgent.Wasm.Policy` | WASM-specific tool approval policies |
| `CodingAgent.Wasm.Builder` | WASM module compilation and loading |
| `CodingAgent.Wasm.Config` | WASM configuration and discovery |
| `CodingAgent.Wasm.Protocol` | Wire protocol for WASM tool communication |

### Concurrency and Background Work

| Module | Description |
|--------|-------------|
| `CodingAgent.LaneQueue` | Lane-aware FIFO queue with per-lane concurrency caps (default: main=4, subagent=8, background_exec=2) |
| `CodingAgent.Coordinator` | GenServer orchestrating concurrent subagent sessions with timeout management |
| `CodingAgent.Parallel` | Semaphore-based concurrency control and `map_with_concurrency_limit` |
| `CodingAgent.ProcessManager` | DynamicSupervisor for background `exec` processes |
| `CodingAgent.ProcessSession` | GenServer for a single background process |
| `CodingAgent.ProcessStore` / `ProcessStoreServer` | ETS store for background process state |
| `CodingAgent.TaskStore` / `TaskStoreServer` | ETS+DETS store for async task tool runs |
| `CodingAgent.ParentQuestions` / `ParentQuestionStoreServer` | ETS+DETS store for child-to-parent clarification requests |

The task tool defaults omitted `async` to `true`. For external engines, pure text/reasoning tasks without an explicit `cwd` are routed into a per-task scratch workspace so Codex/Claude do not spend startup time loading unrelated repo context. Pure text Codex/Claude tasks with no explicit `cwd`, role, or model override also take a direct-provider fast path instead of spawning the CLI, which removes most of the latency for simple conversational subtasks while keeping coding/workspace-aware and tool-requiring tasks on the normal external-runner path.
When a provider omits the task `description` field but sends a valid `prompt`, Lemon now derives a short description from that prompt instead of rejecting the task call outright.
When an internal task omits `model`, the child session now inherits the live parent session model at execution time instead of relying only on the captured tool opts, so Telegram/session-scoped model overrides also apply to async subtasks.
Internal task child sessions also have a bounded wait for terminal session events. If a child provider stream wedges or the child session exits without emitting `agent_end` / `error`, the task returns a timeout or session-exit error instead of leaving `join` blocked forever.

For coordination workflows that must produce one final same-turn answer, queued task results should be treated as launch receipts, not completion. Keep the returned `task_id`s and call `action=join` before responding; auto-followup is for later delivery, not guaranteed same-turn aggregation. `action=join` now suppresses the later async auto-followup for those task ids so the parent session does not get a redundant completion prompt after it already waited. Task result surfaces (`poll`, `join`, `get`, and async auto-followup) expose only visible assistant output plus task metadata, not stored event streams, tool-call internals, or thinking deltas. When `:coding_agent, :async_followups` is set to `:steer_backlog`, live streaming parent sessions now attempt an in-session steer first before falling back to router backlog semantics.

### Subagents and Commands

| Module | Description |
|--------|-------------|
| `CodingAgent.Subagents` | Subagent definition loading (built-in: `research`, `implement`, `review`, `test`; custom: `.lemon/subagents.json`) |
| `CodingAgent.Mentions` | `@name prompt` parsing for subagent invocation |
| `CodingAgent.Commands` | Slash command discovery from `.lemon/command/*.md` and `~/.lemon/agent/command/*.md` with YAML frontmatter |

### Harness and Checkpointing

| Module | Description |
|--------|-------------|
| `CodingAgent.Checkpoint` | Snapshot/restore for long-running sessions with aggregate stats |
| `CodingAgent.Tools.FeatureRequirements` | Persists `FEATURE_REQUIREMENTS.json` with dependency-aware progress tracking |
| `CodingAgent.Evals.Harness` | Evaluation harness for automated agent testing |

### Security

| Module | Description |
|--------|-------------|
| `CodingAgent.Security.ExternalContent` | External content sanitization |
| `CodingAgent.Security.UntrustedToolBoundary` | Pre-LLM boundary for untrusted tool output; composed with `ContextGuardrails` |

### Utilities

| Module | Description |
|--------|-------------|
| `CodingAgent.UI` | Pluggable UI abstraction (notify, working messages, approval requests) |
| `CodingAgent.UI.Context` | UI context helpers and test support |
| `CodingAgent.Messages` | Message type definitions and LLM format conversion |
| `CodingAgent.BashExecutor` | Streaming shell command execution |
| `CodingAgent.InternalUrls` | Internal URL protocol handling |
| `CodingAgent.InternalUrls.NotesProtocol` | `notes://` protocol handler |
| `CodingAgent.Progress` | Progress reporting utilities |
| `CodingAgent.Utils.Http` | HTTP utility functions |
| `CodingAgent.Project.Codexignore` | `.codexignore` file parsing |

### Mix Tasks

| Task | Description |
|------|-------------|
| `Mix.Tasks.Lemon.Eval` | Run eval harness from the command line |
| `Mix.Tasks.Lemon.Workspace` | Manage workspace bootstrap files |

### CLI Runners

| Module | Description |
|--------|-------------|
| `CodingAgent.CliRunners.LemonRunner` | CLI runner for Lemon sessions |
| `CodingAgent.CliRunners.LemonSubagent` | CLI runner for Lemon subagent sessions |

## Key Concepts

### Sessions

A session is a `GenServer` process that wraps an `AgentCore.Agent` loop. Each session has:

- A working directory (`cwd`)
- A model configuration
- A set of tools (default: `coding_tools/2`)
- JSONL persistence with tree-structured entries
- Event subscription (direct send or backpressure-aware streams)
- Steering (mid-run interrupts) and follow-up (post-run) queues
- Auto-compaction and overflow recovery

Sessions are started under `SessionSupervisor` (dynamic) and registered in `SessionRegistry` by their UUID.

### Tool Execution

Tools follow a pipeline: the LLM requests a tool call, `ToolRegistry` resolves it by name (checking builtin, then WASM, then extensions), `ToolPolicy` checks allow/deny, `ToolExecutor` gates on approval if required, and the tool module's `execute/4` closure runs with abort signal support.

Each tool module exposes `tool(cwd, opts)` returning an `%AgentCore.Types.AgentTool{}` struct whose `execute` field is a 4-arity closure capturing `cwd` and `opts`.

### Model Resolution

`Session.ModelResolver` resolves models from string specs (`"provider:model_id"`), maps, or `%Ai.Types.Model{}` structs. API keys are resolved in order:
1. Provider environment variables (`ANTHROPIC_API_KEY`, etc.)
2. Plain `providers.<name>.api_key` in settings
3. `providers.<name>.api_key_secret` via `LemonCore.Secrets`
4. Default secret name `llm_<provider>_api_key`

OAuth payloads are handled by `LemonAiRuntime.Auth.OAuthSecretResolver` with automatic refresh.

### Compaction

When conversations grow large, auto-compaction kicks in:
1. The system estimates context size (messages + system prompt + tool schemas)
2. If over threshold, it finds valid cut points (not mid-tool-call)
3. An LLM summary of compacted messages is generated
4. A compaction entry is appended to the session tree
5. Overflow recovery handles cases where the context window is exhausted mid-run

Settings: `compaction_enabled` (default: true), `reserve_tokens` (default: 16,384), `keep_recent_tokens` (default: 20,000).

### Budget Tracking

Budgets track token and cost usage per run. The `RunGraph` maintains parent/child relationships with DETS persistence. Budgets cascade: subagents inherit (and can further restrict) parent limits. The state machine enforces monotonic transitions (`queued -> running -> completed|error|killed|cancelled|lost`).

### Extensions

Extensions provide additional tools and lifecycle hooks. They are discovered from `~/.lemon/agent/extensions/` (global) and `<cwd>/.lemon/extensions/` (project). Each extension implements the `CodingAgent.Extensions.Extension` behaviour. WASM extensions run as sidecar processes.

## Configuration

### Settings Files

Settings are loaded from TOML files and merged (global, then project):
- Global: `~/.lemon/config.toml`
- Project: `<cwd>/.lemon/config.toml`

### Key Paths (via `CodingAgent.Config`)

| Function | Default Path | Env Override |
|----------|-------------|-------------|
| `agent_dir/0` | `~/.lemon/agent` | `LEMON_AGENT_DIR` |
| `sessions_dir/1` | `~/.lemon/agent/sessions/{encoded-cwd}/` | -- |
| `extensions_dir/0` | `~/.lemon/agent/extensions/` | -- |
| `workspace_dir/0` | `~/.lemon/agent/workspace/` | -- |
| `project_extensions_dir/1` | `<cwd>/.lemon/extensions/` | -- |

### Application Environment

| Key | Default | Description |
|-----|---------|-------------|
| `:lane_caps` | `%{main: 4, subagent: 8, background_exec: 2}` | Per-lane concurrency caps for `LaneQueue` |
| `:task_max_concurrency` | `Parallel.default_max_concurrency()` | Max concurrent tasks for `Parallel.Semaphore` |
| `:primary_session` | `nil` | Keyword list of opts to auto-start a session on boot |

### Workspace Bootstrap Files

`workspace_dir/0` is the assistant home bootstrap directory, not the active project root.
The active project boundary remains `cwd`.

Loaded from `~/.lemon/agent/workspace/` (initialized from `priv/templates/workspace/`):

| File | Scope | Purpose |
|------|-------|---------|
| `AGENTS.md` | main + subagent | Project guidelines for AI agents |
| `SOUL.md` | main only | Agent personality/identity |
| `TOOLS.md` | main + subagent | Tool documentation |
| `IDENTITY.md` | main only | Identity configuration |
| `USER.md` | main only | User preferences |
| `HEARTBEAT.md` | main only | Health check configuration |
| `BOOTSTRAP.md` | main only | Startup instructions |
| `MEMORY.md` | main only | Persistent memory (optional) |

## Usage Examples

### Starting a Session

```elixir
# Under supervision (preferred)
{:ok, session} = CodingAgent.start_session(
  cwd: "/path/to/project",
  model: Ai.Models.get_model(:anthropic, "claude-sonnet-4-20250514"),
  thinking_level: :medium
)

# Direct (for tests)
{:ok, session} = CodingAgent.Session.start_link(
  cwd: "/path/to/project",
  model: model
)
```

### Interacting with a Session

```elixir
# Send a prompt
:ok = CodingAgent.Session.prompt(session, "Fix the failing test")

# Steer mid-run
:ok = CodingAgent.Session.steer(session, "Focus on auth module only")

# Queue a follow-up
:ok = CodingAgent.Session.follow_up(session, "Now run the tests")

# Abort current operation
:ok = CodingAgent.Session.abort(session)
```

### Subscribing to Events

```elixir
# Direct mode (default)
unsubscribe = CodingAgent.Session.subscribe(session)
receive do
  {:session_event, session_id, event} -> IO.inspect(event)
end
unsubscribe.()

# Stream mode (backpressure-aware)
{:ok, stream_pid} = CodingAgent.Session.subscribe(session, mode: :stream)
```

### Using Tool Policies

```elixir
# Predefined profile
policy = CodingAgent.ToolPolicy.from_profile(:safe_mode)

# Custom policy
policy = CodingAgent.ToolPolicy.custom(
  allow: :all,
  deny: ["bash", "exec"],
  require_approval: ["write", "edit"]
)

{:ok, session} = CodingAgent.start_session(
  cwd: cwd,
  model: model,
  tool_policy: policy
)
```

### Running Subagents

```elixir
{:ok, coordinator} = CodingAgent.Coordinator.start_link(
  cwd: "/path/to/project",
  model: model
)

results = CodingAgent.Coordinator.run_subagents(coordinator, [
  %{prompt: "Analyze the code", subagent: "research"},
  %{prompt: "Review for bugs", subagent: "review"}
], timeout: 60_000)
```

## Dependencies

### Umbrella Dependencies

| App | Purpose |
|-----|---------|
| `agent_core` | Core agent runtime, types (`AgentTool`, `AgentToolResult`), event loop, abort signals |
| `ai` | AI model providers, LLM integration, message types, OAuth resolution |
| `lemon_skills` | Skill discovery, loading, and relevance matching |
| `lemon_core` | Shared primitives -- sessions, storage, bus (PubSub), exec approvals, secrets, config, telemetry, introspection |

### External Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| `jason` | ~> 1.4 | JSON encoding/decoding for JSONL persistence |
| `req` | ~> 0.5 | HTTP client for web tools |
| `readability` | ~> 0.12 | HTML content extraction for `webfetch` |
| `uuid` | ~> 1.1 | UUID generation for session IDs |

## Testing

```bash
# All tests
mix test apps/coding_agent

# Specific module
mix test apps/coding_agent/test/coding_agent/session_manager_test.exs

# Specific test by line number
mix test apps/coding_agent/test/coding_agent/tools/read_test.exs:46

# Include integration tests
mix test --include integration apps/coding_agent
```

The test suite covers 90+ test files including unit tests for all tools, session management, budget tracking, extensions, WASM integration, and coordinator orchestration. Tests use temporary directories, direct `start_link` (not supervised), and mock UIs via `CodingAgent.UI.Context`.
