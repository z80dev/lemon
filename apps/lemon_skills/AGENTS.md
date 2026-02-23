# LemonSkills - Skill Management System

This app manages the skill system for extending Lemon's capabilities. Skills are modular, reusable capabilities that enhance agent functionality.

## Purpose and Responsibilities

- **Skill Registry**: Centralized GenServer-based caching of all available skills
- **Skill Discovery**: Online discovery from GitHub (repos with `lemon-skill` or `lemon-agent-skill` topics)
- **Installation/Updates**: Install from Git repos or local paths (approval-gated via `LemonCore.ExecApprovals`)
- **Manifest Management**: Parse YAML or TOML frontmatter in SKILL.md files (hand-rolled parser, no external YAML/TOML deps)
- **Built-in Seeding**: Distribute bundled skills to user directories on app start
- **Status Tracking**: Verify required binaries and environment variables
- **Skill Tools**: Agent-accessible tools for skill operations

## Skill Structure

A skill is a directory containing at minimum a `SKILL.md` file:

```
my-skill/
├── SKILL.md          # Required: Skill documentation and manifest
├── scripts/          # Optional: Helper scripts
└── assets/           # Optional: Additional resources
```

### Manifest Format

SKILL.md supports YAML frontmatter (recommended) or TOML frontmatter (`+++` delimiters):

```yaml
---
name: my-skill
description: Brief description for relevance matching
version: "1.0.0"
author: "Author Name"
tags: [automation, api]
keywords: [deploy, kubernetes, k8s]
requires:
  bins:
    - kubectl
    - jq
  config:
    - API_KEY
    - SERVICE_URL
---

# Skill Documentation

Instructions, examples, and usage patterns...
```

### Manifest Fields

| Field | Description | Required |
|-------|-------------|----------|
| `name` | Skill identifier | No (defaults to directory name) |
| `description` | Brief description for discovery | No |
| `version` | Semantic version | No |
| `author` | Skill author | No |
| `tags` | List of categorization tags | No |
| `keywords` | Keywords for relevance scoring (weighted above description, below name) | No |
| `requires.bins` | Required binaries (checked via `System.find_executable/1`) | No |
| `requires.config` | Required environment variables (checked via `System.get_env/1`) | No |

**Note:** The manifest parser is hand-rolled and handles basic YAML/TOML structures. It does not support anchors, references, or complex YAML features.

## Directory Structure for Skills

Skills are loaded from these locations, with later sources overriding earlier ones on key collision:

### Global (precedence order, first wins)
1. `~/.lemon/agent/skill/*/SKILL.md` — primary global skills
2. `~/.agents/skills/*/SKILL.md` — harness-compatible global skills

The agent dir defaults to `~/.lemon/agent` but can be overridden via:
- `LEMON_AGENT_DIR` environment variable
- `config :lemon_skills, :agent_dir, "/path"`
- Falls back to `config :coding_agent, :agent_dir, ...` if `:lemon_skills` doesn't define it

### Project (when `cwd` is provided, project overrides global)
1. `<cwd>/.lemon/skill/` — project-specific skills (highest precedence)
2. `.agents/skills/` directories from `cwd` up to git repository root (or filesystem root)

The ancestor `.agents/skills` discovery walks up the directory tree, stopping at the git root (detected via `.git` file/directory). This allows monorepos to share skills at different hierarchy levels.

Example for cwd at `/repo/packages/feature`:
```
/repo/packages/feature/.lemon/skill     (highest)
/repo/packages/feature/.agents/skills
/repo/packages/.agents/skills
/repo/.agents/skills                    (stops at git root)
```

## How to Add a New Skill

### 1. Create the Skill Directory

```bash
mkdir -p ~/.lemon/agent/skill/my-skill
```

### 2. Write SKILL.md

```bash
cat > ~/.lemon/agent/skill/my-skill/SKILL.md << 'EOF'
---
name: my-skill
description: What this skill does
requires:
  bins:
    - some-tool
  config:
    - SOME_API_KEY
---

# My Skill

Instructions for using this skill...
EOF
```

### 3. Refresh the Registry

```elixir
LemonSkills.refresh()
```

### 4. Verify Installation

```elixir
LemonSkills.get("my-skill")
LemonSkills.status("my-skill")
```

## Skill Installation Flow

```
Source (Git URL / Local Path)
    ↓
Resolve Source Type
    ↓
Validate SKILL.md Exists
    ↓
Check for Existing Installation
    ↓
Request Approval (via LemonCore.ExecApprovals, if :require_approval is true)
    ↓
Clone/Copy to Target Directory
    ↓
Parse Manifest
    ↓
Register with Registry
    ↓
Return Entry
```

Installation requires user approval by default (configurable via `config :lemon_skills, :require_approval, true`). Pass `approve: true` to skip. If the approvals infrastructure is unavailable, install proceeds anyway.

Git installs use `git clone --depth 1` and then remove the `.git` directory to save space. Updates attempt `git pull` only if `.git` still exists; otherwise they re-clone.

## Built-in Skills

Located in `priv/builtin_skills/`, seeded on app start (via `LemonSkills.Application`):

| Skill | Description |
|-------|-------------|
| `github` | GitHub CLI (`gh`) workflows |
| `tmux` | Terminal multiplexer control |
| `pinata` | IPFS pinning service |
| `summarize` | Text summarization patterns |
| `skill-creator` | Guidelines for creating skills |
| `runtime-remsh` | BEAM remote shell debugging |
| `session-logs` | Session logging patterns |
| `peekaboo` | UI/hidden window management |

Built-in skills are copied to `~/.lemon/agent/skill/` only if the destination directory is missing (never overwritten). Seeding can be disabled via `config :lemon_skills, :seed_builtin_skills, false`.

## Skill Tools

Agents can access skills via these tools (defined in `LemonSkills.Tools`):

### `read_skill`

Fetch skill content and metadata. Returns not-found suggestions when the skill doesn't exist.

```elixir
LemonSkills.Tools.ReadSkill.tool(cwd: "/project/path")
# Parameters: %{"key" => "skill-name", "include_status" => true}
```

### `post_to_x`

Post to X (Twitter). Supports text tweets, replies, and media attachments. Returns a helpful error if credentials are missing.

```elixir
LemonSkills.Tools.PostToX.tool()
# Parameters: %{"text" => "Hello", "reply_to" => "tweet_id", "media_path" => "image.png"}
```

**Parameters:**
- `text` (string, optional if `media_path` provided) - Tweet content, max 280 characters
- `reply_to` (string, optional) - Tweet ID to reply to
- `media_path` (string, optional) - Path to image file to attach (PNG, JPG, GIF, WebP)

**Media Attachments:**
When `media_path` is provided, the image is uploaded to X and attached to the tweet. The path can be absolute or relative to the workspace.

Requires: `X_API_CLIENT_ID`, `X_API_CLIENT_SECRET`, `X_API_ACCESS_TOKEN`, `X_API_REFRESH_TOKEN`

### `get_x_mentions`

Check recent X mentions (default: 10, max: 100).

```elixir
LemonSkills.Tools.GetXMentions.tool()
# Parameters: %{"limit" => 10}
```

## Mix Task Usage

```bash
# List installed skills
mix lemon.skill list
mix lemon.skill list --global          # Global only

# Search skills (local + online)
mix lemon.skill search web
mix lemon.skill search api --max-local=5 --max-online=10
mix lemon.skill search web --no-online # Local only

# Discover skills from GitHub
mix lemon.skill discover github
mix lemon.skill discover api --max=15

# Install a skill
mix lemon.skill install https://github.com/user/lemon-skill-name
mix lemon.skill install /local/path --local
mix lemon.skill install /path --force  # Overwrite existing

# Update a skill
mix lemon.skill update my-skill

# Remove a skill
mix lemon.skill remove my-skill
mix lemon.skill remove my-skill --force # Skip confirmation

# Show skill details
mix lemon.skill info my-skill
```

## Common Tasks and Examples

### List All Skills

```elixir
# All skills (global + project)
LemonSkills.list()

# Project-specific included
LemonSkills.list(cwd: "/path/to/project")

# With refresh
LemonSkills.list(refresh: true)
```

### Get Skill Details

```elixir
{:ok, skill} = LemonSkills.get("github")
skill.key           # "github"
skill.name          # Display name
skill.description   # Brief description
skill.source        # :global, :project, or URL string
skill.path          # Absolute path
skill.enabled       # Boolean
skill.manifest      # Parsed manifest map (string keys, e.g. "name", "requires")
skill.status        # :ready | :missing_deps | :missing_config | :disabled | :error
```

### Check Skill Status

```elixir
# Check if ready to use
LemonSkills.status("my-skill")
# => %{ready: true, missing_bins: [], missing_config: [], disabled: false, error: nil}

LemonSkills.status("k8s-skill")
# => %{ready: false, missing_bins: ["kubectl"], missing_config: [], disabled: false, error: nil}
```

### Install Skills Programmatically

```elixir
# From GitHub (git clone --depth 1)
{:ok, entry} = LemonSkills.install("https://github.com/user/skill-repo")

# From local path (global)
{:ok, entry} = LemonSkills.install("/path/to/skill")

# Project-local install
{:ok, entry} = LemonSkills.install("/path/to/skill", global: false, cwd: "/project")

# Force overwrite
{:ok, entry} = LemonSkills.install("/path/to/skill", force: true)

# Pre-approved (skip approval)
{:ok, entry} = LemonSkills.install("/path/to/skill", approve: true)
```

### Update/Remove Skills

```elixir
# Update a skill
{:ok, entry} = LemonSkills.update("my-skill")

# Uninstall
:ok = LemonSkills.uninstall("my-skill")
```

### Enable/Disable Skills

```elixir
LemonSkills.enable("my-skill")
LemonSkills.enable("my-skill", global: false, cwd: "/project")

LemonSkills.disable("my-skill")
LemonSkills.disable("my-skill", global: false, cwd: "/project")
```

Disabled state is stored in `~/.lemon/agent/skills.json` (global) or `<cwd>/.lemon/skills.json` (project).

### Find Relevant Skills

Relevance scoring: exact name match (100) > partial name (50) > context-in-name (30) > exact keyword (40/word) > partial keyword (20/word) > description words (10/word) > body words (2/word). Project-source skills get a +1000 bonus so they rank above global skills when both match.

```elixir
# Find skills matching context
skills = LemonSkills.find_relevant("kubernetes deployment")
# => Returns top 3 matches by relevance

# Custom limit
skills = LemonSkills.find_relevant("docker", max_results: 5)
```

### Registry Counts

```elixir
# Get installed/enabled counts (useful for status UIs)
%{installed: 8, enabled: 7} = LemonSkills.Registry.counts()
%{installed: 3, enabled: 2} = LemonSkills.Registry.counts(cwd: "/project")
```

### Online Discovery

Searches GitHub for repos with `lemon-skill` or `lemon-agent-skill` topics. All sources run concurrently with per-source timeouts.

```elixir
# Search GitHub for skills
results = LemonSkills.Registry.discover("github")
# => [%{entry: %Entry{}, source: :github, validated: false, url: "..."}, ...]

# Combined local + online search
%{local: local_skills, online: online_skills} =
  LemonSkills.Registry.search("api", max_local: 3, max_online: 5)

# Local only
%{local: skills, online: []} =
  LemonSkills.Registry.search("api", include_online: false)
```

### Working with Entries

```elixir
# Create entry from path
entry = LemonSkills.Entry.new("/path/to/skill", source: :global)

# Create entry from discovered manifest (used by Discovery)
entry = LemonSkills.Entry.from_manifest(manifest, "https://github.com/...", source: :github)

# Get skill file path
skill_file = LemonSkills.Entry.skill_file(entry)
# => "/path/to/skill/SKILL.md"

# Read content
{:ok, content} = LemonSkills.Entry.content(entry)

# Check if ready
LemonSkills.Entry.ready?(entry)

# Update with manifest
entry = LemonSkills.Entry.with_manifest(entry, %{"name" => "Better Name"})

# Update status
entry = LemonSkills.Entry.with_status(entry, :missing_deps)
```

### Manifest Parsing

```elixir
# Parse SKILL.md content (returns {:ok, manifest, body} or :error)
{:ok, manifest, body} = LemonSkills.Manifest.parse(content)

# Parse frontmatter only
{:ok, manifest} = LemonSkills.Manifest.parse_frontmatter(content)

# Get body only (strips frontmatter)
body = LemonSkills.Manifest.parse_body(content)

# Validate manifest
:ok = LemonSkills.Manifest.validate(manifest)

# Get requirements (manifest keys are strings)
bins = LemonSkills.Manifest.required_bins(manifest)   # ["kubectl", "jq"]
config = LemonSkills.Manifest.required_config(manifest) # ["API_KEY"]
```

### Status Checking

```elixir
# Check by key
status = LemonSkills.Status.check("my-skill", cwd: "/project")

# Check an entry directly
status = LemonSkills.Status.check_entry(entry, cwd: "/project")

# Individual checks
LemonSkills.Status.binary_available?("kubectl")   # => false
LemonSkills.Status.config_available?("API_KEY")   # => true

# Get lists of missing items
LemonSkills.Status.missing_binaries(entry)  # => ["kubectl"]
LemonSkills.Status.missing_config(entry)    # => ["API_KEY"]
```

### Configuration Management

```elixir
# Get directories
LemonSkills.Config.global_skills_dir()        # ~/.lemon/agent/skill
LemonSkills.Config.global_skills_dirs()       # [~/.lemon/agent/skill, ~/.agents/skills]
LemonSkills.Config.project_skills_dir("/project/path")  # /project/path/.lemon/skill
LemonSkills.Config.project_skills_dirs("/project/path") # includes ancestor .agents/skills
LemonSkills.Config.agent_dir()                # ~/.lemon/agent

# Git root discovery (used for ancestor skill walking)
LemonSkills.Config.find_git_repo_root("/project/packages/feature")  # => "/project" or nil
LemonSkills.Config.collect_ancestor_agents_skill_dirs("/project/packages/feature")
# => ["/project/packages/feature/.agents/skills", "/project/packages/.agents/skills", ...]

# Load/save config
config = LemonSkills.Config.load_config("/project/path")  # deep-merges global + project
:ok = LemonSkills.Config.save_config(config, true)         # Global
:ok = LemonSkills.Config.save_config(config, false, "/project")  # Project

# Per-skill config
skill_config = LemonSkills.Config.get_skill_config("my-skill", "/project")
:ok = LemonSkills.Config.set_skill_config("my-skill", %{"key" => "value"}, global: false, cwd: "/project")

# Check if disabled
LemonSkills.Config.skill_disabled?("my-skill", "/project")
```

## Testing Guidance

### Run Tests

```bash
# All tests
mix test apps/lemon_skills

# Specific test files
mix test apps/lemon_skills/test/lemon_skills/registry_relevance_test.exs
mix test apps/lemon_skills/test/lemon_skills/manifest_test.exs
mix test apps/lemon_skills/test/lemon_skills/installer_test.exs
mix test apps/lemon_skills/test/lemon_skills/ancestor_skills_test.exs
```

### Test Structure

```
test/lemon_skills/
├── registry_relevance_test.exs    # find_relevant scoring and filtering
├── registry_global_dirs_test.exs  # Global directory precedence
├── ancestor_discovery_test.exs    # find_git_root, collect_ancestor_dirs
├── ancestor_skills_test.exs       # Integration: .agents/skills ancestor walking
├── manifest_test.exs              # Manifest parsing (YAML + TOML)
├── entry_test.exs                 # Entry struct
├── status_test.exs                # Status checking
├── installer_test.exs             # Installation (local path, approval gating)
├── builtin_seeder_test.exs        # Built-in seeding behavior
├── discovery_test.exs             # Online discovery
├── discovery_readme_test.exs      # Discovery README documentation tests
├── config_test.exs                # Configuration load/save/merge
└── tools/
    ├── post_to_x_test.exs
    ├── get_x_mentions_test.exs
    └── read_skill_test.exs
test/mix/tasks/
└── lemon.skill_test.exs           # Mix task CLI
```

### Common Test Patterns

```elixir
# Test with temporary skill directory
tmp_dir = System.tmp_dir!()
skill_dir = Path.join(tmp_dir, "test-skill")
File.mkdir_p!(skill_dir)
File.write!(Path.join(skill_dir, "SKILL.md"), "---\nname: test\n---\n")

# Clean up
on_exit(fn -> File.rm_rf!(skill_dir) end)
```

### Test Helpers

- Tests use isolated temp directories under `apps/lemon_skills/tmp/` (leftover dirs from test runs are normal)
- Installer tests override the agent dir via `:lemon_skills, :agent_dir` app env
- Approval gating is disabled in tests via `config :lemon_skills, :require_approval, false`
- Discovery tests stub HTTP calls; actual GitHub requests are not made in unit tests

## Directory Structure

```
apps/lemon_skills/
├── lib/
│   ├── lemon_skills.ex              # Main public API (delegates to sub-modules)
│   ├── lemon_skills/
│   │   ├── application.ex           # OTP app: seeds builtins, starts Registry
│   │   ├── registry.ex              # GenServer registry (list, get, find_relevant, discover, search, counts)
│   │   ├── entry.ex                 # Skill entry struct
│   │   ├── manifest.ex              # Manifest parsing (hand-rolled YAML/TOML)
│   │   ├── status.ex                # Status checking
│   │   ├── installer.ex             # Installation logic (approval via LemonCore.ExecApprovals)
│   │   ├── config.ex                # Directory paths, config load/save, ancestor discovery
│   │   ├── builtin_seeder.ex        # Built-in skill seeding
│   │   ├── discovery.ex             # Online discovery (GitHub topic search)
│   │   └── tools/
│   │       ├── post_to_x.ex
│   │       ├── get_x_mentions.ex
│   │       └── read_skill.ex
│   └── mix/tasks/
│       └── lemon.skill.ex           # Mix task CLI
├── priv/
│   └── builtin_skills/              # Bundled skills (seeded to ~/.lemon/agent/skill/)
│       ├── github/
│       ├── tmux/
│       └── ...
└── test/
    └── lemon_skills/
```

## Dependencies

- `lemon_core` - Shared primitives, including `LemonCore.ExecApprovals` for approval gating
- `agent_core` - Agent types (`AgentTool`, `AgentToolResult`)
- `ai` - AI types (`TextContent`)
- `lemon_channels` - X API integration (`LemonChannels.Adapters.XAPI`)
- `jason` - JSON encoding/decoding for `skills.json` config files

## Key Modules Reference

| Module | Purpose |
|--------|---------|
| `LemonSkills` | Main public API (delegates to sub-modules) |
| `LemonSkills.Registry` | GenServer: list, get, find_relevant, discover, search, counts, register, unregister |
| `LemonSkills.Entry` | Skill entry struct; `new/2`, `from_manifest/3`, `with_manifest/2`, `with_status/2`, `content/1`, `skill_file/1`, `ready?/1` |
| `LemonSkills.Manifest` | Hand-rolled YAML/TOML parser; `parse/1`, `parse_frontmatter/1`, `parse_body/1`, `validate/1`, `required_bins/1`, `required_config/1` |
| `LemonSkills.Installer` | Install/update/uninstall with approval gating |
| `LemonSkills.Status` | `check/2`, `check_entry/2`, `binary_available?/1`, `config_available?/1`, `missing_binaries/1`, `missing_config/1` |
| `LemonSkills.Config` | Directory paths, config load/save, ancestor `.agents/skills` discovery, `find_git_repo_root/1` |
| `LemonSkills.BuiltinSeeder` | Seed built-in skills on app start (idempotent, never overwrites) |
| `LemonSkills.Discovery` | Online GitHub topic search for skills |
| `Mix.Tasks.Lemon.Skill` | CLI interface |
