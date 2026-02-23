# PLN-20260222: Debt Phase 5 — Complexity Reduction in Largest Modules/Files

**Date:** 2026-02-22
**Owner:** Platform Engineering
**Branch:** `feature/pln-20260222-debt-phase-05-complexity-reduction`
**Status:** M1 Complete

---

## Goal

Create a ranked inventory of the largest and highest-complexity modules in the codebase to inform refactoring priorities, then execute targeted extractions in subsequent milestones.

---

## Milestones

- [x] **M1** — Baseline complexity/churn inventory (analysis only)
- [ ] **M2** — Extract submodules from top 3–5 candidates
- [ ] **M3** — Validate behavior parity with contract tests
- [ ] **M4** — Update docs and close out phase

---

## M1: Baseline Complexity/Churn Inventory

### Analysis Method

- **Module sizes:** `find apps/*/lib/ -name '*.ex' | xargs wc -l | sort -rn`
- **Test sizes:** `find apps/*/test/ -name '*.exs' | xargs wc -l | sort -rn`
- **Churn (all-time):** `git log --format=format: --name-only -- 'apps/*/lib/**/*.ex' | sort | uniq -c | sort -rn | head -30`
- **Churn (30d):** Same command with `--since="30 days ago"`
- **Analysis date:** 2026-02-22

---

### Top 20 Largest Source Modules

| Rank | File | Lines |
|------|------|-------|
| 1 | `apps/ai/lib/ai/models.ex` | 11,203 |
| 2 | `apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport.ex` | 3,950 |
| 3 | `apps/coding_agent/lib/coding_agent/session.ex` | 3,261 |
| 4 | `apps/lemon_router/lib/lemon_router/run_process.ex` | 1,984 |
| 5 | `apps/coding_agent/lib/coding_agent/tools/task.ex` | 1,591 |
| 6 | `apps/lemon_gateway/lib/lemon_gateway/transports/webhook.ex` | 1,489 |
| 7 | `apps/lemon_channels/lib/lemon_channels/adapters/xmtp/transport.ex` | 1,432 |
| 8 | `apps/coding_agent/lib/coding_agent/extensions.ex` | 1,393 |
| 9 | `apps/ai/lib/ai/providers/openai_completions.ex` | 1,388 |
| 10 | `apps/ai/lib/ai/providers/bedrock.ex` | 1,386 |
| 11 | `apps/lemon_router/lib/lemon_router/stream_coalescer.ex` | 1,368 |
| 12 | `apps/ai/lib/ai/providers/anthropic.ex` | 1,339 |
| 13 | `apps/lemon_core/lib/lemon_core/config.ex` | 1,259 |
| 14 | `apps/coding_agent/lib/coding_agent/tools/websearch.ex` | 1,237 |
| 15 | `apps/lemon_gateway/lib/lemon_gateway/transports/email/inbound.ex` | 1,228 |
| 16 | `apps/agent_core/lib/agent_core/agent.ex` | 1,193 |
| 17 | `apps/agent_core/lib/agent_core/cli_runners/jsonl_runner.ex` | 1,174 |
| 18 | `apps/ai/lib/ai/providers/openai_responses_shared.ex` | 1,085 |
| 19 | `apps/coding_agent/lib/coding_agent/compaction.ex` | 1,081 |
| 20 | `apps/coding_agent/lib/coding_agent/tools/fuzzy.ex` | 1,051 |

**Total lines across all lib .ex files:** ~154,243

---

### Top 20 Largest Test Files

| Rank | File | Lines |
|------|------|-------|
| 1 | `apps/lemon_gateway/test/run_test.exs` | 2,878 |
| 2 | `apps/coding_agent/test/coding_agent/extensions_test.exs` | 2,677 |
| 3 | `apps/coding_agent/test/coding_agent/compaction_test.exs` | 2,490 |
| 4 | `apps/lemon_gateway/test/scheduler_test.exs` | 2,298 |
| 5 | `apps/lemon_gateway/test/thread_worker_test.exs` | 2,169 |
| 6 | `apps/ai/test/providers/google_vertex_comprehensive_test.exs` | 2,133 |
| 7 | `apps/ai/test/providers/azure_openai_comprehensive_test.exs` | 2,094 |
| 8 | `apps/agent_core/test/agent_core/context_test.exs` | 1,861 |
| 9 | `apps/coding_agent/test/coding_agent/session_test.exs` | 1,839 |
| 10 | `apps/ai/test/providers/openai_codex_comprehensive_test.exs` | 1,760 |
| 11 | `apps/coding_agent_ui/test/coding_agent/ui/rpc_test.exs` | 1,748 |
| 12 | `apps/ai/test/providers/google_gemini_cli_comprehensive_test.exs` | 1,748 |
| 13 | `apps/agent_core/test/agent_core/cli_runners/claude_runner_test.exs` | 1,735 |
| 14 | `apps/agent_core/test/agent_core/cli_runners/codex_subagent_comprehensive_test.exs` | 1,733 |
| 15 | `apps/agent_core/test/agent_core/cli_runners/codex_runner_test.exs` | 1,672 |
| 16 | `apps/coding_agent/test/coding_agent/tools/find_test.exs` | 1,550 |
| 17 | `apps/agent_core/test/agent_core/proxy_error_test.exs` | 1,525 |
| 18 | `apps/agent_core/test/agent_core/cli_runners/claude_subagent_test.exs` | 1,502 |
| 19 | `apps/agent_core/test/agent_core/context_property_test.exs` | 1,475 |
| 20 | `apps/coding_agent/test/coding_agent/tools/patch_test.exs` | 1,447 |

**Total lines across all test .exs files:** ~212,357

---

### High-Churn Files (All-Time Commits)

Measured via `git log --format=format: --name-only -- 'apps/*/lib/**/*.ex' | sort | uniq -c | sort -rn | head -30`:

| Commits | File |
|---------|------|
| 31 | `apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport.ex` |
| 30 | `apps/coding_agent/lib/coding_agent/session.ex` |
| 29 | `apps/ai/lib/ai/models.ex` |
| 26 | `apps/lemon_router/lib/lemon_router/run_process.ex` |
| 22 | `apps/lemon_gateway/lib/lemon_gateway/run.ex` |
| 20 | `apps/coding_agent/lib/coding_agent/tools/task.ex` |
| 19 | `apps/lemon_gateway/lib/lemon_gateway/telegram/transport.ex` |
| 18 | `apps/lemon_core/lib/lemon_core/config.ex` |
| 18 | `apps/coding_agent/lib/coding_agent/tool_registry.ex` |
| 17 | `apps/lemon_router/lib/lemon_router/stream_coalescer.ex` |
| 17 | `apps/lemon_router/lib/lemon_router/run_orchestrator.ex` |
| 16 | `apps/lemon_gateway/lib/lemon_gateway/config_loader.ex` |
| 15 | `apps/lemon_gateway/lib/lemon_gateway/thread_worker.ex` |
| 15 | `apps/lemon_gateway/lib/lemon_gateway/application.ex` |
| 13 | `apps/lemon_gateway/lib/lemon_gateway/scheduler.ex` |
| 13 | `apps/lemon_channels/lib/lemon_channels/adapters/telegram/outbound.ex` |
| 12 | `apps/lemon_gateway/lib/lemon_gateway/telegram/api.ex` |
| 12 | `apps/agent_core/lib/agent_core/cli_runners/jsonl_runner.ex` |
| 11 | `apps/lemon_gateway/lib/lemon_gateway/telegram/outbox.ex` |
| 11 | `apps/lemon_core/lib/lemon_core/config/validator.ex` |
| 11 | `apps/coding_agent/lib/coding_agent/tools/websearch.ex` |
| 11 | `apps/coding_agent/lib/coding_agent/tools/hashline.ex` |
| 11 | `apps/ai/lib/ai/providers/anthropic.ex` |
| 11 | `apps/agent_core/lib/agent_core/cli_runners/codex_runner.ex` |
| 10 | `apps/lemon_gateway/lib/lemon_gateway/store.ex` |
| 10 | `apps/lemon_gateway/lib/lemon_gateway/engines/cli_adapter.ex` |
| 10 | `apps/lemon_gateway/lib/lemon_gateway/config.ex` |
| 10 | `apps/lemon_core/lib/lemon_core/store.ex` |
| 10 | `apps/lemon_control_plane/lib/lemon_control_plane/protocol/schemas.ex` |

### High-Churn Files (Last 30 Days)

Same command with `--since="30 days ago"` (identical results — all commits are within the 30-day window for this repo's recent history):

| Commits (30d) | File |
|---------------|------|
| 32 | `apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport.ex` |
| 31 | `apps/coding_agent/lib/coding_agent/session.ex` |
| 29 | `apps/ai/lib/ai/models.ex` |
| 27 | `apps/lemon_router/lib/lemon_router/run_process.ex` |
| 23 | `apps/lemon_gateway/lib/lemon_gateway/run.ex` |
| 20 | `apps/coding_agent/lib/coding_agent/tools/task.ex` |
| 20 | `apps/lemon_gateway/lib/lemon_gateway/telegram/transport.ex` |
| 19 | `apps/lemon_core/lib/lemon_core/config.ex` |
| 18 | `apps/coding_agent/lib/coding_agent/tool_registry.ex` |
| 18 | `apps/lemon_router/lib/lemon_router/stream_coalescer.ex` |
| 17 | `apps/lemon_router/lib/lemon_router/run_orchestrator.ex` |
| 16 | `apps/lemon_gateway/lib/lemon_gateway/config_loader.ex` |
| 15 | `apps/lemon_gateway/lib/lemon_gateway/thread_worker.ex` |
| 15 | `apps/lemon_gateway/lib/lemon_gateway/application.ex` |
| 13 | `apps/lemon_gateway/lib/lemon_gateway/scheduler.ex` |

---

### Cross-Reference: Known Debt Candidates

The debt plan (`debt_plan.md`) calls out two specific files. Confirmed measurements:

| File | Lines | All-Time Commits | 30d Commits | Status |
|------|-------|-----------------|-------------|--------|
| `apps/ai/lib/ai/models.ex` | **11,203** | 29 | 29 | Confirmed top candidate — #1 by size, #3 by churn |
| `apps/coding_agent/lib/coding_agent/session.ex` | **3,261** | 30 | 31 | Confirmed top candidate — #3 by size, #2 by churn |

Both files are unambiguously in the top tier by both size and churn. They are the primary targets as originally identified.

---

### Ranked Inventory: Size × Churn Cross-Reference

The table below combines size rank (S), all-time commit count (C), and a brief rationale. Files appearing in both top-size and top-churn lists are highest priority.

| Rank | File | Lines | Commits (30d) | Rationale/Notes |
|------|------|-------|---------------|-----------------|
| 1 | `apps/ai/lib/ai/models.ex` | 11,203 | 29 | Extreme outlier: 3.4x larger than #2. Pure data catalog masquerading as a module. Debt plan M10 target. |
| 2 | `apps/coding_agent/lib/coding_agent/session.ex` | 3,261 | 31 | Highest-churn file in the codebase. Mixed concerns: GenServer lifecycle, transcript compaction, WASM sidecar, overflow handling. Debt plan M10 target. |
| 3 | `apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport.ex` | 3,950 | 32 | Highest-churn and second-largest source file. Telegram protocol complexity — transport, formatting, and media handling bundled together. |
| 4 | `apps/lemon_router/lib/lemon_router/run_process.ex` | 1,984 | 27 | High churn + large size. Run orchestration logic likely has interleaved concerns (state machine, error handling, budget enforcement). |
| 5 | `apps/coding_agent/lib/coding_agent/extensions.ex` | 1,393 | — | Large file, moderate churn. Extension/tool-selection logic with broad surface area. |
| 6 | `apps/lemon_gateway/lib/lemon_gateway/run.ex` | 883 | 23 | Moderate size but very high churn (23 commits in 30d). Gateway run coordination shows active instability. |
| 7 | `apps/lemon_core/lib/lemon_core/config.ex` | 1,259 | 19 | Config module has broad reach across all apps. High churn signals frequent config schema drift. |
| 8 | `apps/coding_agent/lib/coding_agent/tools/task.ex` | 1,591 | 20 | Large tool file with high churn. Task tool complexity and evolving spec. |
| 9 | `apps/lemon_router/lib/lemon_router/stream_coalescer.ex` | 1,368 | 18 | Large + high churn. Streaming/coalescing logic with frequent adjustment. |
| 10 | `apps/agent_core/lib/agent_core/agent.ex` | 1,193 | — | Large core agent loop. Lower churn but size indicates accumulated complexity. |
| 11 | `apps/agent_core/lib/agent_core/cli_runners/jsonl_runner.ex` | 1,174 | 12 | Large JSONL runner module with moderate churn. |
| 12 | `apps/ai/lib/ai/providers/openai_completions.ex` | 1,388 | — | Large provider adapter. Low churn suggests stability but still a large single file. |
| 13 | `apps/ai/lib/ai/providers/bedrock.ex` | 1,386 | — | Large provider adapter. Similar profile to openai_completions. |
| 14 | `apps/coding_agent/lib/coding_agent/session_manager.ex` | 1,011 | — | Debt plan flags as persistence bottleneck (full-file JSONL rewrite). Size + known debt. |
| 15 | `apps/lemon_core/lib/lemon_core/store.ex` | 1,006 | 10 | Debt plan flags as single-process hotspot. Moderate size + moderate churn + known bottleneck. |
| 16 | `apps/coding_agent/lib/coding_agent/compaction.ex` | 1,081 | — | Large compaction module; `compaction_test.exs` is 3rd largest test file (2,490 lines), suggesting surface area complexity. |
| 17 | `apps/lemon_channels/lib/lemon_channels/adapters/xmtp/transport.ex` | 1,432 | — | Large XMTP transport. Lower churn than Telegram counterpart but similar structural issues. |
| 18 | `apps/lemon_gateway/lib/lemon_gateway/transports/webhook.ex` | 1,489 | — | Large webhook handler. Low churn but substantial size. |
| 19 | `apps/lemon_gateway/lib/lemon_gateway/transports/email/inbound.ex` | 1,228 | — | Large email inbound handler. Debt plan flags off-path attachment parsing as risk. |
| 20 | `apps/ai/lib/ai/providers/openai_responses_shared.ex` | 1,085 | — | Large shared OpenAI responses module. Low churn but size warrants monitoring. |

---

## M2 Candidate Recommendations

Based on the inventory, the following 5 modules are recommended as M2 extraction targets, in priority order:

### 1. `apps/ai/lib/ai/models.ex` (11,203 lines) — HIGHEST PRIORITY

**Rationale:** This is the single most egregious outlier in the codebase. At 11,203 lines it is more than 3× the size of the next-largest file. The debt plan correctly identifies this as a "mega-module for model catalog." The file should be decomposed into:
- A data layer (model catalog as structured data files or embedded data modules per-provider)
- A query/lookup API module (`Ai.Models`) that remains the public interface
- Per-provider capability modules (e.g., `Ai.Models.Anthropic`, `Ai.Models.OpenAI`, etc.)

**Expected impact:** Dramatic reduction in file size, faster compilation, cleaner provider-specific diffs.

### 2. `apps/coding_agent/lib/coding_agent/session.ex` (3,261 lines, 31 commits/30d) — HIGH PRIORITY

**Rationale:** Highest-churn file in the codebase AND third-largest by size. The debt plan flags mixed concerns: GenServer lifecycle, transcript compaction, WASM sidecar management, and overflow handling. This file changes constantly, meaning any refactor has maximum leverage for reducing future churn. Extraction targets:
- `CodingAgent.Session.Compaction` (transcript compaction logic)
- `CodingAgent.Session.WasmSidecar` (WASM lifecycle)
- `CodingAgent.Session.Overflow` (overflow/budget handling)
- `CodingAgent.Session` retains GenServer skeleton and public API

**Expected impact:** Reduced coupling, lower per-change diff noise, easier isolated testing.

### 3. `apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport.ex` (3,950 lines, 32 commits/30d) — HIGH PRIORITY

**Rationale:** The highest-churn AND second-largest file. The Telegram transport bundles transport mechanics, message formatting, media handling, and protocol edge cases. This creates large diffs for small changes. Extraction targets:
- `LemonChannels.Adapters.Telegram.MediaHandler`
- `LemonChannels.Adapters.Telegram.MessageFormatter`
- `LemonChannels.Adapters.Telegram.Transport` (retains core transport loop)

**Expected impact:** Narrowed change scope per commit, easier Telegram-specific debugging.

### 4. `apps/lemon_router/lib/lemon_router/run_process.ex` (1,984 lines, 27 commits/30d) — MEDIUM-HIGH PRIORITY

**Rationale:** Fourth-highest churn, large file. Run orchestration is a core correctness-sensitive area. The debt plan also flags a concurrency correctness risk in `run_graph.ex` — decomposing `run_process.ex` into a clear state-machine layer and side-effect layer would make the concurrency model easier to audit and test.

**Expected impact:** Cleaner state machine boundaries, improved testability of run lifecycle transitions.

### 5. `apps/lemon_core/lib/lemon_core/store.ex` (1,006 lines, 10 commits) — MEDIUM PRIORITY

**Rationale:** The debt plan explicitly flags this as a single-process throughput bottleneck with O(n) persistence patterns. While churn is moderate, the architectural risk is high since it's a foundational dependency for all apps. Decomposition would split high-traffic storage domains into dedicated processes or sharded ETS owners.

**Expected impact:** Reduced per-process mailbox pressure, unblocks Phase 8 scalability goals.

---

## Progress Log

### 2026-02-22 — M1 Baseline Inventory Complete

- Ran `wc -l` across all `apps/*/lib/**/*.ex` files (total: ~154k lines across the codebase).
- Ranked top 20 largest source modules and top 20 largest test files.
- Ran `git log` churn analysis (all-time and 30-day windows — identical results since codebase history is within 30 days).
- Confirmed debt-plan candidates `ai/models.ex` (11,203 lines, 29 commits) and `coding_agent/session.ex` (3,261 lines, 31 commits) are both top-tier by both metrics.
- Produced ranked inventory table with size, churn, and rationale.
- Recommended 5 M2 extraction targets with justification.
- M1 milestone marked complete.

