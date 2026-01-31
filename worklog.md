# Worklog

## 2026-01-30
- Initialized worklog and prepared to consolidate existing uncommitted changes.

## 2026-01-31 13:26 ET
- Change: lemon-tui now sets `inputEditor.disableSubmit = state.busy` when busy state changes, preventing accidental submits while the agent is streaming/processing. (clients/lemon-tui/src/index.ts)
- Tests:
  - clients/lemon-tui: `npm test` (pass), `npm run build` (pass)
  - repo root: `mix test` currently failing on main branch state (1557 tests, 76 failures; e.g. CodingAgent.SubagentsTest `filters invalid entries and merges overrides`). Not touched by this change.
- Commit: 076409e (branch: auto/lemon-20260131-1322)
- Next: Investigate/fix the failing `CodingAgent.SubagentsTest` (likely whitespace/blank prompt handling) and then re-run `mix test` until green.
