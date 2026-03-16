# What This PR Actually Does — A Detailed Breakdown

**PR:** `feat/milestone-m0-m8-implementation`
**Scope:** 168 files | +22,351 / -4,019 lines | Milestones M0 through M8

This is a single massive commit that implements nine milestones worth of features across the entire Lemon platform. Here's everything it does, explained in plain English.

---

## Table of Contents

1. [The 30-Second Version](#the-30-second-version)
2. [M0 — Foundation (Ownership, Feature Flags)](#m0--foundation)
3. [M1 — Runtime & Tooling (Boot, Setup, Doctor, Update)](#m1--runtime--tooling)
4. [M2 — Skill Installer & Registry](#m2--skill-installer--registry)
5. [M3 — Progressive Skill Loading](#m3--progressive-skill-loading)
6. [M4 — Skill Quality (Audit, Trust, Lint)](#m4--skill-quality)
7. [M5 — Session Memory (Store, Search, Retention)](#m5--session-memory)
8. [M6 — Adaptive Behavior (Outcomes, Fingerprints, Feedback)](#m6--adaptive-behavior)
9. [M7 — Rollout Gates & Skill Synthesis](#m7--rollout-gates--skill-synthesis)
10. [M8 — Documentation & Release Infrastructure](#m8--documentation--release-infrastructure)
11. [How It All Fits Together](#how-it-all-fits-together)
12. [File Index](#file-index)

---

## The 30-Second Version

Before this PR, Lemon was a working AI agent platform but lacked:

- A proper way to **start up and configure** itself (runtime management)
- A way to **remember** what happened in past conversations (durable memory)
- A way to **learn** which AI models work best for different tasks (adaptive routing)
- A way to **automatically create** reusable skill templates from past work (skill synthesis)
- A way to **safely install third-party skills** with security auditing (trust & audit)
- **Release infrastructure** — CI/CD, versioning, smoke tests, docs site

This PR adds all of that. Think of it as taking Lemon from "working prototype" to "production-ready platform."

---

## M0 — Foundation

### What it adds

**Ownership model** — A `CODEOWNERS` file that declares who's responsible for which parts of the code. Currently everything is owned by `@z80`, but the structure is ready for multi-team ownership across lanes: runtime, skills, agent, memory, docs, release, and clients.

**Feature flags** — A system for turning features on and off without changing code.

Every new feature in this PR is gated behind a flag in `~/.lemon/config.toml`:

```toml
[features]
session_search = "off"           # Memory search (M5)
routing_feedback = "opt-in"      # Adaptive routing (M6)
skill_synthesis_drafts = "opt-in" # Auto-generated skills (M7)
```

Each flag has three states:

| State | What it means |
|-------|--------------|
| `"off"` | Feature is completely disabled. Code paths become no-ops. |
| `"opt-in"` | Available but not active by default. You have to explicitly enable it. |
| `"default-on"` | Active for everyone unless explicitly disabled. |

Flags can also be set via environment variables (highest priority):
```bash
export LEMON_FEATURE_SESSION_SEARCH=default-on
```

**Why this matters:** Every risky feature can be instantly disabled with a config change and restart. No code deployment needed.

### Key files
- `.github/CODEOWNERS` — ownership assignments
- `apps/lemon_core/lib/lemon_core/config/features.ex` — feature flag engine

---

## M1 — Runtime & Tooling

### The Problem

Before this PR, starting Lemon involved a grab-bag of shell scripts, manual environment variable juggling, and no way to check if your setup was healthy. First-time users had to figure everything out from README examples.

### What it adds

#### 1. The Boot System

A structured startup sequence that replaces ad-hoc shell scripts.

**`bin/lemon`** is the entry point — a bash script that:
1. Parses CLI flags (`--port`, `--debug`, `--daemon`, etc.)
2. Sets environment variables
3. Hands off to Elixir

**`Runtime.Boot`** is the Elixir orchestrator that:
1. Reads environment config (ports, paths, debug mode)
2. Checks if another instance is already running
3. Starts the right set of applications based on the chosen profile
4. Reports success or failure

**`Runtime.Env`** centralizes all environment configuration into one struct:

```
                           Priority
CLI flag (--port 4080)      ← highest
Environment var (LEMON_WEB_PORT=4080)
Default value (4080)        ← lowest
```

Key settings resolved: web port, control-plane port, simulator port, project root path, debug mode, Erlang node name, Erlang distribution cookie.

**`Runtime.Health`** checks if a Lemon instance is alive by making a raw TCP connection to `/healthz`. No external HTTP client needed — uses Erlang's built-in `:gen_tcp`. Can either check once (`running?/2`) or poll until healthy (`await/2`).

**`Runtime.Profile`** defines named groups of applications to start together:

| Profile | What starts | Use case |
|---------|------------|----------|
| `runtime_min` | Gateway, Router, Channels, Control Plane | CI, headless, embedded |
| `runtime_full` | Everything above + Web UI, Sim UI, Automation, Skills | Local development |

#### 2. The Setup Wizard

An interactive first-time setup that walks users through:

1. **Config scaffolding** — Creates `~/.lemon/config.toml` with sensible defaults if it doesn't exist
2. **Secrets initialization** — Sets up the encrypted keychain for API keys
3. **Provider onboarding** — Guides you through connecting an AI provider (Anthropic, OpenAI, etc.)
4. **Runtime configuration** — Choose your profile and port numbers
5. **Gateway setup** — Connect a messaging platform (Telegram supported, with a plugin architecture for adding Slack/Discord later)

The Telegram setup specifically:
- Prompts for your bot token (from @BotFather)
- Validates the token format
- Makes a test API call to verify it works
- Prints the config snippet to add

Everything uses dependency-injected I/O callbacks, so it can be tested without a real terminal and supports both CLI and TUI frontends.

#### 3. The Doctor

A diagnostic tool (`mix lemon.doctor`) that runs 6 categories of health checks:

| Category | What it checks |
|----------|---------------|
| **Config** | Global config exists? Valid TOML? Project config valid? |
| **Secrets** | Encryption master key available? |
| **Runtime** | Control plane port responsive? Project root path valid? |
| **Providers** | Default provider set? Any credentials configured? |
| **Node Tools** | `git` installed? `node`/`npm` available? |
| **Skills** | Skills directory exists and has valid skills? |

Each check returns one of: pass, warn (potential problem), fail (action needed), or skip (dependency missing).

Output modes: human-readable with ANSI colors, verbose (show all checks including passing), or JSON for CI.

#### 4. The Update System

`mix lemon.update` runs three idempotent stages:

1. **Version check** — Reports current version (CalVer format: `YYYY.MM.PATCH`)
2. **Config migration** — Detects deprecated TOML sections and auto-migrates them. For example, `[agent]` → `[defaults]`, `[agents.foo]` → `[profiles.foo]`. Always creates a backup first.
3. **Bundled-skill sync** — Ensures all built-in skills are present in the skills directory.

Run `mix lemon.update --check` for a dry run that reports what would change without modifying anything.

### Key files
- `bin/lemon` — bash launcher
- `apps/lemon_core/lib/lemon_core/runtime/` — boot.ex, env.ex, health.ex, profile.ex
- `apps/lemon_core/lib/lemon_core/setup/` — wizard.ex, gateway.ex, telegram.ex, scaffold.ex, provider.ex
- `apps/lemon_core/lib/lemon_core/doctor/` — check.ex, report.ex, checks/*.ex
- `apps/lemon_core/lib/lemon_core/update/` — config_migrator.ex, version.ex
- `apps/lemon_core/lib/mix/tasks/` — lemon.setup.ex, lemon.doctor.ex, lemon.update.ex

---

## M2 — Skill Installer & Registry

### The Problem

Before this PR, skills were either bundled with Lemon or manually placed in a directory. There was no way to install skills from the internet, track where they came from, or detect when they'd been modified.

### What it adds

#### Source Abstraction

A pluggable system where each "source" knows how to discover, fetch, and verify skills from a particular location. Five sources are implemented:

| Source | Identifier format | Trust level | How it works |
|--------|------------------|-------------|-------------|
| **Builtin** | `"builtin"` | `:builtin` (highest) | Reads from `priv/builtin_skills/` shipped with Lemon |
| **Local** | `/path/to/skill` or `./relative` | `:trusted` | Copies a directory from your filesystem |
| **Git** | `https://...` or `git@...` | `:community` | Clones a git repo, removes `.git/` to save space |
| **GitHub** | `gh:owner/repo` | `:community` | Uses GitHub API to search for repos tagged `lemon-skill`, then clones |
| **Registry** | `namespace/category/name` | `:official` or `:community` | Queries an official skill registry service, resolves to a git URL |

The **Source Router** (`source_router.ex`) looks at the identifier format and dispatches to the right source module. You just say `mix lemon.skill install gh:someone/cool-skill` and it figures out the rest.

#### Manifest v2

Skills are defined by `SKILL.md` files with YAML or TOML frontmatter. This PR adds a v2 manifest format with new fields:

```yaml
---
name: Deploy to Kubernetes
description: Apply a K8s deployment manifest
version: 2
platforms:
  - linux
  - macos
requires_tools:
  - bash
  - kubectl
required_environment_variables:
  - KUBECONFIG
metadata:
  lemon:
    category: engineering
---

## Steps
1. Verify kubectl context...
```

New v2 fields include: `platforms`, `requires_tools`, `required_environment_variables`, `metadata.lemon.category`, `verification`, and `references`.

Old v1 manifests work unchanged — the validator auto-detects the version and fills in v2 defaults.

The parser is hand-rolled (no external YAML/TOML library dependency) and supports nested maps, lists, and both `---` (YAML) and `+++` (TOML) frontmatter delimiters.

#### Lockfile

Every installed skill gets tracked in a lockfile (`skills.lock.json`):

```json
{
  "deploy-k8s": {
    "source_kind": "git",
    "source_id": "https://github.com/someone/k8s-skills.git",
    "trust_level": "community",
    "content_hash": "sha256:abc123...",
    "upstream_hash": "def456...",
    "installed_at": "2026-03-16T14:00:00Z",
    "audit_status": "pass"
  }
}
```

This enables:
- **Drift detection** — Has someone modified the installed skill locally? (Compare `content_hash`)
- **Update detection** — Is there a newer version upstream? (Compare `upstream_hash`)
- **Provenance tracking** — Where did this skill come from?

Two lockfiles exist: global (`~/.lemon/agent/skills.lock.json`) and project-level (`<cwd>/.lemon/skills.lock.json`).

#### Migrator

A one-time migration that runs at startup to back-fill lockfile entries for skills that existed before v2. It uses heuristics: if `.git/` exists it was probably a git install, if the name matches a bundled skill it's builtin, otherwise it's local.

#### Install Flow

The full install pipeline:

```
User: mix lemon.skill install gh:someone/cool-skill
  │
  ├─ 1. Source Router resolves "gh:someone/cool-skill" → GitHub source
  ├─ 2. GitHub source searches API, finds repo
  ├─ 3. InstallPlan created (source, destination, trust level, scope)
  ├─ 4. User approval prompted (unless auto-approved by trust policy)
  ├─ 5. Git clone into skills directory
  ├─ 6. SKILL.md manifest parsed and validated
  ├─ 7. Audit engine scans for security issues (community skills only)
  ├─ 8. If audit passes: write lockfile entry, register in skill catalog
  └─ 9. Done — skill available for use
```

### Key files
- `apps/lemon_skills/lib/lemon_skills/source.ex` — source behaviour
- `apps/lemon_skills/lib/lemon_skills/source_router.ex` — identifier routing
- `apps/lemon_skills/lib/lemon_skills/sources/` — builtin.ex, git.ex, github.ex, local.ex, registry.ex
- `apps/lemon_skills/lib/lemon_skills/manifest/` — parser.ex, validator.ex
- `apps/lemon_skills/lib/lemon_skills/lockfile.ex` — provenance tracking
- `apps/lemon_skills/lib/lemon_skills/migrator.ex` — legacy migration
- `apps/lemon_skills/lib/lemon_skills/installer.ex` — install orchestration
- `apps/lemon_skills/lib/lemon_skills/install_plan.ex` — install planning

---

## M3 — Progressive Skill Loading

### The Problem

Loading every installed skill into every prompt wastes tokens and context window space. Most skills aren't relevant to most tasks.

### What it adds

**SkillView** — A display-oriented summary of a skill that includes:
- Activation state: `:active` (ready to use), `:not_ready` (missing dependencies), `:hidden`, `:incompatible`
- Missing dependencies: which tools, binaries, or environment variables are absent
- Platform compatibility: does this skill work on the current OS?

**PromptView** — Renders skills as XML that gets injected into the AI's system prompt:

```xml
<available_skills>
  <skill key="deploy-k8s" name="Deploy to Kubernetes"
         activation_state="active" location="~/.lemon/agent/skills/deploy-k8s">
    Apply a Kubernetes deployment manifest
  </skill>
  <skill key="git-pr" name="Create Pull Request"
         activation_state="not_ready" missing="gh">
    Create and manage GitHub pull requests
  </skill>
</available_skills>
```

Only displayable skills (`:active` or `:not_ready`) are shown. Hidden and incompatible skills are filtered out. The prompt builder limits context-matched skills to 3 maximum.

### Key files
- `apps/lemon_skills/lib/lemon_skills/skill_view.ex` — display model
- `apps/lemon_skills/lib/lemon_skills/prompt_view.ex` — XML rendering
- `apps/lemon_skills/lib/lemon_skills/status.ex` — status checking (modified)

---

## M4 — Skill Quality

### The Problem

If anyone can install a skill from the internet, how do you prevent malicious or dangerous skills from doing harm?

### What it adds

#### Trust Policy

A four-tier trust system:

| Trust Level | Source | Auto-approved? | Audited? |
|-------------|--------|---------------|----------|
| `:builtin` | Shipped with Lemon | Yes | No |
| `:official` | Official registry (`official/` namespace) | No (user approves) | No |
| `:trusted` | Local filesystem | No (user approves) | No |
| `:community` | Git, GitHub, third-party registry | No (user approves) | **Yes** |

Only `:community` skills go through the audit engine. The reasoning: builtin skills are controlled by Lemon developers, official skills are curated, local skills are created by the user, but community skills could be anything.

#### Audit Engine

Scans `SKILL.md` content for 5 categories of security issues:

| Rule | Verdict | What it catches |
|------|---------|----------------|
| **Destructive commands** | `:warn` | `rm -rf`, `dd`, `mkfs`, `fdisk`, `shred` |
| **Remote code execution** | `:block` | `curl \| bash`, `wget \| sh` — piping remote content to a shell |
| **Data exfiltration** | `:block` | Accessing `/etc/passwd`, `~/.ssh/` with network tools like `curl`, `nc` |
| **Path traversal** | `:warn` | `../../../`, direct `/etc/shadow` references |
| **Symlink escape** | `:block` | Symlinks pointing to `/etc/`, `/root/`, `~/.ssh/` |

The worst finding wins: if any rule returns `:block`, the entire skill is blocked from installation. `:warn` findings are shown to the user but don't prevent install.

#### Skill Lint

A CI-oriented quality checker (`mix lemon.skill.lint`) that validates:
- `SKILL.md` exists in the skill directory
- Frontmatter is valid YAML/TOML
- `name` field is present (error if missing)
- `description` field is present (warning if missing)
- Referenced file paths actually exist
- Body content is non-empty
- Audit engine passes clean

Supports `--strict` mode (warnings become errors) and `--json` output for CI integration.

### Key files
- `apps/lemon_skills/lib/lemon_skills/trust_policy.ex` — trust level rules
- `apps/lemon_skills/lib/lemon_skills/audit/engine.ex` — security scanner
- `apps/lemon_skills/lib/lemon_skills/audit/finding.ex` — finding data structure
- `apps/lemon_skills/lib/lemon_skills/audit/skill_lint.ex` — CI quality checker
- `apps/lemon_skills/lib/mix/tasks/lemon.skill.lint.ex` — lint CLI

---

## M5 — Session Memory

### The Problem

Every conversation with Lemon was ephemeral. The AI couldn't remember what happened in previous sessions — what it tried, what worked, what failed. Users had to re-explain context every time.

### What it adds

A parallel storage system that keeps compact, searchable summaries of past runs.

#### Memory Document

The fundamental data structure — a normalized summary of one run:

```
doc_id:          "mem_abc123"
run_id:          "run_456"
session_key:     "agent:my_agent:main"
workspace_key:   "/home/user/myproject"
scope:           :session
prompt_summary:  "How do I fix the login bug?" (truncated to 2KB)
answer_summary:  "The bug was in the JWT expiration..." (truncated to 2KB)
tools_used:      ["bash", "read_file", "edit_file"]
provider:        "anthropic"
model:           "claude-opus-4-6"
outcome:         :success
ingested_at_ms:  1710612345000
```

#### Memory Store

An SQLite-backed database (`memory.sqlite3`) separate from the main run history. This separation is intentional — it prevents lock contention between the main conversation store and background memory queries.

Features:
- **Full-text search** via SQLite FTS5 — find past runs by keywords in prompt/answer text
- **Scope-based access** — query by session, agent, workspace, or search everything
- **Automatic retention** — sweep deletes documents older than 30 days every 15 minutes
- **Per-scope limits** — max 500 documents per session/agent/workspace (prevents unbounded growth)
- **WAL mode** — allows concurrent reads while writes happen

#### Memory Ingest

An async pipeline that converts completed runs into memory documents:

```
Run finishes → Store calls MemoryIngest.ingest(run_id, record, summary)
  → MemoryIngest (GenServer, async) builds a MemoryDocument
  → Validates it has a session_key (drops sessionless runs)
  → If session_search flag is on: persists to MemoryStore
  → If routing_feedback flag is on: records feedback for M6
  → Emits telemetry (duration, success/failure)
```

The key design choice: ingest is fire-and-forget. It never blocks run finalization. If something goes wrong, it logs and moves on.

#### Session Search

A wrapper that provides the public search API with safety guardrails:
- Checks the `session_search` feature flag (returns empty if off)
- Caps results at 20 maximum
- Validates queries (returns empty for blank input)
- Formats results for human/AI consumption

#### Search Memory Tool

The AI agent's interface to memory. When the agent needs context from past runs, it calls:

```json
{
  "name": "search_memory",
  "parameters": {
    "query": "login bug fix",
    "scope": "agent",
    "limit": 5
  }
}
```

And gets back formatted results like:
```
[1] 2026-03-16 14:23 UTC | session: agent:my_agent:main
Q: How do I fix the login bug?
A: The bug was in the JWT expiration check...
```

#### CLI Management

`mix lemon.memory` provides operational commands:
- `stats` — total documents, oldest/newest, config
- `prune` — enforce retention and per-scope limits
- `erase --scope session --key "..."` — bulk delete by scope

### Key files
- `apps/lemon_core/lib/lemon_core/memory_document.ex` — document struct
- `apps/lemon_core/lib/lemon_core/memory_store.ex` — SQLite persistence + FTS5 search
- `apps/lemon_core/lib/lemon_core/memory_ingest.ex` — async ingest pipeline
- `apps/lemon_core/lib/lemon_core/session_search.ex` — public search API
- `apps/coding_agent/lib/coding_agent/tools/search_memory.ex` — agent tool
- `apps/lemon_core/lib/mix/tasks/lemon.memory.ex` — CLI

---

## M6 — Adaptive Behavior

### The Problem

Lemon supports 26 AI providers and many models. Which model is best for a given task? Users had to guess, or always use the same default. There was no way for the system to learn from experience.

### What it adds

A feedback loop that records outcomes, groups them by task type, and uses that data to pick better models next time.

#### Run Outcome

After every run, the system classifies how it went:

| Outcome | Meaning | How it's detected |
|---------|---------|------------------|
| `:success` | Task completed successfully | `completed.ok: true` + non-empty answer |
| `:partial` | Ran but produced incomplete results | `completed.ok: true` + empty answer |
| `:failure` | Something went wrong | `completed.ok: false` + error |
| `:aborted` | User or system cancelled | `completed.ok: false` + abort signal |
| `:unknown` | Can't tell | No clear signal |

#### Task Fingerprint

Each run gets classified into a "fingerprint" that groups similar tasks:

```
task_family:    :code           (detected from keywords in prompt)
toolset:        ["bash", "read_file"]  (tools actually used)
workspace_key:  "/my/project"   (working directory)
provider:       "anthropic"     (AI provider)
model:          "claude-opus-4-6" (specific model)
```

The **task family** is classified by keyword matching:
- `:code` — implement, fix, debug, refactor, build, test, deploy
- `:query` — explain, describe, analyze, compare, review, summarize
- `:file_ops` — read, open, save, delete, move, rename, copy
- `:chat` — yes, no, thanks, ok, hi, bye, help
- `:unknown` — everything else

These get serialized into a key like: `code|bash,read_file|/my/proj|anthropic|claude-opus-4-6`

#### Routing Feedback Store

A separate SQLite database (`routing_feedback.sqlite3`) that accumulates outcome records:

| fingerprint_key | outcome | duration_ms | recorded_at_ms |
|----------------|---------|-------------|---------------|
| `code\|bash,read_file\|/my/proj\|anthropic\|opus` | success | 4200 | 1710612345000 |
| `code\|bash,read_file\|/my/proj\|anthropic\|opus` | success | 3800 | 1710612400000 |
| `code\|bash,read_file\|/my/proj\|openai\|gpt-4o` | failure | 8100 | 1710612500000 |

Key queries:
- **Aggregate stats** for a fingerprint — success rate, mean duration, outcome distribution
- **Best model for context** — across all fingerprints matching a task family + workspace prefix, which model has the highest success rate?
- **List all fingerprints** — see everything the system has learned

#### How It Influences Model Selection

When a new run is submitted, the orchestrator checks if routing feedback is enabled and queries for the best historical model:

```
ModelSelection precedence (highest → lowest):

1. Explicit model (user said "use gpt-4o")
2. Meta model (from request metadata)
3. Session model (sticky session preference)
4. Profile model (agent profile default)
5. History model ← NEW (best model from routing feedback)
6. Router default
```

The history model is a **soft tie-breaker**. It never overrides explicit user intent — it only fills in when nothing higher-priority has a preference.

#### Reporting

`mix lemon.feedback` lets operators inspect what the system has learned:

```bash
mix lemon.feedback stats              # Overview: total records, unique fingerprints
mix lemon.feedback list               # All fingerprints with confidence levels
mix lemon.feedback list --family code  # Filter by task type
mix lemon.feedback inspect <key>       # Deep dive on one fingerprint
```

Confidence levels: `:insufficient` (too few samples), `:low` (<50% success), `:medium` (50-80%), `:high` (80%+).

### Key files
- `apps/lemon_core/lib/lemon_core/run_outcome.ex` — outcome classification
- `apps/lemon_core/lib/lemon_core/task_fingerprint.ex` — task grouping
- `apps/lemon_core/lib/lemon_core/routing_feedback_store.ex` — SQLite persistence
- `apps/lemon_core/lib/lemon_core/routing_feedback_report.ex` — analysis and reporting
- `apps/lemon_core/lib/mix/tasks/lemon.feedback.ex` — CLI
- `apps/lemon_router/lib/lemon_router/model_selection.ex` — model resolution (modified)
- `apps/lemon_router/lib/lemon_router/run_orchestrator.ex` — integration point (modified)

---

## M7 — Rollout Gates & Skill Synthesis

### The Problem

Two questions:
1. How do you know when an adaptive feature is working well enough to enable by default?
2. Can the system automatically create new skills from patterns in past runs?

### What it adds

#### Rollout Gates

Measurable thresholds that must pass before an `"opt-in"` feature can be promoted to `"default-on"`.

**For routing feedback:**

| Gate | Threshold | Why |
|------|-----------|-----|
| Sample size | >= 50 runs | Need enough data for statistical significance |
| Success delta | >= +5pp improvement | History-preferred model must actually be better |
| Retry delta | <= +5pp increase | Can't make things worse |

**For skill synthesis:**

| Gate | Threshold | Why |
|------|-----------|-----|
| Candidates processed | >= 20 | Pipeline must evaluate enough memory documents |
| Generation rate | >= 60% | Most qualified candidates should produce drafts |
| False positive rate | <= 10% | Audit engine shouldn't be blocking too many drafts |

If all gates pass → feature is ready for promotion. If any gate fails → it tells you why and how far off you are.

#### Skill Synthesis Pipeline

An automated pipeline that mines past successful runs and generates skill drafts:

```
1. SELECT — Filter memory documents for synthesis-worthy candidates:
   - Outcome must be :success or :partial
   - Prompt >= 50 chars, answer >= 100 chars (substantive content)
   - No secret patterns (API keys, passwords, PEM keys, JWTs)
   - Task family not :chat or :unknown
   - Deduplicate by normalized prompt

2. GENERATE — Convert each candidate into a draft SKILL.md:
   - Generate a skill key from the prompt summary
   - Derive category from task family
   - Extract tools from the fingerprint
   - Write v2 manifest frontmatter + structured body
   - Mark as synthesized (so humans know it came from AI)

3. LINT — Run quality checks on the draft

4. AUDIT — Run security scan (same audit engine as M4)

5. STORE — Save to draft directory for human review
```

Drafts are stored separately from installed skills:
- Global: `~/.lemon/agent/skill_drafts/`
- Project: `<cwd>/.lemon/skill_drafts/`

Each draft is a directory with `SKILL.md` + `.draft_meta.json` (metadata about how it was generated).

**Critically, drafts are never auto-installed.** A human must review and explicitly promote them:

```bash
mix lemon.skill draft list              # See all drafts
mix lemon.skill draft review <key>      # View draft content
mix lemon.skill draft publish <key>     # Promote to installed skill
mix lemon.skill draft delete <key>      # Discard
```

### Key files
- `apps/lemon_core/lib/lemon_core/rollout_gate.ex` — gate evaluation (threshold-based)
- `apps/lemon_core/lib/lemon_core/rollout_gates.ex` — gate orchestration (aggregate-based)
- `apps/lemon_skills/lib/lemon_skills/synthesis/pipeline.ex` — synthesis orchestration
- `apps/lemon_skills/lib/lemon_skills/synthesis/candidate_selector.ex` — document filtering
- `apps/lemon_skills/lib/lemon_skills/synthesis/draft_generator.ex` — SKILL.md generation
- `apps/lemon_skills/lib/lemon_skills/synthesis/draft_store.ex` — draft persistence

---

## M8 — Documentation & Release Infrastructure

### The Problem

No release pipeline, no docs site, no contributor guide, no way for a new user to get oriented.

### What it adds

#### CI/CD Workflows

Four GitHub Actions workflows:

**`release.yml`** — The full release pipeline:
1. Validate: git tag matches CalVer format, `mix.exs` version matches
2. Build: compile two profiles (`runtime_min` and `runtime_full`) into `.tar.gz` with checksums
3. Publish: create GitHub Release with artifacts and changelog extract

**`product-smoke.yml`** — Thorough end-to-end smoke test:
- Builds a release, boots it, waits for health
- Runs `lemon.doctor`, lints all builtin skills
- Tests memory search API and adaptive routing gates
- Runs daily + on every PR

**`release-smoke.yml`** — Fast boot verification:
- Builds minimal release, checks it starts and responds on `/healthz`
- Runs weekly + on release-related PRs

**`docs-site.yml`** — Documentation website:
- Builds a VitePress site from the markdown docs
- Checks for broken links
- Deploys to GitHub Pages on push to main

#### Versioning

**CalVer format:** `YYYY.MM.PATCH` (e.g., `2026.03.0`)
- Year and month from the calendar
- Patch resets to 0 each month, increments for hotfixes

**Three release channels:**

| Channel | Audience | Cadence |
|---------|----------|---------|
| stable | Regular users | Monthly |
| preview | Early adopters | Weekly |
| nightly | Contributors | Daily |

**Version bumping:** `scripts/bump_version.sh` updates `mix.exs` + 6 `package.json` files in one command.

#### Documentation

| Document | What it covers |
|----------|---------------|
| `docs/user-guide/setup.md` | Prerequisites, installation, config, `lemon.setup` wizard, `lemon.doctor` |
| `docs/user-guide/skills.md` | Skill anatomy, install/list/audit/synthesize commands |
| `docs/user-guide/memory.md` | How memory works, search, retention, privacy |
| `docs/user-guide/adaptive.md` | Routing feedback, history-aware routing, skill synthesis |
| `docs/user-guide/rollout.md` | Feature flag lifecycle (off → opt-in → default-on), gate criteria, rollback |
| `docs/architecture/overview.md` | 18+ apps, BEAM processes, data flows, run lifecycle, lane scheduling |
| `docs/release/versioning_and_channels.md` | CalVer scheme, release channels, auto-update |
| `docs/release/deployment_flows.md` | 3 ways to run: source-dev, release-runtime, attached-client |
| `CONTRIBUTING.md` | Dev setup, test commands, commit style, PR requirements |
| `CHANGELOG.md` | All milestones M0-M8 |
| `SECURITY.md` | Vulnerability reporting policy |
| `LICENSE` | Project license |

The **README** was condensed from 3,100+ lines to ~180 lines — a quick-start guide that points to the detailed docs.

#### Project Infrastructure

- `.github/ISSUE_TEMPLATE/` — Bug report and feature request templates
- `.github/pull_request_template.md` — PR template with checklist
- `examples/config.example.toml` — Annotated example configuration
- `docs/catalog.exs` — Registry of all documentation files

### Key files
- `.github/workflows/` — release.yml, product-smoke.yml, release-smoke.yml, docs-site.yml
- `scripts/bump_version.sh` — version bumping
- `docs/` — all documentation
- `README.md` — condensed README
- `CONTRIBUTING.md`, `CHANGELOG.md`, `SECURITY.md`, `LICENSE`

---

## How It All Fits Together

Here's the complete data flow when someone uses Lemon after this PR:

```
                         FIRST TIME SETUP
                         ================

User runs: mix lemon.setup
  → Wizard creates config scaffold
  → Prompts for provider API key (stored encrypted)
  → Optionally configures Telegram bot
  → mix lemon.doctor verifies everything works


                         NORMAL OPERATION
                         ================

User sends a message (via TUI, web, or Telegram)
  │
  ▼
RunOrchestrator receives the request
  │
  ├─ 1. CLASSIFY — TaskFingerprint classifies prompt as :code/:query/etc.
  │
  ├─ 2. HISTORY LOOKUP — If routing_feedback flag is on:
  │     Query RoutingFeedbackStore for best model for this task type + workspace
  │
  ├─ 3. MODEL SELECTION — Pick model using precedence chain:
  │     explicit → meta → session → profile → history → default
  │
  ├─ 4. SKILL INJECTION — PromptView renders relevant skills into system prompt
  │     (filtered by platform, dependencies, context relevance — max 3)
  │
  ├─ 5. MEMORY INJECTION — If agent calls search_memory tool:
  │     SessionSearch queries MemoryStore for relevant past runs
  │
  ├─ 6. EXECUTION — AI model generates response, tools execute
  │
  └─ 7. FINALIZATION — Run completes
        │
        ├─ RunOutcome classifies result as :success/:failure/etc.
        │
        ├─ MemoryIngest creates MemoryDocument and stores in memory.sqlite3
        │     (if session_search flag is on)
        │
        └─ RoutingFeedbackStore records fingerprint + outcome
              (if routing_feedback flag is on)


                         LEARNING CYCLE
                         ==============

After many runs, the feedback store accumulates data:
  "For code tasks in /myproject, Claude Opus succeeds 85% of the time,
   GPT-4o succeeds 70% of the time"

Rollout gates evaluate: Is there enough data? Is the improvement significant?
  → If yes: feature can be promoted from "opt-in" to "default-on"
  → If no: keep collecting data

Skill synthesis pipeline (on demand):
  → Filters past successful runs for synthesis-worthy candidates
  → Generates draft SKILL.md files
  → Human reviews and promotes (or discards) drafts


                         MAINTENANCE
                         ===========

mix lemon.doctor          — Check system health
mix lemon.update          — Migrate config, sync skills, check version
mix lemon.memory stats    — Check memory store size
mix lemon.memory prune    — Clean up old documents
mix lemon.feedback stats  — Check routing feedback data
mix lemon.skill lint      — Verify skill quality
```

---

## File Index

### New Files (sorted by subsystem)

#### Runtime & Setup (M0-M1)
| File | Purpose |
|------|---------|
| `bin/lemon` | Bash launcher (modified) |
| `apps/lemon_core/lib/lemon_core/runtime/boot.ex` | Startup orchestrator |
| `apps/lemon_core/lib/lemon_core/runtime/env.ex` | Environment config resolver |
| `apps/lemon_core/lib/lemon_core/runtime/health.ex` | Health probing |
| `apps/lemon_core/lib/lemon_core/runtime/profile.ex` | Named app profiles |
| `apps/lemon_core/lib/lemon_core/config/features.ex` | Feature flag engine |
| `apps/lemon_core/lib/lemon_core/setup/wizard.ex` | Interactive setup |
| `apps/lemon_core/lib/lemon_core/setup/scaffold.ex` | Config skeleton generator |
| `apps/lemon_core/lib/lemon_core/setup/gateway.ex` | Gateway adapter dispatcher |
| `apps/lemon_core/lib/lemon_core/setup/gateway/adapter.ex` | Adapter behaviour |
| `apps/lemon_core/lib/lemon_core/setup/gateway/telegram.ex` | Telegram setup |
| `apps/lemon_core/lib/lemon_core/setup/provider.ex` | Provider onboarding wrapper |
| `apps/lemon_core/lib/lemon_core/doctor/check.ex` | Check result struct |
| `apps/lemon_core/lib/lemon_core/doctor/report.ex` | Aggregated report |
| `apps/lemon_core/lib/lemon_core/doctor/checks/config.ex` | Config checks |
| `apps/lemon_core/lib/lemon_core/doctor/checks/secrets.ex` | Secrets checks |
| `apps/lemon_core/lib/lemon_core/doctor/checks/runtime.ex` | Runtime checks |
| `apps/lemon_core/lib/lemon_core/doctor/checks/providers.ex` | Provider checks |
| `apps/lemon_core/lib/lemon_core/doctor/checks/node_tools.ex` | System tool checks |
| `apps/lemon_core/lib/lemon_core/doctor/checks/skills.ex` | Skills directory checks |
| `apps/lemon_core/lib/lemon_core/update/config_migrator.ex` | TOML migration |
| `apps/lemon_core/lib/lemon_core/update/version.ex` | CalVer version handling |
| `apps/lemon_core/lib/mix/tasks/lemon.setup.ex` | Setup CLI |
| `apps/lemon_core/lib/mix/tasks/lemon.doctor.ex` | Doctor CLI |
| `apps/lemon_core/lib/mix/tasks/lemon.update.ex` | Update CLI |

#### Skills (M2-M4)
| File | Purpose |
|------|---------|
| `apps/lemon_skills/lib/lemon_skills/source.ex` | Source behaviour |
| `apps/lemon_skills/lib/lemon_skills/source_router.ex` | Identifier routing |
| `apps/lemon_skills/lib/lemon_skills/sources/builtin.ex` | Builtin source |
| `apps/lemon_skills/lib/lemon_skills/sources/git.ex` | Git source |
| `apps/lemon_skills/lib/lemon_skills/sources/github.ex` | GitHub source |
| `apps/lemon_skills/lib/lemon_skills/sources/local.ex` | Local source |
| `apps/lemon_skills/lib/lemon_skills/sources/registry.ex` | Registry source |
| `apps/lemon_skills/lib/lemon_skills/manifest/parser.ex` | YAML/TOML parser |
| `apps/lemon_skills/lib/lemon_skills/manifest/validator.ex` | Manifest validation |
| `apps/lemon_skills/lib/lemon_skills/lockfile.ex` | Provenance lockfile |
| `apps/lemon_skills/lib/lemon_skills/migrator.ex` | v1→v2 migration |
| `apps/lemon_skills/lib/lemon_skills/install_plan.ex` | Install planning |
| `apps/lemon_skills/lib/lemon_skills/trust_policy.ex` | Trust level rules |
| `apps/lemon_skills/lib/lemon_skills/audit/engine.ex` | Security scanner |
| `apps/lemon_skills/lib/lemon_skills/audit/finding.ex` | Audit finding struct |
| `apps/lemon_skills/lib/lemon_skills/audit/skill_lint.ex` | CI quality checker |
| `apps/lemon_skills/lib/lemon_skills/skill_view.ex` | Display model |
| `apps/lemon_skills/lib/lemon_skills/prompt_view.ex` | XML prompt rendering |
| `apps/lemon_skills/lib/mix/tasks/lemon.skill.lint.ex` | Lint CLI |

#### Skill Synthesis (M7)
| File | Purpose |
|------|---------|
| `apps/lemon_skills/lib/lemon_skills/synthesis/pipeline.ex` | Synthesis orchestration |
| `apps/lemon_skills/lib/lemon_skills/synthesis/candidate_selector.ex` | Document filtering |
| `apps/lemon_skills/lib/lemon_skills/synthesis/draft_generator.ex` | SKILL.md generation |
| `apps/lemon_skills/lib/lemon_skills/synthesis/draft_store.ex` | Draft persistence |

#### Memory (M5)
| File | Purpose |
|------|---------|
| `apps/lemon_core/lib/lemon_core/memory_document.ex` | Document struct |
| `apps/lemon_core/lib/lemon_core/memory_store.ex` | SQLite + FTS5 store |
| `apps/lemon_core/lib/lemon_core/memory_ingest.ex` | Async ingest pipeline |
| `apps/lemon_core/lib/lemon_core/session_search.ex` | Public search API |
| `apps/coding_agent/lib/coding_agent/tools/search_memory.ex` | Agent search tool |
| `apps/lemon_core/lib/mix/tasks/lemon.memory.ex` | Memory CLI |

#### Adaptive Behavior (M6-M7)
| File | Purpose |
|------|---------|
| `apps/lemon_core/lib/lemon_core/run_outcome.ex` | Outcome classification |
| `apps/lemon_core/lib/lemon_core/task_fingerprint.ex` | Task grouping |
| `apps/lemon_core/lib/lemon_core/routing_feedback_store.ex` | Feedback SQLite store |
| `apps/lemon_core/lib/lemon_core/routing_feedback_report.ex` | Analysis and reporting |
| `apps/lemon_core/lib/lemon_core/rollout_gate.ex` | Gate evaluation |
| `apps/lemon_core/lib/lemon_core/rollout_gates.ex` | Gate orchestration |
| `apps/lemon_core/lib/mix/tasks/lemon.feedback.ex` | Feedback CLI |

#### CI/CD & Docs (M8)
| File | Purpose |
|------|---------|
| `.github/workflows/release.yml` | Release pipeline |
| `.github/workflows/product-smoke.yml` | End-to-end smoke tests |
| `.github/workflows/release-smoke.yml` | Fast boot verification |
| `.github/workflows/docs-site.yml` | Docs site build/deploy |
| `.github/CODEOWNERS` | Code ownership |
| `.github/ISSUE_TEMPLATE/` | Issue templates |
| `.github/pull_request_template.md` | PR template |
| `scripts/bump_version.sh` | Version bumping |
| `docs/user-guide/` | User documentation |
| `docs/architecture/overview.md` | Architecture overview |
| `docs/release/` | Release and deployment docs |
| `CONTRIBUTING.md` | Contributor guide |
| `CHANGELOG.md` | Release notes |
| `SECURITY.md` | Security policy |
| `LICENSE` | License |
| `README.md` | Condensed README |

### Modified Files
| File | What changed |
|------|-------------|
| `apps/lemon_skills/lib/lemon_skills/entry.ex` | Added v2 provenance fields |
| `apps/lemon_skills/lib/lemon_skills/installer.ex` | Integrated source/audit/lockfile pipeline |
| `apps/lemon_skills/lib/lemon_skills/manifest.ex` | Added v2 parsing/normalization |
| `apps/lemon_skills/lib/lemon_skills/status.ex` | Extended status checking |
| `apps/lemon_skills/lib/lemon_skills/tools/read_skill.ex` | Enhanced skill reading |
| `apps/lemon_skills/lib/mix/tasks/lemon.skill.ex` | Added search/inspect/check/draft subcommands |
| `apps/lemon_router/lib/lemon_router/model_selection.ex` | Added history_model slot |
| `apps/lemon_router/lib/lemon_router/run_orchestrator.ex` | Added fingerprint + history lookup |
| `apps/coding_agent/lib/coding_agent/prompt_builder.ex` | Added custom sections + skill injection |
| `apps/coding_agent/lib/coding_agent/system_prompt.ex` | Added memory workflow guidance |
| `apps/coding_agent/lib/coding_agent/tool_registry.ex` | Registered search_memory tool |
| `apps/lemon_core/lib/lemon_core/application.ex` | Added MemoryStore + RoutingFeedbackStore to supervision tree |
| `apps/lemon_core/lib/lemon_core/config/modular.ex` | Added features section |
| `apps/lemon_core/lib/lemon_core/config/validator.ex` | Added feature flag validation |
| `apps/lemon_core/lib/lemon_core/store.ex` | Added memory ingest hook on run finalization |
| `apps/lemon_core/lib/lemon_core/telemetry.ex` | Added memory/feedback telemetry events |
| `.github/workflows/quality.yml` | Added lint/boundary checks |
| `clients/lemon-web/package.json` | Version bump |
