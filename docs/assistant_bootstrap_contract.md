# Lemon Assistant Bootstrap Contract

This document defines the runtime contract for Lemon's assistant bootstrap context.

## Execution Modes

Lemon runs in one of three mutually exclusive execution modes. Later milestones (M1, M2) must remain consistent with these definitions.

| Mode | Description |
| --- | --- |
| `source_dev` | Running directly from source via `bin/lemon-dev` or `iex -S mix`. Used for local development. Configuration is read from `config/dev.exs` and Mix runtime. |
| `release_runtime` | Running from a compiled Elixir release (`lemon_runtime_min` or `lemon_runtime_full`). Configuration is read from `config/runtime.exs` and environment variables only. No Mix tooling available. |
| `attached_client` | A lightweight client (TUI or web) attached to a running release via the channel/gateway layer. The client does not execute agent logic directly; it submits requests and streams responses. |

These modes are detected at boot by `LemonCore.Runtime` (once extracted in M1-01). All boot-path decisions must be gated on mode rather than Mix environment atoms to avoid drift between source and release.

## Scope

Lemon composes a system prompt from:

1. Explicit `:system_prompt` option (if provided)
2. Prompt template (if provided)
3. Lemon base prompt (skills + workspace bootstrap context)
4. Instruction files from `ResourceLoader` (`CLAUDE.md`, `AGENTS.md`)

The composed prompt is refreshed before each user prompt so file edits in workspace context are picked up without restarting the session.

## Workspace Bootstrap Files

Workspace bootstrap lives in `~/.lemon/agent/workspace` (or `:workspace_dir` override) and is auto-initialized on session startup.

Canonical files:

- `AGENTS.md`
- `SOUL.md`
- `TOOLS.md`
- `IDENTITY.md`
- `USER.md`
- `HEARTBEAT.md`
- `BOOTSTRAP.md`
- `MEMORY.md` (long-term memory, main sessions only)

Daily memory files are expected under `memory/YYYY-MM-DD.md` and are read/written via tools.

## Memory Scopes

Lemon uses four frozen memory scopes. New stores must be placed in one of these scopes; no additional scopes may be introduced without updating this document.

| Scope | Owner store location | Lifetime | Description |
| --- | --- | --- | --- |
| `session` | `lemon_core` (run/session stores) | Single agent run | Per-run state: messages, tool calls, context window. Discarded when the run ends. |
| `workspace` | `lemon_core` (workspace store) | Workspace lifetime | Project-level persistent memory tied to a workspace directory. Survives individual runs. |
| `agent` | `lemon_core` (agent memory store) | Agent lifetime | Cross-run memory for a specific agent identity. Shared across workspaces for the same agent. |
| `global` | `lemon_core` (global store) | Installation lifetime | Installation-wide configuration and state. Shared across all agents and workspaces. |

Architecture placement rule: all scope-owning stores live in `lemon_core`. No other app may own a scope-level store. `coding_agent` and `lemon_router` may read from stores but must not define new scope boundaries.

## Session Scoping

Bootstrap injection is session-scoped:

- Main sessions: full bootstrap context, including `MEMORY.md`.
- Subagent sessions: restricted bootstrap context (`AGENTS.md`, `TOOLS.md` only).

Subagent scope is inferred from `:parent_session` when present, or can be set explicitly via `:session_scope`.

## Memory Workflow Policy

Main-session prompt policy requires the assistant to:

- Inspect `MEMORY.md` and relevant daily memory files before answering memory-dependent questions.
- Use `read` for recall, `write` to create daily files, and `edit` for curated updates.
- Persist user-requested memories to files, not ephemeral reasoning.

Subagent prompt policy forbids reading/updating `MEMORY.md` unless explicitly requested by the parent task.
