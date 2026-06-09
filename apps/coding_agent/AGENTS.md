# CodingAgent App Guide

The main coding agent implementation for the Lemon AI assistant platform. This app provides a complete AI coding agent with 40+ tools, session management, budget tracking, extensions, WASM tool support, and context compaction.

## Dependencies

- `agent_core` - Core agent runtime, types, and event loop
- `ai` - AI model providers and LLM integration
- `lemon_core` - Shared primitives (sessions, storage, bus, exec approvals)
- `lemon_skills` - Skill discovery and loading

## Architecture Overview

```
+-----------------------------------------------------------------------------+
|                           CodingAgent.Session                                |
|  (Main GenServer - orchestrates agent loop, events, steering, follow-ups)   |
+--------------------+--------------------------------------------------------+
                     |
    +----------------+----------------+---------------+----------------+
    |                |                |               |                |
    v                v                v               v                v
+---------+   +------------+  +------------+  +------------+  +--------------+
| Session |   |  Settings  |  |   Tools    |  | Workspace  |  |   Prompt     |
| Manager |   |   Manager  |  |  (30+)     |  |  (bootstrap|  |   Builder    |
| (JSONL) |   |  (TOML)    |  |            |  |   files)   |  |              |
+---------+   +------------+  +------------+  +------------+  +--------------+

+-----------------------------------------------------------------------------+
|                        Session Supervision Tree                              |
+-----------------------------------------------------------------------------+
|  CodingAgent.SessionRootSupervisor (permanent)                               |
|  +-- CodingAgent.SessionSupervisor (dynamic, one_for_one)                   |
|  |   +-- CodingAgent.Session processes (temporary restart)                  |
|  +-- CodingAgent.SessionRegistry (via Registry)                             |
|  +-- CodingAgent.RunGraphServer (ETS + DETS persistence)                    |
|  +-- CodingAgent.TaskSupervisor (for async operations)                      |
|  +-- CodingAgent.ProcessStoreServer (background process tracking)           |
|  +-- CodingAgent.TaskStoreServer (async task tracking with DETS)            |
|  +-- CodingAgent.ParentQuestionStoreServer (parent-question tracking)       |
|  +-- CodingAgent.LaneQueue (concurrency-capped subagent/background lanes)  |
+-----------------------------------------------------------------------------+
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

Session lifecycle calls to `save/1` and auto-compaction state reads are treated as best-effort.
When downstream store or agent processes time out, callers should log and continue instead of crashing the session/runner process.

### Tools

Tools are divided into two sets. `coding_tools/2` is the default set passed to sessions; `all_tools/2` includes extras not in the default set.

**Default `coding_tools/2`** (55 tools registered in `CodingAgent.Tools.coding_tools/2` and `@builtin_tools` in `ToolRegistry`):

| Category | Tools |
|----------|-------|
| **File Operations / Skills** | `read`, `read_skill`, `skill_manage`, `memory_topic`, `memory`, `search_memory`, `session_search`, `checkpoint`, `write`, `edit`, `patch`, `hashline_edit`, `lsp_diagnostics`, `ls` |
| **Search** | `grep`, `find` |
| **Execution** | `bash` |
| **Web / Browser / Media** | `websearch`, `webfetch`, `browser_navigate`, `browser_snapshot`, `browser_get_content`, `browser_click`, `browser_type`, `browser_hover`, `browser_select_option`, `browser_upload_file`, `browser_download`, `browser_press`, `browser_scroll`, `browser_back`, `browser_wait_for_selector`, `browser_evaluate`, `browser_events`, `browser_get_cookies`, `browser_set_cookies`, `browser_clear_state`, `browser_screenshot`, `browser_analyze`, `media_status`, `media_generate_image`, `media_generate_speech`, `media_transcribe_audio`, `media_analyze_image`, `media_generate_video` |
| **Task/Agent** | `task`, `agent`, `parent_question`, `todo`, `kanban` |
| **Social** | `x_search`, `post_to_x`, `get_x_mentions` |
| **System** | `tool_auth`, `extensions_status` |

`browser_screenshot` writes screenshot bytes to local artifacts by default
instead of returning base64 to the model. Pass `includeImage: true` only when a
run needs model-visible screenshot content; the tool still keeps raw base64 out
of result details. Pass `sendToChannel: true` only when the screenshot should be
attached to the final Telegram/Discord answer through redacted `auto_send_files`
metadata. Screenshot writes prune the browser artifact directory to 14 days or
the newest 100 files.

`browser_analyze` composes the supervised browser screenshot path with
`media_analyze_image` so models can capture and analyze the current page in one
BEAM-owned operation. It stores the screenshot and analysis as managed artifacts,
keeps raw base64 out of details, and can optionally return the screenshot as
model-visible image content.

`browser_navigate` classifies targets on the BEAM side before worker dispatch.
The default `route: "auto"` preserves local-first use while reporting public,
private, or local-document target kind; `route: "public"` rejects local/private
targets, `route: "local"` rejects public web targets, and metadata endpoints
are always blocked before the browser worker.

`browser_get_cookies`, `browser_set_cookies`, and `browser_clear_state` expose
session-state controls over the supervised browser boundary. Cookie values are
redacted by default unless `includeValues: true` is explicit. `browser_clear_state`
clears browser-context cookies, current-page local/session storage, and buffered
events by default; pass the specific `clear*` flags to narrow the reset.

`memory` is the compact prompt-injected memory surface. It reads, adds,
replaces, and removes bounded assistant-home `USER.md` profile notes and
`MEMORY.md` quick facts without relying on project-local file paths. It rejects
duplicates, requires unique text for replace/remove, enforces compact file
limits, and screens writes for common secrets, prompt-injection phrases, NUL
bytes, and invisible/bidirectional controls. Use `memory_topic` for longer
structured notes under `memory/topics/`.

`session_search` is the Hermes-compatible no-LLM recall tool. It infers
discovery, scroll, or browse mode from the argument shape and reads from Lemon's
durable memory/run-history stores; `search_memory` remains the native scoped
memory tool.

`media_status` gives the model a read-only view of redacted media job summaries,
recent jobs, cleanup policy, and worker supervisor state. `media_generate_image`,
`media_generate_speech`, and `media_transcribe_audio` are model-facing media
previews. They run deterministic local preview jobs, provider-backed OpenAI
image/TTS/STT jobs, Vertex Imagen image jobs, ElevenLabs TTS, Google TTS, and
Deepgram STT, plus provider-backed OpenAI video and Vertex Veo jobs through
`LemonCore.MediaJobSupervisor`, store redacted
`LemonCore.MediaJobs` metadata with prompt/input hash/chars and artifact
metadata, and can opt into final Telegram/Discord generated-file delivery with
`sendToChannel: true`. Provider media jobs retry bounded transient provider
failures with `maxRetries`; failed provider jobs record only a safe error kind
plus structured provider status/type when present, never raw provider messages.
Completed live generated-media channel proof remains outside the stable surface.

`write`, `edit`, and `patch` create filesystem checkpoints automatically when
the tool context includes a session id. The `checkpoint` tool lists, diffs,
restores, and deletes those checkpoints through `LemonCore.Checkpoint`.
Checkpoint create/restore/delete events are recorded through
`LemonCore.Introspection` and broadcast on run/session bus topics for audit and
live status surfaces. `CodingAgent.Checkpoint` only adds coding-agent todo and
requirement state for resume flows.
`exec` can snapshot configured file paths before destructive shell commands:
pass `checkpoint_paths` and a session id, and commands such as `rm`, `mv`,
`sed -i`, `find ... -delete`, `git reset`, or `git clean` will create a
filesystem checkpoint before backend launch.

`lsp_diagnostics` is the model-facing diagnostics tool. It runs workspace-aware
file diagnostics with graceful fallback when a checker is unavailable, and
`write`, `edit`, and `patch` can opt into post-edit baseline/delta diagnostics.
Operator status is exposed without paths, file contents, workspace roots, or
diagnostic output through `lsp.diagnostics.status` and support bundle
`lsp_diagnostics.json`. `LemonCore.LspServerManager` owns redacted
language-server registry, stdio session lifecycle status, initialize
orchestration, document open/change/close notifications, JSON-RPC request
framing, and diagnostic notification counters.

`kanban` is the model-facing durable board tool. It creates/lists boards,
creates/lists/updates/comments tasks, and reads from `LemonCore.KanbanStore` so
multi-agent work can outlive one session. Kanban-dispatched worker runs block
the `kanban` tool through tool policy to avoid recursive board management.

**Additional tools** (exist as modules but NOT in default set -- must be registered explicitly or accessed via `all_tools/2`):

| Tool | Module | Notes |
|------|--------|-------|
| `multiedit` | `Tools.MultiEdit` | Multiple sequential edits to one file |
| `exec` | `Tools.Exec` | Long-running background processes with poll/kill |
| `process` | `Tools.Process` | Control interface for `exec` processes, including manual restart of finished runs |
| `await` | `Tools.Await` | Block until background jobs complete |
| `webdownload` | `Tools.WebDownload` | Download binary content (images, PDFs) to disk |
| `truncate` | `Tools.Truncate` | Truncate long text with configurable strategies |
| `todoread` | `Tools.TodoRead` | Low-level todo read (used internally by `todo`) |
| `todowrite` | `Tools.TodoWrite` | Low-level todo write (used internally by `todo`) |
| `restart` | `Tools.Restart` | Restart the Lemon BEAM process (dev only) |
| `lsp_formatter` | `Tools.LspFormatter` | Format supported files with local formatters |
| `ask_parent` | `Tools.AskParent` | Child-only extra tool injected into eligible task-spawned sessions |

**Internal helpers** (not exposed as tools): `Tools.Fuzzy` (fuzzy match used by `edit`), `Tools.Hashline` (used by `hashline_edit`), `Tools.WebCache`, `Tools.WebGuard`, `Tools.TodoStore`, `Tools.TodoStoreOwner`.

### Tool Infrastructure

| Module | Purpose |
|--------|---------|
| `CodingAgent.Tools` | Tool factory -- `coding_tools/2`, `read_only_tools/2`, `all_tools/2`, `get_tool/3` |
| `CodingAgent.ToolRegistry` | Dynamic tool resolution (builtin > WASM > extension); ETS extension cache |
| `CodingAgent.ToolExecutor` | Approval-gated tool execution wrapper |
| `CodingAgent.ToolPolicy` | Tool allow/deny/approval policies; predefined profiles (`:full_access`, `:orchestrator`, `:leaf_worker`, `:read_only`, `:safe_mode`, `:subagent_restricted`, `:no_external`, `:minimal_core`) |

Internal `task` children default to the `:leaf_worker` policy. They keep normal work tools such as `read`, `write`, and `bash`, but recursive `task`/`agent` delegation is blocked unless a caller passes an explicit `tool_policy` override.

### Budget & Resource Management

| Module | Purpose |
|--------|---------|
| `CodingAgent.BudgetTracker` | Token/cost budget tracking per run |
| `CodingAgent.BudgetEnforcer` | Budget limit enforcement |
| `CodingAgent.ParentQuestions` | ETS+DETS-backed child-to-parent clarification request store with lifecycle events |
| `CodingAgent.ParentQuestionStoreServer` | Owns the ParentQuestions ETS/DETS tables and cleanup |
| `CodingAgent.RunGraph` | ETS-backed parent/child run relationships |
| `CodingAgent.RunGraphServer` | DETS persistence for run graph |

### Memory & Context

| Module | Purpose |
|--------|---------|
| `CodingAgent.Compaction` | Context compaction when conversations grow large |
| `CodingAgent.CompactionHooks` | Hooks for compaction events |
| `CodingAgent.ContextGuardrails` | Pre-LLM hard caps for large tool outputs/args with optional spill-to-disk references |
| `CodingAgent.Workspace` | Bootstrap file loading (AGENTS.md, SOUL.md, etc.) from the assistant home at `~/.lemon/agent/workspace/` |
| `CodingAgent.SystemPrompt` | Builds the Lemon base system prompt (assistant-home bootstrap files + skills) |
| `CodingAgent.PromptBuilder` | Higher-level prompt builder adding skills, commands, @mentions sections |
| `CodingAgent.ResourceLoader` | Loads CLAUDE.md/AGENTS.md from cwd up to filesystem root, then home dir |

`CodingAgent.Session` now composes `ContextGuardrails -> UntrustedToolBoundary -> custom transform_context` at the pre-LLM boundary. Oversized tool results are truncated with stable spill references under `~/.lemon/agent/sessions/<encoded-cwd>/spill/<session-id>/...` so the model can fetch full payloads via file tools when needed.
Its public GenServer shell stays `CodingAgent.Session`, but the larger internal concern clusters are now split into helper modules under `lib/coding_agent/session/`:
- `Lifecycle` for startup, extension reload, and reset orchestration
- `State` for state-building, prompt/reset shaping, diagnostics, and guardrail transform composition
- `Notifier` for UI notifications plus subscriber/event-stream lifecycle and fanout
- `Persistence` for message/session persistence helpers and session-file saving
- `BackgroundTasks` for deferred branch-summary/background work and branch navigation helpers
- `CompactionLifecycle` for auto-compaction triggering/result handling
- `OverflowRecovery` for context-window recovery and retry flow

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
| `LemonCore.TerminalBackend` / `TerminalBackends` | Shared backend contract and registry for supervised terminal/process execution |
| `CodingAgent.TaskStore` | ETS+DETS store for async task tool runs |
| `CodingAgent.TaskStoreServer` | Owns the TaskStore ETS/DETS tables |
| `CodingAgent.TaskProgressBindingStore` | ETS-backed parent-task surface bindings for async child runs; lazily restores `TaskProgressBindingServer` if the child is missing at runtime |

`CodingAgent.Tools.Task` now emits lifecycle events (`:task_started`, `:task_completed`, `:task_error`, `:task_timeout`, `:task_aborted`) to both `LemonCore.Bus` (`run:*` topics) and `LemonCore.Introspection`, with run/parent/session/agent lineage metadata for monitoring UIs.
Its public entry module stays `CodingAgent.Tools.Task`, but the internals are now split across:
- `CodingAgent.Tools.Task.Params` for validation and option shaping
- `CodingAgent.Tools.Task.Execution` for top-level run orchestration and execution-context construction
- `CodingAgent.Tools.Task.Async` for background lifecycle and task/run bookkeeping
- `CodingAgent.Tools.Task.Runner` for CLI/internal execution paths
- `CodingAgent.Tools.Task.Followup` for async followup routing
- `CodingAgent.Tools.Task.Result` for poll/join/result shaping

`CodingAgent.Tools.Task` now defaults omitted `async` to `true`, matching the tool contract. The task engine list includes `droid` alongside the other CLI runners, and Droid task runs forward `thinking_level` as Droid reasoning effort so delegated agents can use the live Droid CLI path through the normal task tool. Internal task runs also infer a restrictive `tool_policy` plus a verification-prefixed prompt when the request explicitly says `use ... tools only`, so tool-constrained subtasks do not answer from model priors with the default full toolset.
When an internal task omits `model`, `Task.Params` resolves the inherited model from the live parent session before falling back to captured tool opts, so Telegram/session-scoped `/model` overrides still propagate into async child sessions.
Internal task child sessions now poll for aborts/session exit in `Task.Runner`, with an optional explicit `task_session_timeout_ms` guard when callers want a bounded wait. If a provider stream wedges or the child session dies without a terminal event, the task still fails with a timeout/session-exit error instead of leaving `task action=join` and the parent Telegram thread stuck indefinitely.
Queued async task results should be treated as launch receipts. When a workflow needs one final answer in the same turn, the model/tooling should keep the returned `task_id`s and call `task action=join` before responding instead of relying on later auto-followup delivery to stitch the workflow back together. `task action=join` now suppresses the later async completion followup for those task ids so the parent session does not receive a second completion prompt after it already waited. Task result surfaces (`poll`, `join`, `get`, and auto-followup) are intentionally sanitized to visible assistant output plus task metadata, without leaking stored events, tool-call internals, or thinking deltas back into the parent session. Structured child reasoning is preserved in `details.reasoning` and projected as a reasoning action for operator surfaces, but it is not embedded as `[thinking]` text in parent-visible task answers. For non-terminal tasks, `poll` and `get` behave as status queries: they return the task status in user-visible text and keep the latest structured `current_action`/`reasoning` metadata in `details` instead of surfacing raw command/tool event text as answer content. Async followup delivery also idempotently backfills terminal task/run state, so a delivered completion message cannot leave the task store stranded in `queued` or `running`. Auto-followup now forwards the full visible task answer into the followup path instead of slicing it to a fixed prefix before routing, and router-delivered task followups use the `echo` engine so the raw completion text reaches the user without going back through the parent model. Any transport-specific chunking happens later at the channel layer.

`exec` and `process` now carry terminal backend metadata through
`LemonCore.TerminalBackends`. Registered backends are `:local`, implemented by
the existing supervised `ProcessSession` Erlang Port runner, `:local_pty`,
which wraps commands through util-linux `script(1)` when available, `:docker`,
which runs commands in a bounded Docker CLI container with the cwd mounted at
`/workspace`, a read-only root filesystem by default, and a bounded `/tmp`
tmpfs scratch mount, and optional `:ssh`, which uses OpenSSH in `BatchMode=yes` when
`LEMON_SSH_TERMINAL_TARGET` is configured. Future sandbox backends should
implement the backend contract and stay inside `ProcessManager` so policy,
logs, restart lineage, and status remain shared. Poll/list metadata includes
bounded-log counts, max-log settings, started/completed timestamps, and manual
restart lineage for finished processes restarted through the `process` tool.
`LemonCore.TerminalBackendPolicy` enforces
`LEMON_TERMINAL_BACKENDS_ALLOW` / `LEMON_TERMINAL_BACKENDS_DENY`, optional
`LEMON_DOCKER_TERMINAL_ALLOWED_IMAGES`, and optional
`LEMON_SSH_TERMINAL_ALLOWED_TARGETS` before a backend starts. It also validates
Docker image, network, memory, CPU, pids, and tmpfs-size settings plus SSH port,
connect-timeout, and strict-host-key settings before launch, so invalid
container/remote policy fails closed before reaching Docker or OpenSSH. The
`exec` tool also honors `LEMON_TERMINAL_BACKENDS_REQUIRE_APPROVAL` when an
approval context is available, sending a redacted approval action with backend,
command hash, cwd hash, and env keys only. Support surfaces show policy state
without raw SSH targets or env values. `exec.env` is validated before launch:
env must be an object with string values and keys matching normal environment
variable names.
`exec.checkpoint_paths` is validated as a list of non-empty strings. When a
risky shell command is detected and filesystem checkpoints are enabled, those
paths are snapshotted through `LemonCore.Checkpoint` before process start and
the result details include checkpoint metadata for restore.
`scripts/live_terminal_backend_smoke.exs` is the opt-in live proof lane for this
boundary: it runs a fixed command through every available registered backend,
records hashed proof JSON, skips unavailable backends, and fails the smoke on
backend errors or missing expected output.

Child sessions launched through `CodingAgent.Tools.Task` can now receive a child-only `ask_parent` extra tool when they have a live parent session plus run lineage. The parent answers through the default `parent_question` tool, and `CodingAgent.ParentQuestions` persists request state plus broadcasts lifecycle events (`:parent_question_requested`, `:parent_question_answered`, `:parent_question_timed_out`, `:parent_question_cancelled`, `:parent_question_error`).
`CodingAgent.CliRunners.LemonRunner` also preserves task-tool result metadata such as async
`task_id`, task status, engine, latest `current_action`, tool-reported
`exit_code`, and synthesized nonzero `bash` command-exit metadata inside action
`detail.result_meta` so router/channel layers can keep later `task action=poll`
updates and failed command summaries attached to the original external task
status surface.
When compacted history is restored, `SessionManager` preserves older async followup entries as
custom `async_followup` messages with provenance metadata so the next LLM projection still knows
which system-delivered completions came from task/delegated runs.

### Long-Running Harness Primitives

Lemon includes built-in harness primitives to support multi-step, long-lived implementation sessions:

- `CodingAgent.Tools.FeatureRequirements` persists `FEATURE_REQUIREMENTS.json` files in a workspace and reports requirement-level progress (`get_progress/1`, dependency-aware `get_next_features/1`).
- `CodingAgent.Tools.Todo` exposes higher-level progress actions (`action: "progress"`, `action: "actionable"`) on top of `TodoStore`.
- `CodingAgent.Tools.TodoStore` tracks dependency-aware todo progression and normalizes mixed key shapes (atom-key and JSON string-key todo maps).
- `CodingAgent.Checkpoint` wraps `LemonCore.Checkpoint` for long-running session resume state; shared rollback operations live in core for Web, control-plane, and channel reuse.

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
       |
       v
+--------------+
| ToolRegistry | --> Resolves tool by name (builtin/WASM/extension)
+------+-------+
       |
       v
+--------------+
| ToolExecutor | --> Checks ToolPolicy for approval requirement
+------+-------+
       |
       v
+--------------+
|  Tool Module | --> Executes tool logic with abort signal support
+--------------+
```

## Session Lifecycle

### Starting a Session

```elixir
# Under supervision (preferred -- falls back to start_link if supervisor not running)
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

1. `CodingAgent.SystemPrompt.build/2` -- base Lemon prompt (workspace bootstrap + skills list)
2. Prompt template content (if `:prompt_template` option given -- loaded from `.lemon/prompts/`, `.claude/prompts/`, `~/.lemon/agent/prompts/`)
3. Explicit `:system_prompt` option
4. `CodingAgent.ResourceLoader.load_instructions/1` -- CLAUDE.md/AGENTS.md from cwd hierarchy

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
- Explicit trusted paths in `[runtime] extension_paths`
- Global/project defaults only when `[runtime.extensions] auto_load_default_paths = true`

Default global/project extension directories are diagnostics-only unless
explicitly trusted. This keeps third-party code from running just because a file
exists under `~/.lemon/agent/extensions/` or `<cwd>/.lemon/extensions/`.

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
- Finds valid cut points (not mid-tool-call -- only cuts at user/assistant/custom/bash_execution boundaries)
- Generates an LLM summary of compacted messages
- Preserves file operation context
- Estimates request size from conversation messages plus system prompt and tool schema payloads
- Overflow recovery is also attempted if context window is exhausted mid-run

Settings controlling compaction (in `SettingsManager`/`config.toml`):
- `compaction_enabled` (default: true)
- `reserve_tokens` (default: 16_384) -- tokens reserved for model response
- `keep_recent_tokens` (default: 20_000) -- min recent context retained after compaction

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

The `Task` and `Agent` tools can use `Subagents` to prepend a role prompt before execution.
`Task` also supports per-run routing controls for async followups (`session_key`, `agent_id`, `queue_mode`, `meta`) while keeping execution local/CLI-oriented.
`Agent` keeps delegated-run submission `queue_mode` separate from delegated-completion `followup_queue_mode`; omitted completion modes resolve through `:coding_agent, :async_followups` before falling back to `:followup`.
With the default `:steer_backlog` config, live streaming parent sessions now attempt in-session steer delivery before router backlog fallback so async task/agent completions can converge back into the active turn.

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
[{"id": "my-agent", "description": "Short description", "prompt": "Role prompt prepended to task/agent runs."}]
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
+-- lib/
|   +-- coding_agent.ex                      # Main public API
|   +-- coding_agent/
|   |   +-- application.ex                   # OTP application (supervision tree)
|   |   +-- session.ex                       # Main GenServer orchestrator
|   |   +-- session/
|   |   |   +-- compaction_manager.ex        # Auto-compaction state machine
|   |   |   +-- event_handler.ex             # Agent event -> session state
|   |   |   +-- message_serialization.ex     # Message format conversion
|   |   |   +-- model_resolver.ex            # Model + API key resolution
|   |   |   +-- prompt_composer.ex           # System prompt layering
|   |   |   +-- wasm_bridge.ex              # WASM tool bridging
|   |   +-- session_manager.ex               # JSONL persistence
|   |   +-- session_supervisor.ex            # DynamicSupervisor
|   |   +-- session_registry.ex              # Process registry
|   |   +-- session_root_supervisor.ex       # Top-level supervisor
|   |   +-- tool_executor.ex                 # Approval gating
|   |   +-- tool_registry.ex                 # Dynamic resolution + ETS extension cache
|   |   +-- tool_policy.ex                   # Policy profiles and checks
|   |   +-- tools.ex                         # Tool factory (coding_tools, read_only_tools, all_tools)
|   |   +-- tools/                           # Individual tool modules
|   |   |   +-- read.ex, write.ex, edit.ex, multiedit.ex
|   |   |   +-- patch.ex, hashline_edit.ex, hashline.ex
|   |   |   +-- bash.ex, exec.ex, process.ex, await.ex
|   |   |   +-- grep.ex, find.ex, ls.ex, fuzzy.ex
|   |   |   +-- webfetch.ex, websearch.ex, webdownload.ex
|   |   |   +-- web_cache.ex, web_guard.ex
|   |   |   +-- todo.ex, todoread.ex, todowrite.ex
|   |   |   +-- todo_store.ex, todo_store_owner.ex
|   |   |   +-- task.ex, agent.ex
|   |   |   +-- tool_auth.ex, extensions_status.ex
|   |   |   +-- read_skill.ex, skill_manage.ex, memory_topic.ex, truncate.ex
|   |   |   +-- x_search.ex, post_to_x.ex, get_x_mentions.ex
|   |   |   +-- lsp_formatter.ex, lsp_diagnostics.ex, restart.ex
|   |   |   +-- feature_requirements.ex
|   |   +-- budget_tracker.ex, budget_enforcer.ex
|   |   +-- run_graph.ex, run_graph_server.ex
|   |   +-- compaction.ex, compaction_hooks.ex
|   |   +-- extensions.ex
|   |   +-- extensions/extension.ex           # Behaviour
|   |   +-- extension_lifecycle.ex
|   |   +-- wasm/                             # WASM tool runtime
|   |   |   +-- builder.ex, config.ex, policy.ex
|   |   |   +-- protocol.ex, tool_factory.ex
|   |   |   +-- sidecar_session.ex, sidecar_supervisor.ex
|   |   +-- security/
|   |   |   +-- external_content.ex
|   |   |   +-- untrusted_tool_boundary.ex
|   |   +-- workspace.ex                      # Bootstrap file loading
|   |   +-- system_prompt.ex                  # Lemon base system prompt builder
|   |   +-- prompt_builder.ex                 # Higher-level prompt builder
|   |   +-- resource_loader.ex                # CLAUDE.md/AGENTS.md hierarchy loader
|   |   +-- settings_manager.ex               # TOML config adapter
|   |   +-- config.ex                         # Path/env configuration
|   |   +-- subagents.ex, mentions.ex         # Subagent definitions and @mention parsing
|   |   +-- commands.ex                       # Slash command loading
|   |   +-- coordinator.ex                    # Concurrent subagent orchestration
|   |   +-- lane_queue.ex                     # Concurrency-capped lane queue
|   |   +-- parallel.ex                       # Semaphore and bounded parallelism
|   |   +-- process_manager.ex                # DynamicSupervisor for background processes
|   |   +-- process_session.ex, process_store.ex, process_store_server.ex
|   |   +-- terminal_backend.ex, terminal_backends.ex
|   |   +-- terminal_backends/local.ex
|   |   +-- task_store.ex, task_store_server.ex
|   |   +-- bash_executor.ex                  # Streaming shell execution
|   |   +-- messages.ex                       # Message types and LLM conversion
|   |   +-- checkpoint.ex                     # Session and filesystem checkpoint/restore store
|   |   +-- progress.ex                       # Progress reporting
|   |   +-- ui.ex                             # Pluggable UI abstraction
|   |   +-- ui/context.ex                     # UI context helpers
|   |   +-- cli_runners/                      # CLI runner integrations
|   |   +-- evals/harness.ex                  # Eval harness
|   +-- mix/tasks/                            # Mix tasks
+-- test/
|   +-- coding_agent/
|   |   +-- *_test.exs                        # 90+ test files
|   |   +-- tools/*_test.exs
|   +-- support/
+-- priv/templates/workspace/                 # Default workspace bootstrap templates
```

## Key Types

```elixir
# AgentTool from AgentCore -- the core tool contract
%AgentCore.Types.AgentTool{
  name: "tool_name",          # used in LLM tool call
  description: "What it does",
  label: "Display Label",     # human-readable (UI)
  parameters: %{"type" => "object", "properties" => %{...}, "required" => [...]},
  execute: fn tool_call_id, params, signal, on_update -> result end
}

# AgentToolResult -- returned by execute/4
%AgentCore.Types.AgentToolResult{
  content: [%Ai.Types.TextContent{text: "result"}],
  details: %{}   # structured metadata shown in UI (optional)
}

# SessionEntry -- one node in the JSONL session tree
%CodingAgent.SessionManager.SessionEntry{
  id: "entry_id",
  parent_id: "parent_id" | nil,
  type: :message | :compaction | :branch_summary | :label,
  # ... type-specific fields
}

# SettingsManager -- loaded from ~/.lemon/config.toml and <cwd>/.lemon/config.toml
%CodingAgent.SettingsManager{
  default_model: %{provider: "anthropic", model_id: "...", base_url: nil},
  default_thinking_level: :medium,
  provider_routing: %{
    enabled: true,
    fallback_providers: [],
    default_pool: nil,
    default_profile: nil,
    credential_pools: %{},
    profiles: %{},
    require_credentials: true
  },
  compaction_enabled: true,
  reserve_tokens: 16_384,
  keep_recent_tokens: 20_000,
  shell_path: nil,
  extension_paths: []
  # ... more fields
}
```

## Settings and Configuration

Settings are loaded from TOML via `LemonCore.Config` and merged (global -> project):

- Global: `~/.lemon/config.toml`
- Project: `<cwd>/.lemon/config.toml`

```elixir
settings = CodingAgent.load_settings(cwd)
# or directly:
settings = CodingAgent.SettingsManager.load(cwd)
```

Default model resolution consumes `runtime.provider_routing` conservatively:
when the configured default provider has no ready credentials, routing is
enabled, and a configured fallback/profile/pool provider has credentials plus
the same model id in `Ai.Models`, `CodingAgent.Session.ModelResolver` selects
the fallback before starting the supervised `AgentCore.Agent`. Explicit user
model specs are not rewritten. Default-model streams are also wrapped by
`CodingAgent.Session.ProviderFallback`: if the selected provider fails before
visible assistant content or tool calls are emitted, the same turn is retried
against the next credential-ready fallback provider with the same model id.

Key config paths (via `CodingAgent.Config`):

| Function | Path |
|----------|------|
| `agent_dir/0` | `~/.lemon/agent` (override: `LEMON_AGENT_DIR`) |
| `sessions_dir/1` | `~/.lemon/agent/sessions/{encoded-cwd}/` |
| `extensions_dir/0` | `~/.lemon/agent/extensions/` |
| `workspace_dir/0` | `~/.lemon/agent/workspace/` (assistant home bootstrap dir, distinct from `cwd`) |
| `project_extensions_dir/1` | `<cwd>/.lemon/extensions/` |

Provider API key resolution is handled by `CodingAgent.Session.ModelResolver` with fixed precedence:
1. Provider env vars (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, etc.)
2. Plain `providers.<name>.api_key`
3. `providers.<name>.api_key_secret` from `LemonCore.Secrets`
4. Default secret name `llm_<provider>_api_key` (Anthropic raw API keys use `llm_anthropic_api_key_raw`; Claude OAuth uses `llm_anthropic_api_key`)

When a secret value is an OAuth payload, `LemonAiRuntime.Auth.OAuthSecretResolver` dispatches to provider-specific OAuth decoders (Anthropic, Copilot, Google Antigravity, Google Gemini CLI, OpenAI Codex), refreshes near expiry, and best-effort persists refreshed tokens back to `LemonCore.Secrets`.
If the central resolver module is unavailable at runtime (mixed-version or partial deploy), `ModelResolver` falls back to calling provider-specific resolver modules directly so secret resolution does not crash.

## Testing Guidelines

- Use `CodingAgent.Session.start_link/1` directly in tests (not supervised)
- Mock UI with `CodingAgent.UI.Context` test helpers
- Use temporary directories for file operations (clean up in `on_exit`)
- Clean up sessions with `Process.exit(session, :normal)`
- For tool tests: assert on both `content` and `details` in results
- Use `async: false` for tests that modify global state (extensions, ETS tables, ProcessManager)
- `await` and `exec`/`process` tools depend on `ProcessStore` being started; start `ProcessStoreServer` in test setup if needed
- `ToolRegistry` uses an ETS cache for extensions; call `ToolRegistry.invalidate_extension_cache()` in teardown if tests prime the cache
Task-tool normalization is intentionally tolerant of provider variance: if a model supplies a prompt but omits the optional-looking `description` field, `CodingAgent.Tools.Task.Params` derives a short description from the prompt instead of rejecting the task call. Bash-only internal tasks also have a direct fast path for both backticked `Run \`cmd\`` prompts and plain `Run this exact command and return the output: cmd` phrasing so tool-using providers do not pay for a full child session just to execute one shell command.
