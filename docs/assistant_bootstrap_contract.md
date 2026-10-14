# Lemon Assistant Bootstrap Contract

This document defines the runtime contract for Lemon's assistant bootstrap context.

## Execution Modes

Lemon runs in one of three mutually exclusive execution modes. Later milestones (M1, M2) must remain consistent with these definitions.

| Mode | Description |
| --- | --- |
| `source_dev` | Running directly from source via `bin/lemon-tui` or `iex -S mix`. Used for local development. Configuration is read from `config/dev.exs` and Mix runtime. |
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

Available skill metadata is part of the stable base prompt. Per-turn relevance matches are held only in authenticated session state for missed-skill introspection and telemetry; they are not appended to the system prompt or persisted/presented as user content. Full community/project skill content is loaded explicitly with `read_skill` and enters the model boundary as untrusted data. Audited bundled skill semantics whose installed bundle matches the release copy, plus intentional `AGENTS.md`/bootstrap instruction loading, are the explicit trusted instruction paths.

## Workspace Bootstrap Files

Workspace bootstrap lives in `~/.lemon/agent/workspace` (or `:workspace_dir` override) and is auto-initialized on session startup.

This directory is the assistant's persistent home for identity and long-lived notes.
It is distinct from the active project root / `cwd` used for repo-local config discovery,
shell execution, and session persistence.

Canonical files:

- `AGENTS.md`
- `SOUL.md`
- `TOOLS.md`
- `IDENTITY.md`
- `USER.md` (bounded profile and preference notes about the human)
- `HEARTBEAT.md` (checklist the scheduled heartbeat cron job works through; see [Reminders and heartbeats](user-guide/reminders-and-heartbeats.md))
- `BOOTSTRAP.md`
- `MEMORY.md` (bounded curated quick facts and topic index, main sessions only)

Daily memory files are expected under `memory/YYYY-MM-DD.md` and are read/written via tools.

### Placed profile sessions

Profile execution supplies a JSON-safe `profile_instructions` snapshot mapping
`AGENTS.md`, `IDENTITY.md`, `README.md` and `SOUL.md` to text, alongside
the profile's explicit `system_prompt`. Native sessions overlay this snapshot
in the existing bootstrap composition; they do not need controller-local profile
files and do not write the snapshot into destination files. Omitted snapshot
files do not inherit a stale destination persona. The overlay remains stable
through prompt refresh and follows the same truncation and subagent filtering
as disk bootstrap files.

The profile ID derives the assistant workspace on the execution host. Project
cwd, session journal paths, provider credentials, `TOOLS.md`, `USER.md`, `MEMORY.md`
and daily memory remain destination-local. `USER.md` is mutable preference
memory; controller snapshots cannot override it. An omitted remote cwd selects the worker's
default, never the controller's router cwd.
Explicit `profiles.sync` persists only the four controller-owned persona files
and a credential-free revision record; it acknowledges verified storage without
changing controller placement or transferring mutable memory.

Profile `mcp_servers` execution definitions contain streamable-HTTP `name`, `url`
and `headers`, plus optional exact `enabledTools` and origin consent policies.
The native run owner opens them through `LemonSkills.McpSession`. Profile
executions expose only their owner-bound connections (plus explicitly attached
ACP clients), never ambient machine-global MCP credentials, even when their
connector list is empty. Generic non-profile sessions retain configured clients.
Connections close when execution ends, initialization fails or the owner dies.
Headers are volatile execution credentials, not session management metadata.
`${LEMON_SECRET:NAME}` references in profile HTTP headers resolve through
`LemonCore.Secrets.get/1` on the executing host before any client starts.
Reference-bearing request metadata stays unchanged; resolved values are used
only in volatile connection configuration. No environment expansion or external
source fallback is performed. Missing/failing reads and malformed references
fail attachment with a credential-free `secret_resolution_failed` classification.
Origin-policy clients validate destination DNS and pin their real transport
before decrypting headers, preserve Host/TLS identity and reject redirects.
Per-invocation connector replacements never merge another principal's headers.

Before remote JSON encoding, private invocation/memory proof metadata keeps
canonical atom-key presence authoritative, including explicit `false` and
`nil`; snake/camel aliases cannot override it through duplicate JSON keys.
String-only meaningful proof, grant, context or proof-descriptor claims are
rejected rather than removed into legacy defaults. Existing negative presence
remains negative, and trusted positive canonical fields travel only as data
for the authenticated execution boundary's owning validation. This is not
generic model-map authority promotion. MCP/secret references remain unresolved.
Factory-only source profile/session identities, managed-context sentinels,
controller connection PID and generation, and native follow-up/floor callbacks
are excluded from execution JSON in all atom/snake/camel forms. The destination derives actual source
identities from its immutable native session options; body metadata cannot
select or attest a source profile/session.

Profile MCP aliases are stable public-identity hashes, exposed by discovery as
`executionName`. Credential rotation and DNS pinning do not change policy names.
Profile clients use native `ToolPolicy` as the execution/approval authority:
deny/blocked sets and required approvals cannot be bypassed by server hints or
invocation configuration. Persistent profile, invocation, session and
destination floors intersect on fresh admission. Active restriction changes
require the owning application's admission fence and settled cancellation.

Selected skills use the same destination-owned profile workspace as the skill
registry root, not a different project cwd. Metadata appears in the normal
available-skills section; `read_skill` loads bodies lazily from
`workspace/.lemon/skill/<key>/SKILL.md`. Bodies are not concatenated into the
profile system prompt or silently truncated to fit its 128 KiB limit.


## Memory Scopes

Lemon uses four frozen memory scopes. New stores must be placed in one of these scopes; no additional scopes may be introduced without updating this document.

| Scope | Owner store location | Lifetime | Description |
| --- | --- | --- | --- |
| `session` | `lemon_core` (run/session stores) | Single agent run | Per-run state: messages, tool calls, context window. Discarded when the run ends. |
| `workspace` | `lemon_core` (workspace store) | Workspace lifetime | Durable memory keyed by a directory boundary. In practice this may be a project root (`cwd`) or the assistant home directory, depending on the feature. Survives individual runs. |
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

- Use `remember` to add, replace, or remove compact facts in `USER.md` and `MEMORY.md`.
- Use `recall` to search past conversations and longer notes under `memory/`.
- Automatic recall may attach a bounded **Relevant memory** block to the user message.
- Persist user-requested memories to durable files, not ephemeral reasoning.

Subagent prompt policy forbids reading/updating `MEMORY.md` unless explicitly requested by the parent task.
