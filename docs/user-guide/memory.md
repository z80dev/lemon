# Memory User Guide

Lemon records every run as a **memory document** — a structured summary of what was asked
and what was done. This lets you search across past sessions, avoid repeating yourself, and
build a persistent knowledge base about how you work.

---

## How Memory Works

When a run completes, the runtime records a `MemoryDocument` with:

| Field | Description |
|---|---|
| `prompt_summary` | Condensed version of what you asked |
| `answer_summary` | Condensed version of what the agent did |
| `tools_used` | List of tool names invoked during the run |
| `outcome` | `:success`, `:partial`, `:failure`, `:aborted`, or `:unknown` |
| `provider` / `model` | Which LLM handled the run |
| `workspace_key` | Project directory (if bound) |
| `session_key` | Session identifier |
| `ingested_at_ms` | Unix timestamp (milliseconds) |

The built-in provider stores memory documents in `memory.sqlite3` under the
configured Lemon store directory. The default store directory is
`~/.lemon/store`; set `LEMON_STORE_PATH` or `:lemon_core, LemonCore.Store`
backend options to use another location.

`LemonCore.MemoryProviders` is the supervised provider boundary. Lemon always
registers the local SQLite provider, and BEAM extensions can register additional
memory providers that receive the same safety-screened `MemoryDocument` ingest
events and participate in scoped search. Provider failures are isolated; a slow
or broken external provider must not block run finalization or broaden search
scope.

---

## Searching Memory

The `search_memory` and `session_search` tools are available to agents for
no-LLM recall over past runs.

For coding sessions, Lemon distinguishes between:

- **Project root (`cwd`)**: the active repo or directory where commands and file edits run
- **Assistant home**: the persistent bootstrap home at `~/.lemon/agent/workspace`

`search_memory` supports both boundaries:

- `scope: "current"`: search project root plus assistant home
- `scope: "project"`: search the active `cwd` only
- `scope: "home"`: search the assistant home only
- `scope: "session"` / `"agent"` / `"all"`: narrower or broader search across prior runs

`scope: "workspace"` is kept as a compatibility alias for `current`.

`session_search` is the Hermes-compatible calling shape. It infers the mode from
arguments:

- pass `query` for discovery across durable Lemon memory documents
- pass `session_id` plus `around_message_id` to scroll a bounded run-history
  window in that session
- pass no args to browse recent runs in the current session

Use `session_search` when a prompt or imported workflow explicitly asks for
Hermes-style session search. Use `search_memory` when Lemon-native scope control
is more important.

Enable it in your config:

```toml
[features]
session_search = "default-on"
```

Once enabled, your agent can answer questions like:

> "What did I use to deploy that k8s app last week?"
> "Remind me how I configured the nginx reverse proxy."

The agent automatically searches memory when it detects that a question is about past work.

### Which persistence surface should agents use?

Lemon has several memory-adjacent tools. They are intentionally separate:

| Need | Use | Why |
|---|---|---|
| Recall what happened in previous runs | `search_memory` / `session_search` | Searches completed run summaries and tool traces; `session_search` also supports Hermes-style browse/scroll calls |
| Store compact profile facts or curated quick facts | `memory` | Updates bounded assistant-home `USER.md` or `MEMORY.md` safely |
| Store a longer durable fact, preference, decision, person, date, or project context | `memory_topic` | Creates structured topic notes under `memory/topics/` |
| Capture a repeatable procedure, command sequence, integration, debugging playbook, or checklist | `skill_manage` | Creates or updates an audited reusable skill |
| Track the current run's work queue | `todo` | Keeps transient progress for this session only |
| Inspect user-editable workspace notes | `read` / `grep` | Opens `USER.md`, `MEMORY.md`, `memory/topics/*.md`, or daily notes directly |

Use `memory` for short notes that are injected into the assistant prompt:
stable facts about the human belong in `USER.md`, and curated quick facts or
topic links belong in `MEMORY.md`. Use `memory_topic` for durable context that
needs more structure or room, not for step-by-step procedures. Use
`skill_manage` for procedures the agent should be able to repeat. Use `todo`
for active work only; todos are not long-term memory.

### Compact profile memory

The `memory` tool operates only inside assistant home, never the active project
root:

| Target | File | Limit | Purpose |
|---|---|---:|---|
| `user` | `~/.lemon/agent/workspace/USER.md` | 1,375 chars | Stable profile facts and preferences about the human |
| `memory` | `~/.lemon/agent/workspace/MEMORY.md` | 2,200 chars | Curated quick facts and links to topic notes |

Supported actions are `read`, `add`, `replace`, and `remove`. Add rejects
duplicates, replace/remove require a unique substring, and writes are rejected
when they would exceed the compact file limits. Because these files are injected
into the system prompt, writes are screened for common secret-looking strings,
prompt-injection phrases, NUL bytes, and invisible/bidirectional control
characters before they reach disk.

Bare `USER.md`, `MEMORY.md`, and `memory/...` paths resolve to the assistant
home for file tools when a session has `workspace_dir`; prefix with `./` if a
repo-local file with the same name is intentionally needed.

### Maintenance CLI

Search is exposed to agents through the `search_memory` tool. The current
management task exposes store maintenance commands:

```bash
mix lemon.memory stats
mix lemon.memory prune
mix lemon.memory erase --scope <session|agent|workspace> --key <value>
```

---

## Memory Management

### Retention and pruning

Memory documents older than the retention window are pruned automatically.
Default retention: **30 days** (configurable through the `LemonCore.MemoryStore`
application environment).

```toml
# config/runtime.exs or application env
config :lemon_core, LemonCore.MemoryStore,
  path: "~/.lemon/store",
  retention_ms: 30 * 24 * 60 * 60 * 1000,
  max_per_scope: 500
```

Manual prune:

```bash
mix lemon.memory prune               # Prune expired documents
```

### Erasing a scope

```bash
mix lemon.memory erase --scope session --key <session-key>
mix lemon.memory erase --scope agent --key <agent-id>
mix lemon.memory erase --scope workspace --key <workspace-key>
```

---

## Routing Feedback

Each completed run also records a **routing feedback entry** that tracks:

- Task fingerprint (task family + toolset + workspace + provider + model)
- Outcome (success/failure)
- Duration

This feedback powers the adaptive routing system. See
[`docs/user-guide/adaptive.md`](adaptive.md) for how it's used.

Enable routing feedback:

```toml
[features]
routing_feedback = "default-on"
```

---

## Skill Synthesis from Memory

When `skill_synthesis_drafts` is enabled, Lemon can mine your successful runs and
generate draft skills automatically. See [`docs/user-guide/adaptive.md`](adaptive.md)
and [`docs/user-guide/skills.md`](skills.md#skill-drafts-synthesized-skills).

---

## Storage Locations

| Scope | Database location |
|---|---|
| Default local provider | `~/.lemon/store/memory.sqlite3` |
| Custom store path | `<LEMON_STORE_PATH>/memory.sqlite3` |

## Provider Diagnostics

Support bundles include `memory_diagnostics.json`. It reports provider count,
enabled provider count, provider ids, sources, scopes, timeout shape, and module
load state. The same provider shape is available through read-only
`memory.status` and Web `/ops`. These surfaces do not include memory document
contents, raw provider config, secret values, prompts, tool output, or provider
error payloads.

---

## Privacy and Secrets

Before a run is stored as a memory document, Lemon's candidate selector scans
`prompt_summary` and `answer_summary` for common secret patterns:

- `password=` key-value pairs
- API key patterns (`sk-...`, `AKIA...`)
- PEM headers (`-----BEGIN ... KEY-----`)
- JWT-like tokens (`eyJ...`)

If any pattern matches, the run is **not** recorded. You can also manually delete
a document if you need to remove a past entry.

---

## Feature Flags

```toml
[features]
session_search       = "off"        # full-text search across past runs
routing_feedback     = "off"        # record outcome signals for adaptive routing
skill_synthesis_drafts = "off"      # auto-generate skill drafts from memory
```

*Last reviewed: 2026-05-16*
