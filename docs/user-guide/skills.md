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

Runs the audit engine against the skill. Outputs pass/warn/block verdicts with reasons.

---

## Installing Skills

### From a local path

```bash
mix lemon.skill install /path/to/skill-directory
```

Copies the skill into `~/.lemon/agent/skills/` (global) or `.lemon/skills/` (project).

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

Trust policy: official registry skills are trusted by default. Third-party sources
require explicit trust approval.

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

The audit engine (`LemonSkills.Audit.Engine`) runs 5 rules against every skill:

| Rule | Verdict when failing |
|---|---|
| Valid manifest v2 schema | `:block` |
| Name field present and non-empty | `:block` |
| Description field present | `:warn` |
| No banned patterns (secrets, shell injection) | `:block` |
| Required tools declared | `:warn` |

Run `mix lemon.skill check <key>` to see the full audit report.

Skills with `:block` verdicts cannot be promoted or activated by the runtime.
Skills with `:warn` verdicts load but show a warning in doctor output.

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
> engine runs automatically during generation — drafts with `:block` findings are
> never written to disk.

See [`docs/user-guide/adaptive.md`](adaptive.md) for the full synthesis pipeline.

---

## Skill Locations

| Scope | Path |
|---|---|
| Global | `~/.lemon/agent/skills/` |
| Project | `<cwd>/.lemon/skills/` |
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
