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

## 2026-01-31 13:48 ET
- Change: `CodingAgent.Subagents` now trims and rejects subagent entries with blank/whitespace `id` or `prompt`, and sanitizes non-binary `description` to "". This fixes `Subagents.get/2` returning a "custom" subagent whose prompt was only whitespace. (apps/coding_agent/lib/coding_agent/subagents.ex)
- Tests:
  - `mix test apps/coding_agent/test/coding_agent/subagents_test.exs` (pass)
- Commit: 6104417 (branch: auto/lemon-20260131-1346)
- Next: run the full umbrella `mix test` and pick off the next single failure (there were many earlier; this removes one of the named failures from the worklog).

## 2026-01-31 14:10 ET
- Change: Fix WebFetch to use supported Req connect options and add explicit format/timeout validation (prevents Req option crash and matches tool schema). (apps/coding_agent/lib/coding_agent/tools/webfetch.ex)
- Tests:
  - `mix test apps/coding_agent/test/coding_agent/tools/webfetch_test.exs` (pass)
- Commit: (see git log; branch: auto/lemon-20260131-1408)

## 2026-01-31 14:12 ET
- Change: Fix `AgentCore.Proxy.complete_json/1` to close `]` before `}` so partial JSON like `{ "items": [1,2` completes to `]}` (fixes `parse_streaming_json/1` for partial arrays). (apps/agent_core/lib/agent_core/proxy.ex)
- Tests:
  - `mix test apps/agent_core/test/agent_core/proxy_test.exs` (pass)
- Commit: c144e4a (branch: auto/lemon-20260131-1408)
- Next: Run full umbrella `mix test` and pick the next single failure to knock down (lots currently failing on main).

## 2026-01-31 14:35 ET
- Change: AgentCore.EventStream now demonitors the previously attached task when re-attaching, stores task_ref, and clears task_pid/task_ref on cancel/termination. Added regression test ensuring old task crash doesn't terminate stream after re-attach.
- Tests: mix test apps/agent_core (exit 0).
- Next: consider adding telemetry events for stream overflow/cancel/complete or integrating EventStream stats into agent-level metrics.

## 2026-01-31 14:58 ET
- Change: Harden Todo tools to match schema + tests:
  - Added `CodingAgent.Tools.TodoStore.delete/1` and `clear/0` (safe no-op if ETS table is missing).
  - `CodingAgent.Tools.TodoWrite` now validates todo entries (object shape, non-empty `id`/`content`, allowed `status`/`priority`, unique ids) before writing.
  - Prevents crashes from non-map todo entries and returns helpful error tuples.
- Tests:
  - `mix test apps/coding_agent/test/coding_agent/tools/todo_test.exs` (pass)
- Commit: dec3437 (branch: auto/lemon-20260131-1458)
- Next: Add `CodingAgent.Tools.WebSearch.reset_rate_limit/0` (no-op or ETS reset) to unbreak `WebSearchTest` setup, then tackle remaining `coding_agent` failures bucket-by-bucket.
