# Skills User Guide

Skills are reusable knowledge modules that Lemon loads into context when relevant.
They capture task patterns, approaches, and domain knowledge so you don't have to
repeat yourself across sessions.

---

## What Is a Skill?

A skill is a directory containing:

- **`SKILL.md`** — the skill body: YAML frontmatter (metadata) + Markdown content
- **`AGENTS.md`** (optional) — instructions for AI agents using this skill

### Skill frontmatter (manifest v2)

```yaml
---
name: "Deploy to Kubernetes"
description: "Apply a Kubernetes deployment manifest with resource limits and rolling updates"
requires_tools:
  - bash
metadata:
  lemon:
    category: engineering
---

# Deploy to Kubernetes

## Task Pattern

...
```

Key fields:

| Field | Purpose |
|---|---|
| `name` | Human-readable display name |
| `description` | One-line summary shown in skill listings |
| `requires_tools` | Tools that must be available for this skill to activate |
| `metadata.lemon.category` | Routing category (`engineering`, `knowledge`, `filesystem`, `general`) |

---

## Listing Skills

```bash
mix lemon.skill list
```

Shows all installed skills with name, source, and status.

Filter by category:

```bash
mix lemon.skill list --category engineering
```

---

## Inspecting a Skill

```bash
mix lemon.skill inspect <skill-key>
```

Prints the full skill content including frontmatter, description, and body.

Check for manifest issues:

```bash
mix lemon.skill check <skill-key>
```

Shows readiness, local drift, and upstream status for the installed skill.

Agents also have a `read_skill` tool in the default native Lemon tool set. The
system prompt lists installed skills by key and tells the agent to call
`read_skill` before following any clearly relevant skill, so skill instructions
can be loaded on demand without injecting every full `SKILL.md` body up front.

Agents can also maintain procedural memory with `skill_manage`. Use project
scope for repository-specific workflows and global scope for reusable workflows.
The tool can create, edit, patch, delete, and maintain supporting files under
`references/`, `templates/`, `scripts/`, and `assets/`; each write is audited
before the registry is refreshed. Use `action="report"` to inspect usage and
stale/archive candidates before pinning, archiving, restoring, or deleting
agent-authored skills.

Use skills for procedures, not for every remembered fact. A good skill captures
repeatable steps: commands, preconditions, checks, rollback paths, API quirks, or
project conventions that should guide future runs. Use `memory_topic` instead
for durable facts, preferences, decisions, people, dates, or project context.
Use `search_memory` to recall previous run history before answering "last time"
questions, and use `todo` only for the active run's work queue.

---

## Installing Skills

### From a local path

```bash
mix lemon.skill install /path/to/skill-directory
```

Copies the skill into `~/.lemon/agent/skill/` (global) or `.lemon/skill/` (project).

### From a remote source

```bash
mix lemon.skill install github:org/repo//skills/my-skill
```

Source types: `github:`, `gitlab:`, `local:`, `registry:`.

### From the official registry

```bash
mix lemon.skill browse         # Browse available skills
mix lemon.skill install registry:lemon-official/git-workflow
```

Trust policy: built-in skills skip audit. All other skills are audited on install/update; `:warn`
verdicts require explicit approval and `:block` verdicts are refused.

---

## Updating Skills

```bash
mix lemon.skill update <skill-key>   # Update one skill
mix lemon.skill update --all         # Update all skills from their sources
```

---

## Removing Skills

```bash
mix lemon.skill remove <skill-key>
```

---

## Quality Checks

The audit engine (`LemonSkills.Audit.Engine`) runs deterministic security checks for:

- destructive commands
- remote execution patterns
- data exfiltration patterns
- path traversal
- symlink / escape patterns

Audits are bundle-aware. Lemon hashes `SKILL.md` plus supported files under `references/`,
`templates/`, `scripts/`, and `assets/`, rejects symlinked bundle entries, stores detailed
results in `skills.audit.json`, and automatically rescans when the bundle or audit fingerprint
changes.

If configured, Lemon also runs `LemonSkills.Audit.LlmReviewer` to classify higher-level suspicious or malicious intent across the bundle payload.

Run `mix lemon.skill check <key>` to see readiness, drift, and the installed skill's current status.

Install/update behavior:

- `:pass` continues normally
- `:warn` requires explicit approval before the skill is kept
- `:block` refuses the operation

Optional LLM audit config:

```elixir
config :lemon_skills, :audit_llm,
  enabled: true,
  model: "openai:gpt-4o-mini"
```

Audit state files:

- global: `~/.lemon/agent/skills.audit.json`
- project: `<cwd>/.lemon/skills.audit.json`

---

## Skill Drafts (Synthesized Skills)

Lemon can automatically generate draft skills from your past successful runs.
Enable the feature flag first:

```toml
[features]
skill_synthesis_drafts = "default-on"
```

Then generate drafts from recent agent memory:

```bash
mix lemon.skill draft generate --agent <agent-id>
```

Review a draft:

```bash
mix lemon.skill draft list
mix lemon.skill draft review <draft-key>
```

Promote a draft to an installed skill (after manual review):

```bash
mix lemon.skill draft publish <draft-key>
```

Delete a draft:

```bash
mix lemon.skill draft delete <draft-key>
```

> **Note:** Synthesized drafts require human review before promotion. The audit
> engine runs automatically during generation. Drafts with `:block` findings are
> deleted immediately, and drafts with `:warn` findings are kept but require
> approval on promotion.

See [`docs/user-guide/adaptive.md`](adaptive.md) for the full synthesis pipeline.

## Skill Curation

Lemon tracks load/write counts and lifecycle state outside `SKILL.md` in
`skills.usage.json`. Agent-authored skills can be reported, pinned, archived,
or restored with `skill_manage`.

For a maintenance pass:

```bash
mix lemon.skill curator status
mix lemon.skill curator run --prompt
```

The run marks idle agent-authored skills `stale`, archives long-idle candidates
by disabling them, and reactivates stale skills that were used again. It never
deletes skills and skips pinned or non-agent-authored entries. `--prompt` prints
a curator prompt for an agent to consolidate narrow learned skills into broader
umbrella skills with `read_skill` and `skill_manage`. The prompt asks the agent
to patch existing class-level skills first, update supporting files when useful,
and create a new umbrella skill only when no existing skill fits.

Every run also writes `run.json` and `REPORT.md` under
`.lemon/logs/curator/<run>/` for project skills, or
`~/.lemon/agent/logs/curator/<run>/` for global skills. The JSON report is the
machine-readable audit record; the markdown report is the quick human review.
When a background curator run submits an agent review, the report records the
submitted review run id.

The runtime also has an idle background curator path. When enabled, Lemon waits
for active router sessions to drain, applies the same interval/pause gates, and
submits the curator prompt to the configured agent only when review is required.
Those background reviews default to the learning tools only: `read_skill`,
`skill_manage`, `search_memory`, and `memory_topic`.

---

## Skill Locations

| Scope | Path |
|---|---|
| Global | `~/.lemon/agent/skill/` |
| Project | `<cwd>/.lemon/skill/` |
| Global drafts | `~/.lemon/agent/skill_drafts/` |
| Project drafts | `<cwd>/.lemon/skill_drafts/` |

Project skills take precedence over global skills with the same key.

---

## Feature Flags

Skills-related feature flags in `~/.lemon/config.toml`:

```toml
[features]
skill_manifest_v2            = "default-on"   # manifest v2 parser (required for new skills)
progressive_skill_loading_v2 = "default-on"   # lazy body loading (saves context tokens)
skills_hub_v2                = "default-on"   # full hub UX
skill_synthesis_drafts       = "off"          # auto-generate drafts from memory
```

*Last reviewed: 2026-03-16*
