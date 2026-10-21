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
4. Instruction files from `ResourceLoader` (`CLAUDE.md`, `AGENTS.md`, `GEMINI.md`, Copilot and other agents' files), then always-apply rules and the rulebook index from `CodingAgent.Rules` — see [instruction files and rules](user-guide/context-files.md)

The composed prompt is refreshed before each user prompt so file edits in workspace context are picked up without restarting the session.

Tool usage guidance is emitted only for tools available in the session, in a fixed
order independent of registry ordering. Optional guidance covers blocking questions,
conversation exploration versus filesystem checkpoints, structural search/rewrites,
language-server navigation and rename, DAP debugging and external agent delegation.

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
Controller admission-row root binding maps (including nested profile/policy/
destination hashes) are likewise excluded; the owning admission store checks
them, never body-selected worker authority.

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

For context-owned Bot sessions, `USER.md` and `MEMORY.md` are virtual projections
of provenance-proven canonical **shared** preference facts from the existing
`LemonMemory.Preferences`/`LemonMemory.Store` owner. Unknown raw files and daily
notes remain retained but are not injected or searched by context-owned recall.
Private preferences enter bounded volatile recall instead of the static prefix.
Owner review/import must explicitly authorize exact facts before sharing; one
shared append never promotes unrelated legacy bytes. An unavailable shared store
or missing native proof never permits raw-file fallback.

## Memory Scopes

Lemon uses four frozen memory scopes. New stores must be placed in one of these scopes; no additional scopes may be introduced without updating this document.

| Scope | Owner store location | Lifetime | Description |
| --- | --- | --- | --- |
| `session` | `lemon_core` (run/session stores) | Single agent run | Per-run state: messages, tool calls, context window. Discarded when the run ends. |
| `workspace` | `lemon_core` (workspace store) | Workspace lifetime | Durable memory keyed by a directory boundary. In practice this may be a project root (`cwd`) or the assistant home directory, depending on the feature. Survives individual runs. |
| `agent` | `lemon_core` (agent memory store) | Agent lifetime | Cross-run memory for a specific agent identity. Shared across workspaces for the same agent. |
| `global` | `lemon_core` (global store) | Installation lifetime | Installation-wide configuration and state. Shared across all agents and workspaces. |

Scope identities and run/session stores remain owned by `lemon_core`; existing
durable document indexing, project facts and canonical preferences are owned by
`lemon_memory`. Consumers in `coding_agent`/`lemon_router` reuse those services
rather than creating parallel stores. Privacy is an ownership partition inside
the existing scope/store, not a fifth scope or a second product memory store.

Context-owned runs require a paired admitted `invocationContextKey` and stable
`memoryContextKey` with private native proof. Both keys are 1–128 ASCII characters
matching `[A-Za-z0-9][A-Za-z0-9_.:-]*`; only trusted runtime atom fields attest
admission, never model/tool/provider metadata. Stable Bot+user preference keys do
not include grant epochs; shared-room keys additionally bind actor, conversation
and authorized audience, never reuse a private DM key. Owning SQL filters this
partition before candidate limits and rechecks it on get/delete. Historical rows
without persisted proof are not backfilled or rewritten into private/shared
authority; retained claims alone cannot create proof, including through transfer.

## Session Scoping

Bootstrap injection is session-scoped:

- Legacy unscoped main sessions: existing full file bootstrap.
- Context-owned main sessions: allowed identity files plus canonical shared
  preference projections, never raw legacy/personal files.
- Subagent sessions: restricted bootstrap context (`AGENTS.md`, `TOOLS.md` only).

Subagent scope is inferred from `:parent_session` when present, or can be set explicitly via `:session_scope`.

## Memory Workflow Policy

Main-session prompt policy requires the assistant to:

- Use `remember` for compact user/memory/project facts. Context-owned saves stay
  private in the existing owner unless an authenticated trusted maintainer grant
  explicitly authorizes the exact new shared fact; tool booleans cannot authorize it.
- Use `recall` for exact owned summaries, canonical preferences and project facts.
  Context-owned reads exclude legacy/unproven rows and raw file bytes.
- Automatic recall attaches bounded **Relevant memory** after the cache breakpoint.
  Both contributor collection and initial/refreshed bootstrap receive the admitted
  ownership fields; proof failure skips rather than broadening the search.
- Automatic project capture always stays private, even with a shared-write grant.
- Automatic native skill synthesis excludes private/unproven indexed sources from
  profile/global draft files. Proven shared and legitimate legacy non-product
  sources retain eligibility; private Experiences use their existing owning flow.
- Local finalized-run ingest stamps original admitted root metadata; the destination
  execution worker also indexes its completed runs locally from a bounded original
  request snapshot, never provider/completion metadata or MCP credentials.
- Legacy unscoped CLI/operator file behavior is retained; product backends must
  always send explicit private/shared memory management selectors.

Subagents receive no personal bootstrap or memory tool authority. Inherited
context cannot broaden the parent scope, and a shared-write grant is not inherited.
