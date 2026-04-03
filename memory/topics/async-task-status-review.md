## 2026-07 Re-evaluation (Codex) — UPDATED 2026-07-29

> Second Codex evaluation confirmed: provenance workstream shipped, status workstream is
> architecture cleanup only. Old worktree branches no longer exist in this checkout.

### Current codebase state (verified 2026-07-29)

- `LemonRouter.AsyncTaskSurface` does not exist on `main`.
  - There is no `apps/lemon_router/lib/lemon_router/async_task_surface.ex` in this checkout.
  - **The Step 1 scaffold worktrees no longer exist** — `git worktree list` and `git branch --list 'async-*'` show nothing. They were cleaned up at some point.
- Router-side async status projection is present on `main`, but the module is `LemonRouter.AsyncTaskSurfaceSubscriber`, not `LemonRouter.AsyncTaskSurface`.
  - Files:
    - `apps/lemon_router/lib/lemon_router/async_task_surface_subscriber.ex`
    - `apps/lemon_router/lib/lemon_router/application.ex`
    - `apps/lemon_router/lib/lemon_router/surface_manager.ex`
  - `LemonRouter.Application` starts `LemonRouter.AsyncTaskSurfaceRegistry` and `LemonRouter.AsyncTaskSurfaceSupervisor`, but today those are used for subscriber workers, not for a router-owned async task surface state machine.
  - `LemonRouter.SurfaceManager` starts the subscriber when a task root action completes with `result_meta.status == "queued"` and `result_meta.run_id` / `result_meta.task_id` are present.
- The old coding-agent bridge/binding path is still present and still active on `main`.
  - Files:
    - `apps/coding_agent/lib/coding_agent/task_progress_binding_store.ex`
    - `apps/coding_agent/lib/coding_agent/task_progress_binding_server.ex`
    - `apps/coding_agent/lib/coding_agent/tools/task/live_bridge.ex`
    - `apps/coding_agent/lib/coding_agent/tools/task/live_bridge_supervisor.ex`
    - `apps/coding_agent/lib/coding_agent/tools/task/execution.ex`
    - `apps/coding_agent/lib/coding_agent/tools/task/async.ex`
  - `CodingAgent.Tools.Task.Execution` still creates a progress binding at async launch.
  - `CodingAgent.Tools.Task.Async.run_async/5` still starts `LiveBridge` before launching the async child.
  - `CodingAgent.Application` still supervises both `LiveBridgeSupervisor` and `TaskProgressBindingServer`.
- The parent run still handles the old projected-child event path.
  - File:
    - `apps/lemon_router/lib/lemon_router/run_process.ex`
  - `RunProcess` still has a `handle_info/2` branch for `:task_projected_child_action`.
- `ToolStatusCoalescer` still contains old repair/dedupe logic for projected child status and poll/join fallback.
  - File:
    - `apps/lemon_router/lib/lemon_router/tool_status_coalescer.ex`
  - Current behavior still includes:
    - projected-child ingestion
    - embedded child expansion from `partial_result.details.current_action`
    - embedded child expansion from `detail.result_meta.current_action`
    - dedupe based on `child_run_id` + `parent_tool_use_id`
    - skipping parent `task poll` / `task join` actions and rendering their child action instead
- Poll/followup rebinding metadata is still part of the design on `main`.
  - Files:
    - `apps/coding_agent/lib/coding_agent/cli_runners/lemon_runner.ex`
    - `apps/coding_agent/lib/coding_agent/tools/task/result.ex`
    - `apps/lemon_router/lib/lemon_router/surface_manager.ex`
  - `lemon_runner` still injects `detail.result_meta` including `task_id`, `run_id`, `status`, `current_action`, `action_detail`, and `engine`.
  - Router code still relies on that metadata to keep `task action=poll` updates attached to the original task surface.

### Worktree state (updated 2026-07-29)

- **All previously-cited worktrees have been cleaned up.** `git worktree list` and `git branch --list 'async-*'` show nothing in this checkout. The branches and worktrees referenced below no longer exist:
  - ~~`.worktrees/async-status-coding`~~
  - ~~`.worktrees/async-status-router`~~
  - ~~`.worktrees/async-task-surface-step1`~~
  - ~~`.worktrees/async-task-surface-clean`~~

*(Original 2026-04 worktree state preserved below for historical reference.)*

<details>
<summary>Original worktree state (2026-04 — now historical)</summary>

- `.worktrees/async-status-coding` existed and was clean, but its branch was not merged into `main`.
  - Unique commits on that branch:
    - `f4dc8da5 fix(coding_agent): harden async task live status launch`
    - `88fae262 fix(coding_agent): harden async task live status`
    - `35547e1e fix(coding_agent): harden async task live bridge`
    - `8b7443d7 fix(coding_agent): harden async task bridge teardown`
    - `445897b9 fix(coding_agent): harden async live bridge cleanup`
- `.worktrees/async-status-router` existed and was clean, but its branch was also not merged into `main`.
  - Unique commits on that branch:
    - `27e5044b fix(lemon_router): tighten projected child status routing`
    - `e8d1ae2d fix(lemon_router): harden async task status routing`
    - `64b5b50c fix(lemon_router): harden watchdog and task status cleanup`
    - `a3653db7 fix(lemon_router): finish async task status routing`
- AsyncTaskSurface scaffold worktrees also still exist and are unmerged:
  - `.worktrees/async-task-surface-step1`
  - `.worktrees/async-task-surface-clean`
  - Those branches contain:
    - `apps/lemon_router/lib/lemon_router/async_task_surface.ex`
    - `apps/lemon_router/lib/lemon_router/async_task_surface_supervisor.ex`
    - `apps/lemon_router/test/lemon_router/async_task_surface_test.exs`
- One scaffold-related followup branch appears merged:
  - `a6597ac6 fix(coding_agent): restore missing task progress binding server` is already an ancestor of `HEAD`.

</details>

### What has already landed since the original migration plan

- Significant incremental migration/hardening already landed on `main`.
  - `42a416ea feat(agent-runtime): improve task status streaming and run recovery`
    - introduced the binding store/server, `LiveBridge`, projected-child routing, and task result metadata plumbing
  - `46fde881 Improve AI provider and task bridge handling`
    - additional binding/live-bridge/task-result hardening
  - `342ad48c fix: truncate streaming snapshots to prevent Telegram message spam`
    - added `CodingAgent.Tools.Task.Projection`
    - added `LemonRouter.AsyncTaskSurfaceSubscriber`
    - moved child projection closer to router ownership, but did not replace the old bridge path
  - `a6597ac6 fix(coding_agent): restore missing task progress binding server`
    - merged store/server resiliency work
- This means workstream #1 is not "missing" on `main`; a live status projection system exists and has test coverage.
- It also means the AsyncTaskSurface redesign is not merged; the code still runs a layered compatibility stack rather than the proposed end-state architecture.

### Test/verification snapshot

- Focused async-status tests that passed on `main`:
  - `mix test apps/coding_agent/test/coding_agent/tools/task/live_bridge_test.exs apps/coding_agent/test/coding_agent/tools/task/execution_test.exs`
  - `mix test apps/lemon_router/test/lemon_router/run_process_test.exs:579 apps/lemon_router/test/lemon_router/run_process_test.exs:1100 apps/lemon_router/test/lemon_router/run_process_test.exs:1304 apps/lemon_router/test/lemon_router/tool_status_coalescer_test.exs:712`
- A broader focused router status run was not fully green:
  - `mix test apps/lemon_router/test/lemon_router/surface_manager_test.exs apps/lemon_router/test/lemon_router/tool_status_coalescer_test.exs`
  - Result: async-specific cases passed, but `apps/lemon_router/test/lemon_router/tool_status_coalescer_test.exs` still had a failing anchored-status test (`"anchored tool status keeps tool lines visible when the handed-off prefix is very long"`).
- Conclusion from tests:
  - async live projection is implemented and working on the covered happy paths
  - the surrounding status-surface machinery is still fragile enough that more lifecycle/ownership simplification would still pay off

### Is the work still needed? (updated 2026-07-29)

- **Not for product capability. Async status works today.**
- The hybrid implementation (LiveBridge + AsyncTaskSurfaceSubscriber + ToolStatusCoalescer dedupe) is functional and has test coverage.
- The AsyncTaskSurface redesign is **optional architecture cleanup** — it would simplify ownership by consolidating everything into router, but nothing is broken.
- The provenance workstream (see plan at `docs/plans/2026-03-26-async-followup-delivery-and-provenance-plan.md`) is **shipped** with 3 known open items (delivery metadata accuracy, compaction provenance, router-path regression test).

### Recommendation on product direction

- **Keep the feature.**
- The codebase and docs still treat live nested async status as a desired behavior:
  - `apps/lemon_router/AGENTS.md` explicitly describes child actions staying attached to parent task surfaces and `task action=poll` rebinding to the original task surface.
  - There is still active test coverage in `run_process_test.exs`, `surface_manager_test.exs`, `tool_status_coalescer_test.exs`, `execution_test.exs`, and `live_bridge_test.exs`.
- So the relevant decision is not whether to keep the feature, but whether to stop at the current hybrid implementation or continue the redesign to simplify it.

### What should happen next (updated 2026-07-29)

- **Nothing required.** Async status is working and the provenance plan shipped.
- If you want to clean up the architecture later, the AsyncTaskSurface redesign would consolidate ownership into router. But it's optional and not blocking anything.
- The 3 open provenance items (delivery metadata bug, compaction, regression test) are low-priority correctness improvements, not blockers.

### Risks and cautions (updated 2026-07-29)

- ~~Do not assume the old hardening branches can be merged directly.~~ **Resolved** — worktrees and branches no longer exist.
- ~~The current `AsyncTaskSurfaceRegistry` / `AsyncTaskSurfaceSupervisor` names on `main` are misleading.~~ Still true but low-priority naming cleanup.
- ~~The missing review/history file is itself a risk.~~ **Resolved** — this file now exists and is maintained.

## Cross-Workstream Conflict Analysis (Codex)

### Overlapping files and modules

Direct overlap or adjacent seam overlap:

- `apps/coding_agent/lib/coding_agent/tools/task/followup.ex`
  - status workstream depends on this module continuing to emit stable async followup/task identity (`task_id`, `run_id`, queue semantics) even though it does not own status rendering.
  - followup/provenance workstream explicitly changes its live-session vs router fallback behavior.
- `apps/coding_agent/lib/coding_agent/cli_runners/lemon_runner.ex`
  - status path already depends on `detail.result_meta` coming through Lemon-runner-backed task/poll flows.
  - followup/provenance plan explicitly needs this file for router-delivered structured ingress.
- `apps/lemon_router/lib/lemon_router/session_transitions.ex`
  - status workstream does not center on it, but current async task completions use its auto-followup promotion and merge behavior.
  - followup/provenance workstream explicitly needs merge-safe async provenance here.

Shared infrastructure with strong coupling but mostly non-overlapping edits:

- `apps/coding_agent/lib/coding_agent/tools/task/execution.ex`
- `apps/coding_agent/lib/coding_agent/tools/task/async.ex`
- `apps/coding_agent/lib/coding_agent/tools/task/result.ex`
- `apps/coding_agent/lib/coding_agent/task_progress_binding_store.ex`
- `apps/coding_agent/lib/coding_agent/task_progress_binding_server.ex`
- `apps/coding_agent/lib/coding_agent/tools/task/live_bridge.ex`
- `apps/lemon_router/lib/lemon_router/async_task_surface_subscriber.ex`
- `apps/lemon_router/lib/lemon_router/surface_manager.ex`
- `apps/lemon_router/lib/lemon_router/tool_status_coalescer.ex`
- `apps/lemon_router/lib/lemon_router/run_process.ex`
- `apps/coding_agent/lib/coding_agent/session.ex`
- `apps/coding_agent/lib/coding_agent/session/state.ex`
- `apps/coding_agent/lib/coding_agent/session/persistence.ex`
- `apps/coding_agent/lib/coding_agent/session/message_serialization.ex`
- `apps/coding_agent/lib/coding_agent/session_manager.ex`
- `apps/coding_agent/lib/coding_agent/messages.ex`
- `apps/coding_agent/lib/coding_agent/tools/agent.ex`
- `apps/coding_agent/lib/coding_agent/task_store.ex`
- `apps/coding_agent/lib/coding_agent/run_graph.ex`

### What each workstream currently assumes

Live Status Projection currently assumes:

- async child progress can be mapped back to the parent task surface through `TaskProgressBindingStore` and `AsyncTaskSurfaceSubscriber`.
- task roots expose stable `detail.result_meta.task_id`, `detail.result_meta.run_id`, `detail.result_meta.status`, `detail.result_meta.current_action`, and `detail.result_meta.action_detail` for poll rebinding and embedded child rendering.
- router-owned display code still compensates for hybrid ownership in `SurfaceManager`, `RunProcess`, and `ToolStatusCoalescer`.

Async Followup Delivery & Provenance currently assumes:

- async completion delivery still enters the session through text-first APIs: `CodingAgent.Session.prompt/3`, `steer/2`, and `follow_up/2`.
- router fallback still carries binary prompt text and queue metadata, with `SessionTransitions.merge_prompt/2` concatenating strings.
- a safe first fix uses structured provenance in metadata plus structured ingress at `LemonRunner`/`Session`, without sending raw structs through `RunRequest.prompt`.

### Conflicts found

No hard architectural contradiction was found. The workstreams target different layers:

- live status is primarily router-side status-surface ownership and async child projection.
- followup/provenance is primarily session ingress, persistence, and model-context encoding.

The real conflicts are sequencing and contract conflicts:

1. `SessionTransitions` is a shared correctness hotspot.
- Followup/provenance needs merge-safe `async_followups` accumulation instead of current scalar-overwrite `Map.merge/2`.
- If that is not fixed first, concurrent async completions can still lose provenance even if structured ingress lands.
- Status work does not directly depend on that data today, but it shares the same async completion traffic and queue timing.

2. `LemonRunner` is a shared ingress seam.
- Followup/provenance needs it to detect router-carried async metadata and call structured session ingress.
- Status already relies on Lemon-runner-backed task metadata surviving through poll/result flows.
- A parallel change that starts sending non-binary prompt payloads through router before `LemonRunner` and `Session` are updated would break current router assumptions (`merge_prompt/2` still assumes text).

3. The status redesign wants to delete infrastructure the current system still uses.
- The status review explicitly recommends eventually removing `TaskProgressBindingStore`, `TaskProgressBindingServer`, and `CodingAgent.Tools.Task.LiveBridge`.
- That does not block followup/provenance directly, but it means the status branch must not delete or repurpose task/run identity plumbing until router-owned replacements preserve the current `task_id`/`run_id` contract.

4. Metadata namespace drift is an avoidable conflict.
- Status currently relies on `result_meta` and projected-child `detail` fields for display routing.
- Followup/provenance should keep using a dedicated metadata key such as `async_followups` on router submissions, not overload status metadata fields.
- This matches the followup plan's current assessment and avoids accidental collisions with status rendering.

### Shared infrastructure opportunities

- Canonical async identity contract:
  keep `task_id`, `run_id`, `parent_run_id`, and queue-mode semantics stable across both workstreams. Both features already rely on `TaskStore` and `RunGraph`.
- Canonical router-carried async metadata:
  define one dedicated `meta["async_followups"]` list shape for completion provenance. That can be merged in `SessionTransitions` without touching status metadata.
- Router-owned async lifecycle ownership:
  if the AsyncTaskSurface redesign proceeds, it should reuse existing task lifecycle events on `LemonCore.Bus` plus `TaskStore`/`RunGraph`, instead of inventing a second async identity source.
- Shared end-to-end tests:
  add at least one router fallback async completion test that verifies both:
  router queue/merge behavior and session ingress provenance preservation.

### Recommended implementation order

1. Land a small shared-contract cut first.
- Update `apps/lemon_router/lib/lemon_router/session_transitions.ex` to accumulate async provenance as a list instead of overwriting scalar metadata.
- Keep router prompts binary; do not send raw `%CustomMessage{}` through `RunRequest.prompt`.
- Reserve a dedicated router metadata key for async provenance, separate from status metadata.

2. Land followup/provenance structured ingress next.
- `apps/coding_agent/lib/coding_agent/cli_runners/lemon_runner.ex`
- `apps/coding_agent/lib/coding_agent/session.ex`
- `apps/coding_agent/lib/coding_agent/session/state.ex`
- `apps/coding_agent/lib/coding_agent/session/persistence.ex`
- `apps/coding_agent/lib/coding_agent/session/message_serialization.ex`
- `apps/coding_agent/lib/coding_agent/session_manager.ex`
- `apps/coding_agent/lib/coding_agent/messages.ex`
- `apps/coding_agent/lib/coding_agent/tools/task/followup.ex`
- `apps/coding_agent/lib/coding_agent/tools/agent.ex`

3. Then do the deeper AsyncTaskSurface/status ownership cleanup.
- `apps/lemon_router/lib/lemon_router/surface_manager.ex`
- `apps/lemon_router/lib/lemon_router/async_task_surface_subscriber.ex`
- `apps/lemon_router/lib/lemon_router/run_process.ex`
- `apps/lemon_router/lib/lemon_router/tool_status_coalescer.ex`
- `apps/coding_agent/lib/coding_agent/task_progress_binding_store.ex`
- `apps/coding_agent/lib/coding_agent/task_progress_binding_server.ex`
- `apps/coding_agent/lib/coding_agent/tools/task/live_bridge.ex`
- `apps/coding_agent/lib/coding_agent/tools/task/execution.ex`
- `apps/coding_agent/lib/coding_agent/tools/task/result.ex`

Reason for this order:

- the followup/provenance work fixes a current correctness bug on `main`.
- it only needs a small router contract change up front.
- the status redesign is broader and explicitly intends to remove compatibility layers, so it is safer to do after the ingress/provenance carrier is stabilized.

### Final verdict

These workstreams should not be treated as fully independent, but they also do not need to be strictly sequential end-to-end.

- They can proceed in parallel after a small shared contract agreement on:
  `SessionTransitions` merge behavior, router metadata naming, and keeping prompt transport text-based.
- They should avoid concurrent edits to:
  `apps/lemon_router/lib/lemon_router/session_transitions.ex`
  and
  `apps/coding_agent/lib/coding_agent/cli_runners/lemon_runner.ex`.
- The status redesign should merge after the ingress/provenance carrier is stable, especially before deleting `TaskProgressBindingStore`/`LiveBridge` compatibility paths.

Practical verdict: parallelizable with coordination, but not safely independent; do the small router metadata/merge contract first, then followup/provenance, then the heavier AsyncTaskSurface cleanup.
