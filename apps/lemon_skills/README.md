# LemonSkills

## Learn from bounded sources

`LemonSkills.Learn` turns existing `LemonCore.Context` references into one
durable-memory proposal and one audited synthesis draft. `review/2` never
writes; it returns hashes, counts, audit rule identifiers, and destination
conflicts without returning source text, prompts, paths, URLs, or secrets.
`confirm/3` re-runs the complete selection and accepts only the exact digest
from the fresh review. It writes to `LemonMemory.Store` and
`LemonSkills.Synthesis.DraftStore`; there is no separate learning database and
the resulting skill remains a draft until the existing promotion flow reviews
it. The service disables optional LLM audit for selected source content,
atomically creates exact memory/draft destinations, and stores only hashed
source provenance plus the exact source-memory ID and audited bundle digest in
ordinary records removable through the existing store APIs.

Skill registry, discovery, installation, audit, and lifecycle management for the Lemon agent platform.

LemonSkills provides a centralized system for extending agent capabilities through modular, file-based skills. Skills are directories containing a `SKILL.md` manifest file with optional YAML/TOML frontmatter, and the system handles discovery from disk, online sources, installation with approval gating, static security audit, optional LLM-backed audit review, status checking, and relevance-based retrieval.

`lemon_skills` is one of the packages that make up the [Lemon](https://github.com/z80dev/lemon)
agent platform. It depends on `lemon_core`, `lemon_agent`, `lemon_ai`,
`lemon_memory` and `lemon_media`.

## Installation

```elixir
def deps do
  [{:lemon_skills, "~> 0.1"}]
end
```

Start the application (it is an OTP application with its own supervision tree)
and the skill registry is available through the `LemonSkills` facade:

```elixir
skills = LemonSkills.list()
{:ok, entry} = LemonSkills.get("my-skill")
relevant = LemonSkills.find_relevant("deploy a container", max_results: 3)
```

## Architecture Overview

### Skill Lifecycle

```
                          +-------------------+
                          |   SKILL.md file   |
                          |  (on disk or URL) |
                          +--------+----------+
                                   |
                    +--------------+--------------+
                    |                             |
              Local Discovery               Online Discovery
              (disk scanning)            (GitHub topic search)
                    |                             |
                    v                             v
          +------------------+          +-------------------+
          | Manifest.parse/1 |          | Discovery.discover|
          +--------+---------+          +--------+----------+
                   |                             |
                   v                             v
          +------------------+          +-------------------+
          |  Entry struct    |          | Discovery result  |
          +--------+---------+          +--------+----------+
                   |                             |
                   v                             |
          +------------------+                   |
          |    Registry      |<-- install -------+
          |   (GenServer)    |
          +--------+---------+
                   |
        +----------+----------+
        |          |          |
        v          v          v
     list()     get()    find_relevant()
```

### Execution Model

LemonSkills does not execute skills directly. Instead, it serves as a **content and metadata provider** for other parts of the system (primarily `coding_agent` and `lemon_agent`). The workflow is:

1. **Registration** -- On application start, the `Registry` GenServer loads all skills from global and project directories into an in-memory cache. Built-in skills are seeded first via `BuiltinSeeder`.
2. **Retrieval** -- Agents and tools query the registry for skills by key or by relevance to a context string. The `find_relevant/2` function scores skills using keyword matching across name, description, keywords, and body content.
3. **Content delivery** -- The stable system prompt receives bounded metadata through `PromptView`; full `SKILL.md` content is read only when a caller requests `Entry.content/1`, normally through the `read_skill` tool.
4. **Status gating** -- Before a skill is used, `Status.check/2` verifies that required binaries and environment variables are present.
5. **Installation** -- New skills can be installed from Git repositories, local paths, or the live official Hermes catalog, with approval gating via `LemonCore.ExecApprovals`.
6. **Audit** -- All non-builtin installs and updates run through deterministic audit checks plus an optional LLM reviewer. `:block` verdicts fail the operation, and `:warn` verdicts require explicit approval before the skill is kept.

Portable skill + automation bundles are orchestrated by
`LemonAutomation.Blueprint`, not by another LemonSkills registry or installer.
That service reuses this package's deterministic bundle hash, manifest lint,
audit engine, project config, and registry refresh while placing skills only in
the target profile's derived project workspace. See the
[`daily-note` example](../../examples/skill-automation-bundles/daily-note/)
and [user guide](../../docs/user-guide/skills.md#portable-skill-and-automation-bundles).

### Application Startup

The OTP application (`LemonSkills.Application`) performs two actions on start:

1. Ensures the global skills directory exists (`~/.lemon/agent/skill/`).
2. Seeds built-in skills from `priv/builtin_skills/` to the global directory (only copies missing skills, never overwrites).
3. Starts the `LemonSkills.Registry` GenServer under a one-for-one supervisor.

## Module Inventory

| Module | File | Purpose |
|--------|------|---------|
| `LemonSkills` | `lib/lemon_skills.ex` | Public API facade; delegates to sub-modules |
| `LemonSkills.Application` | `lib/lemon_skills/application.ex` | OTP application; seeds builtins, starts Registry |
| `LemonSkills.Registry` | `lib/lemon_skills/registry.ex` | GenServer for in-memory skill cache; list, get, find_relevant, discover, search, counts, register, unregister |
| `LemonSkills.Entry` | `lib/lemon_skills/entry.ex` | Skill entry struct with metadata, content access, and factory functions |
| `LemonSkills.Manifest` | `lib/lemon_skills/manifest.ex` | YAML/TOML frontmatter parsing and normalized manifest access |
| `LemonSkills.Status` | `lib/lemon_skills/status.ex` | Status checking: binary availability, config presence, disabled state |
| `LemonSkills.Installer` | `lib/lemon_skills/installer.ex` | Install/update/uninstall with approval gating via LemonCore.ExecApprovals |
| `LemonSkills.Audit.Engine` | `lib/lemon_skills/audit/engine.ex` | Static security audit and verdict aggregation |
| `LemonSkills.Audit.LlmReviewer` | `lib/lemon_skills/audit/llm_reviewer.ex` | Optional model-backed review for suspicious or malicious skill content |
| `LemonSkills.Config` | `lib/lemon_skills/config.ex` | Directory paths, config load/save, ancestor `.agents/skills` discovery, git root detection |
| `LemonSkills.BuiltinSeeder` | `lib/lemon_skills/builtin_seeder.ex` | Copies bundled skills from priv/ to user config dir on startup |
| `LemonSkills.Discovery` | `lib/lemon_skills/discovery.ex` | Online skill discovery from GitHub (topic search) and registry URL probing |
| `LemonSkills.HttpClient` | `lib/lemon_skills/http_client.ex` | HTTP client behaviour for dependency injection |
| `LemonSkills.HttpClient.Httpc` | `lib/lemon_skills/http_client/httpc.ex` | Default HTTP client using Erlang `:httpc` |
| `LemonSkills.Tools.ReadSkill` | `lib/lemon_skills/tools/read_skill.ex` | Agent tool for fetching skill content and metadata |
| `LemonSkills.Tools.SkillManage` | `lib/lemon_skills/tools/skill_manage.ex` | Agent tool for creating, editing, patching, deleting, and auditing local skills |
| `LemonSkills.Tools.Memory` | `lib/lemon_skills/tools/memory.ex` | Agent tool for compact assistant-home USER.md/MEMORY.md notes |
| `LemonSkills.Tools.MemoryTopic` | `lib/lemon_skills/tools/memory_topic.ex` | Agent tool for durable topic memory scaffolding |
| `LemonSkills.Tools.SearchMemory` | `lib/lemon_skills/tools/search_memory.ex` | Agent tool for scoped prior-run memory search |
| `LemonSkills.Tools.MediaStatus` | `lib/lemon_skills/tools/media_status.ex` | Agent tool for redacted media job status |
| `LemonSkills.Tools.MediaGenerateImage` | `lib/lemon_skills/tools/media_generate_image.ex` | Agent tool for managed image generation artifacts |
| `LemonSkills.Tools.MediaGenerateSpeech` | `lib/lemon_skills/tools/media_generate_speech.ex` | Agent tool for managed speech generation artifacts |
| `LemonSkills.Tools.MediaTranscribeAudio` | `lib/lemon_skills/tools/media_transcribe_audio.ex` | Agent tool for managed audio transcription artifacts |
| `LemonSkills.Tools.MediaAnalyzeImage` | `lib/lemon_skills/tools/media_analyze_image.ex` | Agent tool for managed image analysis artifacts |
| `LemonSkills.Tools.MediaGenerateVideo` | `lib/lemon_skills/tools/media_generate_video.ex` | Agent tool for managed video generation artifacts |
| `LemonSkills.Tools.Kanban` | `lib/lemon_skills/tools/kanban.ex` | Agent tool for durable Lemon kanban boards and tasks |
| `LemonSkills.SkillView` | `lib/lemon_skills/skill_view.ex` | Display projection of an entry: active state and what is missing |
| `LemonSkills.PromptView` | `lib/lemon_skills/prompt_view.ex` | Renders bounded skill metadata into an agent's system prompt |
| `LemonSkills.McpSource` | `lib/lemon_skills/mcp_source.ex` | MCP servers as a runtime tool source (stdio, HTTP, SSE) |
| `LemonSkills.Source` | `lib/lemon_skills/source.ex` | Behaviour every skill source implements; `Sources.*` are its implementations |
| `LemonSkills.SourceRouter` | `lib/lemon_skills/source_router.ex` | Resolves a URL or path to the source module that handles it |
| `LemonSkills.Sources.Hermes` | `lib/lemon_skills/sources/hermes.ex` | Live official Nous Hermes catalog and sparse skill import source |
| `LemonSkills.TrustPolicy` | `lib/lemon_skills/trust_policy.ex` | Which trust levels require an audit and which auto-approve |
| `LemonSkills.Audit.BundleAudit` | `lib/lemon_skills/audit/bundle_audit.ex` | Whole-bundle audit with a fingerprinted verdict cache |
| `LemonSkills.Curator` | `lib/lemon_skills/curator.ex` | Usage-driven curation pass over installed skills |
| `LemonSkills.Synthesis.Pipeline` | `lib/lemon_skills/synthesis/pipeline.ex` | Drafts new skills from an agent's own history |
| `LemonSkills.Usage` | `lib/lemon_skills/usage.ex` | Persisted per-skill usage counters and pinned/archived state |
| `LemonSkills.Migrator` | `lib/lemon_skills/migrator.ex` | Moves skills forward when a release changes their layout |
| `Mix.Tasks.Lemon.Skill` | `lib/mix/tasks/lemon.skill.ex` | CLI interface for skill management |
| `Mix.Tasks.Lemon.Skill.Lint` | `lib/mix/tasks/lemon.skill.lint.ex` | Lints skill directories against the manifest rules |

Modules not listed here are internal to the package (`@moduledoc false`) and
may change without a major version: `Bundle`, `Lockfile`, `InstallPlan`,
`PathBoundary`, `Audit.State`, `Audit.SkillLint`, and the `Synthesis` draft
internals.

## How Skills Are Defined

A skill is a directory containing at minimum a `SKILL.md` file:

```
my-skill/
+-- SKILL.md          # Required: manifest + documentation
+-- scripts/          # Optional: helper scripts
+-- assets/           # Optional: additional resources
```

### SKILL.md Format

The file supports YAML frontmatter (recommended) or TOML frontmatter:

```yaml
---
name: my-skill
description: Brief description for relevance matching
version: "1.0.0"
author: "Author Name"
tags:
  - automation
  - api
keywords:
  - deploy
  - kubernetes
  - k8s
requires:
  bins:
    - kubectl
    - jq
  config:
    - API_KEY
    - SERVICE_URL
---

# My Skill

Instructions, examples, and usage patterns for agents to follow.
```

TOML frontmatter uses `+++` delimiters:

```toml
+++
name = "my-skill"
description = "Brief description"
tags = ["automation", "api"]
+++

# My Skill

Instructions here.
```

### Manifest Fields

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Skill identifier (defaults to directory name if omitted) |
| `description` | string | Brief description used for discovery and relevance matching |
| `version` | string | Semantic version |
| `author` | string | Skill author |
| `tags` | list | Categorization tags |
| `keywords` | list | Keywords for relevance scoring (weighted above description, below name) |
| `requires.bins` | list | Required binaries, checked via `System.find_executable/1` |
| `requires.config` | list | Required environment variables, checked via `System.get_env/1` |

YAML frontmatter is parsed with `YamlElixir`; TOML frontmatter supports Lemon's flat scalar/list subset. Hermes platform aliases (`macos`, `windows`) and `prerequisites.commands` / `prerequisites.env_vars` are normalized to Lemon's platform and requirement fields.

## Importing official Hermes skills

The official Nous Research catalog is looked up dynamically from the current
`NousResearch/hermes-agent` GitHub tree, so newly added official skills appear
without a Lemon release. Browse it from a source checkout:

```bash
mix lemon.skill hermes
mix lemon.skill hermes research --details
mix lemon.skill hermes --collection=optional --category=research --details
mix lemon.skill install hermes:optional/research/arxiv
```

In `lemon-tui`, run `/skills` to choose a category, filter skills, toggle any
number with Space, and confirm the batch with Enter. `/skills <query>` opens a
filtered skill list directly. Already installed skills are marked and cannot be
selected. Imports retain Lemon's official-source audit and approval flow;
deselecting a row only removes it from the pending batch and never uninstalls an
existing skill.

## How Skills Are Registered

Skills are loaded from multiple directory locations into the `Registry` GenServer. The registry maintains two maps: `global_skills` and `project_skills` (keyed by cwd).

### Directory Precedence

#### Global (loaded on startup, first directory wins on key collision)

1. `~/.lemon/agent/skill/*/SKILL.md` -- primary global skills
2. `~/.agents/skills/*/SKILL.md` -- harness-compatible global skills

#### Project (loaded lazily on first access for a given cwd, project overrides global)

1. `<cwd>/.lemon/skill/*/SKILL.md` -- project-specific skills (highest precedence)
2. `.agents/skills/*/SKILL.md` directories from cwd up to git repository root

The ancestor `.agents/skills` discovery walks up the directory tree, stopping at the git root (detected via `.git` file or directory). This supports monorepos where skills can be organized at different hierarchy levels:

```
/repo/packages/feature/.lemon/skill     (highest precedence)
/repo/packages/feature/.agents/skills
/repo/packages/.agents/skills
/repo/.agents/skills                    (stops at git root)
```

### Relevance Matching

The `find_relevant/2` function scores skills against a context string using weighted keyword matching:

| Signal | Score |
|--------|-------|
| Exact name/key match | 100 |
| Partial name/key match | 50 |
| Context contains name/key | 30 |
| Exact keyword match | 40 per word |
| Partial keyword match | 20 per word |
| Description word match | 10 per word |
| Body content word match | 2 per word |
| Project-source bonus | +1000 |

Project skills always rank above equivalently-scored global skills. Skills that are disabled (via `skills.json` or the entry's `enabled` flag) are excluded from relevance results.

## Audit

Every install/update for a non-builtin skill runs through the audit path before the skill is registered.

Agent-authored skill writes use the same bundle audit path through `skill_manage`. The tool writes only to the configured project or global skill directories, restricts supporting files to `references/`, `templates/`, `scripts/`, and `assets/`, and rolls back blocked audit verdicts before refreshing the registry. `skill_manage` also exposes a `report` action that summarizes usage sidecar rows and flags stale/archive candidates before an agent curates skills.

1. The package computes a deterministic bundle hash across `SKILL.md` plus supported files under `references/`, `templates/`, `scripts/`, and `assets/`. Symlinked bundle entries are rejected so the audit payload cannot escape the skill root.
2. `LemonSkills.Audit.BundleAudit` reuses cached results from `skills.audit.json` only when the bundle hash and audit fingerprint still match.
3. `LemonSkills.Audit.Engine` runs deterministic checks for destructive commands, remote execution, exfiltration, traversal, and escape patterns across all auditable text files in the bundle.
4. If configured, `LemonSkills.Audit.LlmReviewer` reviews a bundle payload and classifies the skill as `pass`, `warn`, or `block`.
5. The installer enforces the verdict:
   - `:pass` continues
   - `:warn` requires explicit approval before the install/update completes
   - `:block` aborts the operation

Enable the optional LLM reviewer with:

```elixir
config :lemon_skills, :audit_llm,
  enabled: true,
  model: "openai:gpt-4o-mini"
```

The configured model can be either a bare model id such as `"gpt-4o-mini"` or a provider-qualified id such as `"openai:gpt-4o-mini"`.

Detailed audit state is persisted separately from provenance lockfiles:

- global: `~/.lemon/agent/skills.audit.json`
- project: `<cwd>/.lemon/skills.audit.json`

## How Skills Are Executed (Consumed)

Skills are not executed by this app. They are consumed as text content by agents. The typical flow is explicit:

1. The stable system prompt lists bounded metadata for every displayable skill.
2. `LemonSkills.find_relevant("kubernetes deployment")` can select turn-local relevance keys without changing that prompt.
3. The agent calls `read_skill` for the selected key (or an application caller explicitly invokes `LemonSkills.Entry.content/1`).
4. The returned full content enters the conversation under the caller's trust boundary, and the agent follows the selected skill only after that explicit load.

## Built-in Skills

These skills ship with the application in `priv/builtin_skills/` and are seeded to `~/.lemon/agent/skill/` on first startup:

| Skill | Description |
|-------|-------------|
| `github` | GitHub CLI (`gh`) workflows and patterns |
| `tmux` | Terminal multiplexer control with helper scripts |
| `pinata` | IPFS pinning service with shell scripts for auth, pin, upload, unpin |
| `summarize` | Text summarization patterns |
| `skill-creator` | Guidelines and templates for creating new skills |
| `runtime-remsh` | BEAM remote shell debugging patterns |
| `session-logs` | Session logging patterns |
| `peekaboo` | UI/hidden window management |

Seeding behavior:
- Only copies skills whose destination directory does not exist.
- Never overwrites user-customized skills.
- Can be disabled via `config :lemon_skills, :seed_builtin_skills, false`.

## How to Create a New Skill

### 1. Create the directory

For a global skill:
```bash
mkdir -p ~/.lemon/agent/skill/my-new-skill
```

For a project-local skill:
```bash
mkdir -p .lemon/skill/my-new-skill
```

### 2. Write the SKILL.md

```bash
cat > ~/.lemon/agent/skill/my-new-skill/SKILL.md << 'EOF'
---
name: my-new-skill
description: One-line description for relevance matching
keywords:
  - relevant
  - search
  - terms
requires:
  bins:
    - some-binary
  config:
    - SOME_API_KEY
---

# My New Skill

## When to use

- Describe when agents should use this skill
- Be specific about trigger conditions

## Instructions

Step-by-step instructions for the agent to follow.

## Examples

Show concrete examples of inputs and expected outputs.
EOF
```

### 3. Refresh the registry

```elixir
LemonSkills.refresh()
```

### 4. Verify

```elixir
{:ok, skill} = LemonSkills.get("my-new-skill")
status = LemonSkills.status("my-new-skill")
```

### 5. Bundle as built-in (optional)

To distribute a skill with the application:

1. Create the directory at `apps/lemon_skills/priv/builtin_skills/my-new-skill/`.
2. Add the `SKILL.md` file (and any helper scripts).
3. The `BuiltinSeeder` will copy it to `~/.lemon/agent/skill/` on next application start for users who do not already have it.

### Creating an agent tool for a skill

If a skill needs programmatic execution (not just content injection), create a tool module:

```elixir
defmodule LemonSkills.Tools.MyNewTool do
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent

  def tool(opts \\ []) do
    %AgentTool{
      name: "my_new_tool",
      description: "Description for agents",
      label: "My New Tool",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "param1" => %{
            "type" => "string",
            "description" => "Parameter description"
          }
        },
        "required" => ["param1"]
      },
      execute: &execute(&1, &2, &3, &4)
    }
  end

  def execute(_tool_call_id, params, _signal, _on_update) do
    # Implementation here
    %AgentToolResult{
      content: [%TextContent{text: "Result"}],
      details: %{}
    }
  end
end
```

## Agent Tools

Twelve tools are available for agents to mount at runtime. Each module exposes
`tool/1` or `tool/2`, returning a `LemonAgent.Types.AgentTool` whose `execute`
closure runs the tool and answers with a `LemonAgent.Types.AgentToolResult`.

### read_skill

Fetches skill content and metadata by key. Returns the full SKILL.md content along with metadata. If the skill is not found, returns a list of available skills as suggestions.

```elixir
LemonSkills.Tools.ReadSkill.tool(cwd: "/project/path")
# Parameters: %{"key" => "github", "include_status" => true}
```

### skill_manage

Creates, edits, patches, deletes and audits local skills. Every write runs
through the audit engine, so a model cannot install content that a `:block`
verdict rejects.

```elixir
LemonSkills.Tools.SkillManage.tool(cwd: "/project/path")
```

### memory, memory_topic, search_memory

Assistant-home notes (`USER.md`/`MEMORY.md`), durable topic memory, and scoped
search over prior runs. These are backed by `lemon_memory`.

### kanban

Durable Lemon kanban boards and tasks for multi-step work.

### media_status, media_generate_image, media_generate_speech, media_generate_video, media_analyze_image, media_transcribe_audio

Managed media generation and analysis. Artifacts and their redacted job records
go through `lemon_media`; each tool needs the credentials of the provider it
calls (OpenAI, Vertex, ElevenLabs or Google), and reports a missing credential
as a tool error rather than raising.

## Online Discovery

The `Discovery` module searches for skills from online sources:

1. **GitHub** -- Searches repositories with `lemon-skill` or `lemon-agent-skill` topics.
2. **Registry URLs** -- Probes well-known URL patterns (`skills.lemon.agent`, `raw.githubusercontent.com/lemon-agent/skills/main/`).

All sources run concurrently with per-source timeouts. Results are deduplicated by URL and sorted by a relevance score that factors in GitHub stars and query match quality.

```elixir
# Search online only
results = LemonSkills.Registry.discover("api")

# Search both local and online
%{local: local, online: online} = LemonSkills.Registry.search("web")
```

## Mix Task CLI

```bash
mix lemon.skill list                          # List installed skills
mix lemon.skill list --global                 # Global only
mix lemon.skill search <query>                # Search local + online
mix lemon.skill search <query> --no-online    # Local only
mix lemon.skill search <query> --max-local=5 --max-online=10
mix lemon.skill discover <query>              # GitHub discovery
mix lemon.skill discover <query> --max=15
mix lemon.skill install <url-or-path>         # Install globally
mix lemon.skill install <path> --local        # Install to project
mix lemon.skill install <path> --force        # Overwrite existing
mix lemon.skill update <key>                  # Update a skill
mix lemon.skill remove <key>                  # Remove (with confirmation)
mix lemon.skill remove <key> --force          # Remove without confirmation
mix lemon.skill info <key>                    # Show skill details
```

## Configuration Options

### Application Environment

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `:agent_dir` | string | `~/.lemon/agent` | Base directory for global skills and config |
| `:seed_builtin_skills` | boolean | `true` | Whether to seed built-in skills on startup |
| `:require_approval` | boolean | `true` | Whether install/update/uninstall requires user approval |
| `:approval_timeout_ms` | integer | `300_000` | Timeout for approval requests (5 minutes) |
| `:http_client` | module | `LemonSkills.HttpClient.Httpc` | HTTP client module for discovery |
| `:mcp_servers` | list | `[]` | MCP servers to expose as tools (see `LemonSkills.McpSource`) |
| `:mcp_disabled` | boolean | `false` | Turn the MCP tool source off entirely |
| `:audit_llm` | keyword | `[enabled: false]` | Optional model-backed audit review (`:enabled`, `:model`) |

### Environment Variables

| Variable | Description |
|----------|-------------|
| `LEMON_AGENT_DIR` | Override the global agent directory (takes precedence over app config) |
| `GITHUB_TOKEN` | GitHub personal access token for higher discovery rate limits |
| `LEMON_MCP_SERVERS` | JSON array of MCP servers to connect as a tool source |
| `LEMON_MCP_DISABLED` | Set to `1`/`true`/`yes` to turn the MCP tool source off |
| `LEMON_HARNESS_SKILLS_DIR` | Override the harness-compatible global skills directory |

### Configuration Files

Skills configuration is stored in JSON files:

- **Global**: `~/.lemon/agent/skills.json`
- **Project**: `<cwd>/.lemon/skills.json`

Project configuration is deep-merged on top of global configuration.

```json
{
  "disabled": ["skill-key-1", "skill-key-2"],
  "skills": {
    "my-skill": {
      "custom_setting": "value"
    }
  }
}
```

## Dependencies

| Dependency | Type | Purpose |
|------------|------|---------|
| `lemon_core` | umbrella | Shared primitives; `LemonCore.ExecApprovals` for approval gating, `LemonCore.Secrets` for secret resolution |
| `lemon_agent` | umbrella | Agent types (`AgentTool`, `AgentToolResult`) used by tool definitions |
| `lemon_ai` | umbrella | AI types (`TextContent`) used in tool results; the model call behind the optional LLM audit |
| `lemon_memory` | umbrella | Durable memory behind the memory, memory_topic and search_memory tools |
| `lemon_media` | umbrella | Media job records and artifacts behind the media tools |
| `jason` | hex | JSON encoding/decoding for `skills.json` configuration files |
| `phoenix_pubsub` | hex | Broadcasts skill and media lifecycle events on `LemonCore.PubSub` |
| `req` | hex | HTTP client for the media provider APIs |

## Installation Flow Detail

```
Source (Git URL / Local Path)
    |
    v
Resolve Source Type (:git or :local)
    |
    v
Extract Skill Name (from URL or path basename)
    |
    v
Check for Existing Installation (fail unless force: true)
    |
    v
Request Approval (via LemonCore.ExecApprovals, skipped if approve: true or :require_approval is false)
    |
    v
Determine Target Directory (global: ~/.lemon/agent/skill/<name>, project: <cwd>/.lemon/skill/<name>)
    |
    v
Perform Install
  - Git: clone --depth 1, then remove .git directory
  - Local: validate SKILL.md exists, then cp_r
    |
    v
Load Installed Skill (parse manifest from SKILL.md)
    |
    v
Register with Registry GenServer
    |
    v
Return {:ok, Entry.t()}
```
