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

### Agent Skills interoperability

Lemon reads the [Agent Skills specification](https://agentskills.io/specification)
YAML format and discovers bundles under `.agents/skills` as well as its native
roots. Portable skills require `name` (1–64 lowercase letters/digits/hyphens,
no leading/trailing or consecutive hyphens, matching the directory) and
`description` (1–1024 characters). `license`, `compatibility`, string-to-string
`metadata`, and experimental `allowed-tools` are preserved in the manifest.
`scripts/`, `references/`, and `assets/` are optional resources, not automatically
executed or loaded during discovery. `allowed-tools` is advisory data: it does
not grant permissions or bypass Lemon's tool policy or approval checks.

Lemon intentionally accepts legacy nonportable bundles: missing frontmatter,
missing name/description, display names outside the portable naming rules,
directory/name mismatches, and names up to 128 bytes. Empty or wrongly typed
present names/descriptions and malformed YAML are rejected and skipped.
Descriptions support up to 1024 Unicode characters (4096 bytes), but Lemon's
prompt-metadata safety policy additionally requires a single line and rejects
control/bidi characters; use YAML folded scalars (`>-`) for wrapped prose.
Unlike strict spec validation, compatibility length and allowed-tools types
are not checked, and metadata can contain nested Lemon extensions.
Use the specification's `skills-ref validate` for strict portability checks;
successful Lemon discovery is not a strict conformance certificate.

---

## Discovery and Precedence

Lemon discovers existing bundles without copying or installing them. Put each
skill at `<skills-root>/<skill-key>/SKILL.md`; scanning is one level deep, not
recursive. The directory name is the lookup key, while frontmatter `name` is a
display name. Invalid manifests are skipped.

Project skills override user skills with the same key. Within the project:

1. `<cwd>/.lemon/skill` wins.
2. Walk from cwd to the nearest repository root (including it). At each level,
   read `.agents/skills`, then `.omp/skills`, `.claude/skills`, `.codex/skills`
   and `.github/skills`. The nearest level wins over more distant ancestors,
   regardless of provider.

A `.git` directory or worktree `.git` file stops the walk. Outside a repository,
the walk reaches the filesystem root. Ancestor `.lemon/skill` directories are
not scanned. Supplying a different cwd changes project discovery; global-only
lookups do not include project skills.

User roots, highest precedence first:

1. `~/.lemon/agent/skill`
2. `~/.agents/skills`
3. `~/.omp/agent/skills`
4. `~/.claude/skills`
5. `~/.codex/skills`

`LEMON_AGENT_DIR` overrides the Lemon agent directory, followed by the
`:lemon_skills` and `:coding_agent` `:agent_dir` application settings.
`LEMON_HARNESS_SKILLS_DIR` (or `:lemon_skills, :harness_global_skills_dir`)
overrides the harness root. When any of these isolation overrides is present,
the additional OMP, Claude and Codex **user defaults are omitted**; existing Lemon
and harness resolution is unchanged.

To explicitly include alternative user roots, set `LEMON_OMP_SKILLS_DIR`,
`LEMON_CLAUDE_SKILLS_DIR` and/or `LEMON_CODEX_SKILLS_DIR`. Their
application-setting equivalents are `:lemon_skills, :omp_global_skills_dir`,
`:lemon_skills, :claude_global_skills_dir` and
`:lemon_skills, :codex_global_skills_dir`; environment variables win.
These explicit paths still apply in isolated runtimes.

Discovery does not grant trust or execute a bundle. External and project skills
remain untrusted content. Listings expose metadata; `read_skill` loads the
selected body or supporting file on demand. Registry refresh and content-change
detection apply equally to all roots.

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

The coding `read` tool also accepts `skill://<skill-key>` for the raw `SKILL.md`
and `skill://<skill-key>/references/example.md` for a supporting file. These use
the same scoped registry and remain untrusted, read-only references. Use normal
`offset` and `limit` parameters for a long file; use `read_skill` when you want
the skill's status, manifest, or a selected heading.

Agents can also maintain procedural memory with `skill_manage`. Use project
scope for repository-specific workflows and global scope for reusable workflows.
The tool can create, edit, patch, delete, and maintain supporting files under
`references/`, `templates/`, `scripts/`, and `assets/`; each write is audited
before the registry is refreshed. Use `action="report"` to inspect usage and
stale/archive candidates before pinning, archiving, restoring, or deleting
agent-authored skills.

Use skills for procedures, not for every remembered fact. A good skill captures
repeatable steps: commands, preconditions, checks, rollback paths, API quirks, or
project conventions that should guide future runs. Use `remember` for compact
durable facts and `recall` for previous run history or longer memory notes.
Use `todo` only for the active run's work queue.

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

## Portable Skill and Automation Bundles

A versioned bundle can distribute an audited skill together with one
agent-backed cron blueprint without creating another skill registry or
scheduler. Put each unpacked bundle directly below the local catalog:

```text
~/.lemon/bundles/daily-note/
├── bundle.json
└── skills/
    └── daily-note/
        └── SKILL.md
```

The repository includes a harmless disabled example. Copy it into the catalog:

```bash
mkdir -p ~/.lemon/bundles
cp -R examples/skill-automation-bundles/daily-note ~/.lemon/bundles/daily-note
```

The directory name, `bundle.json` `id`, skill key, and declared
`skills/<key>` path use lowercase safe IDs. Version 1 requires this manifest
header, at least one skill, and exactly one cron automation:

```json
{
  "format": "lemon-skill-automation-bundle",
  "version": 1,
  "id": "daily-note",
  "skills": [{"key": "daily-note", "path": "skills/daily-note"}],
  "automations": [{
    "id": "daily-note-reminder",
    "kind": "cron",
    "name": "Daily note reminder",
    "schedule": "0 0 1 1 *",
    "prompt": "Use the daily-note skill to summarize completed work.",
    "enabled": false,
    "timezone": "UTC"
  }]
}
```

### Review and activate

Use the same catalog-scoped CLI in a source checkout or packaged release. Both
launchers start the daemon when needed. With no arguments the family lists the
bounded catalog, and a bundle ID plus `--profile` is preview shorthand:

```bash
lemon blueprints
lemon blueprints inspect daily-note
lemon blueprints validate daily-note --json
lemon blueprints daily-note --profile operator
lemon blueprints preview daily-note --profile operator --json
```

These commands never accept an arbitrary filesystem path. The CLI delegates to
the authenticated catalog-scoped control-plane methods rather than loading the
bundle or starting automation in its one-shot VM. Direct WebSocket clients can
use the same RPCs:

```json
{"type":"req","id":"1","method":"blueprints.list","params":{}}
{"type":"req","id":"2","method":"blueprints.inspect","params":{"bundleId":"daily-note"}}
{"type":"req","id":"3","method":"blueprints.validate","params":{"bundleId":"daily-note"}}
{"type":"req","id":"4","method":"blueprints.preview","params":{"bundleId":"daily-note","profileId":"operator"}}
```

`blueprints.preview` does not mutate anything. Review its exact skill and cron
actions, target profile, content hashes, schedule, enabled state, and cleanup
flags. The response deliberately contains prompt byte/hash metadata rather than
prompt text. If the plan is correct, send its exact `confirmationDigest`:

```bash
lemon blueprints activate daily-note --profile operator \
  --confirm <digest-from-preview>
```

Or through JSON-RPC:

```json
{"type":"req","id":"5","method":"blueprints.activate","params":{"bundleId":"daily-note","profileId":"operator","confirmationDigest":"<digest from preview>"}}
```

Or open the token-required Web management page at `/manage/blueprints`. The
browser lists safe IDs/counts, validates the selected entry, and previews the
same exact profile skill and cron actions. Type the displayed digest to apply.
The Web socket deliberately omits free-form manifest prose as well as prompts,
skill bodies, commands, environment values, paths, tokens, and secrets.

The Bun TUI uses the same catalog and activation service:

```text
/blueprints
/blueprint inspect daily-note
/blueprint validate daily-note
/blueprint preview daily-note --profile operator
/blueprint activate daily-note --profile operator --confirm <digest-from-preview>
```

The picker and command receipts are deliberately narrower than the RPC and Web
projections: only bounded IDs, counts, actions, booleans, and digests enter
terminal state. Every activation obtains a fresh preview before mutation,
refuses a changed or incorrect digest without calling activate, never queues
the admin method offline, clears the pending plan on refusal, and preserves the
bounded profile draft. Preview again after a create to obtain the new unchanged
digest for duplicate-safe replay.

Activation reloads and re-plans under a lock. Any content change, destination
change, existing-ID conflict, or stale digest rejects the operation. A
successful activation copies the skill only into the profile's derived
`workspace/.lemon/skill/` boundary, enables it in that workspace, and claims a
stable cron ID through the existing `CronManager`. Previewing and activating
the same bundle again reports `unchanged` and leaves one job.

### Security boundary

Portable bundles are untrusted input. Version 1 rejects archives, symlinks,
unknown paths or fields, oversized trees, unsupported file types, control/bidi
characters, command/shell/script jobs, environment or working-directory
overrides, memory-file overrides, credential-like keys or values, and non-UTC
timezones. Skill manifest/lint and deterministic audit checks run on the source
and again on the staged copy before any rename. Public results omit absolute
paths, skill bodies, prompt text, command text, and secret values.

This first vertical does not provide archive import, signing, publishing, a
remote registry, command blueprints, heartbeats, or multiple jobs per bundle.
Use the local `LemonAutomation.Blueprint` service directly
only for trusted source-checkout administration that genuinely needs a local
path; normal operators should use `lemon blueprints`, and remote clients should
use the catalog-scoped RPC.

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
`skill_manage`, `remember`, and `recall`.

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

*Last reviewed: 2026-08-30*
