# Long-Running Agent Harnesses

This guide documents Lemon's long-running harness primitives used to keep coding sessions structured across multi-step work.

## Why this exists

Long-running implementation tasks can drift when the agent has no durable task model. Lemon now provides:

- feature requirement files (`FEATURE_REQUIREMENTS.json`)
- todo dependency/progress tracking
- checkpoint/resume snapshots
- unified progress snapshots
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
- `CodingAgent.Progress`
  - Aggregates todo + requirements + checkpoint stats into one snapshot payload

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
