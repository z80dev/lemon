---
id: PLN-20260224-inspiration-ideas-implementation
title: Implement Inspiration Ideas from Upstream Research
owner: janitor
reviewer: codex
status: ready_to_land
workspace: feature/pln-20260224-inspiration-ideas-implementation
change_id: pending
created: 2026-02-24
updated: 2026-02-25
---

## Goal

Implement three high-value, low-complexity features identified during upstream inspiration research:
1. Chinese context overflow error pattern detection
2. Grep grouped output with round-robin limiting
3. Auto-reasoning gate by effective thinking level

## Background

During inspiration research from Oh-My-Pi, OpenClaw, and Pi upstream projects, several features were identified as "proceed" recommendations. This plan implements three of them that are small-to-medium complexity with medium-to-high value.

## Milestones

- [x] M1 — Chinese context overflow pattern detection
- [x] M2 — Grep grouped output with round-robin limiting
- [x] M3 — Auto-reasoning gate implementation
- [x] M4 — Final review and landing

## M1: Chinese Context Overflow Pattern Detection

### Description
Add detection for Chinese context overflow error patterns to improve error classification for non-English error messages.

### Chinese Patterns Added
- "上下文长度超过限制" — context length exceeds limit
- "令牌数量超出" — token count exceeded
- "输入过长" — input too long
- "超出最大长度" — exceeds maximum length
- "上下文窗口已满" — context window full

### Files Modified
- `apps/coding_agent/lib/coding_agent/session.ex` — Added Chinese patterns to `context_length_exceeded_error?/1`
- `apps/lemon_gateway/lib/lemon_gateway/run.ex` — Added Chinese patterns to `@context_overflow_error_markers`
- `apps/lemon_router/lib/lemon_router/run_process.ex` — Added Chinese patterns to `@context_overflow_error_markers`

### Testing
- Existing overflow recovery tests pass
- Chinese patterns are detected via string matching in error text

## M2: Grep Grouped Output with Round-Robin Limiting

### Description
Add grouped output format and round-robin limiting to the grep tool for better result organization when searching across many files.

### New Parameters
- `grouped` (boolean, default: false) — Return results grouped by file
- `max_per_file` (integer, optional) — Maximum results per file when grouped

### Output Format (when grouped=true)
```elixir
%{
  "results" => %{
    "file1.ex" => [%{line: 1, match: "..."}, ...],
    "file2.ex" => [%{line: 5, match: "..."}, ...]
  },
  "total_matches" => 10,
  "files_searched" => 5,
  "truncated" => false
}
```

### Files Modified
- `apps/coding_agent/lib/coding_agent/tools/grep.ex` — Added grouped output and round-robin limiting
- `apps/coding_agent/test/coding_agent/tools/grep_test.exs` — Added tests for new functionality

### New Functions
- `do_grouped_elixir_search/3` — Collects matches per file
- `parse_ripgrep_output_grouped/2` — Parses ripgrep output into grouped format
- `apply_grouped_limits/3` — Applies max_per_file and round-robin limits
- `round_robin_take/2` / `do_round_robin/5` — Round-robin distribution algorithm

### Testing
- 9 new tests covering grouped output, max_per_file, round-robin distribution
- All 37 grep tests pass

## M3: Auto-Reasoning Gate by Effective Thinking Level

### Description
Gate auto-reasoning to prevent redundant reasoning when thinking is already active.

### Logic
- If `thinking_level != :off` → use `thinking_level` (thinking already active)
- If `thinking_level == :off` AND `auto_reasoning == true` AND `model.reasoning == true` → `:medium`
- Otherwise → `nil`

### Files Modified
- `apps/agent_core/lib/agent_core/types.ex` — Added `auto_reasoning: boolean()` field to `AgentState`
- `apps/agent_core/lib/agent_core/agent.ex` — Added `set_auto_reasoning/2` API and `effective_reasoning/1` gate
- `apps/agent_core/test/agent_core/agent_test.exs` — Added tests for auto-reasoning functionality

### Testing
- 6 new tests covering set_auto_reasoning API and stream options
- All 79 agent tests pass

## Exit Criteria

- [x] All three features implemented
- [x] Tests pass for all modified modules
- [x] No regressions in existing functionality
- [x] Code review completed
- [ ] Merged to main

## Progress Log

| Timestamp | Milestone | Notes |
|-----------|-----------|-------|
| 2026-02-24 | M1 | Added Chinese context overflow patterns to session.ex, run.ex, and run_process.ex |
| 2026-02-24 | M2 | Implemented grouped output and round-robin limiting in grep tool |
| 2026-02-24 | M3 | Implemented auto-reasoning gate in agent_core |
| 2026-02-24 | Tests | All tests pass: 79 agent tests, 37 grep tests, 5 overflow recovery tests |
| 2026-02-25 | M1 verification/backfill | Added missing Chinese overflow markers (`上下文长度超过限制`, `令牌数量超出`, `输入过长`, `超出最大长度`, `上下文窗口已满`) to `coding_agent/session`, `lemon_gateway/run`, and `lemon_router/run_process`; added regression tests in `session_overflow_recovery_test.exs` and `lemon_gateway/run_test.exs`. Router suite has unrelated pre-existing `TestRunOrchestrator` failures in this environment. |
| 2026-02-25 | M4 | Completed review + merge artifacts and moved plan to `ready_to_land`; revalidated targeted suites (`session_overflow_recovery`, `run_test:2361`, `agent_test`, `grep_test`) and reconfirmed existing unrelated router harness failure at `run_process_test:697`. |
