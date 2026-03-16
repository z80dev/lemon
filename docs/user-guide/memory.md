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

Memory documents are stored in a SQLite database at `~/.lemon/memory.db` (global) and
optionally `<cwd>/.lemon/memory.db` (project-scoped).

---

## Searching Memory

The `search_memory` tool (available to agents) runs a full-text search over past runs.

Enable it in your config:

```toml
[features]
session_search = "default-on"
```

Once enabled, your agent can answer questions like:

> "What did I use to deploy that k8s app last week?"
> "Remind me how I configured the nginx reverse proxy."

The agent automatically searches memory when it detects that a question is about past work.

### Manual search (CLI)

```bash
mix lemon.memory search "kubernetes deployment"
mix lemon.memory search --agent <agent-id> "docker build"
mix lemon.memory search --session <session-key> "fix bug"
```

---

## Memory Management

### Viewing recent memory

```bash
mix lemon.memory list                     # Recent documents (last 20)
mix lemon.memory list --limit 50          # More results
mix lemon.memory list --agent <agent-id>  # Filter by agent
```

### Retention and pruning

Memory documents older than the retention window are pruned automatically.
Default retention: **90 days** (configurable).

```toml
[memory]
retention_days = 90      # Documents older than this are pruned
max_documents  = 10000   # Hard cap per scope
```

Manual prune:

```bash
mix lemon.memory prune               # Prune expired documents
mix lemon.memory prune --dry-run     # Preview what would be pruned
mix lemon.memory prune --before 2026-01-01  # Prune documents before a date
```

### Deleting a specific document

```bash
mix lemon.memory delete <doc-id>
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
| Global (agent) | `~/.lemon/memory.db` |
| Project | `<cwd>/.lemon/memory.db` |

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

*Last reviewed: 2026-03-16*
