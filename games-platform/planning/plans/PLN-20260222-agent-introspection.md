---
id: PLN-20260222-agent-introspection
title: End-to-end agent introspection (commands, tools, tasks, lineage)
status: landed
priority_bucket: now
owner: codex
reviewer: codex
workspace: feature/pln-20260222-agent-introspection-m1
change_id: bec7bfae
created: 2026-02-22
updated: 2026-02-23
roadmap_ref: ROADMAP.md:74
review_doc: planning/reviews/RVW-PLN-20260222-agent-introspection.md
landing_doc: planning/merges/MRG-PLN-20260222-agent-introspection.md
decision_docs: []
depends_on: []
---

# Summary

Implement an end-to-end introspection system so operators can inspect agent execution state and lineage across Lemon-native and external engines.

## Scope

- In scope:
  - Canonical event schema for introspection events.
  - Store API for append/query with filtering and retention sweep.
  - Redaction defaults for sensitive payload fields.
  - Unit-test coverage for canonical contract and filtering behavior.
- Out of scope:
  - Full control-plane timeline API rollout.
  - External-engine adapter parity work.

## Milestones

- [x] M0 - Discovery and architecture direction.
- [x] M1 - Event model and storage contract.
- [ ] M2 - Lemon-native instrumentation coverage.
- [x] M3 - External-engine adapter enrichment.
- [ ] M4 - Query/operations surfaces and runbooks.

## M1 Delivered

- Added `LemonCore.Introspection` as canonical envelope builder and persistence API.
- Added `LemonCore.Store.append_introspection_event/1` and `LemonCore.Store.list_introspection_events/1`.
- Added event validation/filter/sort logic and periodic retention sweep for `:introspection_log`.
- Added targeted test coverage and docs updates.

## M3 Delivered

- Instrumented `AgentCore.Agent` with `:agent_loop_started`, `:agent_turn_observed`, `:agent_loop_ended` introspection events (provenance: `:direct`).
- Instrumented `AgentCore.CliRunners.JsonlRunner` with `:jsonl_stream_started`, `:tool_use_observed`, `:assistant_turn_observed`, `:jsonl_stream_ended` events (provenance: `:direct`).
- Instrumented all five CLI runner adapters (Codex, Claude, Kimi, OpenCode, Pi) with `:engine_subprocess_started`, `:engine_output_observed`, `:engine_subprocess_exited` events (provenance: `:inferred`).
- Fixed `Ai.Types.Model` Access protocol bug in agent.ex introspection payload construction.
- Added 15 targeted introspection tests covering all CLI runners and cross-runner provenance contract.
- 0 new test failures (1607 tests, 13 pre-existing CodexRunnerIntegrationTest failures match trunk baseline `main`).

## Evidence

### M1 Evidence

- Code commit: `62144b29` (`feat(lemon_core): add canonical introspection event store contract`).
- Key files:
  - `apps/lemon_core/lib/lemon_core/introspection.ex`
  - `apps/lemon_core/lib/lemon_core/store.ex`
  - `apps/lemon_core/test/lemon_core/introspection_test.exs`
  - `apps/lemon_core/test/lemon_core/store_test.exs`
  - `apps/lemon_core/AGENTS.md`
  - `docs/telemetry.md`

### M3 Evidence

- Key files:
  - `apps/agent_core/lib/agent_core/agent.ex` (agent loop introspection)
  - `apps/agent_core/lib/agent_core/cli_runners/jsonl_runner.ex` (JSONL stream introspection)
  - `apps/agent_core/lib/agent_core/cli_runners/codex_runner.ex` (Codex adapter introspection)
  - `apps/agent_core/lib/agent_core/cli_runners/claude_runner.ex` (Claude adapter introspection)
  - `apps/agent_core/lib/agent_core/cli_runners/kimi_runner.ex` (Kimi adapter introspection)
  - `apps/agent_core/lib/agent_core/cli_runners/opencode_runner.ex` (OpenCode adapter introspection)
  - `apps/agent_core/lib/agent_core/cli_runners/pi_runner.ex` (Pi adapter introspection)
  - `apps/agent_core/test/agent_core/cli_runners/introspection_test.exs` (M3 tests)

## Test Matrix

| Layer | Command / Check | Pass Criteria | Owner | Status |
|---|---|---|---|---|
| unit (M1) | `mix test apps/lemon_core/test/lemon_core/introspection_test.exs apps/lemon_core/test/lemon_core/store_test.exs apps/lemon_core/test/lemon_core_test.exs` | 0 failures | `codex` | `pass` |
| unit (M3) | `mix test apps/agent_core/test/agent_core/cli_runners/introspection_test.exs` | 0 failures | `claude` | `pass` |
| suite (M3) | `mix test apps/agent_core` | 0 new failures vs main | `claude` | `pass` |
| quality | `mix lemon.quality` | full quality gates pass | `codex` | `blocked` |

Quality blockers are unrelated to introspection scope:
- Duplicate test modules in `apps/ai/test/...` from concurrent AI test expansion work.
- Existing architecture-boundary violations in `apps/market_intel/lib/market_intel/commentary/pipeline.ex`.

## Risks and Mitigations

- Risk: Heterogeneous engine metadata availability.
  - Mitigation: retain provenance and optional fields in canonical envelope.
- Risk: Event growth/storage churn.
  - Mitigation: retention sweep and query limits.
- Risk: Sensitive payload leakage.
  - Mitigation: default redaction in `LemonCore.Introspection`.

## Progress Log

| Date (UTC) | Actor | Update | Evidence |
|---|---|---|---|
| 2026-02-22 | `codex` | Plan initiated for introspection workstream | `planning/INDEX.md` |
| 2026-02-23 | `codex` | M1 store/schema contract implemented in an isolated jj workspace and landed on `main` | `62144b29`, `apps/lemon_core/lib/lemon_core/introspection.ex` |
| 2026-02-23 | `codex` | M1 unit tests passed on `main` | `mix test ...` (32 tests, 0 failures) |
| 2026-02-23 | `claude` | M3 external-engine adapter enrichment: instrumented Agent, JsonlRunner, and all 5 CLI runners with introspection events | `apps/agent_core/lib/agent_core/agent.ex`, `cli_runners/*.ex` |
| 2026-02-23 | `claude` | M3 introspection test suite: 15 tests, 0 failures; full suite: 0 new failures vs main | `apps/agent_core/test/agent_core/cli_runners/introspection_test.exs` |
| 2026-02-23 | `claude` | Fixed M3 doc review issues: corrected per-event provenance column in `AGENTS.md` (`:agent_turn_observed` is `:inferred`, JSONL runner events split); added full introspection event taxonomy table to `docs/telemetry.md` | `apps/agent_core/AGENTS.md`, `docs/telemetry.md` |
| 2026-02-23 | `codex` | Staff review completed for M2/M3/M4 workspaces; blockers identified and review/landing artifacts updated | `planning/reviews/RVW-PLN-20260222-agent-introspection.md`, `planning/merges/MRG-PLN-20260222-agent-introspection.md` |
| 2026-02-23 | `codex` | Final re-review passed after fixes (M2: 26 tests, M3: 15 tests, M4: 148 tests); plan set to ready_to_land | `planning/reviews/RVW-PLN-20260222-agent-introspection.md` |
| 2026-02-23 | `codex` | Final stack landing executed (`M2 -> M3 -> M4`), `main` advanced, and post-landing smoke tests passed | `bec7bfae0281c23e616148c191c287a79362b7e4`, `mix test apps/lemon_core/test/lemon_core/introspection_test.exs apps/lemon_core/test/lemon_core/store_test.exs` (18 tests, 0 failures) |

## Completion Checklist

- [x] M1 scope delivered
- [x] M3 scope delivered
- [x] Tests recorded with pass/fail evidence
- [x] Review artifact completed
- [x] Landing artifact completed
- [x] Relevant docs updated (`AGENTS.md`, `docs/telemetry.md`, module docs)
- [x] Blocking review findings resolved
- [x] Plan status set to `ready_to_land`
- [x] Plan status set to `landed`
