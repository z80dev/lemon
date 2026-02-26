---
id: IDEA-20260223-ironclaw-shell-completion
title: [IronClaw] Shell Completion Generation via clap_complete
source: ironclaw
source_commit: 7f68207
discovered: 2026-02-23
status: proposed
---

# Description
IronClaw added shell completion generation using `clap_complete` crate (commit 7f68207). This feature:
- Generates bash, zsh, and fish completions automatically
- Uses `clap_complete::Shell` for native completion support
- Adds 5,953 lines of generated completion files
- Improves CLI UX with tab completion

Key changes in upstream:
- Modified `src/cli/completion.rs` (39 lines)
- Added `clap_complete` dependency
- Generated `ironclaw.bash`, `ironclaw.fish`, `ironclaw.zsh`

# Lemon Status
- Current state: **Doesn't have** - Lemon uses Mix tasks, not CLI
- Gap analysis:
  - Lemon is Elixir-based with `mix` tasks
  - Has `mix lemon.*` tasks in `apps/lemon_core/lib/mix/tasks/`
  - No shell completion support currently
  - Could add completion scripts for Mix tasks

# Investigation Notes
- Complexity estimate: **M**
- Value estimate: **L** - Nice DX improvement
- Open questions:
  1. Can Mix tasks have shell completion?
  2. Should Lemon generate completion scripts for common shells?
  3. What's the effort to maintain completion scripts?
  4. Is there an Elixir equivalent to clap_complete?

# Recommendation
**Defer** - Nice-to-have DX improvement. Lower priority. Consider as part of CLI polish effort. Could be a good first contribution for community.

# References
- IronClaw commit: 7f68207
- Lemon files:
  - `apps/lemon_core/lib/mix/tasks/` - Mix tasks
