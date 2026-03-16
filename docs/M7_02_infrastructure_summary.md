# M7-02 Skill Synthesis Draft Pipeline - Infrastructure Summary

Date: 2026-03-16

## 1. MemoryDocument Fields

**Location**: `/home/z80/dev/lemon/apps/lemon_core/lib/lemon_core/memory_document.ex`

### Core Fields
- `doc_id` - Unique document ID (prefixed `"mem_"`)
- `run_id` - Source run ID
- `session_key` - Session the run belongs to
- `agent_id` - Agent that executed the run
- `workspace_key` - Workspace the run was executed in (nil if unknown)
- `scope` - Memory scope: `:session`, `:workspace`, `:agent`, or `:global`
- `started_at_ms` - Run start timestamp in milliseconds
- `ingested_at_ms` - When document was written to memory store

### Content/Summary Fields
- `prompt_summary` - Truncated prompt text (for FTS, max 2000 bytes)
- `answer_summary` - Truncated answer text (for FTS, max 2000 bytes)
- `tools_used` - List of tool name strings used during the run (deduplicated)

### Quality Signal Fields (KEY FOR DRAFT SYNTHESIS)
- `outcome` - Outcome label inferred by `LemonCore.RunOutcome.infer/1`
  - Type: `:success | :partial | :failure | :aborted | :unknown`
  - `success` → completed with `ok: true` and non-empty answer (BEST)
  - `partial` → completed with `ok: true` but no substantive answer (GOOD)
  - `failure` → completed with `ok: false` for non-abort reason (BAD)
  - `aborted` → cancelled by user or watchdog (SKIP)
  - `unknown` → cannot determine (SKIP)
- `meta` - Arbitrary metadata map (can be extended for quality signals)

### Model/Provider Tracking
- `provider` - LLM provider name (e.g., `"anthropic"`)
- `model` - LLM model name (e.g., `"claude-opus-4-6"`)

### Key Extraction Logic (from MemoryDocument.from_run/4):
```elixir
# Outcome inference priority:
# 1. Explicit :outcome field on summary (operator override)
# 2. completed.ok + answer content → :success or :partial
# 3. completed.ok == false + error text → :aborted or :failure
# 4. Top-level :ok fallback
# 5. Default: :unknown
```

### Summary for Draft Selection:
- **Filter for HIGH quality**: `outcome == :success` (has answer, completed successfully)
- **Consider MEDIUM quality**: `outcome == :partial` (may be tool-only runs, useful context)
- **Skip**: `:aborted`, `:failure`, `:unknown`

---

## 2. MemoryStore Query API

**Location**: `/home/z80/dev/lemon/apps/lemon_core/lib/lemon_core/memory_store.ex`

### Query Methods

#### Primary Queries (returns list of MemoryDocuments)
```elixir
# Fetch by session (typically single agent run)
LemonCore.MemoryStore.get_by_session(session_key, opts \\ [limit: 20])

# Fetch by agent across all sessions
LemonCore.MemoryStore.get_by_agent(agent_id, opts \\ [limit: 20])

# Fetch by workspace (multi-agent)
LemonCore.MemoryStore.get_by_workspace(workspace_key, opts \\ [limit: 20])
```

#### Full-Text Search (M5-02, available for draft similarity matching)
```elixir
# Options: scope: :session | :agent | :workspace | :all
LemonCore.MemoryStore.search(query, opts \\ [])
# Searches prompt_summary and answer_summary with FTS5

# Default scope: :session
# Required if scope != :all: :scope_key
# Optional: :limit (default 5)
```

#### Administrative
```elixir
# Aggregate stats
LemonCore.MemoryStore.stats() 
# => %{total: count, oldest_ms: timestamp, newest_ms: timestamp}

# Retention enforcement
LemonCore.MemoryStore.prune()
# => {:ok, %{swept: integer, pruned: integer}}

# Deletion by scope
LemonCore.MemoryStore.delete_by_session(session_key)
LemonCore.MemoryStore.delete_by_agent(agent_id)
LemonCore.MemoryStore.delete_by_workspace(workspace_key)
```

### Database Schema (SQLite)
```sql
CREATE TABLE memory_documents (
  doc_id TEXT PRIMARY KEY,
  run_id TEXT NOT NULL,
  session_key TEXT NOT NULL,
  agent_id TEXT NOT NULL,
  workspace_key TEXT,
  scope TEXT DEFAULT 'session',
  started_at_ms INTEGER NOT NULL,
  ingested_at_ms INTEGER NOT NULL,
  prompt_summary TEXT DEFAULT '',
  answer_summary TEXT DEFAULT '',
  tools_used_blob BLOB NOT NULL,           -- erlang term binary
  provider TEXT,
  model TEXT,
  outcome TEXT DEFAULT 'unknown',          -- KEY FIELD FOR FILTERING
  meta_blob BLOB NOT NULL                  -- erlang term binary
);

-- Indexes for fast scoped queries
idx_mem_session    ON (session_key, ingested_at_ms DESC)
idx_mem_agent      ON (agent_id, ingested_at_ms DESC)
idx_mem_workspace  ON (workspace_key, ingested_at_ms DESC)
idx_mem_ingested   ON (ingested_at_ms DESC)
```

### Configuration
```elixir
config :lemon_core, LemonCore.MemoryStore,
  path: "~/.lemon/store",          # memory.sqlite3 created inside
  retention_ms: 30 * 24 * 3600_000, # 30 days (default)
  max_per_scope: 500               # max documents per scope key
```

### Implementation Notes
- Uses `Exqlite.Sqlite3` (embedded SQLite)
- Runs as GenServer for concurrent access
- Write failures are logged but don't propagate (async cast)
- FTS5 for future full-text search support

---

## 3. Manifest v2 Structure for SKILL.md Generation

**Location**: `/home/z80/dev/lemon/apps/lemon_skills/lib/lemon_skills/manifest.ex`

### Parse/Generate API
```elixir
# Parse existing skill file
{:ok, manifest, body} = LemonSkills.Manifest.parse(content)
manifest["name"]       # => "k8s-rollout"
manifest["platforms"] # => ["linux", "darwin"]

# Parse frontmatter only
{:ok, manifest} = LemonSkills.Manifest.parse_frontmatter(content)

# Parse body only
body = LemonSkills.Manifest.parse_body(content)

# Validate and normalize
{:ok, normalised} = LemonSkills.Manifest.validate(manifest)
normalised["required_environment_variables"]  # always a list

# Determine version
:v2 = LemonSkills.Manifest.version(manifest)
```

### Manifest v2 Fields (All Optional with Defaults)

#### Legacy Fields (v1)
- `name` - Skill name
- `description` - Skill description
- `version` - Version string
- `author` - Author name
- `tags` - List of tags
- `requires.bins` - Required binaries list
- `requires.config` - Required environment variables (legacy)

#### v2 Extension Fields
```yaml
# Multi-platform support
platforms: ["linux", "darwin", "win32", "any"]

# Semantic categorization for registry
metadata:
  lemon:
    category: "devops/kubernetes"

# Semantic dependencies (not just bins)
requires_tools: ["docker", "kubectl"]

# Tools this skill provides guidance for
fallback_for_tools: ["helm", "kustomize"]

# Environment requirements (replaces requires.config)
required_environment_variables:
  - KUBECONFIG
  - HELM_EXPERIMENTAL_OCI

# Verification method (e.g., test script)
verification:
  method: "script"
  command: "./verify.sh"
  expected_exit_code: 0

# References/supplementary materials
references:
  - path: "README.md"
  - url: "https://kubernetes.io/docs/concepts/..."
  - path: "examples/deployment.yaml"
```

### Accessor Functions for Generated Content
```elixir
LemonSkills.Manifest.required_bins(manifest)                 # => [String]
LemonSkills.Manifest.required_config(manifest)               # => [String] (legacy)
LemonSkills.Manifest.required_environment_variables(manifest) # => [String]
LemonSkills.Manifest.requires_tools(manifest)                # => [String]
LemonSkills.Manifest.fallback_for_tools(manifest)            # => [String]
LemonSkills.Manifest.platforms(manifest)                     # => [String] (defaults to ["any"])
LemonSkills.Manifest.references(manifest)                    # => [map | String]
LemonSkills.Manifest.lemon_category(manifest)                # => String | nil
```

### Parser Implementation Details
- Supports YAML (---) and TOML (+++) frontmatter
- Hand-rolled YAML subset parser (dependency-free, covers 2-level nesting)
- Scalar coercion: "true"/"false" → booleans, rest → strings

### Validation Returns Normalized Manifest
- All v2 fields present with sensible defaults
- Legacy skills remain valid (get v2 defaults applied)
- String keys (consistent with YAML/TOML output)

---

## 4. Existing Draft/Synthesis Infrastructure

**Search Results**: No existing draft or synthesis files found in codebase

- No `*draft*` files in `apps/lemon_skills/lib/**/*`
- No `*synthesis*` files in `apps/lemon_skills/lib/**/*`
- Feature flag exists: `skill_synthesis_drafts = "off"` in `/home/z80/dev/lemon/docs/config.md` (line 179)
- M7-02 mentioned in missions as "skill synthesis draft pipeline"

### Rollout Configuration
- Feature flags in config: `config :lemon_core, :feature_flags`
- Used for M7-02 progressive rollout
- Config path: `~/.lemon/config.toml` + `/project/.lemon/config.toml`

---

## 5. Skill Directory Config & Conventions

**Location**: `/home/z80/dev/lemon/apps/lemon_skills/lib/lemon_skills/config.ex`

### Directory Structure

#### Global Skills
```
~/.lemon/agent/
├── skill/                  # Primary (highest precedence)
│   ├── bun-file-io/
│   │   └── SKILL.md
│   └── git-workflow/
│       └── SKILL.md
└── skills.json            # Global config

~/.agents/skills/          # Harness-compatible (fallback)
├── some-skill/
│   └── SKILL.md
```

#### Project Skills
```
<project>/.lemon/
├── skill/                 # Primary project skills
│   └── my-custom-skill/
│       └── SKILL.md
└── skills.json           # Project config

<project>/.agents/skills/ # Harness-compatible project skills
└── another-skill/
    └── SKILL.md
```

#### Ancestor Discovery (.agents/skills)
Skills in `.agents/skills` are discovered from cwd up to git repo root:
```
/home/user/myrepo/
├── .lemon/skill/             # Highest priority
├── packages/
│   └── feature/
│       ├── .lemon/skill/
│       └── .agents/skills/    # Discovered 3rd
├── .agents/skills/            # Discovered 4th (repo root)
```

### Config API
```elixir
# Directories
LemonSkills.Config.global_skills_dir()      # => "~/.lemon/agent/skill"
LemonSkills.Config.global_skills_dirs()     # => [global, compat]
LemonSkills.Config.project_skills_dir(cwd)  # => "<cwd>/.lemon/skill"
LemonSkills.Config.project_skills_dirs(cwd) # => [project, ancestors, compat]

# Config files
LemonSkills.Config.global_config_file()     # => "~/.lemon/agent/skills.json"
LemonSkills.Config.project_config_file(cwd) # => "<cwd>/.lemon/skills.json"

# Load/Save
config = LemonSkills.Config.load_config(cwd)
LemonSkills.Config.save_config(config, global, cwd)

# Skill-specific config
skill_cfg = LemonSkills.Config.get_skill_config(key, cwd)
LemonSkills.Config.set_skill_config(key, cfg, opts)

# Enable/Disable
LemonSkills.Config.enable(key, opts)
LemonSkills.Config.disable(key, opts)

# Directories exist?
LemonSkills.Config.ensure_dirs!()
```

### Draft Directory Convention (PROPOSED)
- Follow the precedence pattern: `~/.lemon/agent/skill_drafts/` (global) and `<project>/.lemon/skill_drafts/` (project)
- Or: `~/.lemon/agent/drafts/` to match existing flat structure
- Store as SKILL.md files, follow same directory-per-skill pattern

---

## 6. Mix Task Patterns for Review Commands

**Location**: `/home/z80/dev/lemon/apps/lemon_skills/lib/mix/tasks/lemon.skill.ex`

### Existing Skill Management Task Structure
```elixir
mix lemon.skill list              # List installed skills
mix lemon.skill browse            # Browse with activation state
mix lemon.skill search <query>    # Search local + online
mix lemon.skill discover <query>  # Discover from GitHub
mix lemon.skill install <source>  # Install from URL/path
mix lemon.skill update <key>      # Update installed skill
mix lemon.skill remove <key>      # Remove installed skill
mix lemon.skill inspect <key>     # Deep-inspect skill (provenance, hashes, etc.)
mix lemon.skill check <key>       # Check readiness (requirements, drift)
mix lemon.skill info <key>        # Show details (alias for inspect)
```

### Command Pattern (from task implementation)
```elixir
defmodule Mix.Tasks.Lemon.Skill do
  use Mix.Task
  
  @impl true
  def run(args) do
    Mix.Task.run("app.start")      # Ensure app started
    
    case args do
      ["list" | opts] -> list_skills(opts)
      ["inspect", key | opts] -> inspect_skill(key, opts)
      _ -> print_usage()
    end
  end
  
  # Option parsing
  defp get_cwd(opts) do
    case Enum.find(opts, &String.starts_with?(&1, "--cwd=")) do
      nil -> File.cwd!()
      opt -> String.replace_prefix(opt, "--cwd=", "")
    end
  end
  
  defp get_int_opt(opts, flag, default) do
    case Enum.find(opts, &String.starts_with?(&1, "#{flag}=")) do
      nil -> default
      opt -> String.replace_prefix(opt, "#{flag}=", "") |> String.to_integer()
    end
  end
end
```

### Key Patterns
- Entry point: `run(args)` with case match on first arg
- Option parsing: `--cwd=<path>`, `--global`, `--local`, `--force`, etc.
- Output: via `Mix.shell().info()`, `.error()`, `.prompt()`
- Formatting: tables via padding/alignment, colored output with `[:color, text, :reset]`
- Error handling: `Mix.raise(reason)` on fatal errors

### Suggested Command Pattern for Draft Review
```elixir
mix lemon.skill draft list              # List draft skills
mix lemon.skill draft review <key>      # Show draft with quality signals
mix lemon.skill draft publish <key>     # Promote draft to installed
mix lemon.skill draft delete <key>      # Remove draft
mix lemon.skill draft generate <query>  # Synthesize drafts from memory
mix lemon.skill draft check <key>       # Validate draft readiness
```

---

## 7. Skill Registration System

**Location**: `/home/z80/dev/lemon/apps/lemon_skills/lib/lemon_skills/registry.ex`

### Registry API
```elixir
# List all skills (merged global + project)
skills = LemonSkills.Registry.list(cwd: nil, refresh: false)

# Get single skill
{:ok, entry} = LemonSkills.Registry.get(key, cwd: nil)

# Find relevant skills (keyword matching)
relevant = LemonSkills.Registry.find_relevant(context, cwd: nil, max_results: 3)

# Search (local + online)
%{local: [...], online: [...]} = LemonSkills.Registry.search(query, 
  cwd: nil, max_local: 3, max_online: 5, include_online: true)

# Counts
%{installed: n, enabled: m} = LemonSkills.Registry.counts(cwd: nil)

# Refresh
:ok = LemonSkills.Registry.refresh(cwd: nil)

# Register/Unregister
:ok = LemonSkills.Registry.register(entry)
:ok = LemonSkills.Registry.unregister(key, :global, nil)
```

### Entry Structure
```elixir
%LemonSkills.Entry{
  key: "skill-name",
  name: "Skill Name",
  description: "...",
  path: "/path/to/skill",
  source: :global | :project | url_string,
  enabled: true,
  manifest: %{...},            # Parsed and validated v2 manifest
  content_hash: "sha256...",   # For drift detection
  upstream_hash: "sha256...",  # For update detection
  trust_level: nil | :verified,
  source_kind: "github" | nil,
  source_id: "user/repo" | nil,
  installed_at: %DateTime{},
  updated_at: %DateTime{},
  audit_status: nil | "passed",
  audit_findings: []
}
```

### Skill Activation States
- `:active` - Ready to use (all requirements met)
- `:not_ready` - Missing requirements (bins, env vars, tools)
- `:hidden` - Explicitly hidden from browse
- `:platform_incompatible` - Platform not supported
- `:blocked` - Disabled or incompatible with agent

### Relevance Scoring
- Exact name match: +100
- Partial name match: +50
- Exact keyword match: +40 per word
- Description word match: +10 per word
- Body content match: +2 per word
- Project-local bonus: +1000
- Min score threshold for filtering: > 0

---

## 8. Key Takeaways for M7-02 Implementation

### Quality Signals Available
1. **Primary**: `MemoryDocument.outcome` field
   - `:success` = best quality drafts (complete + answer)
   - `:partial` = usable (complete, no answer)
   - Skip `:failure`, `:aborted`, `:unknown`

2. **Secondary**: Metadata extensibility
   - Can add custom quality signals to `MemoryDocument.meta`
   - E.g., `meta.skill_category`, `meta.confidence`, `meta.relevance_score`

### Query Patterns
- **Batch query**: `MemoryStore.get_by_agent(agent_id, limit: 100)` for draft synthesis
- **Filter in code**: by `outcome`, `tools_used`, `timestamp` range
- **Search**: `MemoryStore.search(query, scope: :agent)` for similarity matching

### Manifest Generation
- Use `LemonSkills.Manifest.parse/1` + `validate/1` for round-trip
- All v2 fields will have defaults after validation
- String keys in normalized manifest (YAML/TOML compatible)

### Directory Structure for Drafts
- Convention: `~/.lemon/agent/skill_drafts/` (global) + `<project>/.lemon/skill_drafts/` (project)
- Each draft: `skill_drafts/<draft-key>/SKILL.md` (same pattern as installed skills)
- Config: `~/.lemon/agent/skill_drafts.json` or nested in `skills.json`

### Mix Task Pattern
- Entry point: `mix lemon.skill draft <subcommand>`
- Follow existing skill command patterns
- Options: `--cwd=<path>`, `--global`/`--local`, `--force`
- Output: Mix.shell() for consistent styling

### Registry Integration
- Draft registry separate from skill registry initially (avoid collision)
- Future: merge into unified registry with `source: :draft` designation
- Entry state: `:draft` (review pending), `:promoted` (published), `:archived` (rejected)

### No Breaking Changes
- All infrastructure exists and stable
- Feature flag for progressive rollout
- Backward compatible with existing v1 skills
- Config extends naturally

---

## File Paths (Absolute)

- `/home/z80/dev/lemon/apps/lemon_skills/lib/lemon_skills/manifest.ex` - Main API
- `/home/z80/dev/lemon/apps/lemon_skills/lib/lemon_skills/manifest/parser.ex` - Parse implementation
- `/home/z80/dev/lemon/apps/lemon_skills/lib/lemon_skills/manifest/validator.ex` - Validation + defaults
- `/home/z80/dev/lemon/apps/lemon_core/lib/lemon_core/memory_store.ex` - Query API
- `/home/z80/dev/lemon/apps/lemon_core/lib/lemon_core/memory_document.ex` - MemoryDocument struct + extraction
- `/home/z80/dev/lemon/apps/lemon_core/lib/lemon_core/run_outcome.ex` - Outcome inference logic
- `/home/z80/dev/lemon/apps/lemon_skills/lib/lemon_skills/config.ex` - Directory configuration
- `/home/z80/dev/lemon/apps/lemon_skills/lib/mix/tasks/lemon.skill.ex` - Mix task pattern
- `/home/z80/dev/lemon/apps/lemon_skills/lib/lemon_skills/registry.ex` - Skill registration system

