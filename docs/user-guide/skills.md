# Skills User Guide

Skills are reusable knowledge modules that Lemon loads into context when relevant.
They capture task patterns, approaches, and domain knowledge so you don't have to
repeat yourself across sessions.

## Learning timeline

```bash
lemon learning                         # default assistant, newest first
lemon learning --profile research --kind skill --limit 20
lemon learning --kind project --json
```

In Lemon Web, open **Learning** (`/learning`) for the same timeline grouped by UTC
day. Choose a local profile ID and kind; filters stay in the URL. Previews are
escaped plain text, never rendered as skill instructions or HTML. Refresh reloads
current saved state. Memory/Skills links open existing management workflows.

The timeline combines saved user/memory notes, repository learnings, reviewed
source memories, skill drafts, installs, audits, and available usage/lifecycle
timestamps. Select a local profile explicitly with `--profile`; no other profile's
home is scanned. Skill sidecars are read only below that assistant home; the
canonical default assistant also includes agent-attributed global skill events
and global drafts whose source memory belongs to it. Unattributed global records
and repository skills outside the home cannot be attributed safely and are omitted.

This is a **current-state timeline**, not an append-only history: only existing
creation and latest-change timestamps are available. Deleted records and earlier
edits are absent, workspace-note timestamps describe the file, and an older
event's preview shows the current text. Loads without recorded agent attribution
and legacy write attempts without a success marker are omitted. Previews are
redacted and truncated; treat them as untrusted data.
The default is 50 events, with a maximum of 100, from bounded source windows.
Oversized or unreadable skill sidecars report unavailable rather than pretending
to be empty.

IDs are existing management references, not a new mutation API. Use the Memory
page's revision-confirmed delete for a memory ID; use `remember(text, replaces)`
in the owning conversation for note edits, and `lemon skill` / `lemon skill draft`
for existing skill management. Check `lemon skill --help` before destructive
actions. Listing never modifies memory or skills or makes a provider call.

## Learning reminders

Lemon occasionally prompts the main assistant to preserve useful knowledge:

- After 10 user turns without a `remember` call, it suggests saving durable
  facts/preferences with `remember`. Without a save, the reminder repeats every
  10 turns, rather than on every subsequent message.
- If the previous completed run dispatched at least 15 tools without calling
  `skill_manage`, the next user turn suggests creating or patching a reusable
  procedure with `skill_manage`. This suggestion appears once for that run.

These are short, fixed reminders in volatile turn context, not automatic writes
or background model calls. The assistant still decides whether anything is worth
saving; tool and skill content remains untrusted. Subagents never receive or
contribute to these reminders. Counters are isolated by live session process and
reset when that session exits or Lemon restarts; historical transcripts are not
scanned to rebuild them.

Customize `learning_nudge` in `~/.lemon/agent/skills.json`, or override it in the
project's `.lemon/skills.json`:

```json
{
  "learning_nudge": {
    "enabled": true,
    "memory_turn_interval": 10,
    "skill_tool_threshold": 15
  }
}
```

Set `enabled` to `false` to disable both reminders. Thresholds must be positive
integers; invalid values use the defaults. These are **skills.json** settings,
not TOML settings. See the [configuration reference](../config.md#learning-reminders-skillsjson).

### Optional background review

To review a finished run silently instead of inserting a reminder, add
`"background_review": {"enabled": true}` inside `learning_nudge`. This is **off
by default**. The same turn/tool thresholds apply at run completion. Eligible
sessions require a verified private memory owner; legacy, unverified, subagent,
cron/sub-session and internal-followup runs do not trigger reviews.

Each accepted trigger costs **one extra model run** (which may make several
model responses while using tools). It uses the parent session's selected
model and provider credentials by default. To use a cheaper model, set
`background_review.model` to a normal Lemon model specification, for example
`"openai:gpt-4o-mini"`; credentials must already be configured for that provider.
No review output is posted to your conversation or channel.

The isolated review receives only bounded, credential-redacted summaries of the
finished prompt and visible final answer, labelled untrusted; no raw transcript,
tool payloads, reasoning or bootstrap personal-memory files are copied. It may
save private facts through `remember` (never using a shared grant), create skill
drafts for normal review/promotion, or patch non-pinned skills through existing
audits. It cannot run other tools, unpin/delete/promote skills or send messages.
Defaults are one review per session per five minutes, never concurrent, at most
three tool-use turns and a 60-second timeout. Counters/limits are volatile and
reset with the live session/runtime. Triggers blocked by a limit are not queued.
See [all review settings](../config.md#learning-reminders-skillsjson).


---

## What Is a Skill?

A skill is a directory containing:

- **`SKILL.md`** — the skill body: YAML (`---`) or TOML (`+++`) frontmatter
  (metadata) followed by Markdown content
- Optional supporting files under `references/`, `templates/`, `scripts/` and
  `assets/`, which `read_skill` or `read` can load on demand

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

Common fields (see the [manifest reference](../reference/skill-manifest-v2.md)
for the full schema, limits and validation rules):

| Field | Purpose |
|---|---|
| `name` | Human-readable display name (defaults to the directory name) |
| `description` | One-line summary shown in skill listings |
| `requires_tools` | Tools that must be found on `PATH` for the skill to be ready |
| `requires.bins` / `required_environment_variables` | Binaries and environment variables that must be present for the skill to be ready |
| `platforms` | Operating systems where the skill applies (`linux`, `darwin`, `win32`, `any`) |
| `metadata.lemon.category` | Optional category string used for grouping and browsing (for example `engineering`) |
| `hide` | `true` keeps the skill out of the model-visible prompt listing while leaving it loadable by name |

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

## Managing Skills with `lemon skill`

`lemon skill` works in installed releases and source checkouts (`./bin/lemon skill`);
`mix lemon.skill` is a thin wrapper over the same command. Run `lemon skill --help`
for the full option list. Options that take a value use the `--name=value` form
(for example `--cwd=/path/to/project`). Commands read the current directory's
project skills unless `--cwd=PATH` is given.

## Listing Skills

```bash
lemon skill list            # installed skills: key, enabled/disabled, source, description
lemon skill list --global   # global skills only, ignoring the project
lemon skill browse          # activation state and trust level (active and not-ready skills)
lemon skill browse --active
lemon skill browse --not-ready   # skills with missing binaries, variables or tools
lemon skill browse --all         # also disabled, platform-incompatible and blocked skills
lemon skill search <query>       # installed skills plus GitHub results (--no-online for local only)
lemon skill discover <query>     # GitHub skill discovery
```

In Lemon Web, **Skills** (`/skills`) lists installed skills with search,
filters and enable/disable, and also browses and installs from the official
Hermes catalog.

---

## Inspecting a Skill

```bash
lemon skill inspect <skill-key>    # alias: lemon skill info <skill-key>
```

Prints the skill's path, activation state, provenance (source, trust level,
install/update times, audit status), content hashes and drift, requirement
status (binaries, environment variables, tools) and declared references. It does
not print the skill body; open `SKILL.md` or use `read_skill` for that.

Check readiness and drift:

```bash
lemon skill check <skill-key>
```

Shows readiness, local drift (content changed since install) and upstream status
for the installed skill.

---

## Installing Skills

```bash
lemon skill install <source>          # global: ~/.lemon/agent/skill/
lemon skill install <source> --local  # project: <cwd>/.lemon/skill/
lemon skill install <source> --force  # overwrite an existing installation
```

Accepted `<source>` forms:

| Form | Source |
|---|---|
| `/abs/path`, `./rel`, `../rel` | Local directory |
| `https://…`, `http://…`, `git@…`, `git+<url>` | Git repository |
| `gh:<owner>/<repo>` | GitHub shorthand |
| `hermes:optional/<category>/<skill>`, `hermes:bundled/<category>/<skill>` | Official Hermes catalog (`lemon skill hermes [query]` lists IDs; supports `--category=`, `--collection=`, `--details`) |
| `<namespace>/<category>/<name>` (for example `official/devops/k8s-rollout`) | Skill registry (`https://skills.lemon.agent` by default; `config :lemon_skills, :registry_url`) |

Installs are staged, audited, then activated, and provenance is recorded in
`~/.lemon/agent/skills.lock.json` (global) or `<cwd>/.lemon/skills.lock.json`
(project).

### Trust and approval

The source determines the trust level: `builtin` (bundled with Lemon), `official`
(`official/…` registry namespace), `trusted` (local path) or `community`
(everything else). Built-in skills skip the audit and need no approval. All other
skills are audited on install and update, and installing, updating or removing
one requires approval through the normal execution-approval flow. An audit `:warn`
verdict needs an additional explicit approval; a `:block` verdict is refused
unless you approve a separate, clearly labelled security override for that exact
bundle.

---

## Updating Skills

```bash
lemon skill update <skill-key>
```

Reports local modifications and upstream changes first, then re-fetches the
skill from its recorded source when the upstream content differs from what is
installed. Update one skill at a time; there is no update-all option.

---

## Removing Skills

```bash
lemon skill remove <skill-key>           # asks for confirmation
lemon skill remove <skill-key> --force   # skip the confirmation prompt
```

Removes the skill directory, its lockfile record and its audit state.

---

## Agent Tools for Skills

Agents also have a `read_skill` tool in the default native Lemon tool set. The
system prompt lists installed skills by key and tells the agent to call
`read_skill` before following any clearly relevant skill, so skill instructions
can be loaded on demand without injecting every full `SKILL.md` body up front.
`read_skill` takes a `key` plus an optional `view` (`full`, `summary`,
`section` with `section`, or `file` with `path`), `include_status`,
`include_manifest` and `max_chars`.

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

## Review agent skill writes

Enable human review of agent-authored procedural memory in `config.toml`:

```toml
[skills]
write_approval = true
```

Off by default, this gates every mutating `skill_manage` action: create, edit,
patch, delete, supporting-file writes/removals, pin/unpin, and archive/restore.
`report` remains available without write approval. The existing execution
approval UI shows the target/action and bounded, escaped, redacted content or
patch summary; a digest binds the full mutation to its workspace. Approval is
not an audit override: unsafe or pinned writes can still be refused.

Declined, unavailable or expired approval means nothing is written. Unattended
background review cannot create drafts or patch skills behind this gate; cron
and channels without approval controls also fail closed. Interactive native
sessions and Telegram/Discord use their existing approval flow. Explicit
operator skill-management services retain their existing review rules.
See [configuration](../config.md#memory) for timeout and memory-write settings.

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

Run `lemon skill check <key>` to see readiness, drift, and the installed skill's current status.

Install/update behavior:

- `:pass` continues normally
- `:warn` requires explicit approval before the skill is kept
- `:block` refuses the operation unless you approve a separate security override for that exact bundle

Optional LLM audit config:

```elixir
config :lemon_skills, :audit_llm,
  enabled: true,
  model: "openai:gpt-4o-mini"
```

If the LLM review is enabled but cannot complete (unknown model, invalid reply),
the audit records a `:warn` finding instead of silently passing.

Audit state files:

- global: `~/.lemon/agent/skills.audit.json`
- project: `<cwd>/.lemon/skills.audit.json`

To lint skill bundles for manifest compliance and audit cleanliness (for example
before publishing), run `mix lemon.skill.lint [PATH ...] [--strict] [--json]` in a
source checkout; with no path it lints the built-in skills.

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

Or open **Blueprints** (`/blueprints`) in Lemon Web (operator sign-in required).
The browser lists safe IDs/counts, validates the selected entry, and previews the
same exact profile skill and cron actions. Type the displayed digest to apply.
The Web page deliberately omits free-form manifest prose as well as prompts,
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

Lemon generates draft skills from your past successful runs. The
`skill_synthesis_drafts` feature flag is `"default-on"`, and a scheduled pass
(every 6 hours by default) writes drafts from recent agent memory. Drafts are
inert: they sit in the draft store until you publish them. Disable generation
with `[features] skill_synthesis_drafts = "off"` or stop only the scheduled pass
with `config :lemon_automation, :synthesis_runner, enabled: false`.

Generate drafts manually from recent agent memory:

```bash
lemon skill draft generate --agent=<agent-id>   # also --max-docs=N (default 50), --local --cwd=PATH
```

Review a draft:

```bash
lemon skill draft list
lemon skill draft review <draft-key>
```

Promote a draft to an installed skill (after manual review):

```bash
lemon skill draft publish <draft-key>
```

Delete a draft:

```bash
lemon skill draft delete <draft-key>
```

Drafts are global unless you pass `--local` (project drafts under `--cwd=PATH` or
the current directory). `--force` overwrites an existing skill on `publish` and
skips the confirmation on `delete`.

> **Note:** Synthesized drafts require human review before promotion. The audit
> engine runs automatically during generation. Drafts with `:block` findings are
> deleted immediately, and drafts with `:warn` findings are kept but require
> approval on promotion.

You can also turn bounded local or remote sources into one memory note and one
skill draft with [`lemon learn`](learn-from-sources.md).

See [adaptive learning](adaptive.md) for the full synthesis pipeline.

## Skill Curation

Lemon tracks load/write counts and lifecycle state outside `SKILL.md` in
`skills.usage.json`. Agent-authored skills can be reported, pinned, archived,
or restored with `skill_manage`.

Successful `read_skill` views (including status/file views) increment the load
counter; successful `skill_manage` writes and patches increment the write counter.
Discovery/relevance auto-injection contains metadata, not skill instructions, so
it does not count as a load. Counters are independent of introspection telemetry.
Pinned skills cannot be edited, patched, have supporting files written/removed,
deleted, or archived through `skill_manage`: unpin first.
Never-loaded skills cannot be automatically archived before `stale_after_days`,
even when `archive_after_days` is configured shorter.

For a maintenance pass:

```bash
lemon skill curator status    # state, run count and agent-authored candidates
lemon skill curator run       # apply the lifecycle transitions
lemon skill curator run --prompt   # also print the agent review prompt
lemon skill curator pause     # pause scheduled curator checks (resume: lemon skill curator resume)
```

Options: `--local` with `--cwd=PATH` for project skills (default: global),
`--stale-after-days=N` (default 30) and `--archive-after-days=N` (default 90).

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

The runtime also has an idle background curator path, on by default. Lemon waits
for active router sessions to drain, applies the same interval/pause gates, and
submits the curator prompt to the configured agent only when review is required.
Those background reviews default to the learning tools only: `read_skill`,
`skill_manage`, `remember`, and `recall`. Tune it with
`config :lemon_automation, :skill_curator` (`enabled`, `interval_hours` default
168, `min_idle_hours` default 2, `stale_after_days`, `archive_after_days`,
`agent_id` default `"default"`, `session_key` default `agent:<agent_id>:main`).

All curator entry points (background, API, CLI and Mix tasks) exempt skills
referenced by any persisted cron job, including disabled/paused jobs. Cron jobs
have no dedicated skill field: automation contributes `meta.skill` / `meta.skills`
and complete skill names in prompt text (not substrings of longer skill names)
through a runtime provider. This conservative matching may preserve a skill
mentioned only as background context. Explicit `exempt_skills` are additive.
If automation or its provider is unavailable, automatic archival is skipped;
the curator summary and persisted report explain why.

---

## Skill Locations

| Scope | Path |
|---|---|
| Global | `~/.lemon/agent/skill/` (plus the compatibility roots in [Discovery and Precedence](#discovery-and-precedence)) |
| Project | `<cwd>/.lemon/skill/` (plus `.agents/skills` and the other project roots) |
| Global drafts | `~/.lemon/agent/skill_drafts/` |
| Project drafts | `<cwd>/.lemon/skill_drafts/` |

Project skills take precedence over global skills with the same key.

State files sit beside `skills.json` in `~/.lemon/agent/` (global) or
`<cwd>/.lemon/` (project):

| File | Contents |
|---|---|
| `skills.json` | Per-scope skill settings: `disabled` list, per-skill config, `learning_nudge` |
| `skills.lock.json` | Install provenance: source, trust level, content/bundle hashes, audit status |
| `skills.audit.json` | Detailed audit results |
| `skills.usage.json` | Load/write counters and lifecycle state |
| `skills.curator.json` | Curator pause state and last run |

---

## Feature Flags

Skill drafts are controlled by a single flag in `~/.lemon/config.toml`:

```toml
[features]
skill_synthesis_drafts = "default-on"   # "off" disables draft generation
```

It can also be switched with `LEMON_FEATURE_SKILL_SYNTHESIS_DRAFTS=off`. See
[feature flags](../config.md#feature-flags). No other skills behavior is
feature-flagged.

*Last reviewed: 2026-10-15*
