# PLN-20260222: Debt Phase 12 — Deterministic Async Test Harness

**Branch:** `feature/pln-20260222-debt-phase-12-deterministic-async-test-harness`  
**Created:** 2026-02-22  
**Status:** In Progress

## Objective

Reduce flakiness in concurrency-heavy test suites by replacing timing randomness with deterministic synchronization primitives.

## Milestones

- [x] M1 — Critical timing randomness removal in patch_test.exs
- [x] M2 — Shared async test helpers module created
- [x] M3 — Targeted suite migration (scheduler_test, run_test, thread_worker_test)
- [x] M4 — Flake-detection CI gate

## Progress Log

### 2026-02-22

**Setup**
- Created branch `feature/pln-20260222-debt-phase-12-deterministic-async-test-harness`
- Created planning directory and this plan artifact
- Surveyed timing patterns across test suite:
  - `patch_test.exs` line 835: `:timer.sleep(:rand.uniform(10))` in race condition test
  - `patch_test.exs` line 1368: `:timer.sleep(1)` in abort signal test
  - `scheduler_test.exs`: multiple `Process.sleep(10)` calls for cast propagation
  - `run_test.exs`: multiple `Process.sleep(50/100)` calls for process-alive checks
  - `thread_worker_test.exs`: multiple `Process.sleep(50)` calls for queue stabilization

**M2 — Shared async test helpers**
- Created `apps/coding_agent/test/support/async_helpers.ex` with:
  - `assert_eventually/3` — polls a condition with configurable timeout/interval
  - `assert_process_dead/2` — polls until a process stops
  - `assert_process_alive/2` — polls until a process starts
  - `latch/0`, `release/1`, `await_latch/2` — deterministic single-use barrier
  - `barrier/1`, `arrive/1`, `await_barrier/2` — N-process rendez-vous
  - `with_ordered_tasks/1` — runs tasks in controlled order using latches

**M1 — patch_test.exs timing fixes**
- Line 835: Replaced `:timer.sleep(:rand.uniform(10))` with a deterministic latch/barrier
  to stagger concurrent patches without random timing
- Line 1368: Replaced `:timer.sleep(1)` abort race with an explicit latch — the abort
  spawner waits for the patch task to signal it has started, then aborts

**M3 — Targeted suite migration**
- `scheduler_test.exs`: Replaced timing sleeps with `assert_eventually` and
  `assert_process_dead` helpers where the sole purpose was giving a process time to die
  or a cast to propagate
- `run_test.exs`: Replaced `Process.sleep(N); refute/assert Process.alive?` patterns
  with `assert_process_dead/assert_process_alive` helpers
- `thread_worker_test.exs`: Replaced stabilization sleeps with `assert_eventually` helpers

**M4 — Flake-detection CI gate**
- Added `async-flake-detect` job to `.github/workflows/quality.yml`
- Reruns `scheduler_test`, `run_test`, `thread_worker_test`, and `patch_test` 3 times
  to catch nondeterminism

## Files Changed

- `planning/plans/PLN-20260222-debt-phase-12-deterministic-async-test-harness.md` (this file)
- `apps/coding_agent/test/support/async_helpers.ex` (new)
- `apps/coding_agent/test/coding_agent/tools/patch_test.exs` (M1)
- `apps/lemon_gateway/test/scheduler_test.exs` (M3)
- `apps/lemon_gateway/test/run_test.exs` (M3)
- `apps/lemon_gateway/test/thread_worker_test.exs` (M3)
- `.github/workflows/quality.yml` (M4)
