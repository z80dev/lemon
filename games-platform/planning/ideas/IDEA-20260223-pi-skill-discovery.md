---
id: IDEA-20260223-pi-skill-discovery
title: [Pi] Auto-Discover Skills in .agents Paths
source: pi
source_commit: 39cbf47e
discovered: 2026-02-23
status: completed
---

# Description
Pi added automatic skill discovery in `.agents` paths by default (commit 39cbf47e). This feature:
- Discovers skills in `.agents/skills/` and `.agents/` paths automatically
- Removes need for explicit skill configuration
- Updates package manager to scan default paths
- Includes 56 lines of new tests

Key changes in upstream:
- Modified `packages/coding-agent/src/core/package-manager.ts`
- Added `discoverSkillsInAgentsPaths()` function
- Updated documentation in README and SDK docs
- Changed default behavior to auto-discover

# Lemon Status
- Current state: **ALREADY IMPLEMENTED** - Lemon already has this feature!
- Implementation details:
  - `LemonSkills.Config.collect_ancestor_agents_skill_dirs/1` discovers `.agents/skills` from cwd up to git root
  - `LemonSkills.Config.project_skills_dirs/1` includes ancestor discovery automatically
  - Tests in `ancestor_skills_test.exs`, `ancestor_discovery_test.exs`, `registry_global_dirs_test.exs`
  - Global skills also check `~/.agents/skills` as a harness-compatible location

# Investigation Notes
- Complexity estimate: **N/A** - Feature already exists
- Value estimate: **N/A** - Already implemented
- Investigation findings:
  1. ✅ Lemon supports `.agents/skills/` path discovery
  2. ✅ Ancestor discovery walks from cwd up to git root
  3. ✅ Global `~/.agents/skills` is also supported
  4. ✅ Comprehensive test coverage exists

# Recommendation
**No action needed** - This feature is already fully implemented in Lemon. The implementation:
- Discovers `.agents/skills` directories from cwd up to git root
- Supports global `~/.agents/skills` for harness compatibility
- Has extensive test coverage (3 test files)
- Is documented in module docs and AGENTS.md

The IDEA was created based on incomplete information. After investigation, Lemon already has full parity with Pi's skill auto-discovery feature.

# References
- Pi commit: 39cbf47e
- Lemon implementation:
  - `apps/lemon_skills/lib/lemon_skills/config.ex` - `collect_ancestor_agents_skill_dirs/1`
  - `apps/lemon_skills/test/lemon_skills/ancestor_skills_test.exs`
  - `apps/lemon_skills/test/lemon_skills/ancestor_discovery_test.exs`
  - `apps/lemon_skills/test/lemon_skills/registry_global_dirs_test.exs`
