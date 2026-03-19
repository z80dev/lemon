# AsyncTaskSurface Implementation Loop

## Source of Truth
If resuming in a new session, start here:
- `docs/plans/async-task-surface-implementation-loop.md` (this file)
- `memory/topics/async-task-status-review.md`
- `docs/plans/async-task-tool-surfacing-migration-progress.md`

## Goal
Replace the increasingly fragile bridge/binding/coalescer patch stack with a cleaner router-owned `AsyncTaskSurface` lifecycle so async child task activity stays attached to the original parent task surface/message with simpler ownership and cleanup semantics.

## Why we are doing this
Incremental patching improved the happy path but Codex architecture review concluded the ownership boundary is still wrong:
- parent `RunProcess` owns state that should live for the child-task lifetime
- surface mapping is duplicated across coding agent bindings and router in-memory maps
- coalescer behavior is compensating for an underspecified upstream contract
- repeated review/fix rounds keep moving lifecycle bugs instead of removing the root cause

## Architecture choice
Chosen direction: **implement the `AsyncTaskSurface` redesign** described in `memory/topics/async-task-status-review.md`.

### Core design
Introduce `LemonRouter.AsyncTaskSurface` as a router-owned GenServer with one process per async task surface.

State machine:
- `pending_root`
- `bound`
- `live`
- `terminal_grace`
- `reaped`

Key ownership rules:
- task surface is owned by router, not by parent run maps plus coding-agent bindings
- child run subscription belongs to the task-surface process
- poll/join are fallback/snapshot paths, not a second primary source of truth
- cleanup/reap is local to async task surface lifecycle

## 8-step implementation plan
1. Add `LemonRouter.AsyncTaskSurface` + supervisor + registry.
2. Seed surface ownership from task-root start in router.
3. Bind `task_id` + `child_run_id` from existing result metadata path.
4. Move child run subscription into `AsyncTaskSurface`; keep `LiveBridge` only as a temporary shim if needed.
5. Route poll/join by `task_id` through async-task-surface registry.
6. Add explicit `:task_surface_bound` / `:task_surface_terminal` events from task tool lifecycle if necessary.
7. Remove obsolete pieces once replacement is proven: `TaskProgressBindingStore`, `TaskProgressBindingServer`, `LiveBridge`, and embedded-child repair/dedupe logic that becomes unnecessary.
8. Validate end-to-end, including the important case where child progress continues correctly even if the parent `RunProcess` exits.

## Current status
- We completed the original incremental migration/hardening path through multiple Codex rounds.
- We have hardened baseline work in isolated worktrees:
  - coding worktree latest known hardening commit: `8b7443d7`
  - router worktree latest known hardening commits include `a3653db75963e87df65d6eead7fed400601511b5` and `64b5b50c`
- We are now shifting to the **AsyncTaskSurface implementation loop** as the next major step.
- **Step 1 complete in worktree:** `.worktrees/async-task-surface-step1`
  - Added `LemonRouter.AsyncTaskSurface`
  - Added `LemonRouter.AsyncTaskSurfaceSupervisor`
  - Wired `LemonRouter.AsyncTaskSurfaceRegistry` + supervisor into `LemonRouter.Application`
  - Preserved the old projected-child / bridge path unchanged
  - Final Step 1 lifecycle scaffold uses redesign-aligned states: `:pending_root`, `:bound`, `:live`, `:terminal_grace`, `:reaped`
  - Hardened for immediate + concurrent reap/recreate, suspended/busy live reuse, stale pid safety, and actionable invalid-metadata errors
  - Targeted green suites at approval point:
    - `mix test apps/lemon_router/test/lemon_router/async_task_surface_test.exs`
    - `mix test apps/lemon_router/test/lemon_router/run_process_test.exs`
    - `mix test apps/lemon_router/test/lemon_router/tool_status_coalescer_test.exs`

## Implementation/review loop protocol
For each round:
1. Pick the next smallest viable `AsyncTaskSurface` slice.
2. Launch Codex implement task in isolated worktree(s).
3. Run targeted tests.
4. Launch Codex review task.
5. If issues remain, launch the next fix round.
6. Update this file and `memory/topics/async-task-status-review.md` with what changed and what remains.

## Immediate next work
Step 1 is complete.

Proceed to Step 2:
- parent `RunProcess` / `OutputTracker` seeds task-root ownership into `AsyncTaskSurface`
- bind/create/reuse surfaces from task-root start and poll paths
- persist router-owned `surface_id` + `root_action_id` as authoritative identity
- keep existing projected-child rendering path intact for now
- defer LiveBridge removal / child-run subscription migration to later steps

## Exit criteria
We can call this done only when:
- `AsyncTaskSurface` is the primary owner of async task surfaces
- child run subscription no longer relies on fragile cross-layer bridge/binding semantics
- poll/join behave as fallback only
- obsolete bridge/binding repair logic is removed or clearly deprecated
- real Telegram canary confirms correct nested live updates
