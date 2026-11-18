# Long-Running Agent Harnesses

This guide documents Lemon's long-running harness primitives used to keep coding sessions structured across multi-step work.

## Why this exists

Long-running implementation tasks can drift when the agent has no durable task model. Lemon now provides:

- feature requirement files (`FEATURE_REQUIREMENTS.json`)
- todo dependency/progress tracking
- checkpoint/resume snapshots plus preview filesystem rollback snapshots

## Core modules

- `CodingAgent.Tools.FeatureRequirements`
  - Generate/save/load/update feature requirement files
  - Compute requirement progress and next actionable features
- `CodingAgent.Session.Todos`
  - Branch-scoped todo journal: each successful `todo` write appends the complete
    list to the session history, so rewind, navigation, resume and forks agree
- `CodingAgent.Tools.TodoStore`
  - ETS projection of each session's selected-branch list for out-of-session readers
  - Progress stats and actionable todo filtering with dependency + priority semantics
- `CodingAgent.Checkpoint`
  - Create/list/resume/delete checkpoint files under `System.tmp_dir()/lemon_checkpoints`
  - Resume returns checkpointed todos as data; it does not replace a session's list
  - Store filesystem snapshots for file-tool rollback
  - Preview diff and restore all or selected paths from filesystem checkpoints
- `CodingAgent.BackgroundRun`
  - Starts an isolated native session, capped by the destination agent's
    tool-policy floor, and immediately returns a durable id
  - Lists, inspects, retrieves, and cooperatively cancels background work
  - Derives the destination agent from the parent session key; no transcript
    is copied
- `CodingAgent.SideQuery`
  - Answers a bounded no-tools question from an immutable live context snapshot,
    a durable channel session key, or an explicit transcript snapshot
  - Uses a separate ephemeral session and never appends to the source conversation

## Hermes background and side-query APIs

`CodingAgent.BackgroundRun.start(prompt, opts)` returns
`{:ok, %{id: id, status: :queued}}`. Surfaces can use
`BackgroundRun.list/1`, `status/1`, `result/1`, and `cancel/2` for the rest of
the lifecycle. The worker runs through the native coding session and subagent
lane. Its session key is `background:<id>`; `opts[:session_key]` is stored as
parent lineage and also names the destination agent, so a channel `/bg` (which
sends only the session key, cwd, model and thinking level) runs as that agent:
its `agent_id` comes from the key, its tool policy is capped by
`profiles.<agent>.tool_policy` intersected with the profile store
`toolPolicy` (the same floor native runs use), and a profile-bound agent uses
the profile workspace instead of the owner default. An unparseable key with no
live parent, a requested parent that is not available, or a profile-store read
error rejects the start before any task record is written; none of them falls
back to full access.
Runtime error terms are retained only in the internal task record. Public
status/results expose stable classifications; control-plane projections use
content-free `errorCode` values and discard arbitrary provider fields.

`CodingAgent.SideQuery.ask(source, question, opts)` returns the visible answer
synchronously. `source` accepts a live session pid/id, a durable Lemon channel
session key, or a `%{messages: messages, system_prompt: prompt}` map. Side
queries are capped at 30 seconds by default (120 seconds maximum), explicitly
set `tools: []`, and run under their own `side_query:*` session key.
Failures are reported with stable bounded codes rather than provider messages,
paths, or credential-bearing details.

## Validation commands

```bash
mix test apps/coding_agent/test/coding_agent/tools/feature_requirements_test.exs \
  apps/coding_agent/test/coding_agent/tools/todo_store_test.exs \
  apps/coding_agent/test/coding_agent/session/todos_test.exs \
  apps/coding_agent/test/coding_agent/checkpoint_test.exs
```
