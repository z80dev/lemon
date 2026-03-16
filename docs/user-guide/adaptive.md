# Adaptive Behavior User Guide

Lemon learns from past runs to make better routing and skill decisions.
All adaptive features are off by default and controlled by feature flags.

---

## Overview

There are three adaptive subsystems:

| Subsystem | Feature flag | What it does |
|---|---|---|
| Routing feedback | `routing_feedback` | Records run outcomes to inform future model/engine selection |
| History-aware routing | `routing_feedback` | Uses past success/failure signals to break ties in model selection |
| Skill synthesis | `skill_synthesis_drafts` | Auto-generates draft skills from successful runs |

Enable all adaptive features:

```toml
[features]
routing_feedback       = "default-on"
skill_synthesis_drafts = "default-on"
```

---

## Routing Feedback

### What gets recorded

After every completed run, Lemon stores a feedback entry keyed by task fingerprint:

```
<task_family>|<toolset>|<workspace>|<provider>|<model>
```

For example:
```
code|bash,read_file|/home/user/myproject|anthropic|claude-sonnet-4-20250514
```

The entry records: outcome (`:success`/`:failure`/`:partial`), duration in milliseconds,
and a timestamp.

### How it influences routing

With `routing_feedback` enabled, the model selection precedence becomes:

```
explicit_model
  → meta_model (per-run override)
    → session_model (per-session override)
      → profile_model (config profile)
        → history_model  ← NEW: best model for this task fingerprint
          → default_model
```

`history_model` is the model with the highest success rate for the current task's
fingerprint context (task family + toolset + workspace). It only kicks in when
no higher-precedence model is set.

### Viewing feedback data

```bash
mix lemon.feedback report                 # Aggregate success rates by fingerprint
mix lemon.feedback report --top 10        # Top 10 task fingerprints
mix lemon.feedback report --model <name>  # Filter by model
```

---

## Skill Synthesis

### How it works

The synthesis pipeline runs on demand and processes recent memory documents:

1. **Candidate selection** — filters runs by quality criteria:
   - Outcome must be `:success` or `:partial`
   - `prompt_summary` ≥ 50 characters, `answer_summary` ≥ 100 characters
   - No secret patterns in content
   - Task family not `:chat` (conversational) or `:unknown`
   - Deduplicates by normalized prompt content (most recent wins)

2. **Draft generation** — converts each candidate into a SKILL.md with:
   - URL-safe key prefixed with `synth-`
   - YAML frontmatter: name, description, requires_tools, category, `synthesized: true`
   - Body: task pattern from prompt_summary, approach from answer_summary, date generated

3. **Audit** — the audit engine runs the 5 quality rules. Drafts with `:block` findings
   are discarded; `:warn` findings are acceptable (human review required anyway).

4. **Storage** — passing drafts are written to `~/.lemon/agent/skill_drafts/<key>/`.

### Generating drafts

Enable the feature flag:

```toml
[features]
skill_synthesis_drafts = "default-on"
```

Then generate from your recent memory:

```bash
# From agent memory (most common)
mix lemon.skill draft generate --agent <agent-id>

# From a specific session
mix lemon.skill draft generate --session <session-key>

# From a workspace
mix lemon.skill draft generate --workspace <path> --cwd <path>

# Limit the number of documents scanned
mix lemon.skill draft generate --agent <agent-id> --max-docs 100
```

### Reviewing drafts

```bash
mix lemon.skill draft list
```

Shows key, creation date, and audit status for each draft.

```bash
mix lemon.skill draft review <draft-key>
```

Prints the full SKILL.md content so you can edit it before promoting.

### Editing before promotion

Drafts are plain files in `~/.lemon/agent/skill_drafts/<key>/SKILL.md`.
Edit them directly — update the name, description, or body to better capture
the intent.

### Promoting a draft to an installed skill

```bash
mix lemon.skill draft publish <draft-key>
```

Runs a final audit check, then installs the skill into `~/.lemon/agent/skills/`.
The draft directory is removed after successful promotion.

### Discarding a draft

```bash
mix lemon.skill draft delete <draft-key>
```

### Example workflow

```bash
# After a few productive sessions:
mix lemon.skill draft generate --agent my-agent

# See what was generated:
mix lemon.skill draft list
# synth-deploy-kubernetes    2026-03-15  3 candidates  pass
# synth-configure-nginx      2026-03-14  1 candidate   warn

# Review and edit the best one:
mix lemon.skill draft review synth-deploy-kubernetes
$EDITOR ~/.lemon/agent/skill_drafts/synth-deploy-kubernetes/SKILL.md

# Promote it:
mix lemon.skill draft publish synth-deploy-kubernetes
# ✓ Installed: deploy-kubernetes
```

---

## Task Families

The routing and synthesis systems classify every task into a family:

| Family | Description | Example prompts |
|---|---|---|
| `:code` | Writing, debugging, or refactoring code | "Implement a deployment script" |
| `:query` | Explaining, documenting, or researching | "Explain how Kubernetes works" |
| `:file_ops` | Reading, writing, or organizing files | "Find all TODO comments in src/" |
| `:chat` | Conversational, no actionable task | "Yes, thanks, sounds good" |
| `:unknown` | Could not classify | (very short or ambiguous) |

`:chat` and `:unknown` runs are excluded from skill synthesis candidates.

---

## Configuration Reference

```toml
[features]
routing_feedback       = "off"   # "off" | "opt-in" | "default-on"
skill_synthesis_drafts = "off"

[memory]
retention_days = 90       # How long to keep memory documents
max_documents  = 10000    # Hard cap before oldest documents are pruned
```

---

## Further Reading

- [`docs/user-guide/memory.md`](memory.md) — Memory documents and session search
- [`docs/user-guide/skills.md`](skills.md) — Full skills user guide
- [`docs/memory/session_search_and_feedback.md`](../memory/session_search_and_feedback.md) — Internal design notes

*Last reviewed: 2026-03-16*
