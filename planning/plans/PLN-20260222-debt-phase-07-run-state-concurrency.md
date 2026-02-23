# PLN-20260222: Debt Phase 7 — Run-State Correctness and Concurrency Safety

**Status**: Complete  
**Branch**: `feature/pln-20260222-debt-phase-07-run-state-concurrency`  
**Created**: 2026-02-22  

## Goal

Eliminate race conditions in run-state updates and scheduler monitor lifecycle to ensure deterministic, monotonic run transitions under load.

## Milestones

- [x] M1: Atomic run graph transitions with monotonic state enforcement
- [x] M2: Deterministic await model replacing polling with PubSub notifications
- [x] M3: Scheduler monitor lifecycle fixes with regression tests
- [x] M4: Concurrency regression test suite passing under stress

## Design Decisions

### M1: Atomic Run Graph Transitions

**Problem**: `RunGraph.update/2` does a read-modify-write (ETS lookup, apply fn, insert) which is not atomic. Under concurrent updates, the last write wins and intermediate state changes can be lost.

**Solution**: Route state-mutating operations through `RunGraphServer` GenServer for serialization. This uses the BEAM's mailbox ordering guarantee to serialize all writes. Reads remain fast via direct ETS access (`:public` table with `read_concurrency: true`).

Two new GenServer calls:
- `atomic_update/2` — serialized read-modify-write for general updates (add_child, etc.)
- `atomic_transition/3` — serialized state transition with monotonic enforcement

The monotonic state machine enforces: `queued (0) -> running (1) -> {completed|error|killed|cancelled|lost} (2)`. Backward transitions return `{:error, :invalid_transition}`.

### M2: Deterministic Await Model

**Problem**: `RunGraph.await/3` uses a `Process.sleep(50ms)` polling loop. This wastes CPU cycles, introduces non-deterministic latency (up to 50ms after state change), and under high load the polling multiplies.

**Solution**: Use `LemonCore.Bus` (Phoenix PubSub) to broadcast run state changes on topic `"run_graph:<run_id>"`. `await/3` subscribes to run topics and uses `receive` with deadline-based timeout, waking up immediately when state changes. A 5-second safety fallback re-check prevents missed notifications from causing indefinite hangs.

### M3: Scheduler Monitor Lifecycle Fixes

**Problem**: `cleanup_stale_slot_requests/1` calls `maybe_demonitor_worker(state, entry)` but **discards the returned state**. This means monitor refs and worker counts leak — the demonitor side effects are computed but never persisted back to the GenServer state.

**Solution**: Thread state through the stale cleanup reduce accumulator as a 4th element, so demonitor effects (monitor map cleanup + worker_count decrements) are accumulated and persisted in the final state.

## Progress Log

| Timestamp | Event |
|-----------|-------|
| 2026-02-22T00:00 | Plan created, analysis complete |
| 2026-02-22T00:10 | M1: Implemented atomic_update/atomic_transition in RunGraphServer |
| 2026-02-22T00:10 | M1: Added monotonic state machine with @state_order |
| 2026-02-22T00:10 | M2: Replaced polling loop with LemonCore.Bus PubSub notifications |
| 2026-02-22T00:15 | M3: Fixed cleanup_stale_slot_requests to thread state through reduce |
| 2026-02-22T00:20 | M4: Added 16 concurrency regression tests (all passing under stress) |
| 2026-02-22T00:20 | M4: Added 5 scheduler monitor lifecycle regression tests (all passing) |
| 2026-02-22T00:25 | All 94 tests pass (89 RunGraph + 5 Scheduler lifecycle), 0 new failures |

## Files Changed

- `apps/coding_agent/lib/coding_agent/run_graph.ex` — Atomic transitions, PubSub await, monotonic state machine
- `apps/coding_agent/lib/coding_agent/run_graph_server.ex` — `atomic_update/2`, `atomic_transition/3`, broadcast_state_change
- `apps/lemon_gateway/lib/lemon_gateway/scheduler.ex` — Fixed stale cleanup state threading
- `apps/coding_agent/test/coding_agent/run_graph_concurrency_test.exs` — New (16 tests)
- `apps/lemon_gateway/test/lemon_gateway/scheduler_monitor_lifecycle_test.exs` — New (5 tests)
- `planning/plans/PLN-20260222-debt-phase-07-run-state-concurrency.md` — This plan
