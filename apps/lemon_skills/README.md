# LemonSkills

Skill registry, discovery, installation, and lifecycle management for the Lemon agent platform.

LemonSkills provides a centralized system for extending agent capabilities through modular, file-based skills. Skills are directories containing a `SKILL.md` manifest file with optional YAML/TOML frontmatter, and the system handles discovery from disk, online sources, installation with approval gating, status checking, and relevance-based retrieval.

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

LemonSkills does not execute skills directly. Instead, it serves as a **content and metadata provider** for other parts of the system (primarily `coding_agent` and `agent_core`). The workflow is:

1. **Registration** -- On application start, the `Registry` GenServer loads all skills from global and project directories into an in-memory cache. Built-in skills are seeded first via `BuiltinSeeder`.
2. **Retrieval** -- Agents and tools query the registry for skills by key or by relevance to a context string. The `find_relevant/2` function scores skills using keyword matching across name, description, keywords, and body content.
3. **Content delivery** -- The `Entry.content/1` function reads the raw `SKILL.md` content, which is then injected into agent system prompts or returned via the `read_skill` tool.
4. **Status gating** -- Before a skill is used, `Status.check/2` verifies that required binaries and environment variables are present.
5. **Installation** -- New skills can be installed from Git repositories or local paths, with optional approval gating via `LemonCore.ExecApprovals`.

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
| `LemonSkills.Manifest` | `lib/lemon_skills/manifest.ex` | Hand-rolled YAML/TOML frontmatter parser for SKILL.md files |
| `LemonSkills.Status` | `lib/lemon_skills/status.ex` | Status checking: binary availability, config presence, disabled state |
| `LemonSkills.Installer` | `lib/lemon_skills/installer.ex` | Install/update/uninstall with approval gating via LemonCore.ExecApprovals |
| `LemonSkills.Config` | `lib/lemon_skills/config.ex` | Directory paths, config load/save, ancestor `.agents/skills` discovery, git root detection |
| `LemonSkills.BuiltinSeeder` | `lib/lemon_skills/builtin_seeder.ex` | Copies bundled skills from priv/ to user config dir on startup |
| `LemonSkills.Discovery` | `lib/lemon_skills/discovery.ex` | Online skill discovery from GitHub (topic search) and registry URL probing |
| `LemonSkills.HttpClient` | `lib/lemon_skills/http_client.ex` | HTTP client behaviour for dependency injection |
| `LemonSkills.HttpClient.Httpc` | `lib/lemon_skills/http_client/httpc.ex` | Default HTTP client using Erlang `:httpc` |
| `LemonSkills.Tools.ReadSkill` | `lib/lemon_skills/tools/read_skill.ex` | Agent tool for fetching skill content and metadata |
| `LemonSkills.Tools.PostToX` | `lib/lemon_skills/tools/post_to_x.ex` | Agent tool for posting tweets to X (Twitter) |
| `LemonSkills.Tools.GetXMentions` | `lib/lemon_skills/tools/get_x_mentions.ex` | Agent tool for fetching recent X mentions |
| `Mix.Tasks.Lemon.Skill` | `lib/mix/tasks/lemon.skill.ex` | CLI interface for skill management |

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

The manifest parser is hand-rolled and handles basic YAML/TOML structures. It does not support YAML anchors, references, multi-line strings, or other advanced features.

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

## How Skills Are Executed (Consumed)

Skills are not executed by this app. They are consumed as text content by agents. The typical flow:

1. An agent session calls `LemonSkills.find_relevant("kubernetes deployment")` to get contextually relevant skills.
2. For each returned entry, `LemonSkills.Entry.content(entry)` reads the SKILL.md content.
3. The content is injected into the agent's system prompt or context window.
4. The agent follows the instructions in the skill content.

Alternatively, agents can use the `read_skill` tool to fetch skill content on demand during a conversation.

## Built-in Skills

These skills ship with the application in `priv/builtin_skills/` and are seeded to `~/.lemon/agent/skill/` on first startup:

| Skill | Description |
|-------|-------------|
| `github` | GitHub CLI (`gh`) workflows and patterns |
| `tmux` | Terminal multiplexer control with helper scripts |
| `pinata` | IPFS pinning service with shell scripts for auth, pin, upload, unpin |
| `summarize` | Text summarization patterns |
| `agent-games` | Turn-based Games API integration (RPS, Connect4) |
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
  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.TextContent

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

Three tools are available for agents to use at runtime:

### read_skill

Fetches skill content and metadata by key. Returns the full SKILL.md content along with metadata. If the skill is not found, returns a list of available skills as suggestions.

```elixir
LemonSkills.Tools.ReadSkill.tool(cwd: "/project/path")
# Parameters: %{"key" => "github", "include_status" => true}
```

### post_to_x

Posts a tweet to X (Twitter) as the configured account. Supports new tweets and replies.

```elixir
LemonSkills.Tools.PostToX.tool()
# Parameters: %{"text" => "Hello world", "reply_to" => "tweet_id"}
```

Requires environment variables: `X_API_CLIENT_ID`, `X_API_CLIENT_SECRET`, `X_API_ACCESS_TOKEN`, `X_API_REFRESH_TOKEN`.

### get_x_mentions

Fetches recent mentions of the configured X account.

```elixir
LemonSkills.Tools.GetXMentions.tool()
# Parameters: %{"limit" => 10}
```

Same credential requirements as `post_to_x`.

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

### Environment Variables

| Variable | Description |
|----------|-------------|
| `LEMON_AGENT_DIR` | Override the global agent directory (takes precedence over app config) |
| `GITHUB_TOKEN` | GitHub personal access token for higher discovery rate limits |
| `X_API_CLIENT_ID` | X API client ID (for post_to_x and get_x_mentions tools) |
| `X_API_CLIENT_SECRET` | X API client secret |
| `X_API_ACCESS_TOKEN` | X API access token |
| `X_API_REFRESH_TOKEN` | X API refresh token |

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
| `agent_core` | umbrella | Agent types (`AgentTool`, `AgentToolResult`) used by tool definitions |
| `ai` | umbrella | AI types (`TextContent`) used in tool results |
| `lemon_channels` | umbrella | X (Twitter) API integration (`LemonChannels.Adapters.XAPI`) used by post_to_x and get_x_mentions tools |
| `jason` | hex | JSON encoding/decoding for `skills.json` configuration files |

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
