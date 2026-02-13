# Lemon — Continuous Improvement Loop

Every ~30 minutes we run:
1) **Codex**: review + brainstorm + plan next steps
2) **Claude Code**: implement the highest-leverage slice, update docs/tests

Outputs are written to `docs/agent-loop/runs/` and summarized back to z80.

## Working rules
- Prefer small, mergeable increments.
- Always leave a paper trail:
  - what we observed
  - what we decided
  - what changed (diff)
  - what’s next
- Keep architecture modular; avoid hard-coding client-specific behavior into the core.
- Run periodic entropy cleanup for run artifacts:
  - `mix lemon.cleanup` (dry-run)
  - `mix lemon.cleanup --apply --retention-days 21` (prune old run files)
