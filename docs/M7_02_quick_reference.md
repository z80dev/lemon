# M7-02 Skill Synthesis Draft Pipeline - Quick Reference

## Memory Document Quality Signals

```elixir
# Best candidates for draft synthesis:
docs = LemonCore.MemoryStore.get_by_agent(agent_id, limit: 100)

high_quality = docs
  |> Enum.filter(fn doc -> doc.outcome == :success end)
  |> Enum.filter(fn doc -> doc.answer_summary != "" end)
  |> Enum.sort_by(fn doc -> doc.ingested_at_ms end, :desc)
```

**Outcome Enum Values**:
- `:success` = completed with answer (BEST - use these)
- `:partial` = completed, no answer (OK - use sparingly)
- `:failure` = completed with error (SKIP)
- `:aborted` = user cancelled (SKIP)
- `:unknown` = cannot determine (SKIP)

## Manifest v2 Generation

```elixir
# Create new manifest
manifest = %{
  "name" => "my-new-skill",
  "description" => "...",
  "requires_tools" => ["docker"],
  "required_environment_variables" => ["API_KEY"],
  "platforms" => ["linux", "darwin"]
}

# Validate and normalize
{:ok, normalized} = LemonSkills.Manifest.validate(manifest)

# All v2 fields now have defaults, safe to access
normalized["platforms"]  # => ["linux", "darwin"]
normalized["required_environment_variables"]  # => ["API_KEY"]
```

## Directory Structure (Draft Convention)

```
~/.lemon/agent/
├── skill/              # Published skills
└── skill_drafts/       # Draft skills (in review)
    ├── my-draft-1/
    │   └── SKILL.md
    └── my-draft-2/
        └── SKILL.md

<project>/.lemon/
├── skill/              # Project skills
└── skill_drafts/       # Project draft skills
```

## Mix Task Pattern

```bash
# Proposed commands
mix lemon.skill draft list
mix lemon.skill draft generate <agent-id>
mix lemon.skill draft review <key>
mix lemon.skill draft publish <key>
mix lemon.skill draft delete <key>
```

## Registry Integration

### For Draft Registry

```elixir
%LemonSkills.Entry{
  key: "my-draft-skill",
  path: "~/.lemon/agent/skill_drafts/my-draft-skill",
  source: :draft,           # NEW: distinguish from installed
  manifest: %{...},         # v2 manifest
  enabled: true,
}
```

### Entry State Tracking

- `:draft` - Under review (pending human review)
- `:promoted` - Published to installed skills
- `:archived` - Rejected/removed

## Query Patterns for Synthesis

```elixir
# 1. Get candidate memories
memories = LemonCore.MemoryStore.get_by_agent(agent_id, limit: 100)

# 2. Filter by quality
candidates = Enum.filter(memories, fn doc -> doc.outcome == :success end)

# 3. Group by tool usage (optional)
by_tools = Enum.group_by(candidates, & &.tools_used)

# 4. Extract content for synthesis
prompts = Enum.map(candidates, & &.prompt_summary)
answers = Enum.map(candidates, & &.answer_summary)
```

## Manifest Parser/Generator

```elixir
# Parse existing skill file
{:ok, manifest, body} = LemonSkills.Manifest.parse(skill_md_content)

# Generate new SKILL.md file
frontmatter = Jason.encode!(manifest, pretty: true)
skill_md = "---\n#{frontmatter}\n---\n\n#{body}"
File.write!("SKILL.md", skill_md)
```

## Configuration & Feature Flag

```toml
# ~/.lemon/config.toml
[feature_flags]
skill_synthesis_drafts = "on"  # Enable M7-02

[memory_store]
retention_ms = 2592000000  # 30 days (for draft extraction)
```

## Key Files to Reference

- **MemoryDocument**: `/home/z80/dev/lemon/apps/lemon_core/lib/lemon_core/memory_document.ex` (lines 23-41: fields)
- **RunOutcome**: `/home/z80/dev/lemon/apps/lemon_core/lib/lemon_core/run_outcome.ex` (lines 8-16: semantics)
- **Manifest v2**: `/home/z80/dev/lemon/apps/lemon_skills/lib/lemon_skills/manifest.ex` (lines 14-24: schema)
- **Config Dirs**: `/home/z80/dev/lemon/apps/lemon_skills/lib/lemon_skills/config.ex` (lines 10-47: directory layout)
- **Mix Task Pattern**: `/home/z80/dev/lemon/apps/lemon_skills/lib/mix/tasks/lemon.skill.ex` (lines 59-102: task structure)

