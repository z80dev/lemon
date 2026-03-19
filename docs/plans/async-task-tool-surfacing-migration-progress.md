# Async Task Tool Surfacing Migration Progress

> **Status note:** This file records the completed incremental migration/hardening path. The next implementation loop should start from the `AsyncTaskSurface` redesign source of truth in `docs/plans/async-task-surface-implementation-loop.md` and `memory/topics/async-task-status-review.md`.

## AsyncTaskSurface redesign loop checkpoints

### Step 1 scaffold — APPROVED
- **Worktree:** `.worktrees/async-task-surface-step1`
- Added router-owned scaffold pieces:
  - `apps/lemon_router/lib/lemon_router/async_task_surface.ex`
  - `apps/lemon_router/lib/lemon_router/async_task_surface_supervisor.ex`
  - `LemonRouter.AsyncTaskSurfaceRegistry` + `LemonRouter.AsyncTaskSurfaceSupervisor` in `LemonRouter.Application`
- Public scaffold now uses redesign-aligned lifecycle states:
  - `:pending_root`
  - `:bound`
  - `:live`
  - `:terminal_grace`
  - `:reaped`
- Hardening completed during review loop:
  - immediate reap stops/unregisters and supports fresh recreate
  - concurrent reap/recreate no longer returns stale pid
  - live-but-suspended surfaces are reused instead of timed out
  - duplicate same-state transitions preserve prior identity/payload
  - invalid metadata returns actionable errors instead of crashing/misreporting `:not_found`
- Approval review verdict: **APPROVED**
- Targeted green suites at final approval:
  - `mix test apps/lemon_router/test/lemon_router/async_task_surface_test.exs`
  - `mix test apps/lemon_router/test/lemon_router/run_process_test.exs`
  - `mix test apps/lemon_router/test/lemon_router/tool_status_coalescer_test.exs`

### Recommended next slice
- Step 2 only: wire `AsyncTaskSurface` into task-root ownership in router (`RunProcess` / `OutputTracker`) while keeping the existing projected-child path intact.

## Goal
Complete the async task tool surfacing migration so live child task activity stays attached to the original parent task surface/message, with robust lifecycle cleanup and safe dedupe behavior.

## 8-step migration plan

1. **Binding store** — transient task progress binding store and server.
2. **Launch metadata capture** — persist `root_action_id` / `surface` / parent metadata at async launch.
3. **Live bridge** — subscribe to child run bus events and project child actions.
4. **Projected ingress API** — explicit coalescer ingress for projected child actions.
5. **Router integration** — route projected child actions into task surfaces and add regression coverage.
6. **Poll/join dedupe** — reconcile poll/join results with already-live projected child actions.
7. **Coding-side lifecycle hardening** — bridge teardown, fail-open binding creation, starter failure handling, malformed child detail robustness.
8. **Router-side lifecycle hardening + final validation** — watchdog prompt idempotency, task-surface reap/cleanup, projected routing cleanup, final canary/review.

## Status

- [x] Step 1 — Binding store
- [x] Step 2 — Launch metadata capture
- [x] Step 3 — Live bridge
- [x] Step 4 — Projected ingress API
- [x] Step 5 — Router integration + regression coverage
- [x] Step 6 — Poll/join dedupe
- [x] Step 7 — Coding-side lifecycle hardening
- [x] Step 8 — Router-side lifecycle hardening + final validation

## Current known backlog

### Coding-side
- Ensure bridge teardown matches the **real** async terminal lifecycle path, not only synthetic `:run_completed`.
- Prevent `LiveBridge` crashes on non-map `action.detail` payloads.
- Ensure starter callback raises are handled cleanly without partial-state leaks.
- Add regression coverage for the above.

### Router-side
- Fix repeated watchdog prompt idempotency across multiple idle cycles.
- Prevent reaped task-scoped coalescers from being recreated/leaking at parent run completion.
- Preserve `:user_requested` cancel reason through watchdog cancel path.
- Revisit remaining embedded-child dedupe edge cases if still needed.

## Latest checkpoints
- Initial migration tasks (1–6) implemented and covered by targeted tests.
- Additional coding-side hardening commit landed in coding worktree (`8b7443d7`).
- Additional router-side hardening commit landed in router worktree (`a3653db75963e87df65d6eead7fed400601511b5`).
- Final targeted router pass reported:
  - task-surface stale binding cleanup
  - `detail.task_id` / `detail.task_ids` poll rebinding support
  - regression coverage for reaped-surface parent completion and poll-only `detail.task_id`
  - `mix test apps/lemon_router/test/lemon_router/run_process_test.exs apps/lemon_router/test/lemon_router/tool_status_coalescer_test.exs` → `66 tests, 0 failures`
- Migration steps 1–8 are now marked complete in the tracker; next action is final cross-tree review/canary confirmation before merging.

## Notes
- Use Codex tasks in isolated worktrees for further implementation/review rounds.
- Do not call this done until both worktrees get a clean final Codex review and the real Telegram canary is run.
