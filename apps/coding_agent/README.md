# CodingAgent

A full-featured AI coding agent runtime built on top of `LemonAgent`. This OTP application provides session management, 40+ tools, JSONL persistence with branching, budget tracking, context compaction, WASM tool support, extensions, and subagent orchestration for building interactive coding workflows.

## Overview

CodingAgent is an umbrella app within the Lemon AI assistant platform. It turns the lower-level `LemonAgent` event loop into a complete coding assistant by adding:

- **Session lifecycle management** -- GenServer sessions with persistence, branching, steering, and follow-up queues
- **Tool execution pipeline** -- Registry with precedence resolution (builtin > WASM > extension), approval gating, and policy profiles
- **Context compaction** -- Automatic summarization when conversations exceed the model's context window, with overflow recovery
- **Budget enforcement** -- Token and cost tracking per run with parent/child inheritance via a persistent run graph
- **Extension system** -- Dynamic tool and hook injection from Elixir modules or WASM sidecars
- **Subagent orchestration** -- Concurrent subagent sessions via a Coordinator with timeout management
- **Named execution nodes** -- Native delegated sessions can run on an authenticated destination selected by name, with destination-local credentials and working-directory defaults
- **Workspace and prompt composition** -- Layered system prompt from bootstrap files, skills, commands, and project-local CLAUDE.md/AGENTS.md
- **Provider routing** -- Default model selection can fall back through configured fallback providers, routing profiles, and credential pools before starting the supervised agent loop, and default-model streams retry another ready provider when the first provider fails before useful output starts; explicit model specs stay fixed.

## Architecture

```
                          User / Frontend
                               |
                               v
                      +------------------+
                      |   CodingAgent    |   Public API: start_session, lookup_session, load_settings
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

`CodingAgent.Executor` keeps normal requests local. When request metadata names
an execution node, it starts `Executor.RemoteSessionRunner`, which asks
`LemonCore.NodeRegistry` to deliver a versioned `coding_agent.run` request to
the authenticated destination WebSocket. The destination starts the same native
executor/session path and returns one JSON-safe terminal result; no vendor CLI
or subprocess agent runner is involved.

### Supervision Tree

```
CodingAgent.Supervisor (one_for_one)
  +-- Registry (SessionRegistry)
  +-- Registry (BackgroundRun.Registry)
  +-- Registry (ProcessRegistry)
  +-- TodoStoreOwner
  +-- SessionSupervisor (DynamicSupervisor for Session processes)
  +-- BackgroundRun.Supervisor (DynamicSupervisor for isolated `/bg` workers)
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
| `CodingAgent` | Top-level facade -- session/tool/settings APIs plus `start_background/2` and `ask_btw/3` |
| `CodingAgent.BackgroundRun` | Durable isolated full-tool background-run lifecycle API |
| `CodingAgent.SideQuery` | Bounded no-tools side-query API for live or durable parent context |
| `CodingAgent.Application` | OTP application callback; starts the full supervision tree and optionally a primary session |
| `CodingAgent.ParentQuestions` | DETS-backed store and lifecycle helpers for child-to-parent clarification requests |
| `CodingAgent.ParentQuestionStoreServer` | Owns the parent-question ETS/DETS tables and TTL cleanup |

### Session Management

| Module | Description |
|--------|-------------|
| `CodingAgent.Session` | Main GenServer orchestrating the agent loop, event dispatch, steering, follow-ups, compaction, and persistence |
| `CodingAgent.Session.EventHandler` | Translates `LemonAgent` events into session state updates, clears diagnostic queue mirrors on every terminal path, triggers compaction, and fires extension hooks |
| `CodingAgent.Session.CompactionManager` | Auto-compaction scheduling, tracked worker cleanup, overflow recovery state machine, and compaction result application |
| `CodingAgent.Session.MessageSerialization` | Serializes/deserializes messages between session and agent core formats |
| `CodingAgent.Session.ModelResolver` | Resolves model structs from string specs, maps, or settings; handles API key lookup via env vars and secrets with OAuth refresh |
| `CodingAgent.Session.PromptComposer` | Composes the final system prompt by layering the stable base prompt and available-skill metadata, prompt templates, an explicit system prompt, and resource-loader instructions; turn relevance stays outside the prompt |
| `CodingAgent.Session.WasmBridge` | Bridges WASM sidecar tools into the session tool set |
| `CodingAgent.SessionManager` | JSONL persistence engine with tree-structured entries (branching, compaction, labels), atomic writes, append-only incremental saves, and version migrations (v1-v3) |
| `CodingAgent.SessionSupervisor` | DynamicSupervisor for session processes with health check and list capabilities |
| `CodingAgent.SessionRegistry` | Registry wrapper for session lookup by ID |
| `CodingAgent.Executor` | Selects the normal local runner or a named-node remote runner from execution request metadata |
| `CodingAgent.Executor.RemoteSessionRunner` | Bridges one local gateway execution to one live named node and propagates completion/cancellation |

### Named Execution Nodes

| Module | Description |
|--------|-------------|
| `CodingAgent.ExecutionNode.CLI` | Implements `./bin/lemon node join` for a source checkout |
| `CodingAgent.ExecutionNode.Worker` | Authenticates to a controller, maintains the connection with application-level health keepalives, and executes targeted, versioned `coding_agent.run` requests through `CodingAgent.Executor` |
| `CodingAgent.ExecutionNode.Socket` | Reconnecting WebSocket client for control-plane handshakes, requests, responses, and node events |
| `CodingAgent.ExecutionNode.TokenStore` | Stores durable-node-ID-keyed session and recovery credentials under `~/.lemon/nodes/execution/` with a mode-0700 directory and mode-0600 files; migrates compatible legacy name-keyed records |
| `CodingAgent.Executor.RemoteRequestCodec` | Restricts the cross-node boundary to JSON-safe execution request/result fields and destination-cwd intent |

### Tool System

| Module | Description |
|--------|-------------|
| `CodingAgent.ToolRegistry` | The session tool set: `@builtin_tools` plus non-colliding satellite registrations, resolved with precedence (builtin > WASM > extension > MCP); `get_tools/2`, `get_tool/3`, ETS extension cache, conflict reporting. Assistant-platform tools are implemented in `LemonSkills.Tools` and listed here by name |
| `CodingAgent.ToolExecutor` | Approval-gated tool execution wrapper; integrates with `LemonCore.ExecApprovals` |
| `CodingAgent.ToolPolicy` | Policy profiles (`full_access`, `read_only`, `safe_mode`, `subagent_restricted`, `no_external`, `minimal_core`) with allow/deny lists and router-style approval maps |

### Built-in Tools

**Default set (`CodingAgent.ToolRegistry.get_tools/2`):**

| Category | Tools |
|----------|-------|
| File I/O / Skills / Memory | `read`, `read_skill`, `skill_manage`, `remember`, `recall`, `checkpoint`, `write`, `edit`, `patch`, `lsp_diagnostics`, `ls` |
| Search | `grep`, `find`, `ast_grep` (when the real ast-grep CLI is installed) |
| Execution | `bash`, `bash_output`, `kill_process` |
| Web / Browser / Media | `websearch`, `webfetch`, `browser_tabs`, `browser_tab_open`, `browser_tab_activate`, `browser_tab_close`, `browser_navigate`, `browser_snapshot`, `browser_get_content`, `browser_click`, `browser_type`, `browser_hover`, `browser_select_option`, `browser_upload_file`, `browser_download`, `browser_press`, `browser_scroll`, `browser_back`, `browser_wait_for_selector`, `browser_evaluate`, `browser_events`, `browser_get_cookies`, `browser_set_cookies`, `browser_clear_state`, `browser_screenshot`, `browser_analyze`, `media_status`, `media_generate_image`, `media_generate_speech`, `media_transcribe_audio`, `media_analyze_image`, `media_generate_video` |
| Task / Agent | `task`, `agent`, `parent_question`, `todo`, `kanban` |
| System | `tool_auth`, `extensions_status` |

**Snapshot-anchored edits.** A local text `read` returns numbered physical lines
and `[absolute/path#SNAPSHOT]`. Prefer `edit` with that snapshot and an `edits`
array instead of copying a large unique `old_text` block:

```json
{"path":"src/app.ts","snapshot":"0123456789ABCDEF","edits":[{"operation":"replace","start_line":73,"end_line":73,"new_text":"  const retryDelayMs = 250;"}]}
```

The snapshot covers the complete original file, even for a partial read.
Ranges are inclusive, one-based, and all operations use the original coordinates.
Operations are `replace`, `delete`, `insert_before`, and `insert_after`; overlapping
or stale batches fail without writing. Successful edits return a fresh snapshot.
Original BOM, CRLF/LF, and final-newline conventions are preserved. Exact-text
editing remains available for a uniquely matched region; ambiguous matches report
their line locations and never choose an occurrence silently. Read-only internal
references and transformed formats do not advertise editing snapshots.

**Rich reads.** `read` also accepts directories, ZIP/TAR/TAR.GZ/TGZ archives,
`bundle.zip:member/path`, PDFs, notebooks, and native images. Archive members are
read in memory, not extracted into the workspace. `offset`/`limit` select displayed
lines; follow `next_offset` for bounded directory/member/document output.
PDFs support `page`/`page_limit`; notebooks support `cell`/`cell_limit` and include
source, execution counts, text outputs, and errors. PDF extraction requires
`pdftotext`, `mutool`, or Python with `pypdf`/PyMuPDF; a project-local
`.lemon/read-formats-venv` is discovered automatically. No backend means an
actionable error, not fabricated text. On macOS, `sips` supplies proportional
image previews (maximum dimension 1568 by default) with original/preview
dimensions and an animation first-frame notice; original bytes remain untouched.
Input, extraction, preview, and displayed-output limits bound memory use.

**Structural search and replacement.** Install the genuine ast-grep CLI (for
example `brew install ast-grep`) to enable `ast_grep`. It matches syntax trees,
supports `$NAME` and `$$$ARGS` captures, and never substitutes text search.
For `action:"search"`, omitted/null `paths` search the current directory;
omitted/null `language` infers from extensions, and `rewrite` must be omitted/null.
Replacement always requires explicit paths; a null scope never enables a write.
Use `action:"replace"`, explicit `paths`, `pattern`, `rewrite`, and
`dry_run:true` to preview; apply with `dry_run:false` and `expected_matches`
equal to the full preview count. Count mismatches, overlapping ranges, stale
files, binary content, and symlink writes are rejected before writing.
Multi-file replacement is not an atomic filesystem transaction. If a target
changes or an I/O error occurs during writing, the error result preserves its
filesystem `checkpoint_id` and exposes `partial`/`written_paths`; session rewind
can restore the operation's original files. An interrupted call with no result
requires the session rewind's missing-checkpoint safety check.
`max_results` bounds display, not replacement scope; oversized output exposes a
retrievable full JSONL path. Backend planning is capped at 16 MiB: narrow the
scope rather than applying a truncated replacement plan. Because the same tool
can mutate files, read-only tool policies do not enable it.

**Native plans.** `todo` uses `action:"write"` with the complete updated list,
including completed tasks. New entries need only `content`; omitted/null IDs
are generated and remain stable across same-content updates. Status defaults to
`pending` and priority to `medium`. `read`, `progress`, and `actionable` are
read-only; omit `todos` or pass null, never a replacement list. Every successful
action returns the complete `details.todos` and normalized `details.plan.entries`
for TUI/ACP plan rendering, including completed tasks. Plan state survives the
existing session checkpoint/resume path.


**Read-only internal references.** The `read` tool accepts these in its `path`:

- `skill://<skill-key>` opens the selected bundle's `SKILL.md`, using the same
  cwd-aware registry and project-over-user precedence as `read_skill`.
- `skill://<skill-key>/references/example.md` opens a supporting file within that
  bundle. Traversal and symlinks beneath the bundle are rejected.
- `artifact://<id>` retrieves full output advertised by a truncated tool result.
  Use the exact returned handle, with `offset` (one-based line number) and `limit`
  to retrieve just the relevant portion rather than putting the entire output
  back into context.

Foreground `bash`, `bash_output`, and context guardrails expose artifact handles
for their spilled output. Handles are indexed on disk in the session's spill
directory, so they remain usable when that session is resumed while the
underlying output file remains available. They do not grant another session
access to the file, duplicate large output, or change its untrusted status.
They are for `read`, not mutation tools or remote ACP filesystem operations.
When registration is unavailable, results retain the existing absolute output
path instead of advertising a nonexistent handle.

The `agent` tool accepts an optional `node` string for delegated runs. Omit it
or pass `"local"` to use the controller host. A named value must resolve to a
currently connected execution node. If `cwd` is omitted, the destination uses
the default supplied to `node join`; an explicit `cwd` is interpreted and
validated on the destination. The `task` tool remains an in-process child of
the current coding session and does not expose named-node routing.

`browser_screenshot` writes screenshot bytes to local artifacts by default
instead of returning base64 to the model. Pass `includeImage: true` only when a
run needs model-visible screenshot content; result details remain redacted and
do not include raw base64. Pass `sendToChannel: true` only when the screenshot
should be attached to the final Telegram/Discord answer through redacted
`auto_send_files` metadata. Screenshot writes prune the browser artifact
directory to 14 days or the newest 100 files.

`browser_analyze` composes screenshot capture with the LemonSkills-owned
`media_analyze_image` tool so the
model can capture and analyze the current page through one supervised BEAM
operation. It writes managed screenshot and analysis artifacts, keeps raw
base64 out of details, and can optionally return a model-visible image block.

`browser_navigate` classifies targets on the BEAM side before worker dispatch.
The default `route: "auto"` preserves local-first use while reporting public,
private, or local-document target kind; `route: "public"` rejects local/private
targets, `route: "local"` rejects public web targets, and metadata endpoints
are always blocked before the browser worker.

`browser_get_cookies`, `browser_set_cookies`, and `browser_clear_state` expose
supervised browser session-state controls. Cookie values are redacted by
default unless `includeValues: true` is explicit. `browser_clear_state` clears
browser-context cookies, current-page local/session storage, and buffered events
by default; pass `clearCookies`, `clearStorage`, or `clearEvents` to narrow it.

`remember` is implemented as `LemonSkills.Tools.Remember`. It saves compact
assistant-home facts to `USER.md` or `MEMORY.md`, or scoped repository learnings
with target `project`, using `text` and exact `replaces` mutations. Duplicate
additions are ignored, storage limits are enforced, and writes are screened for
secrets and unsafe content. Successful turns and compactions also capture bounded
project facts in the background; explicit saves do not depend on that extraction.

`recall` is the read-only search tool, implemented as `LemonSkills.Tools.Recall`.
It searches past conversation summaries and longer workspace notes under
`memory/`. Conversation results use OR/BM25 lexical search, so paraphrases that
share a keyword can match. Automatic **Relevant memory** is stricter: project
learnings and relevant prior outcomes must stay within the repository, agent,
and assistant-home boundary. It never injects previous user prompts or performs
a model/network call. See the [memory guide](../../docs/user-guide/memory.md) for
bounds, configuration, capture behavior, and isolation.


The media tools are implemented in `LemonSkills.Tools` and registered by
`CodingAgent.ToolRegistry` under their existing names. `media_status` returns redacted media job summaries, recent jobs, cleanup
policy, and worker supervisor state to the model. `media_generate_image`,
`media_generate_speech`, and `media_transcribe_audio` are BEAM-supervised media
previews. They run deterministic local previews, provider-backed OpenAI
image/TTS/STT jobs, Vertex Imagen image jobs, ElevenLabs TTS, Google TTS, and
Deepgram STT, plus provider-backed OpenAI video and Vertex Veo jobs through
`LemonMedia.MediaJobSupervisor`, write managed
artifacts under `.lemon/media-artifacts`, record redacted `LemonMedia.MediaJobs`
metadata with prompt/input hash/chars, and can add generated `auto_send_files`
metadata when `sendToChannel: true` is explicit. Provider media jobs retry
bounded transient provider failures with `maxRetries`; failed provider jobs
record only a safe error kind plus structured provider status/type when present,
never the raw provider message.

`write`, `edit`, and `patch` create filesystem checkpoints automatically when
the tool context includes a session id. The `checkpoint` tool lists checkpoint
history, previews filesystem diffs, restores all or selected paths, and deletes
old checkpoints through `LemonCore.Checkpoint`. Checkpoint create, restore, and
delete operations emit redacted introspection and run/session events for audit
and live status surfaces. `CodingAgent.Checkpoint` remains the compatibility
wrapper that adds todo and requirement state for coding-agent resume flows.
`exec` also supports configured risky-shell checkpoints: pass
`checkpoint_paths` for files that should be snapshotted before destructive
commands such as `rm`, `mv`, `sed -i`, `find ... -delete`, `git reset`, or
`git clean`. The result details include the checkpoint id when a checkpoint was
created. Native LemonRunner action events preserve tool-reported `exit_code`
metadata and synthesize nonzero `bash` exits as structured `result_meta` with
`error_type`, `tool_name`, `exit_code`, and a safe message so router and channel
status surfaces do not need to parse terminal text.

Completed tool action events carry two views of the result. `detail.result` is
the 500-character preview that channel status renderers (Telegram, Discord)
show. Next to it, `CodingAgent.Session.Presentation.put_operator_result/2`
adds `detail.result_full` (the result text bounded to 32 KB, omitted when the
preview already is the whole result) and `detail.details` (the tool's
structured details — an edit's `diff` and `first_changed_line`, `exit_code`,
`path`, … — made JSON-safe and bounded). Reasoning actions likewise carry a
500-character `reasoning.text` preview plus a `reasoning.full_text` bounded to
16 KB. The control plane promotes the full copies for operator clients.

Local `patch` calls preflight every hunk in memory, reject duplicate paths and
destructive move overwrites, revalidate each operation immediately before
commit, and exclusively create new targets. Commits remain sequential, so a
later I/O failure reports the already-committed prefix and any possibly changed
current paths without risking rollback over concurrent filesystem changes.
Local `write` calls canonicalize the path used for validation and mutation,
then reject symlinks, caller-controlled symlinked parent components,
directories, devices, and other special-file targets by default; trusted
internal callers can opt into legacy symlink following with
`allow_symlinks: true`.

`lsp_diagnostics` runs workspace-aware language diagnostics for a single file.
`write`, `edit`, and `patch` can opt into post-edit diagnostics with
baseline/delta reporting so newly introduced issues are surfaced without
redacted checker and supervised language-server session capability metadata
in support bundles. The BEAM manager can also start/stop sessions, run the
initialize handshake, send framed JSON-RPC requests, synchronize open/change/
close document notifications, and capture redacted diagnostic notifications.

`kanban` is implemented in `LemonSkills.Tools` and exposes durable board and task operations backed by
`LemonAgent.Workspace.KanbanStore`. It is the model-facing surface for multi-agent work
that should outlive one session. Kanban-dispatched worker runs block the
`kanban` tool so a leased task cannot recursively manage its own board.

**Additional tools (not in default set):**

| Tool | Module | Notes |
|------|--------|-------|
| `skill_manage` | `Tools.SkillManage` | Create, patch, delete, and maintain audited Lemon skills |
| `remember` | `LemonSkills.Tools.Remember` | Save compact assistant-home facts |
| `recall` | `LemonSkills.Tools.Recall` | Search past conversations and longer workspace notes |
| `lsp_formatter` | `Tools.LspFormatter` | Format supported files with local formatters |
| `ask_parent` | `Tools.AskParent` | Child-only extra tool injected into eligible task-spawned sessions |

**Internal helpers (not exposed as tools):** `Tools.WebCache`, `Tools.WebGuard`, `Tools.TodoStore`, `Tools.TodoStoreOwner`.

Internal task runs infer a restrictive `tool_policy` and verification guardrail when the prompt says `use ... tools only`, so tool-constrained subtasks have to verify against tool output instead of guessing. For internal bash-only tasks, the runner accepts both backticked commands and plain phrasings like `Run this exact command and return the output: ...`, which keeps provider-generated shell subtasks on the normal child-session path.

### Budget and Resource Management

| Module | Description |
|--------|-------------|
| `CodingAgent.BudgetTracker` | Atomic token/cost accounting with parent/child inheritance, bounded child reservations, and idempotent completion aggregation |
| `CodingAgent.BudgetEnforcer` | Raises on exceeded budgets during agent runs |
| `CodingAgent.ParentQuestions` | ETS+DETS-backed child-to-parent clarification request store with lifecycle events |
| `CodingAgent.RunGraph` | ETS-backed parent/child run graph with monotonic state machine (`queued -> running -> completed/error/killed/cancelled/lost`); await via PubSub |
| `CodingAgent.RunGraphServer` | GenServer owning RunGraph ETS/DETS state, serialized lifecycle/budget writes, synchronous startup recovery, and TTL cleanup |

### Memory and Context

| Module | Description |
|--------|-------------|
| `CodingAgent.Compaction` | Context compaction engine -- finds valid cut points, generates LLM summaries, preserves file context |
| `CodingAgent.CompactionHooks` | Hooks for compaction lifecycle events |
| `CodingAgent.Workspace` | Loads bootstrap files (AGENTS.md, SOUL.md, TOOLS.md, IDENTITY.md, USER.md, HEARTBEAT.md, BOOTSTRAP.md, MEMORY.md) from the assistant home at `~/.lemon/agent/workspace/` |
| `CodingAgent.SystemPrompt` | Builds coding-first, tool-aware working rules, skills and memory guidance, and existing assistant-home context; omitted or empty bootstrap files are not injected |
| `CodingAgent.ResourceLoader` | Loads global CLAUDE.md/AGENTS.md first, then ancestors root→cwd with directory scope and local precedence; physical-file aliases appear once. Also loads prompts, themes, and skills |

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
| `CodingAgent.BackgroundRun` | Durable `/bg` lifecycle facade (`start`, `list`, `status`, `result`, `cancel`) for isolated full-tool sessions |
| `CodingAgent.SideQuery` | Bounded `/btw` query facade using an immutable live snapshot or durable session-key history with tools disabled |
| `CodingAgent.Coordinator` | GenServer orchestrating concurrent subagent sessions with timeout management |
| `CodingAgent.Parallel` | Semaphore-based concurrency control and `map_with_concurrency_limit` |
| `CodingAgent.ProcessManager` | DynamicSupervisor for background processes started by `bash` with `run_in_background`, read with `bash_output`, stopped with `kill_process` |
| `CodingAgent.ProcessSession` | GenServer for a single background process |
| `CodingAgent.ProcessStore` / `ProcessStoreServer` | ETS store for background process state |
| `LemonCore.TerminalBackend` / `TerminalBackends` | Shared backend contract and registry for supervised terminal/process execution |
| `CodingAgent.TaskStore` / `TaskStoreServer` | ETS+DETS async-task store with direct reads and serialized event, suppression, and monotonic lifecycle writes |
| `CodingAgent.ParentQuestions` / `ParentQuestionStoreServer` | ETS+DETS store for child-to-parent clarification requests |

The `task` and `agent` schemas keep model-facing guidance compact to reduce repeated prompt overhead. Parameter types, enums, required fields, and persona discovery remain in the tool definitions; this section provides the full delegation workflow reference.

The task tool runs model work in native in-process `CodingAgent.Session`s; swarm coordinators schedule those sessions without an extra model call.
When a provider omits the task `description` field but sends a valid `prompt`, Lemon derives a short description from that prompt instead of rejecting the task call outright.
When a native task omits `model`, it uses `[runtime.task].agent_models[<persona>]` when configured, then its named persona's `model` or model `role` default, then the configured `task` model role when present, otherwise the live parent session model at execution time. Explicit task `model` always wins. Telegram/session-scoped model overrides therefore still apply to children without a separate task/persona model selection. A persona's thinking level and `output` schema likewise default the child's `thinking_level` and `output_schema` unless the call sets them (an explicit `false`/`true` schema included). Personas listed in `[runtime.task].disabled_agents` are hidden from the tool's agent list and refused at launch.
Task workers monitor their native sessions: a crash, provider failure, abort, or configured `task_session_timeout_ms` is reported as an error, never promoted to success because partial text or a tool result exists. The default model wait is unbounded unless `[runtime.task].max_runtime_ms` sets a per-child limit; parent cancellation and worker/session death still end it.

Use one `task` call with `tasks: [{description, prompt, ...}, ...]` for up to 32 independent children. Each child inherits common top-level options, launches in the background, and returns a `task_id`/`run_id` receipt; `async: false` launches the entire batch before joining. Native tasks share a monitored semaphore with a default cap of eight running children; excess children queue without starting model calls. Dead holders and queued callers release capacity. Individual failures are retained alongside successful sibling results.

A top-level `context` string (at most 64 KiB; not allowed per item) is shared background for every child of a single run, batch, or swarm. Each child receives `<context>\n…\n</context>\n\n<assignment>\n…prompt…\n</assignment>`; tool-only guardrails ("use read tools only") are inferred from the assignment, never from the context. Swarm dependency results follow the assignment.

Use `action: "swarm"` for a dependency graph of up to 32 named tasks. Each node has a unique `name`, its normal task options, and optional `depends_on: ["OtherName"]`. The entire graph, names, native task parameters, and dependency edges are validated before any work starts; cycles, self-dependencies and unknown names are errors. Ready nodes are admitted in declaration order up to `concurrency` (1–32, default 8), including children waiting for global model capacity. Busy native child-budget slots also apply backpressure rather than turning ready nodes into failures. The coordinator consumes no model slot, so a cap of one still works.

```json
{
  "action": "swarm",
  "description": "Inspect and improve pricing",
  "async": true,
  "auto_followup": false,
  "concurrency": 3,
  "tasks": [
    {"name": "API", "agent": "scout", "prompt": "Inspect pricing.py and report the bug and corrected formula."},
    {"name": "Cases", "agent": "scout", "prompt": "Read cases.json and report inputs and expected totals."},
    {"name": "Workflow", "agent": "scout", "prompt": "Read README.md and report the verification command and constraints."},
    {"name": "Implement", "depends_on": ["API", "Cases", "Workflow"], "prompt": "Use dependency findings to fix pricing.py, add regression tests, and run verification."},
    {"name": "Document", "depends_on": ["API", "Cases", "Workflow"], "prompt": "Use dependency findings to document the API, examples, and verification command in USAGE.md."}
  ]
}
```

Async swarms return **one coordinator task ID**. Join/get that ID (or pass it explicitly to `wait`) for the merged report, rather than mistaking an individual node result for completion of the graph. `async: false` waits for the same report. A node launches only after all its direct dependencies succeed; their visible results are appended to its user prompt as bounded untrusted peer data, not system instructions. The dependency context is capped at 32 KiB and grants no access to sibling-private histories. Node `agent`, model, output schema, worktree, and tool policy options use the existing isolation rules.

Failed, cancelled, lost or missing child results block their dependents transitively; independent branches keep running. The final `structured_output` contains declaration-ordered `tasks`, status/counts, and launched task/run IDs. Status is `completed` when every node succeeds or `partial_failure` otherwise; errors and blocked nodes are explicit. Output/error previews are bounded to 4 KiB/1 KiB and structured values larger than 4 KiB are explicitly omitted. The owning parent can use each node's task ID to retrieve its full stored result. This merges reports, **not git branches or worktree changes**.

Progress includes graph counts and node identities alongside normal child tool updates. Cancelling the coordinator stops active children and prevents further launches; parent or scheduler death also cancels its work. The coordinator has no model session: its roster entry has `messaging: false`, direct messages fail clearly, and broadcasts skip it. Launched children keep normal scoped parent/sibling messaging and parent-only cancellation.

Set `worktree: true` per child (or on the batch) to create a git branch `lemon/task-<task_id>` from the current checkout's HEAD. Worktrees live beneath the repository's common git directory in `lemon-task-worktrees/<task_id>` and retain the source cwd's relative subdirectory. `merge` (default `[runtime.task].worktree_merge`, itself defaulting to `"none"`) selects what happens after the child **succeeds**; it requires `worktree: true`:

- `none`: uncommitted changes and local credentials/config are not copied, and the worktree and branch are retained, not merged or deleted. Review or cherry-pick the child's commits, then remove the worktree with `git worktree remove`.
- `patch` (omp's default): the parent checkout's uncommitted work — tracked changes plus untracked, non-ignored files (at most 64 MiB; symlinks only when they stay inside the repository) — is replayed into the worktree and committed as a baseline. On success, the child's committed and uncommitted changes relative to that baseline are applied to the parent working tree with `git apply` (not staged or committed), serialized per repository; the worktree and branch are then removed. If the patch does not apply cleanly the parent is left untouched and the worktree, branch and `lemon-task-worktrees/<task_id>.patch` are kept (`status: "conflict"`).
- `branch`: the child's changes are committed on its branch and the worktree is removed; the branch is kept for review. Unlike omp, Lemon never merges it into your branch.

With nothing to merge, both merge modes report `no_changes` and remove the worktree and branch. A failed or cancelled child is never merged; its worktree is retained. Results gain `details.merge` (`mode`, `status`, plus files, patch path or head commit) and one summary line in the visible output. `poll`/`get`/`join` report `cwd`, `worktree_path`, `branch`, and `merge`. A non-git cwd is a task error, not a fallback to the shared checkout.

Merge-back rechecks cancellation after waiting for the parent checkout's merge lock and immediately before applying a patch. Cancellation cannot undo an apply or commit already in progress. If the child replaces its checkout, switches branches, or detaches HEAD, automatic finalization refuses and retains its work for manual review instead of deleting commits that are not on the task branch.

Parents can use `action: "message"` (or `"steer"`) with `task_id` and `message` to deliver peer input at the next child steering boundary, or `action: "cancel"` to cancel a queued/running child. Cancellation and result reads remain bound to the owning parent session/agent; messaging additionally permits the immediate family described below. Cancelling or terminating a parent cancels its children and descendants, including queued children. Unresponsive workers are stopped after a short cancellation grace period. Children always use subagent bootstrap scope and leaf-worker tool policy by default, preserving profile/workspace isolation.

Give a task an optional `name`, separate from its persona `agent`, to address it as `agent://<name>`. Names are case-sensitive, 1–64 ASCII letters/digits/underscores/hyphens, start with a letter, and cannot be `parent`, `self`, or `all`. Batch names must be unique; ambiguous names among existing live tasks fail rather than choosing a recipient. Task IDs remain stable addresses and take precedence over aliases.

Use `agent_message` with `{to: "agent://Worker", message: "..."}`, or `write` with `{path: "agent://Worker", content: "..."}`. `task action=message` also accepts `to` for an address. A child can message `agent://parent`, its siblings, or its own children; a parent can message its direct children. `agent://all` broadcasts to reachable live relatives except the sender. `read agent://` or `agent_message action=list` returns the scoped roster. `read agent://<name-or-task-id>` on a task you launched (including finished ones no longer in the roster) returns its identity, status and, once terminal, the same visible output as `get` plus `structured_output`; `read agent://<id>/<key>/<index>/…` returns one field of its `structured_output` (strings verbatim, other values as JSON) and errors when a segment is missing. Other live relatives (parent, siblings) return identity only, and foreign task IDs or names stay unknown. Unknown, completed, ambiguous, cancelled, and foreign message targets produce explicit errors. Messages cannot cancel siblings or grant access to their stored results.

Sender identity is authenticated from captured session options, never supplied message fields. Messages are labeled untrusted peer content and use the recipient's steering queue, without starting another prompt turn. Unattached children retain FIFO messages, capped at 64 messages / 256 KiB including envelopes; individual UTF-8 message bodies are capped at 32 KiB. Broadcast checks all recipient queue capacities before sending. An accepted receipt means queued peer input, not a completed response or permission to override system/tool restrictions.

The `wait` tool (also `task action=wait`) blocks until the first owned native child returns a result, including failure or cancellation, without stopping siblings. With no `task_ids`, it includes already-finished but unobserved children, then marks only the returned winner observed; the next implicit wait consumes the next result. Explicit `task_ids` restrict the set and may revisit an earlier result. No outstanding/unobserved children is an immediate error. Waiting uses existing join cancellation, parent-question yielding, and winner-only followup suppression; this primitive does not wait on shell/background-process jobs.

For example, after launching a child named `Reviewer`, the parent can make these separate tool calls (the message receipt does not replace waiting for the child's result):

```json
{"tool": "read", "arguments": {"path": "agent://"}}
{"tool": "agent_message", "arguments": {"to": "agent://Reviewer", "message": "Focus on cancellation and report concrete failure cases."}}
{"tool": "wait", "arguments": {}}
```

The child can reply with `agent_message` addressed to `agent://parent`; siblings can exchange findings through their roster names or stable task IDs. Use explicit `task_ids` on `wait` when the next result must come from a particular subset rather than any unobserved child.

Task progress is delivered directly to parent session subscribers even after the launch tool call ends, with `details.task_id`, `run_id`, `description`, `status`, child `session_id` when allocated, and optional `current_action` (`title`, `kind`, `phase`). Receipts, progress, and result rows also carry available `parent_run_id`, `parent_session_id`, and named persona `agent`; tree consumers can index children by `run_id` and attach them to `parent_run_id` without guessing from completion order. A final progress update settles each child as `completed`, `error`, or `aborted`. Join results include structured visible `output` and `error` per child; hidden reasoning is not included.

Translated operator/run events keep the completed launch action separate from each child: child action IDs are `task_<task_id>`, with the launcher recorded in parent-action metadata. Actual child terminal status emits a completed phase with success/failure and visible output; later stale progress cannot reopen it or complete a still-running sibling.

Delegation is depth-limited by `[runtime.task].max_depth` (default 2; `-1` unlimited; `0` stops the main session from delegating). The main session is depth 0 and each child is one deeper; a session at the cap gets an explicit refusal from `run`, `tasks[]`, and `swarm`, and children created at the cap never receive `task`, even when `tool_policy` asks for it. Below the cap, a child gains `task` when its `tool_policy` explicitly permits delegation, or when its non-read-only persona declares `spawns` (the leaf-worker `task` denial is lifted and `task` is added to the persona's tool list, still intersected with any caller policy). A `spawns` list restricts that child's launches to the listed personas, so its `task` calls must name one of them; `"*"` allows any. If a child's tool policy permits further delegation, descendant progress is relayed through native ancestors to the subscribed root session. Descendant task/run/session identities are preserved, including terminal updates; relay events are not relabeled or stored as the ancestor's own work.

Pass `agent: "scout"`, `"reviewer"`, `"security-reviewer"`, `"sonic"`, or `"task-executor"` to select a named persona. Persona instructions are composed into the child **system prompt**, not the user's task. The scout, reviewer, and security-reviewer expose only `read`, `grep`, `find`, `ls`, and scoped `agent_message`, intersected with any narrower policy. Neither a project override, `read_only: false`, `spawns`, an explicit `tool_policy`, nor MCP/extra tools can grant those identities write, shell, or delegation capabilities. Messaging shares findings without relaxing filesystem/profile isolation. `sonic` is a mechanical leaf worker on the `@smol` model role with low thinking. Other personas retain the leaf-worker policy unless explicitly restricted or overridden. The coordinator uses the same persona/session-option path.

Set `output_schema` on a task or batch child to require a JSON-only final response. Validated data appears as `structured_output` in completion, `poll`, `get`, `join` task rows, and live final progress; JSON `null` remains an explicitly present field. When the final response is invalid JSON or mismatches the schema, the same child session is re-prompted with the validation error up to two more times before the session ends. With the default `schema_mode: "strict"` a still-invalid response fails the task rather than silently accepting prose; `schema_mode: "permissive"` instead completes with the visible text and `details.structured_output_error` (no `structured_output`), so worktree merge-back still runs. Supported JSON Schema constraints include types/unions, objects (`properties`, `required`, `additionalProperties`), arrays (`items`, bounds, uniqueness), strings (length and Unicode regex `pattern`), numeric bounds/`multipleOf`, `enum`, `const`, and `allOf`/`anyOf`/`oneOf`/`not`. Boolean schemas are supported. References, formats, and unsupported keywords are rejected before launching work. Schemas are bounded to 64 KiB encoded JSON and 32 nesting levels; validation errors name the failed JSON path without echoing response values.

Task state uses a single-writer contract. `TaskStoreServer` serializes record changes, bounded event appends, explicit-join followup reservations/suppression, and terminalization. Competing completion/error callbacks are first-writer-wins, repeated terminal callbacks are idempotent, and late running/progress updates preserve the terminal state. `RunGraphServer` completes its DETS recovery before reporting startup readiness, then serializes live inserts, transitions, budget updates, and deletes so recovery cannot overwrite accepted live state.

For coordination workflows that must produce one final same-turn answer, queued task results should be treated as launch receipts, not completion. Keep the returned `task_id`s and call `action=join` before responding; auto-followup is for later delivery, not guaranteed same-turn aggregation. Joins reserve followup delivery while waiting. `wait_all` permanently suppresses completed joined tasks, while `wait_any` suppresses only its completed winner and releases every loser; failure, abort, an unknown run, or a child clarification releases the reservation without permanent suppression. Task result surfaces (`poll`, `join`, `get`, and async auto-followup) expose only visible assistant output plus task metadata, not stored event streams, tool-call internals, or thinking deltas. For non-terminal tasks, `poll` and `get` behave as status queries: user-visible text shows task status, while the latest structured `current_action` stays in `details` instead of leaking raw command/tool event text into answer content. Async followup delivery also backfills terminal task/run state before posting the completion message, which prevents delivered completions from leaving task records stranded in `queued` or `running`. Auto-followup preserves the full visible task answer and submits router fallbacks as native followup runs; delivery failures are contained after task/run state is terminalized. Async launches fail immediately when their supervised worker cannot start, rather than returning a task id that remains queued forever. When `:coding_agent, :async_followups` is set to `:steer_backlog`, live streaming parent sessions attempt an in-session steer first before falling back to router backlog semantics.

The delegated `agent` tool mirrors each accepted async router run into `RunGraph`, so `agent action=join` waits on the same lifecycle that its completion watcher updates. TaskStore and RunGraph retain the parent run/session, the parent's child list links to the delegated run, and request metadata carries trusted `delegated_by.run_id`; caller-supplied metadata cannot forge that lineage. A completion watcher that cannot start returns a `tracking_error` receipt with both task and router run ids instead of presenting an untracked run as normally queued. If a running watch exceeds its local timeout, TaskStore reports `tracking_lost` without failing the authoritative router run; a bounded reconciliation phase accepts a late success or failure and advances both stores.

Eligible native child sessions receive `ask_parent`. Its request is delivered through `Session.deliver_parent_question/2`: idle parents start processing immediately, and a parent currently inside `task` or `agent` join yields that join with `needs_parent_answer` before processing the visible question. Parent-question creation and terminal transitions are serialized, one child scope may have only one waiting request, resolver credentials must exactly match both parent session and agent, and only the winning answer/timeout/cancel/error transition emits a terminal event.

`LaneQueue` monitors callers while jobs wait, removes abandoned queued jobs, and turns a missing or failing task supervisor into a per-job `task_start_failed` result while continuing to drain. Background process execution catches LaneQueue GenServer exits and uses the documented direct fallback rather than hanging the caller.

Hermes-compatible background commands use the same native runtime. Call
`CodingAgent.BackgroundRun.start/2` to receive a durable id immediately, then
use `list/1`, `status/1`, `result/1`, or `cancel/2`. Each run owns a fresh
full-tool session on the subagent lane; `:session_key` is retained only as
lineage metadata, and neither the prompt nor result is appended to that parent.
Channel surfaces use `list_scoped/2`, `status_scoped/2`, `result_scoped/2`, and
`cancel_scoped/3`, which require that lineage key and make a foreign id
indistinguishable from a missing id. The unscoped lifecycle remains reserved for
trusted operator/control-plane views.
Queued/running background records recover as `:lost` after a VM restart rather
than pretending an in-memory worker survived.
Internal worker/provider failures remain in the task store for runtime
diagnostics, while `status/1` and `result/1` expose only stable classifications
such as `:failed`, `:lost`, and `:cancelled`. Background lifecycle events use
the same content-free classifications and do not copy retained error terms.

`CodingAgent.SideQuery.ask/3` implements `/btw` as a synchronous, bounded,
no-tools session. Its source may be a live session pid/id, a durable channel
session key, or an explicit `%{messages: ..., system_prompt: ...}` snapshot.
Live context is captured atomically and frozen for the child; durable keys use
bounded `LemonCore.RunStore` history plus session policy. Persisted string
reasoning levels are normalized to the atom-valued native session contract
before the no-tools child starts. Side queries use a separate ephemeral
session key and never mutate parent history.
Runner failures are collapsed to bounded atoms (`:timeout`, `:cancelled`, or
`:query_failed`) so adapters never receive provider details or local paths.

`exec` and `process` now expose terminal backend metadata. Registered backends
include `:local`, backed by the supervised `ProcessSession` Erlang Port runner,
`:local_pty`, backed by util-linux `script(1)` when available, `:docker`,
backed by a bounded Docker CLI container with the cwd mounted at `/workspace`,
read-only root filesystem by default, a bounded `/tmp` tmpfs scratch mount,
and optional `:ssh`, backed by OpenSSH in `BatchMode=yes` when
`LEMON_SSH_TERMINAL_TARGET` is configured. Results and process records include
the backend id plus terminal capabilities so future sandbox backends can plug
into the same observable `ProcessManager` boundary. Poll/list metadata also
includes bounded-log counts, max-log settings, started/completed timestamps,
and manual restart lineage when a finished process is restarted through the
`process` tool. Backend launch also passes
through `LemonCore.TerminalBackendPolicy`, which supports backend allow/deny
lists plus optional Docker image and SSH target allowlists while keeping raw SSH
targets out of support metadata. `LEMON_TERMINAL_BACKENDS_REQUIRE_APPROVAL`
can require backend-specific `exec` approval; approval actions include backend,
command hash, cwd hash, and env keys only.
`exec.env` is validated at the tool boundary: env must be an object with string
values and keys matching normal environment variable names before any backend is
started.
`exec.checkpoint_paths` is validated as a list of non-empty strings and is used
only with filesystem checkpoints enabled. Risky shell checkpoints snapshot the
configured file paths through `LemonCore.Checkpoint` before backend launch and
return `checkpoint_id`, `checkpoint_kind`, and `checkpoint_trigger` in result
details.

### Subagents and Commands

| Module | Description |
|--------|-------------|
| `CodingAgent.Subagents` | Named Markdown personas from `.lemon/agents/*.md`, `~/.lemon/agents/*.md`, omp/Claude Code agent directories, and built-in `scout`, `reviewer`, `security-reviewer`, `sonic`, `task-executor` |
| `CodingAgent.Commands` | Slash command discovery from `.lemon/command/*.md` and `~/.lemon/agent/command/*.md` with YAML frontmatter |

Create `.lemon/agents/architect.md` for a project persona (or use `~/.lemon/agents/architect.md` globally):

```markdown
---
name: architect
description: Map module boundaries and recommend focused changes
role: coding
tools: [read, grep, find, ls]
read_only: true
---
Inspect the relevant implementation before answering. Cite paths and explain
the existing contracts; do not change files.
```

The filename is the agent name; optional `name` must match it. `description` and a nonempty Markdown instruction body are required. Optional `model` names a concrete `provider:model` or `@role`; `role` names a configured model role without `@` (`model` wins if both are supplied). `tools` is an allow-list intersected with the effective task policy, not a grant that bypasses it. `read_only: true` further restricts tools to the four read-only filesystem built-ins and scoped `agent_message`. An invalid higher-priority `.lemon` definition is an error, never a silent fallback. Definitions are read locally without creating config files. Legacy `.lemon/subagents.json` and the task `role` parameter are replaced by Markdown definitions and `agent`; router-level `agent` delegation retains its separate `role` persona selector.

Optional `thinking` (also `thinking_level`, `thinking-level`, `thinkingLevel`) sets the persona's thinking level (`off`, `minimal`, `low`, `medium`, `high`, `xhigh`; `max` means `xhigh`). `spawns` is `"*"` or a list of persona IDs the child may delegate to; it defaults to `"*"` when `tools` includes `task`, and is always cleared for read-only personas. `output` is a default output schema, written as JSON Schema or as an omp JSON Type Definition (RFC 8927), which is converted to JSON Schema (JTD objects allow extra properties; `ref`/`definitions` are unsupported). `tools` and `model` also accept comma-separated strings; tool names are lowercased, `Bash(git:*)`-style suffixes are dropped, Claude/omp names map to Lemon tools (`Glob` → `find`, `MultiEdit`/`NotebookEdit` → `edit`, `TodoWrite` → `todo`, `web_fetch` → `webfetch`), and the first model other than `inherit` is used.

The first definition for an ID wins, searching project `.lemon/agents/`, project `.omp/agents/`, project `.claude/agents/`, `~/.lemon/agents/`, `~/.omp/agent/agents/`, `~/.claude/agents/`, then the shipped definitions. Project `.omp` and `.claude` directories are searched from the working directory up to the Git root, nearest first. Those omp/Claude Code definitions are read tolerantly: the ID comes from `name` (or the filename), unknown fields such as `color` are ignored, Claude model aliases (`sonnet`, `opus`, `haiku`) fall back to the inherited model, long descriptions are truncated, and invalid files are skipped without hiding lower-priority definitions.

### Harness and Checkpointing

| Module | Description |
|--------|-------------|
| `CodingAgent.Checkpoint` | Compatibility wrapper over `LemonCore.Checkpoint` with coding-agent todo/requirement resume state |
| `CodingAgent.Tools.FeatureRequirements` | Persists `FEATURE_REQUIREMENTS.json` with dependency-aware progress tracking |
| `LemonEvals.Harness` | Evaluation harness for automated agent testing; includes deterministic tool contracts, read/edit workflow checks, remember/recall contracts, and relevant-skill prompt progressive-disclosure checks |

The eval harness is intentionally lightweight and deterministic. It should catch harness-contract drift before behavioral/LLM evals run: default tool registry coverage, stable builtin tool ordering, basic file workflow viability, memory recall scope, and skill prompt guidance that points agents to `read_skill` and `skill_manage` without inlining full skill bodies.

### Security

| Module | Description |
|--------|-------------|
| `LemonAgent.Security.ExternalContent` | External content sanitization; `CodingAgent.Security.ExternalContent` remains a compatibility wrapper |
| `CodingAgent.Security.UntrustedToolBoundary` | Pre-LLM boundary for untrusted tool output; composed with `ContextGuardrails` |

Named-node execution does not serialize source-side provider credentials,
executor options, callbacks, or BEAM process state. The worker accepts only the
versioned `coding_agent.run` method, removes `meta.node` before local execution
to prevent recursive selection, and requires the selected cwd to exist locally.
Node session tokens are stored only on the destination and are accepted from
`LEMON_NODE_OPERATOR_TOKEN` / `LEMON_NODE_TOKEN` so they need not appear in
shell history.

### Utilities

| Module | Description |
|--------|-------------|
| `CodingAgent.Messages` | Message type definitions and LLM format conversion |
| `CodingAgent.BashExecutor` | Streaming shell command execution |
| `CodingAgent.InternalUrls` | Internal URL protocol handling |
| `CodingAgent.InternalUrls.NotesProtocol` | `notes://` protocol handler |
| `CodingAgent.Progress` | Progress reporting utilities |
| `CodingAgent.Utils.Http` | HTTP utility functions |

### Mix Tasks

| Task | Description |
|------|-------------|
| `Mix.Tasks.Lemon.Eval` | Run eval harness from the command line |
| `Mix.Tasks.Lemon.Workspace` | Manage workspace bootstrap files |

### Native Task Execution

`CodingAgent.Tools.Task.Runner` starts and monitors native task sessions directly.

## Key Concepts

### Sessions

A session is a `GenServer` process that wraps an `LemonAgent.Agent` loop. Each session has:

- A working directory (`cwd`)
- A model configuration
- A set of tools (default: `CodingAgent.ToolRegistry.get_tools/2`)
- JSONL persistence with tree-structured entries
- Event subscription (direct send or backpressure-aware streams)
- Steering (mid-run interrupts) and follow-up (post-run) queues
- Auto-compaction and overflow recovery

The Session queue fields are diagnostic mirrors; `LemonAgent.Agent` owns actual
delivery and consumption. Terminal, cancel, error, abort, and agent-exit paths
clear the mirrors so `diagnostics/1` cannot report stale follow-ups.

Sessions are started under `SessionSupervisor` (dynamic) and registered in
`SessionRegistry` by their persisted UUID. Registry metadata also retains the
logical runtime session key used by clients.

Live sessions synchronously append completed messages, tool calls/results, model
changes and compaction entries to their JSONL file. They do not depend on a
graceful shutdown or an explicit `Session.save/1`. Resuming with `:session_file`
restores the recorded working directory, selected branch, model and thinking
level; explicit model/thinking options override the recorded selection. An
unreadable session is an error, never a silently empty conversation. A torn
last append is recovered; completed corrupt lines remain errors. Interrupted
tool calls receive an explicit interrupted-result marker, not a fabricated
successful result.
Native identities remain unchanged in their headers; oversized or path-unsafe
identities use deterministic portable journal filenames inside the session directory.
Usage checkpoints preserve response costs and cache-write durations as well as
token counts, so reopening a session does not reset its recorded cost. Rewinding
a live branch preserves the selected provider API, including ChatGPT/Codex models.

`SessionManager.list_sessions/1` lists most recently modified sessions first.
`Session.navigate_tree/3` persists branch selection even before another message
is sent. `SessionManager.fork_file/3` creates an independent branch file with
parent-session provenance; it refuses to overwrite an existing destination.
The control-plane provider exposes history replay and fork through its runtime
seam, binding forked files to independent native resume tokens. Its manual
compaction adapter accepts `cwd:` and also works for an idle saved session after
the previous run's process has exited.

### Planning and context budget

Plan mode follows omp's `/plan` toggle. `Session.plan/3` and the `sessions.plan`
RPC (`status`, `enter`, `exit`) append branch-aware `"lemon.plan"` journal
entries, so restart, branch navigation and compaction keep the mode, the current
plan file and any approved plan. Toggling is refused while a turn runs.

In plan mode every tool still appears, but a shared gate blocks execution of
anything outside `read`, `read_skill`, `recall`, `grep`, `find`, `ls`,
`websearch`, `webfetch` and `ask` (themselves subject to the session policy).
`write`/`edit` are allowed only for Markdown files in the session-private plan
directory (under native session storage, written locally even for ACP clients);
plan-only instances are added when the policy removed the file tools. The agent
drafts `<slug>-plan.md` there and calls `propose_plan`, which asks the user through
`LemonCore.ExecApprovals` (tool `propose_plan`, action `title`/`path`/`plan`).
Approval appends a code-mode entry carrying the plan (≤ 32 KiB), opens the gate,
swaps the system prompt to include the approved plan and steers the running loop
into execution; denial means "refine" and keeps plan mode on. `exit` never approves.
Entering before the first run durably binds the native journal to the logical
session key. Legacy reviewed-artifact entries load as plan mode or approved-plan
context.

Manual `/compact [focus]` (alias `/compress`) forwards focus instructions and cwd
to native compaction, including after the previous runtime has exited. Its
structured handoff preserves exact changed paths, decisions and rationale, open
work, failing tests/blockers, verification commands/results and still-relevant
previous-summary facts. The prompt explicitly carries scope exclusions and exact
public API names, function arities and error atoms/codes. Observed results remain
distinct from proposed or unverified work; transcript/tool instructions are treated
as untrusted data.

`Session.context_budget/1` reports current request tokens, model window, reserve,
automatic-compaction threshold and headroom before that threshold. It shares the
automatic trigger's estimator, using the latest successful provider usage plus
newer message estimates—not cumulative run spending. Sources are `usage`,
`usage+estimate` or `estimate`. Compaction and planning-context changes invalidate
older usage anchors.

`Session.context_usage/1` (`Session.ContextUsage`) splits that same total into
categories: system prompt, tool definitions, skills, context files, memory
(USER.md/MEMORY.md, contributed sections, automatic recall), user and assistant
messages, tool results and summaries, plus the largest contributors. The prompt
composer keeps labelled sections (`PromptComposer.compose_sections/7`) whose texts
join to the exact prompt; only sections present in the prompt being sent are
attributed. Splits use the shared ~4 chars/token estimator and are scaled by
largest remainder to a provider-reported total. Each save records a bounded
overhead profile (counts and labels, no text) keyed by native session id, so
`ControlPlaneProvider.session_context_usage/2` can answer for stopped sessions from
durable history; without a profile, a measured total reports the overhead as
unattributed and an estimate-only cold read is unavailable.

### Tool Execution

Tools follow a pipeline: the LLM requests a tool call, `ToolRegistry` resolves it by name (checking builtin, then WASM, then extensions), `ToolPolicy` checks allow/deny, `ToolExecutor` gates on approval if required, and the tool module's `execute/4` closure runs with abort signal support.

Each tool module exposes `tool(cwd, opts)` returning an `%LemonAgent.Types.AgentTool{}` struct whose `execute` field is a 4-arity closure capturing `cwd` and `opts`.

### Model Resolution

`Session.ModelResolver` resolves models from string specs (`"provider:model_id"`), maps, or `%LemonAi.Types.Model{}` structs. API keys are resolved in order:
1. Provider environment variables (`ANTHROPIC_API_KEY`, etc.)
2. Plain `providers.<name>.api_key` in settings
3. `providers.<name>.api_key_secret` via `LemonCore.Secrets`
4. Default secret name `llm_<provider>_api_key`

OAuth payloads are handled by `LemonAgent.ModelRuntime.Credentials` with automatic refresh persistence.

### Compaction

When conversations grow large, auto-compaction kicks in:
1. The system estimates context size (messages + system prompt + tool schemas)
2. If over threshold, it finds valid cut points (not mid-tool-call)
3. An LLM summary of compacted messages is generated
4. A compaction entry is appended to the session tree
5. Overflow recovery handles cases where the context window is exhausted mid-run

Auto-compaction runs in a tracked background worker after a completed turn and
before dispatching a new prompt that would exceed the reserve threshold. A new
prompt cancels a stale background snapshot, then checks its own full request
budget (including the incoming message) before dispatch. Cancellation remains
available while this preflight compaction runs. Late results are ignored by
signature/state checks. Repeated compaction summarizes the previous summary
plus newly retired messages, preserving decisions, outstanding work and file
operations without repeatedly replaying the entire original transcript.

`Session.compact/2` forces manual compaction by default and waits for the summary
instead of timing out after five seconds. It accepts `:custom_instructions` or
an explicit `:summary`; compacting or switching branches while a turn is
streaming returns `{:error, :busy}`. Summaries use the session's configured
provider credentials. Compaction start/completion events are forwarded to
terminal and ACP clients.

Settings: `compaction_enabled` (default: true), `reserve_tokens` (default: 16,384), `keep_recent_tokens` (default: 20,000).

### Budget Tracking

Budgets track token and cost usage per run. The `RunGraph` maintains parent/child relationships with DETS persistence. Budgets cascade: subagents inherit (and can further restrict) parent limits. Token/cost increments are atomic, child ids reserve `max_children` capacity atomically, and repeated child completion notifications aggregate usage exactly once before releasing the slot. The state machine enforces monotonic transitions (`queued -> running -> completed|error|killed|cancelled|lost`).

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

Named-node session-token records are separate from TOML settings. They live at
`~/.lemon/nodes/execution/<sha256-of-durable-node-id>.json`, include the exact
controller URL, and are reused only when that URL matches. Durable-ID lookup
requires that exact controller argument before it returns session or recovery
material. A controller-issued node session token currently expires after seven
days. The CLI does not refresh it automatically; re-run with `--pair` and
operator authority to recover the same durable identity and rotate its session.
The controller invalidates the previous token and live socket immediately.

The worker sends a WebSocket ping every 25 seconds so the controller's idle
timeout does not interrupt live-node registration. During `--pair`, transient
socket loss resumes the same pairing ID; approving an already approved pairing
reissues a one-time challenge for the same durable node, including when the
previous challenge response was lost after token issuance.

Named-node requests and results use the controller's advertised `maxPayload`
byte limit (1 MiB by default) plus shared depth and item-count limits. Streaming
answer accumulation is cancelled before it can exceed that boundary, and the
worker returns a compact protocol error instead of retaining an unbounded
result.

### Application Environment

| Key | Default | Description |
|-----|---------|-------------|
| `:lane_caps` | `%{main: 4, subagent: 8, background_exec: 2}` | Per-lane concurrency caps for `LaneQueue` |
| `:task_max_concurrency` | `8` | Max concurrently executing native `task` children; excess children queue on the monitored semaphore |
| `:primary_session` | `nil` | Keyword list of opts to auto-start a session on boot |

### Workspace Bootstrap Files

`workspace_dir/0` is the assistant home bootstrap directory, not the active project root.
The active project boundary remains `cwd`.

Loaded from `~/.lemon/agent/workspace/` (initialized from `priv/templates/workspace/`):

| File | Scope | Purpose |
|------|-------|---------|
| `AGENTS.md` | main + subagent | Assistant-wide operating guidelines, separate from repository-local rules |
| `SOUL.md` | main only | Agent personality/identity |
| `TOOLS.md` | main + subagent | Tool documentation |
| `IDENTITY.md` | main only | Identity configuration |
| `USER.md` | main only | User preferences |
| `HEARTBEAT.md` | main only | Checklist the scheduled heartbeat cron job reads (`HEARTBEAT_OK` = nothing to report) |
| `BOOTSTRAP.md` | main only | Startup instructions |
| `MEMORY.md` | main only | Persistent memory (optional) |

### Coding Session Context

The default prompt treats Lemon as a coding agent: inspect relevant code before editing, use the tools actually available to the session, preserve user changes, finish the requested behavior, and report only verification that was observed. Behavioral changes call for focused checks and relevant edge cases—not an unrelated full-suite sweep. Read-only requests stay read-only. One-off coding tasks do not require creating skills or saving temporary facts merely to finalize.

Use `todo` for a multi-step task when tracking is useful. Create or replace the task list, including changed statuses, with `action: "write"` and the full `todos` list. `action: "progress"` only reads completion counts; it does not update tasks.

Repository instructions load from global home locations first, followed by ancestors from filesystem root to the working directory. Each directory includes its root, `.claude/`, and `.lemon/` `AGENTS.md`/`CLAUDE.md` files. Source headers state the applicable directory scope; deeper instructions override broader guidance. Duplicate symlink or hard-link aliases load once using their most specific location.

At session start, Lemon captures the actual Git worktree root, branch/status, a bounded top-level layout, and descendant instruction-file paths. The index lists paths, not file contents: read applicable guides not already injected before editing their directories. Git-backed discovery respects ignored untracked files and excludes generated trees; non-Git discovery uses a bounded traversal without following symlinks. Truncated or unavailable discovery is explicitly labelled, so an omitted path is not proof that a guide does not exist.

This environment snapshot is appended after the stable prompt and reused across turns to preserve provider caching. It does not update as files or branches change; use tools for fresh state when needed. Assistant-home identity and memory remain separate from repository context, missing/empty bootstrap files are omitted, and subagents still receive only the allowed `AGENTS.md`/`TOOLS.md` workspace files.


## Usage Examples

### Starting a Session

```elixir
# Under supervision (preferred)
{:ok, session} = CodingAgent.start_session(
  cwd: "/path/to/project",
  model: LemonAi.Models.get_model(:anthropic, "claude-sonnet-4-20250514"),
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

Recurring check-ins are cron jobs flagged as heartbeats, not session state;
see [`docs/user-guide/reminders-and-heartbeats.md`](../../docs/user-guide/reminders-and-heartbeats.md).

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
  %{prompt: "Analyze the code", subagent: "scout"},
  %{prompt: "Review for bugs", subagent: "reviewer"}
], timeout: 60_000)
```

### Running on a Named Execution Node

Start the controller on one machine, then join from the destination source
checkout. The first command pairs and stores the controller-issued session
token; subsequent starts omit `--pair`:

```bash
# destination machine
LEMON_NODE_OPERATOR_TOKEN=... ./bin/lemon node join \
  --name worker-1 \
  --controller wss://controller.example/ws \
  --pair \
  --cwd /srv/project

./bin/lemon node join \
  --name worker-1 \
  --controller wss://controller.example/ws \
  --cwd /srv/project
```

The private record is keyed by durable node ID, not the launch name. A
controller rename therefore survives destination restarts. Re-run with
`--pair` after the seven-day session expires; recovery keeps the existing
identity and name reservation and revokes older sessions. For a legacy record
that has a node ID but no recovery credential, use the explicit
operator-authorized `--pair --repair --node-id ID` migration path.

Non-loopback plaintext controllers are rejected by default. Prefer `wss://`.
For a development endpoint or a verified encrypted overlay such as Tailscale,
add `--allow-insecure-controller` (or set
`LEMON_NODE_ALLOW_INSECURE_CONTROLLER=true`) explicitly; do not use that
override on an unverified network.

Once `worker-1` is online, a model can route a delegated run through the
`agent` tool with parameters such as:

```json
{
  "action": "run",
  "agent_id": "default",
  "prompt": "Run the focused tests and report failures.",
  "node": "worker-1"
}
```

An explicit abort cancels the registry invocation and sends
`node.invoke.cancel` to the targeted worker. Node disconnects fail pending
invocations. Steering and redirect operations are not supported across this
remote boundary.

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
| `httpoison` | ~> 3.0 | Security-patched HTTP transport override required by `readability` |
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

The test suite covers 90+ test files including unit tests for all tools, session management, budget tracking, extensions, WASM integration, and coordinator orchestration. Tests use temporary directories and direct `start_link` (not supervised).
