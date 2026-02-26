# Debt Remediation Plan

Date: 2026-02-22
Owner: Platform Engineering

## Current Plan Baseline (Phases 1-5)

| Phase | Focus | Status |
| --- | --- | --- |
| 1 | Test/quality determinism foundations | Completed (merged) |
| 2 | Runtime service decoupling | Completed (merged) |
| 3 | Discovery test determinism and duplicate helper cleanup | In progress |
| 4 | Functional TODO closure (X media + commentary persistence) | In progress |
| 5 | Complexity reduction in largest modules/files | Planned |

## New Debt Signals Identified

- CI/test signal gaps: skipped discovery tests and integration gaps (`apps/lemon_skills/test/lemon_skills/discovery_test.exs:32`, `apps/lemon_skills/test/lemon_skills/discovery_test.exs:109`, `.github/workflows/quality.yml:90`).
- Duplicate-module guard not rollout-ready until remaining duplicates are removed (`apps/lemon_core/lib/mix/tasks/lemon.check_duplicate_tests.ex:19`).
- Concurrency correctness risks in run-state updates (`apps/coding_agent/lib/coding_agent/run_graph.ex:166`).
- Busy-poll waiting and scheduler monitor lifecycle issues (`apps/coding_agent/lib/coding_agent/run_graph.ex:205`, `apps/lemon_gateway/lib/lemon_gateway/scheduler.ex:223`).
- Throughput bottlenecks from single-process stores and full-file rewrites (`apps/lemon_core/lib/lemon_core/store.ex:1`, `apps/coding_agent/lib/coding_agent/session_manager.ex:324`).
- Large monoliths slowing change velocity (`apps/ai/lib/ai/models.ex:1`, `apps/coding_agent/lib/coding_agent/session.ex:69`).
- Large bundled JS runtime assets in gateway (`apps/lemon_gateway/priv/xmtp_bridge.mjs:1`, `apps/lemon_gateway/priv/node_modules`).

## Phase 6 - CI and Test Signal Hardening

Goal: Make test/quality failures trustworthy and remove avoidable blind spots.

### Workstreams

1. LemonSkills discovery test unskipping
- Replace `@tag :skip` discovery tests with deterministic HTTP mocking.
- Keep integration scenarios as mock-backed deterministically reproducible tests.

2. CI edge-case coverage
- Replace `@tag :skip_on_ci` filesystem permission tests with OS-agnostic failure simulation.
- Run non-wasm integration coverage for discovery flows in CI.

3. Guard rollout completion
- Make `mix lemon.check_duplicate_tests` parser robust against same-file/string false positives.
- Merge remaining duplicate helper module namespacing, then enable guard in required CI path.

### Exit Criteria

- No `@tag :skip` in `apps/lemon_skills/test/lemon_skills/discovery_test.exs`.
- No `@tag :skip_on_ci` in read/write/patch tool tests for permission cases.
- `mix lemon.check_duplicate_tests` passes on main and runs in required CI.
- CI includes non-wasm discovery integration coverage.

## Phase 7 - Run-State Correctness and Concurrency Safety

Goal: Remove race conditions and nondeterministic run-state transitions.

### Workstreams

1. Atomic run graph transitions
- Replace read-modify-write update path in `RunGraph.update/2` with serialized or atomic update semantics.
- Guarantee monotonic state transitions for `mark_running/1`, `finish/2`, and `fail/2` under concurrency.

2. Deterministic await model
- Replace polling loop in `RunGraph.await/3` with notification/subscription based wake-up.
- Preserve timeout guarantees without fixed sleep jitter.

3. Scheduler monitor lifecycle fixes
- Fix stale-request cleanup to persist demonitor state updates.
- Add regression tests that prove no monitor/worker_count leakage across enqueue timeout churn.

### Exit Criteria

- New concurrency regression suite for run graph transitions passes under stress.
- No state loss observed across simultaneous status updates.
- Scheduler stale queue cleanup leaves monitor maps and worker counts stable over repeated cycles.

## Phase 8 - Store and Persistence Scalability

Goal: Remove known single-process and O(n) persistence bottlenecks.

### Workstreams

1. SessionManager write-path refactor
- Replace full JSONL rewrite on append with append-only/chunked persistence model.
- Avoid repeated `entries ++ [entry]` copy behavior for long sessions.

2. LemonCore.Store hotspot decomposition
- Split high-traffic store domains (chat state, progress, run history) across dedicated storage processes or sharded ETS.
- Keep API compatibility layer while reducing per-process mailbox pressure.

3. RunGraphServer startup/cleanup backpressure
- Move full-table DETS load and cleanup fold work off critical GenServer path.
- Use chunked background jobs or supervised async workers.

### Exit Criteria

- Session append latency is stable as history grows (no linear degradation pattern).
- Store process mailbox growth under load is bounded versus baseline.
- RunGraphServer startup and cleanup no longer block request handling for long tables.

## Phase 9 - Gateway Runtime Reliability Decomposition

Goal: Reduce failure blast radius in gateway/control-plane runtime plumbing.

### Workstreams

1. EventBridge supervision hardening
- Move fanout supervisor under application supervision tree.
- Ensure fanout worker failures are visible/restartable rather than silently degraded.

2. Email inbound async pipeline
- Move attachment parsing/persistence and run submission off request handler critical path.
- Return fast acknowledgment and process inbound payload in controlled worker pipeline.

3. Gateway engine dependency abstraction
- Replace ad hoc engine-side app startup checks with explicit dependency manager boundary.
- Extract channel-specific extra tool selection behind provider abstraction.

### Exit Criteria

- EventBridge fanout supervisor is a supervised child with restart semantics.
- Email inbound request latency remains stable under large attachment scenarios.
- Engine startup path no longer contains scattered direct dependency bootstrapping logic.

## Phase 10 - Monolith and Release Footprint Reduction

Goal: Improve maintainability and release ergonomics by decomposing oversized modules and bundled assets.

### Workstreams

1. Ai.Models decomposition
- Move model catalog data out of single mega-module into data files + validation loaders.
- Keep backwards-compatible query APIs while shrinking `Ai.Models` core module responsibilities.

2. CodingAgent.Session decomposition
- Extract WASM sidecar lifecycle, transcript compaction, and overflow handling into focused modules.
- Retain behavior compatibility with targeted contract tests.

3. Gateway JS asset externalization
- Reduce committed `priv/node_modules` footprint by moving bridge runtime to separately versioned artifact/service.
- Keep deterministic build process and runtime verification checks.

4. Config/doc drift cleanup
- Remove stale MarketIntel config guidance.
- Convert adapter TODO sections to trackable backlog issues with owners and target phases.

### Exit Criteria

- `apps/ai/lib/ai/models.ex` reduced to orchestration layer (catalog moved out).
- `apps/coding_agent/lib/coding_agent/session.ex` reduced with extracted submodules and coverage parity.
- Gateway release size drops materially after JS asset externalization.
- Stale config/doc TODO debt replaced with owned backlog items.

## Recommended Execution Order

1. Finish Phase 3 in-flight duplicate helper cleanup.
2. Execute Phase 6 guard+CI hardening immediately after Phase 3.
3. Run Phases 7 and 8 in parallel (correctness + scalability) with separate owners.
4. Start Phase 9 once Phase 7 scheduler/run-state fixes land.
5. Run Phase 10 as a longer-track refactor stream with milestone releases.
