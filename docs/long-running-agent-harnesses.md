# Long-Running Agent Harnesses

This guide documents Lemon's long-running harness primitives used to keep coding sessions structured across multi-step work.

## Why this exists

Long-running implementation tasks can drift when the agent has no durable task model. Lemon now provides:

- feature requirement files (`FEATURE_REQUIREMENTS.json`)
- todo dependency/progress tracking
- checkpoint/resume snapshots plus preview filesystem rollback snapshots
- unified progress snapshots
- durable isolated background-command lifecycle and bounded no-tools side queries
- control-plane introspection via `agent.progress`

## Core modules

- `CodingAgent.Tools.FeatureRequirements`
  - Generate/save/load/update feature requirement files
  - Compute requirement progress and next actionable features
- `CodingAgent.Tools.TodoStore`
  - Session-scoped todo storage with dependency + priority semantics
  - Progress stats and actionable todo filtering
- `CodingAgent.Checkpoint`
  - Create/list/resume/delete checkpoint files under `System.tmp_dir()/lemon_checkpoints`
  - Store filesystem snapshots for file-tool rollback
  - Preview diff and restore all or selected paths from filesystem checkpoints
- `CodingAgent.Progress`
  - Aggregates todo + requirements + checkpoint stats into one snapshot payload
- `CodingAgent.BackgroundRun`
  - Starts an isolated native full-tool session and immediately returns a durable id
  - Lists, inspects, retrieves, and cooperatively cancels background work
  - Treats a parent session key strictly as lineage metadata
- `CodingAgent.SideQuery`
  - Answers a bounded no-tools question from an immutable live context snapshot,
    a durable channel session key, or an explicit transcript snapshot
  - Uses a separate ephemeral session and never appends to the source conversation

## Hermes background and side-query APIs

`CodingAgent.BackgroundRun.start(prompt, opts)` returns
`{:ok, %{id: id, status: :queued}}`. Surfaces can use
`BackgroundRun.list/1`, `status/1`, `result/1`, and `cancel/2` for the rest of
the lifecycle. The worker runs through the native coding session and subagent
lane with the default full toolset. Its session key is `background:<id>`;
`opts[:session_key]`, when present, is stored only as parent lineage.

`CodingAgent.SideQuery.ask(source, question, opts)` returns the visible answer
synchronously. `source` accepts a live session pid/id, a durable Lemon channel
session key, or a `%{messages: messages, system_prompt: prompt}` map. Side
queries are capped at 30 seconds by default (120 seconds maximum), explicitly
set `tools: []`, and run under their own `side_query:*` session key.

## Progress snapshot API

`CodingAgent.Progress.snapshot/2`:

- input: `session_id`, optional `cwd` (default `.`)
- output includes:
  - `todos` progress stats
  - `features` progress stats (or `nil` if no requirements file)
  - `checkpoints` stats
  - `overall_percentage`
  - `next_actions` (`todos` + `features`)

## Control-plane method: `agent.progress`

JSON-RPC method exposed in `lemon_control_plane`.

### Params

- required: `sessionId`
- optional: `cwd`, `runId`, `sessionKey`, `agentId`

### Behavior

- returns current `CodingAgent.Progress.snapshot/2` payload
- includes a compact `summary` with todo/feature/checkpoint counts,
  next-action counts, overall percentage, and cleanup flags that avoid echoing
  next-action content, prompts, message bodies, credentials, or secrets
- emits introspection event `:agent_progress_snapshot`
- attaches optional run/session/agent metadata to introspection records when provided

## Validation commands

```bash
mix test apps/coding_agent/test/coding_agent/tools/feature_requirements_test.exs \
  apps/coding_agent/test/coding_agent/tools/todo_store_test.exs \
  apps/coding_agent/test/coding_agent/checkpoint_test.exs \
  apps/coding_agent/test/coding_agent/progress_test.exs

mix test apps/lemon_control_plane/test/lemon_control_plane/methods/introspection_methods_test.exs
```
