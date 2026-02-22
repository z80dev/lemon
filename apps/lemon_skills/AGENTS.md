# LemonSkills - Skill Management System

This app manages the skill system for extending Lemon's capabilities. Skills are modular, reusable capabilities that enhance agent functionality.

## Purpose and Responsibilities

- **Skill Registry**: Centralized registration and caching of all available skills
- **Skill Discovery**: Online discovery from GitHub and registries
- **Installation/Updates**: Install from Git repos, local paths, or skill registries
- **Manifest Management**: Parse YAML/TOML frontmatter in SKILL.md files
- **Built-in Seeding**: Distribute bundled skills to user directories
- **Status Tracking**: Verify required binaries and configuration
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

SKILL.md supports YAML or TOML frontmatter:

```yaml
---
name: my-skill
description: Brief description for relevance matching
version: "1.0.0"
author: "Author Name"
tags: [automation, api]
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
| `requires.bins` | Required binaries (checked via `which`) | No |
| `requires.config` | Required env vars | No |

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
Source (Git/Local/Registry)
    ↓
Resolve Source Type
    ↓
Validate SKILL.md Exists
    ↓
Check for Existing Installation
    ↓
Request Approval (if enabled)
    ↓
Clone/Copy to Target Directory
    ↓
Parse Manifest
    ↓
Register with Registry
    ↓
Return Entry
```

Installation requires user approval by default (configurable via `:require_approval` app env).

## Built-in Skills

Located in `priv/builtin_skills/`, these are seeded on first run:

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

Built-in skills are copied to `~/.lemon/agent/skill/` only if missing (never overwritten).

## Skill Tools

Agents can access skills via these tools:

### `read_skill`

Fetch skill content and metadata:

```elixir
LemonSkills.Tools.ReadSkill.tool(cwd: "/project/path")
# Parameters: %{"key" => "skill-name", "include_status" => true}
```

### `post_to_x`

Post to X (Twitter):

```elixir
LemonSkills.Tools.PostToX.tool()
# Parameters: %{"text" => "Hello", "reply_to" => "tweet_id"}
```

Requires: `X_API_CLIENT_ID`, `X_API_CLIENT_SECRET`, `X_API_ACCESS_TOKEN`, `X_API_REFRESH_TOKEN`

### `get_x_mentions`

Check recent X mentions:

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

# Project-specific only
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
skill.source        # :global, :project, or URL
skill.path          # Absolute path
skill.enabled       # Boolean
skill.manifest      # Parsed manifest map
```

### Check Skill Status

```elixir
# Check if ready to use
LemonSkills.status("my-skill")
# => %{ready: true, missing_bins: [], missing_config: [], disabled: false, error: nil}

LemonSkills.status("k8s-skill")
# => %{ready: false, missing_bins: ["kubectl"], missing_config: [], ...}
```

### Install Skills Programmatically

```elixir
# From GitHub
{:ok, entry} = LemonSkills.install("https://github.com/user/skill-repo")

# From local path (global)
{:ok, entry} = LemonSkills.install("/path/to/skill", global: true)

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

### Find Relevant Skills

```elixir
# Find skills matching context
skills = LemonSkills.find_relevant("kubernetes deployment")
# => Returns top 3 matches by relevance

# Custom limit
skills = LemonSkills.find_relevant("docker", max_results: 5)
```

### Online Discovery

```elixir
# Search GitHub for skills
results = LemonSkills.Registry.discover("github")
# => [%{entry: %Entry{}, source: :github, validated: false, url: "..."}, ...]

# Combined local + online search
%{local: local_skills, online: online_skills} =
  LemonSkills.Registry.search("api", max_local: 3, max_online: 5)
```

### Working with Entries

```elixir
# Create entry from path
entry = LemonSkills.Entry.new("/path/to/skill", source: :global)

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
# Parse SKILL.md content
{:ok, manifest, body} = LemonSkills.Manifest.parse(content)

# Parse frontmatter only
{:ok, manifest} = LemonSkills.Manifest.parse_frontmatter(content)

# Get body only
body = LemonSkills.Manifest.parse_body(content)

# Validate manifest
:ok = LemonSkills.Manifest.validate(manifest)

# Get requirements
bins = LemonSkills.Manifest.required_bins(manifest)
config = LemonSkills.Manifest.required_config(manifest)
```

### Configuration Management

```elixir
# Get directories
LemonSkills.Config.global_skills_dir()
LemonSkills.Config.project_skills_dir("/project/path")
LemonSkills.Config.agent_dir()

# Load/save config
config = LemonSkills.Config.load_config("/project/path")
:ok = LemonSkills.Config.save_config(config, true)  # Global
:ok = LemonSkills.Config.save_config(config, false, "/project")  # Project

# Per-skill config
skill_config = LemonSkills.Config.get_skill_config("my-skill", "/project")
:ok = LemonSkills.Config.set_skill_config("my-skill", %{key: "value"}, global: false, cwd: "/project")

# Check if disabled
LemonSkills.Config.skill_disabled?("my-skill", "/project")
```

## Testing Guidance

### Run Tests

```bash
# All tests
mix test apps/lemon_skills

# Specific test files
mix test apps/lemon_skills/test/lemon_skills/registry_test.exs
mix test apps/lemon_skills/test/lemon_skills/manifest_test.exs
mix test apps/lemon_skills/test/lemon_skills/installer_test.exs
```

### Test Structure

```
test/lemon_skills/
├── registry_test.exs          # Registry operations
├── manifest_test.exs          # Manifest parsing
├── entry_test.exs             # Entry struct
├── status_test.exs            # Status checking
├── installer_test.exs         # Installation
├── builtin_seeder_test.exs    # Built-in seeding
├── discovery_test.exs         # Online discovery
├── config_test.exs            # Configuration
└── tools/                     # Tool tests
    ├── post_to_x_test.exs
    ├── get_x_mentions_test.exs
    └── read_skill_test.exs
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

- Tests use temporary directories under `tmp/`
- Mock external APIs using `Mox` or bypass
- Built-in skill tests verify seeding behavior
- Installer tests use isolated temp directories

## Directory Structure

```
apps/lemon_skills/
├── lib/
│   ├── lemon_skills.ex              # Main API module
│   ├── lemon_skills/
│   │   ├── application.ex           # OTP app
│   │   ├── registry.ex              # GenServer registry
│   │   ├── entry.ex                 # Skill entry struct
│   │   ├── manifest.ex              # Manifest parsing
│   │   ├── status.ex                # Status checking
│   │   ├── installer.ex             # Installation logic
│   │   ├── config.ex                # Configuration
│   │   ├── builtin_seeder.ex        # Built-in skill seeding
│   │   ├── discovery.ex             # Online discovery
│   │   └── tools/
│   │       ├── post_to_x.ex
│   │       ├── get_x_mentions.ex
│   │       └── read_skill.ex
│   └── mix/tasks/
│       └── lemon.skill.ex           # Mix task
├── priv/
│   └── builtin_skills/              # Bundled skills
│       ├── github/
│       ├── tmux/
│       └── ...
└── test/
    └── lemon_skills/
```

## Dependencies

- `lemon_core` - Shared primitives
- `agent_core` - Agent types and tool definitions
- `ai` - AI types (TextContent)
- `lemon_channels` - X API integration
- `jason` - JSON encoding/decoding

## Key Modules Reference

| Module | Purpose |
|--------|---------|
| `LemonSkills` | Main public API |
| `LemonSkills.Registry` | GenServer for skill caching |
| `LemonSkills.Entry` | Skill entry struct |
| `LemonSkills.Manifest` | Parse YAML/TOML frontmatter |
| `LemonSkills.Installer` | Install/update/uninstall |
| `LemonSkills.Status` | Check requirements |
| `LemonSkills.Config` | Directory and config management |
| `LemonSkills.BuiltinSeeder` | Seed built-in skills |
| `LemonSkills.Discovery` | Online skill discovery |
| `Mix.Tasks.Lemon.Skill` | CLI interface |
