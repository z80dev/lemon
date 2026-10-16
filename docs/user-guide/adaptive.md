# Adaptive Behavior User Guide

Lemon learns from past runs to make better routing and skill decisions.
All adaptive features ship enabled by default and are controlled by feature
flags (each flag is an operator kill switch).

---

## Overview

There are three adaptive subsystems:

| Subsystem | Feature flag | What it does |
|---|---|---|
| Routing feedback | `routing_feedback` | Records run outcomes to inform future model selection |
| History-aware routing | `routing_feedback` | Uses past success/failure signals to break ties in model selection |
| Skill synthesis | `skill_synthesis_drafts` | Auto-generates draft skills from successful runs |

All adaptive features are on by default. To turn any of them off:

```toml
[features]
routing_feedback       = "off"
skill_synthesis_drafts = "off"
```

---

## Routing Feedback

### What gets recorded

After every finalized run (when `routing_feedback` is on), Lemon stores a
feedback entry keyed by task fingerprint:

```
<task_family>|<toolset>|<workspace>|<provider>|<model>
```

Missing values are written as `-`, and the toolset segment is always `-` in
stored entries, so history is aggregated per task family, workspace, and model.
For example:
```
code|-|/home/user/myproject|anthropic|claude-sonnet-4-20250514
```

The entry records the outcome (`success`, `failure`, `partial`, `aborted`, or
`unknown`), duration in milliseconds, and a timestamp. Entries live in
`routing_feedback.sqlite3` in the Lemon store directory (`~/.lemon/store` by
default) and are swept after 30 days.

### How it influences routing

With `routing_feedback` enabled, the model selection precedence becomes:

```
explicit_model
  → meta_model (per-run override)
    → session_model (per-session override)
      → profile_model (config profile)
        → history_model  ← best model for this task context
          → default_model
```

`history_model` is the model with the highest success rate for the current task's
context (task family + workspace directory). A model only qualifies once it has
at least 5 samples in that context. It only kicks in when no higher-precedence
model is set.

### Viewing feedback data

```bash
mix lemon.feedback stats                    # Totals, fingerprints, date range, min sample size
mix lemon.feedback list                     # All fingerprints with confidence (HIGH/MEDIUM/LOW/INSUFFICIENT)
mix lemon.feedback list --family code       # Filter by task family
mix lemon.feedback list --workspace <path>  # Filter by workspace
mix lemon.feedback list --since 7           # Only entries seen in the last 7 days
mix lemon.feedback inspect <fingerprint>    # Aggregate for one fingerprint key (-v for outcome counts)
```

---

## Skill Synthesis

### How it works

The synthesis pipeline processes recent memory documents. It runs on demand
(`draft generate`) and also as a scheduled pass: by default every 6 hours for
the `default` agent, looking only at documents ingested since the previous pass.
The scheduled runner is configured through the `:lemon_automation,
:synthesis_runner` application env, not `config.toml`; the
`skill_synthesis_drafts` flag disables both.

1. **Candidate selection** — filters runs by quality criteria:
   - Outcome must be `:success` (`:partial` runs are excluded)
   - The document's owner provenance must allow shared/legacy synthesis;
     private or unproven memory is never turned into a draft
   - `prompt_summary` ≥ 50 characters, `answer_summary` ≥ 100 characters
   - No secret patterns in content
   - No negative claims such as "doesn't work", "not supported", "unable to",
     "gave up", or an answer that ends in "failed to" (so a give-up is not
     learned as a refusal)
   - Task family not `:chat` (conversational) or `:unknown`
   - Deduplicates by normalized prompt content (most recent wins)

2. **Draft generation** — converts each candidate into a SKILL.md with:
   - URL-safe key prefixed with `synth-`
   - YAML frontmatter: `name`, `description`, `requires_tools` (when tools were
     used), and `metadata.lemon` with `category` and `synthesized: true`
   - Body: task pattern from prompt_summary, approach from answer_summary, date generated

3. **Audit** — the draft passes through the same deterministic skill audit engine used for installs.
   If optional LLM audit is configured, that reviewer also runs here. Drafts with `:block`
   findings are discarded; `:warn` findings are kept (human review required anyway).

4. **Storage** — passing drafts are written to `~/.lemon/agent/skill_drafts/<key>/`.

### Generating drafts

Generate from your recent memory (global drafts by default; `--local` writes
to `<cwd>/.lemon/skill_drafts`). Options take the `--flag=value` form:

```bash
mix lemon.skill draft generate
mix lemon.skill draft generate --agent=<agent-id>
mix lemon.skill draft generate --agent=<agent-id> --max-docs=100
mix lemon.skill draft generate --local --cwd=<path>
```

`--agent` defaults to `$LEMON_AGENT_ID`, else `default`; `--max-docs` (default
50) limits how many recent memory documents are scanned. The same commands are
available as `lemon skill draft ...`. If `skill_synthesis_drafts` is `"off"`,
generation fails with a "feature disabled" error.

### Reviewing drafts

```bash
mix lemon.skill draft list
```

Shows key, creation time, and whether `SKILL.md` is present for each draft.

```bash
mix lemon.skill draft review <draft-key>
```

Prints the full SKILL.md content and source document ID so you can edit it
before promoting.

### Editing before promotion

Drafts are plain files in `~/.lemon/agent/skill_drafts/<key>/SKILL.md`
(`<project>/.lemon/skill_drafts/<key>/` with `--local`), next to a
`.draft_meta.json` with provenance and audit state. Edit `SKILL.md` directly —
update the name, description, or body to better capture the intent.

### Promoting a draft to an installed skill

```bash
mix lemon.skill draft publish <draft-key>
```

Installs the draft through the normal skill installer (including its audit and
approval checks; a draft with `:warn` findings may need approval) into
`~/.lemon/agent/skill/`. The draft directory is removed after a successful
install. Pass `--force` to overwrite an installed skill of the same name.

### Discarding a draft

```bash
mix lemon.skill draft delete <draft-key>        # asks for confirmation
mix lemon.skill draft delete <draft-key> --force
```

### Example workflow

```bash
# After a few productive sessions:
mix lemon.skill draft generate --agent=my-agent

# See what was generated:
mix lemon.skill draft list
# KEY                            CREATED                  STATUS
# synth-deploy-kubernetes-...    2026-03-15T10:12:44Z     ready

# Review and edit the best one:
mix lemon.skill draft review synth-deploy-kubernetes-cluster
$EDITOR ~/.lemon/agent/skill_drafts/synth-deploy-kubernetes-cluster/SKILL.md

# Promote it:
mix lemon.skill draft publish synth-deploy-kubernetes-cluster
```

---

## Task Families

The routing and synthesis systems classify every task into a family from keywords
in the prompt (checked in this order: code, file ops, query, chat):

| Family | Matching words | Example prompts |
|---|---|---|
| `:code` | implement, fix, debug, refactor, build, write, create, test, deploy, … | "Implement a deployment script" |
| `:file_ops` | read, open, save, delete, remove, move, rename, copy, touch, mkdir | "Rename the config files" |
| `:query` | explain, describe, analyze, compare, review, summarize, what, how, why, find, … | "Explain how Kubernetes works" |
| `:chat` | yes, no, thanks, ok, hello, hi, bye, help, status, version | "Yes, thanks, sounds good" |
| `:unknown` | no keyword matched | (very short or ambiguous) |

`:chat` and `:unknown` runs are excluded from skill synthesis candidates.

---

## Configuration Reference

```toml
[features]
routing_feedback       = "default-on"  # kill switch: set "off" to disable
skill_synthesis_drafts = "default-on"
```

Each flag can also be set with `LEMON_FEATURE_ROUTING_FEEDBACK` /
`LEMON_FEATURE_SKILL_SYNTHESIS_DRAFTS` (the environment wins over TOML).
Memory retention and per-scope limits are set in the `LemonMemory.Store`
application config; see [Memory](memory.md#retention-and-pruning).

---

## Further Reading

- [`docs/user-guide/memory.md`](memory.md) — Memory documents and session search
- [`docs/user-guide/skills.md`](skills.md) — Full skills user guide
- [`docs/user-guide/rollout.md`](rollout.md) — Feature flag states and rollback

*Last reviewed: 2026-10-15*
