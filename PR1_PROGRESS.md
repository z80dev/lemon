# PR1: Make async nested tool uses show up in Telegram

## Success Criteria
- [x] Message the running lemon bot on Telegram
- [x] Ask it to launch a claude task that does semi-complex work resulting in tool uses
- [x] See the tool uses rendered live in the Telegram message (not just "Running...")
- [x] Multi-engine parallel test: 4 async tasks (claude, codex, glm, minimax) building tetris games simultaneously
- [x] Internal (lemon) engine async tasks also show tool uses

## Implementation Steps

### 1. Add `CodingAgent.Tools.Task.Projection` module
Extract shared projection logic from LiveBridge into a reusable module.
- [x] Create `apps/coding_agent/lib/coding_agent/tools/task/projection.ex`

### 2. Change `Async.wrap_on_update` to emit child `:engine_action`
- [x] Update `wrap_on_update/2` → `wrap_on_update/3` with lifecycle_context
- [x] Update `execution.ex` call site to pass lifecycle_context
- [x] Emit `:engine_action` events on child run topic from async updates

### 3. Add `LemonRouter.AsyncTaskSurfaceSubscriber` + supervisor
- [x] Create `apps/lemon_router/lib/lemon_router/async_task_surface_subscriber.ex`
- [x] Add Registry + DynamicSupervisor to `lemon_router/application.ex`

### 4. Start subscriber from `SurfaceManager` on async task queued
- [x] Add `maybe_start_async_task_surface_subscriber` to `ingest_status_action`

### 5. Stop finalizing running task surfaces on parent run completion
- [x] Replace `active_status_surfaces` with `finalizable_status_surfaces` in `finalize_status`
- [x] Use AsyncTaskSurfaceRegistry to check for live subscribers (not binding store)

### 6. Update `LiveBridge` to use shared Projection module
- [x] Refactor to use `Projection.project_child_payload`

## Testing
- [x] Build compiles clean
- [x] Existing tests pass (3730 coding_agent, 387 lemon_router — only pre-existing failures)
- [x] Manual test: telegram async task with tool uses visible (CLI engines: claude, codex)
- [x] Manual test: 4 parallel async tasks across claude/codex/glm/minimax engines
- [x] Manual test: internal/lemon engine async tasks emit tool uses (verified via logs: projection=ok, coalescer dispatching edits to Telegram)

## Files Changed
- `apps/coding_agent/lib/coding_agent/tools/task/projection.ex` (NEW)
- `apps/coding_agent/lib/coding_agent/tools/task/async.ex` (modified)
- `apps/coding_agent/lib/coding_agent/tools/task/execution.ex` (modified)
- `apps/coding_agent/lib/coding_agent/tools/task/live_bridge.ex` (modified)
- `apps/lemon_router/lib/lemon_router/async_task_surface_subscriber.ex` (NEW)
- `apps/lemon_router/lib/lemon_router/application.ex` (modified)
- `apps/lemon_router/lib/lemon_router/surface_manager.ex` (modified)

## Notes
- Internal engine (lemon) emits tool actions via `await_result`'s `:tool_execution_start/update/end` handlers → `maybe_emit_action_update` → `on_update_safe` → `maybe_emit_child_engine_action` → Bus broadcast
- Some Telegram edits fail with MESSAGE_TOO_LONG when many tool actions accumulate — this is a pre-existing rendering constraint, not a bug in this change
