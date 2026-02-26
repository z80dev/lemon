# Lemon Assistant Bootstrap Contract

This document defines the runtime contract for Lemon's assistant bootstrap context.

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
