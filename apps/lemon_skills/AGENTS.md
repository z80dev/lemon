# LemonSkills - AI Agent Context

## Quick Orientation

LemonSkills is the skill management system for the Lemon agent platform. It provides a GenServer-based registry that discovers, caches, and serves skill content (SKILL.md files) from multiple directory sources. Skills are **not executed** by this app -- they are text documents loaded into agent system prompts to give agents specialized knowledge and instructions.

**Core loop**: On startup, load skills from disk into memory. At runtime, agents query for relevant skills by key or context string. Skills can also be installed from Git repos or discovered from GitHub.

**Entry point**: `LemonSkills` (the facade module) delegates everything to sub-modules. Start reading there.

## Key Files and Purposes

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
| `lib/lemon_skills/builtin_seeder.ex` | Copies `priv/builtin_skills/` to `~/.lemon/agent/skill/` on startup (idempotent) | Adding/modifying bundled skills |
| `lib/lemon_skills/discovery.ex` | GitHub topic search + registry URL probing for online skill discovery | Changing online discovery sources |

### Tools (Agent-Callable)

| File | Tool name | Purpose |
|------|-----------|---------|
| `lib/lemon_skills/tools/read_skill.ex` | `read_skill` | Fetches skill content/metadata by key |
| `lib/lemon_skills/tools/post_to_x.ex` | `post_to_x` | Posts tweets via X API |
| `lib/lemon_skills/tools/get_x_mentions.ex` | `get_x_mentions` | Fetches X mentions |

### Infrastructure

| File | Purpose |
|------|---------|
| `lib/lemon_skills/application.ex` | OTP app startup: `ensure_dirs!()`, `seed!()`, starts Registry |
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

Pattern to follow -- see `lib/lemon_skills/tools/read_skill.ex` for the simplest example.

## Important Implementation Details

### Manifest Parser Limitations

The YAML/TOML parser in `manifest.ex` is hand-rolled. It handles:
- Basic `key: value` pairs
- Nested maps (up to 2 levels via indent tracking)
- List items (`- value`)
- Comments (`#`)
- CRLF and LF line endings

It does NOT handle: YAML anchors/references, multi-line strings, flow sequences/mappings, complex nesting beyond 2 levels. All manifest keys are strings (not atoms).

### Registry State

The Registry GenServer holds:
- `global_skills`: `%{key => Entry.t()}` -- loaded eagerly on startup
- `project_skills`: `%{cwd => %{key => Entry.t()}}` -- loaded lazily per cwd

When listing/getting, project skills override global skills on key collision. Skills are sorted by key for deterministic ordering (important for stable system prompts and prompt caching).

### Relevance Scoring

`find_relevant/2` uses weighted keyword matching:
- Exact name match: 100
- Partial name match: 50
- Context contains name: 30
- Exact keyword match: 40/word
- Partial keyword match: 20/word
- Description word match: 10/word
- Body content word match: 2/word
- Project-source bonus: +1000

Body content is truncated to 10,000 chars before scoring to avoid performance issues with large SKILL.md files.

### Approval Gating

The `Installer` requests approval via `LemonCore.ExecApprovals.request/1` before install/update/uninstall operations. If the approvals infrastructure is not available (rescue clause), it defaults to allowing the operation. This allows the installer to work in minimal runtimes.

Key config: `:require_approval` (default `true`), `:approval_timeout_ms` (default 300,000ms = 5 minutes).

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
  status_test.exs                # Binary/config availability checking
  installer_test.exs             # Local path install, approval gating
  builtin_seeder_test.exs        # Seeding behavior, idempotency
  discovery_test.exs             # Online discovery with HTTP mocks
  discovery_readme_test.exs      # Discovery docs validation
  config_test.exs                # Config load/save/merge, directory paths
  tools/
    read_skill_test.exs          # ReadSkill tool
    post_to_x_test.exs           # PostToX tool
    get_x_mentions_test.exs      # GetXMentions tool
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
| Agent tools | `tools/read_skill_test.exs`, `tools/post_to_x_test.exs`, `tools/get_x_mentions_test.exs` |
| Mix task | `mix/tasks/lemon.skill_test.exs` |

## Connections to Other Apps

### Dependencies (this app uses)

| App | What LemonSkills uses from it |
|-----|-------------------------------|
| `lemon_core` | `LemonCore.ExecApprovals` for approval gating in Installer; `LemonCore.Secrets` for GitHub token resolution in Discovery |
| `agent_core` | `AgentCore.Types.AgentTool` and `AgentCore.Types.AgentToolResult` structs for tool definitions |
| `ai` | `Ai.Types.TextContent` struct for tool result content |
| `lemon_channels` | `LemonChannels.Adapters.XAPI` for X API integration (post_to_x, get_x_mentions tools) |

### Consumers (other apps use this)

| App | How it uses LemonSkills |
|-----|------------------------|
| `coding_agent` | Calls `LemonSkills.find_relevant/2` to inject skill content into agent system prompts; uses `LemonSkills.Tools.ReadSkill` as an agent tool; shares `agent_dir` config (fallback: `config :coding_agent, :agent_dir`) |
| `agent_core` | Registers skill tools (`read_skill`, `post_to_x`, `get_x_mentions`) in the agent tool registry |

### Shared Configuration

The global agent directory (`~/.lemon/agent`) is shared between `lemon_skills` and `coding_agent`. The resolution order is:
1. `LEMON_AGENT_DIR` env var
2. `config :lemon_skills, :agent_dir`
3. `config :coding_agent, :agent_dir` (fallback)
4. `~/.lemon/agent` (default)

This ensures skills and the coding agent share a single on-disk location.
