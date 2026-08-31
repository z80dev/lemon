# LemonSkills - AI Agent Context

## Quick Orientation

LemonSkills is the skill management system for the Lemon agent platform. It provides a GenServer-based registry that discovers, caches, and serves skill content (SKILL.md files) from multiple directory sources. Skills are **not executed** by this app -- the system prompt lists their metadata and agents explicitly load selected content as specialized knowledge and instructions.

**Core loop**: On startup, load skills plus bounded search excerpts and requirement views from disk into memory. At runtime, agents query cached entries by key or context string; full skill semantics are loaded explicitly with `read_skill`. Skills can also be installed from Git repos or discovered from GitHub.

**Entry point**: `LemonSkills` (the facade module) delegates everything to sub-modules. Start reading there.

**Published package**: `lemon_skills` ships to hex. Two consequences for any
change under `lib/`: it needs a `## [Unreleased]` entry in `CHANGELOG.md`, and
the public/internal split is load-bearing. A module with a real `@moduledoc` is
public API — renaming it, or changing what one of its `@doc`-ed functions
returns, is a breaking change. A module with `@moduledoc false` (`Bundle`,
`Lockfile`, `InstallPlan`, `PathBoundary`, `Audit.State`, `Audit.SkillLint`,
the `Synthesis` draft internals, `Application`, `Telemetry`) is free to change.
Known API warts, and what we would like to fix in 0.2, are listed at the bottom
of `CHANGELOG.md`.

## Key Files and Purposes

- `lib/lemon_skills/tools/peer.ex` — configured-only A2A peer discovery,
  persistent default conversations, local history, and remote task
  status/cancellation. Every remote result is untrusted; this tool never
  accepts a caller-supplied URL or literal credential.

### Core Modules

| File | What it does | When to touch it |
|------|-------------|------------------|
| `lib/lemon_skills.ex` | Public API facade with `@spec` annotations and `defdelegate` calls | Adding new public API functions |
| `lib/lemon_skills/registry.ex` | GenServer that holds all skills in memory; handles list/get/find_relevant/discover/search/counts | Changing skill loading, caching, or search logic |
| `lib/lemon_skills/entry.ex` | Struct: `key`, `name`, `description`, `source`, `path`, `enabled`, `manifest`, `status` | Adding fields to the skill data model |
| `lib/lemon_skills/manifest.ex` | Hand-rolled YAML/TOML frontmatter parser | Fixing parsing bugs, adding new manifest fields |
| `lib/lemon_skills/config.ex` | Directory paths, config load/save, ancestor `.agents/skills` discovery, git root detection | Changing where skills are found on disk |
| `lib/lemon_skills/status.ex` | Checks binary availability (`which`) and env var presence | Adding new status checks |
| `lib/lemon_skills/installer.ex` | Install/update/uninstall with approval gating via `LemonCore.ExecApprovals` | Changing installation flow |
| `lib/lemon_skills/bundle.ex` | Enumerates auditable files and computes deterministic bundle hashes | Changing which files affect audit identity or LLM audit payloads |
| `lib/lemon_skills/audit/bundle_audit.ex` | Bundle-aware audit runner with cached `skills.audit.json` state | Changing rescan logic, verdict composition, or cache invalidation |
| `lib/lemon_skills/audit/engine.ex` | Deterministic skill security audit; merges static checks with optional LLM review | Changing audit behavior or verdict handling |
| `lib/lemon_skills/audit/llm_reviewer.ex` | Optional model-backed audit reviewer for suspicious/malicious skill content | Changing LLM audit prompts, model resolution, or parsing |
| `lib/lemon_skills/audit/state.ex` | Reads/writes persisted bundle audit state per scope | Changing audit cache storage or state schema |
| `lib/lemon_skills/usage.ex` | Persists skill usage counters, agent-authored provenance, and curation state (`active`/`stale`/`archived`/`pinned`) | Changing skill curation, pin/archive behavior, or usage analytics |
| `lib/lemon_skills/curator.ex` | Applies conservative stale/archive lifecycle transitions and renders curator review prompts | Changing automated skill curation or curator scheduler state |
| `lib/lemon_skills/learn.ex` | Non-mutating bounded-source review plus exact-digest writes to canonical memory and audited draft stores | Changing direct learn-from-file/folder/URL semantics |
| `lib/lemon_skills/builtin_seeder.ex` | Copies `priv/builtin_skills/` to `~/.lemon/agent/skill/` on startup (idempotent) | Adding/modifying bundled skills |
| `lib/lemon_skills/discovery.ex` | GitHub topic search + registry URL probing for online skill discovery | Changing online discovery sources |

### Tools (Agent-Callable)

| File | Tool name | Purpose |
|------|-----------|---------|
| `lib/lemon_skills/tools/read_skill.ex` | `read_skill` | Fetches skill content/metadata by key |
| `lib/lemon_skills/tools/skill_manage.ex` | `skill_manage` | Creates, edits, patches, deletes, and audits local skills |
| `lib/lemon_skills/tools/memory.ex` | `memory` | Reads and updates compact assistant-home USER.md/MEMORY.md notes |
| `lib/lemon_skills/tools/memory_topic.ex` | `memory_topic` | Scaffolds durable topic memory files |
| `lib/lemon_skills/tools/search_memory.ex` | `search_memory` | Searches prior run memory by scope |
| `lib/lemon_skills/tools/media_status.ex` | `media_status` | Reports redacted media job status |
| `lib/lemon_skills/tools/media_generate_image.ex` | `media_generate_image` | Generates managed image artifacts |
| `lib/lemon_skills/tools/media_generate_speech.ex` | `media_generate_speech` | Generates managed speech artifacts |
| `lib/lemon_skills/tools/media_transcribe_audio.ex` | `media_transcribe_audio` | Transcribes audio into managed transcript artifacts |
| `lib/lemon_skills/tools/media_analyze_image.ex` | `media_analyze_image` | Analyzes images and stores managed artifacts |
| `lib/lemon_skills/tools/media_generate_video.ex` | `media_generate_video` | Generates managed video artifacts |
| `lib/lemon_skills/tools/kanban.ex` | `kanban` | Manages durable Lemon kanban boards and tasks |

`PromptView` emits `[:lemon_skills, :skill, :prompt_render]` telemetry when skills are surfaced in prompt blocks, with skill keys/counts only and no skill bodies. `read_skill` emits `[:lemon_skills, :skill, :load]` telemetry for successful and missing skill loads. `skill_manage` emits `[:lemon_skills, :skill, :write]` telemetry for accepted and rejected write attempts. These events include session metadata when available, exclude skill body/supporting-file content, update `LemonSkills.Usage` where applicable, and are projected into introspection as `:skill_prompt_render_observed` / `:skill_load_observed` / `:skill_write_observed`.

### Infrastructure

| File | Purpose |
|------|---------|
| `lib/lemon_skills/application.ex` | OTP app startup: `ensure_dirs!()`, `seed!()`, starts Registry |
| `lib/lemon_skills/mcp_source.ex` | GenServer source for stdio, HTTP JSON-RPC, and legacy HTTP+SSE MCP tool discovery/calls into `CodingAgent.ToolRegistry`; configured stdio sampling policies can route reviewed sampling through `LemonCore.ExecApprovals` with redacted summaries; configured HTTP OAuth sources can resolve client secrets, persist token caches through `LemonCore.Secrets`, capture local PKCE callbacks through LemonCore's localhost listener, and route local authorization requests through `mcp_*_oauth` operator approvals |
| `lib/lemon_skills/http_client.ex` | Behaviour for HTTP fetching (injectable for testing) |
| `lib/lemon_skills/http_client/httpc.ex` | Default implementation using Erlang `:httpc` |
| `lib/mix/tasks/lemon.skill.ex` | CLI: `mix lemon.skill list/search/discover/install/update/remove/info` |

### Built-in Skills

Located at `priv/builtin_skills/`. Each subdirectory has a `SKILL.md` and optional scripts:

`github`, `tmux`, `pinata`, `summarize`, `agent-games`, `skill-creator`, `runtime-remsh`, `session-logs`, `peekaboo`

## How to Add a New Skill (Content-Only)

1. Create directory: `mkdir -p priv/builtin_skills/my-skill/` (for bundled) or `~/.lemon/agent/skill/my-skill/` (for user-local).

2. Write `SKILL.md` with YAML frontmatter:
```yaml
---
name: my-skill
description: One-line description for relevance matching
keywords:
  - relevant-term
  - another-term
requires:
  bins:
    - some-binary
  config:
    - SOME_ENV_VAR
---

# My Skill

Instructions for agents...
```

3. If bundled in priv/, the `BuiltinSeeder` auto-copies it on next app start. For user-local, call `LemonSkills.refresh()` or restart.

4. Verify: `LemonSkills.get("my-skill")` and `LemonSkills.status("my-skill")`.

## How to Add a New Agent Tool

1. Create `lib/lemon_skills/tools/my_tool.ex`.
2. Define a `tool/1` function returning `%AgentTool{}` with name, description, parameters schema, and execute function reference.
3. Define an `execute/4` function (or `/5` if it needs `cwd`) returning `%AgentToolResult{}`.
4. Wire the tool into the agent tool registry (in `agent_core` or `coding_agent`, not in this app).
5. Add tests at `test/lemon_skills/tools/my_tool_test.exs`.

Pattern to follow -- see `lib/lemon_skills/tools/read_skill.ex` for the simplest read-only example and `lib/lemon_skills/tools/skill_manage.ex` for audited write paths.

## Important Implementation Details

### Manifest Parsing and External Catalogs

YAML frontmatter is parsed with `YamlElixir`; TOML retains Lemon's flat subset
parser. All manifest keys remain strings. The validator normalizes Hermes'
`macos`/`windows` platform aliases and `prerequisites` command/environment
fields into Lemon's canonical schema.

`LemonSkills.Sources.Hermes` owns dynamic lookup and sparse import of official
Nous Research skills. Keep `hermes:` identifiers routed through `Installer` so
official-source audit and approval remain mandatory; do not copy these bundles
directly into the registry.

Portable skill + automation distribution is owned by
`LemonAutomation.Blueprint`. It deliberately composes `Bundle`, `Manifest`,
`Audit.Engine`, `Audit.SkillLint`, project `Config`, and `Registry.refresh/1`;
do not introduce a second registry or a separate profile skill store here.
Blueprint activation copies only the already audited file set, then hashes,
lints, and audits the staged copy again before it can enter the derived profile
workspace.

Direct source learning is owned by `LemonSkills.Learn`. Keep it as composition
over `LemonCore.Context`, `LemonMemory.Store`, and the existing synthesis draft
store. Review must stay non-mutating and content-free on the wire; confirmation
must re-resolve sources, recompute destination conflicts, and require the exact
fresh digest. Never create a learning database or execute source content.

When present, `name` and `description` must be non-empty, single-line, valid UTF-8 strings without control or bidirectional formatting characters. They are bounded to 128 and 1,024 bytes respectively. `tags` and `keywords` must be lists of at most 32 strings, with each item subject to the same safe-text checks and a 128-byte limit. Missing `name`/`description` remain compatible with legacy manifests and use registry defaults.

### Registry State

The Registry GenServer holds:
- `global_skills`: `%{key => Entry.t()}` -- loaded eagerly on startup
- `project_skills`: `%{cwd => %{key => Entry.t()}}` -- loaded lazily per cwd
- `global_search` / `project_search`: precomputed lower-cased metadata, keywords, and bounded body excerpts
- `global_identity` / `project_identities`: content-addressed snapshots of discovered `SKILL.md` files and lockfiles

When listing/getting, project skills override global skills on key collision. Skills are sorted by key for deterministic ordering (important for stable system prompts and prompt caching).

Search documents are rebuilt at startup, register/unregister boundaries, and when a 50 ms coalesced identity check observes a changed skill file, directory set, or lockfile. The identity scan hashes file content outside the Registry process, so same-size rewrites invalidate safely without serializing callers behind filesystem I/O. Requirement/provenance views are built from cached entries plus current PATH, environment, and disabled-skill config on each call. `find_relevant/2` takes a short cached snapshot from the GenServer and scores it in the caller process. `LemonSkills.refresh/1` remains available for an immediate forced refresh.

### Relevance Scoring

`find_relevant/2` uses weighted keyword matching:
- Exact name match: 100
- Partial name match: 50
- Context contains name: 30
- Key/name word match: 40/word
- Exact keyword match: 40/word
- Partial keyword match: 20/word
- Description word match: 10/word
- Body content word match: 2/word
- Project-source bonus: +1000 after a positive relevance match

Body content is truncated to 10,000 chars before scoring to avoid performance issues with large SKILL.md files.
Equal scores are ordered by skill key for deterministic prompts and telemetry.

Prompt metadata is defensively flattened, bounded, XML-escaped, and includes explicit `source_kind` / `trust_level` fields. Community, project, and local metadata is relevance data rather than instruction authority.

### Approval Gating

The `Installer` requests approval via `LemonCore.ExecApprovals.request/1` before install/update/uninstall operations. It also requests approval after audit when a skill receives a `:warn` verdict, even if global install approvals are otherwise disabled.

Key config: `:require_approval` (default `true`), `:approval_timeout_ms` (default 300,000ms = 5 minutes).

### Skill Audit

All non-builtin skills are audited during install/update. The audit path is:

- `LemonSkills.Bundle` computes a deterministic bundle hash across `SKILL.md` plus supported files under `references/`, `templates/`, `scripts/`, and `assets/`; symlinked bundle entries are rejected so audit never escapes the skill root
- `LemonSkills.Audit.BundleAudit` checks `skills.audit.json` and reuses cached results only when the bundle hash and audit fingerprint still match
- `LemonSkills.Audit.Engine` scans all auditable text files in the bundle
- optional `LemonSkills.Audit.LlmReviewer` reviews a bundle payload built from the same file set
- installer enforcement: `:block` rejects, `:warn` requires explicit approval
- synthesized drafts persist the same audit metadata and warned drafts default to requiring approval on promotion

LLM audit config lives under:

```elixir
config :lemon_skills, :audit_llm,
  enabled: false,
  model: "openai:gpt-4o-mini"
```

The model string may be either `provider:model-id` or a bare `model-id` that exists in `LemonAi.Models`.

Detailed audit state is stored outside the lockfile:

- global: `~/.lemon/agent/skills.audit.json`
- project: `<cwd>/.lemon/skills.audit.json`

`skills.lock.json` still carries the high-level provenance fields used by the registry (`content_hash`, `bundle_hash`, `audit_status`, etc.), but detailed cached findings live in the audit-state file.

### Usage and Curation State

Skill loads and writes update a sidecar usage file outside `SKILL.md`:

- global: `~/.lemon/agent/skills.usage.json`
- project: `<cwd>/.lemon/skills.usage.json`

The sidecar stores load/write counters, last-use metadata, agent-authored creation provenance, and lifecycle state. `skill_manage` supports `report`, `pin`, `unpin`, `archive`, and `restore`; `report` surfaces stale/archive candidates for agent-authored skills, pinned skills cannot be archived or deleted until unpinned, and archived project/global skills are disabled through `skills.json` so relevance selection stops surfacing them.

### HTTP Client Injection

`LemonSkills.HttpClient` is a behaviour. The default `Httpc` module uses Erlang `:httpc`. In tests, it is replaced with `LemonSkills.HttpClient.Mock` via `config :lemon_skills, :http_client, MockModule`.

## Testing Guidance

### Running Tests

```bash
# All lemon_skills tests
mix test apps/lemon_skills

# Specific test file
mix test apps/lemon_skills/test/lemon_skills/registry_relevance_test.exs

# Single test by line number
mix test apps/lemon_skills/test/lemon_skills/manifest_test.exs:7
```

### Test Environment Setup

The test helper (`test/test_helper.exs`):
1. Isolates HOME to a temp directory so tests never touch real user skills/config.
2. Disables X API secrets resolution.
3. Loads `test/support/http_mock.ex` and wires it as the HTTP client.
4. Starts the `:lemon_skills` application.

Integration tests (tagged `@tag :integration`) are excluded by default. They make real HTTP requests.

### Test Structure

```
test/lemon_skills/
  registry_relevance_test.exs    # find_relevant scoring, disabled skills filtering
  registry_global_dirs_test.exs  # Global directory precedence
  ancestor_discovery_test.exs    # Config.find_git_repo_root, collect_ancestor_dirs
  ancestor_skills_test.exs       # End-to-end ancestor .agents/skills walking
  manifest_test.exs              # YAML/TOML parsing, validation, edge cases
  entry_test.exs                 # Entry struct creation and transformation
  bundle_test.exs                # Bundle hashing and auditable file selection
  audit/engine_test.exs          # Static + LLM audit engine behavior
  audit/bundle_audit_test.exs    # Bundle cache/state invalidation and supporting-file scans
  audit/llm_reviewer_test.exs    # LLM audit model resolution and JSON parsing
  audit/skill_lint_test.exs      # Bundle lint + audit integration
  status_test.exs                # Binary/config availability checking
  installer_test.exs             # Local path install, approval gating
  builtin_seeder_test.exs        # Seeding behavior, idempotency
  discovery_test.exs             # Online discovery with HTTP mocks
  discovery_readme_test.exs      # Discovery docs validation
  config_test.exs                # Config load/save/merge, directory paths
  tools/
    read_skill_test.exs          # ReadSkill tool
    skill_manage_test.exs        # SkillManage tool
    memory_test.exs              # Memory tool
    memory_topic_test.exs        # MemoryTopic tool
    search_memory_test.exs       # SearchMemory tool
    kanban_test.exs              # Kanban tool
    media_*_test.exs             # The six media tools
test/mix/tasks/
  lemon.skill_test.exs           # Mix task CLI
```

### Common Test Patterns

**Temporary skill directories**: Most tests use `@moduletag :tmp_dir` which gives each test an isolated temporary directory via ExUnit's built-in `tmp_dir` feature.

```elixir
@moduletag :tmp_dir

test "my test", %{tmp_dir: tmp_dir} do
  skill_dir = Path.join([tmp_dir, ".lemon", "skill", "test-skill"])
  File.mkdir_p!(skill_dir)
  File.write!(Path.join(skill_dir, "SKILL.md"), "---\nname: test\n---\n")
  LemonSkills.refresh(cwd: tmp_dir)
  # ...assertions...
end
```

**Disabling approval gating** (already done in test setup):
```elixir
Application.put_env(:lemon_skills, :require_approval, false)
```

**HTTP mocking for discovery tests**:
```elixir
HttpMock.stub("https://api.github.com/search/repositories", {:ok, json_body})
HttpMock.stub("https://skills.lemon.agent/", {:error, :nxdomain})
```

### What to Test When Changing Things

| Change | Test files to run |
|--------|-------------------|
| Manifest parsing | `manifest_test.exs` |
| Relevance scoring | `registry_relevance_test.exs` |
| Directory discovery | `config_test.exs`, `ancestor_discovery_test.exs`, `ancestor_skills_test.exs` |
| Global dir precedence | `registry_global_dirs_test.exs` |
| Installation flow | `installer_test.exs` |
| Built-in seeding | `builtin_seeder_test.exs` |
| Online discovery | `discovery_test.exs` |
| Entry struct | `entry_test.exs` |
| Status checking | `status_test.exs` |
| Agent tools | the matching file under `tools/`, e.g. `tools/read_skill_test.exs`, `tools/skill_manage_test.exs`, `tools/kanban_test.exs` |
| Mix task | `mix/tasks/lemon.skill_test.exs` |

## Connections to Other Apps

### Dependencies (this app uses)

| App | What LemonSkills uses from it |
|-----|-------------------------------|
| `lemon_core` | `LemonCore.ExecApprovals` for approval gating in Installer, configured stdio MCP sampling review, and configured HTTP MCP OAuth authorization requests; `LemonCore.Secrets` for GitHub token resolution in Discovery and HTTP MCP OAuth client/token secret storage; `LemonCore.OAuth.LocalCallbackListener` for configured HTTP MCP PKCE callback capture; `LemonCore.Telemetry` for skill load/write events |
| `lemon_agent` | `LemonAgent.Types.AgentTool` and `LemonAgent.Types.AgentToolResult` structs for tool definitions |
| `lemon_ai` | `LemonAi.Types.TextContent` struct for tool result content; the model call behind the optional LLM audit reviewer |
| `lemon_memory` | Durable memory behind the `memory`, `memory_topic` and `search_memory` tools |
| `lemon_media` | Media job records and artifacts behind the six media tools |

### Consumers (other apps use this)

| App | How it uses LemonSkills |
|-----|------------------------|
| `coding_agent` | Lists bounded skill metadata in the stable system prompt, uses `LemonSkills.find_relevant/2` for turn-local missed-skill introspection, and exposes `LemonSkills.Tools.ReadSkill` / `LemonSkills.Tools.SkillManage` for explicit content loading and management; shares `agent_dir` config (fallback: `config :coding_agent, :agent_dir`) |
| `lemon_agent` | Provides the common tool structs used by every module under `LemonSkills.Tools` |

### Shared Configuration

The global agent directory (`~/.lemon/agent`) is shared between `lemon_skills` and `coding_agent`. The resolution order is:
1. `LEMON_AGENT_DIR` env var
2. `config :lemon_skills, :agent_dir`
3. `config :coding_agent, :agent_dir` (fallback)
4. `~/.lemon/agent` (default)

This ensures skills and the coding agent share a single on-disk location.

The harness-compatible global skill directory defaults to `~/.agents/skills`. Isolated runtimes and tests can override it with `LEMON_HARNESS_SKILLS_DIR` or `config :lemon_skills, :harness_global_skills_dir`.
