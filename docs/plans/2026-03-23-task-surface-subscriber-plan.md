# Plan: Decoupling Async Task Tool Uses from Parent RunProcess

## Context & Problem Statement

Currently, when a synchronous subagent task runs, its tool calls are visible in the user's Telegram UI (as nested "working..." steps). This works because:
1. The child task's tool uses are projected by a `LiveBridge` as `:task_projected_child_action` events back to the parent's `LemonCore.Bus` topic.
2. The parent run is still active, so its `LemonRouter.RunProcess` receives these events.
3. The `RunProcess` forwards them to `LemonRouter.ToolStatusCoalescer`, which emits UI edits.

However, for **asynchronous** tasks, the parent's `Task` tool use immediately completes. The parent agent finishes generating its response, and the parent run completes. **When a run completes, its `RunProcess` in `lemon_router` terminates.**

While the async child task continues running in the background and its `LiveBridge` continues broadcasting projected tool uses to the parent's topic, the parent's `RunProcess` is already dead. There is no process left listening to that topic to route those events to the Telegram UI, so the async task's progress is entirely hidden from the user until it finishes and sends a followup message.

## Proposed Architecture: `LemonRouter.TaskSurfaceSubscriber`

To surface these nested tool uses without overcomplicating the router queue or violating architectural boundaries, we will introduce a lightweight, dedicated subscriber process in `lemon_router`.

This completely detaches the UI updates from the parent run's lifespan. The parent run can finish and die, but the `TaskSurfaceSubscriber` stays alive until the async task finishes.

### The Missing Piece
We already have the "UI updater" (`ToolStatusCoalescer`) which is an independent background process. It doesn't actually need `RunProcess` to be alive.
We also have the "Event Broadcaster" (`Bus`) which emits events to `run:<child_run_id>`.

We will build a simple `LemonRouter.TaskSurfaceSubscriber` to bridge them.

### How it will work:
1. **Trigger:** When an async task starts, it is assigned a specific "surface" (e.g., `{:status_task, "task_123"}`). The parent `RunProcess` (or `SurfaceManager`) detects the spawn of an async task (either via a dedicated event or by inspecting the `Task` tool's `:engine_action` payload for `child_run_id`).
2. **Spawn:** `lemon_router` spawns a `TaskSurfaceSubscriber` (e.g., under a DynamicSupervisor) and gives it:
   - `child_run_id`
   - `session_key`
   - `channel_id`
   - `surface`
3. **Subscribe & Route:** The subscriber does exactly one thing: it subscribes to `run:<child_run_id>`, receives `:engine_action` events, and feeds them directly into `ToolStatusCoalescer.ingest_action/5`.
4. **Cleanup:** When the subscriber sees the `:run_completed` event for that task, it tells `ToolStatusCoalescer` to finalize the UI segment, and then the subscriber gracefully terminates.

## Why this approach?

* **No Architectural Violations:** It lives in `lemon_router`, so it is perfectly legal for it to call `ToolStatusCoalescer`.
* **No `RunProcess` Dependency:** The parent run can finish and exit without dragging the UI state down with it.
* **No Queueing Mess:** We don't have to turn background tasks into first-class router runs (which would inadvertently place them into the user's conversational queue and mess up message ordering).
* **Deprecates the `LiveBridge` Hack:** We would no longer need `LiveBridge` (inside `coding_agent`) to masquerade child actions as parent actions to trick the parent's `RunProcess`. The subscriber natively handles the routing.

## Implementation Steps

### Phase 1: Create the Subscriber
1. Create `apps/lemon_router/lib/lemon_router/task_surface_subscriber.ex`.
2. Implement it as a `GenServer` that subscribes to `run:<child_run_id>` on init.
3. Handle `:engine_action` events by calling `ToolStatusCoalescer.ingest_action(session_key, channel_id, child_run_id, action_event, surface: surface)`.
4. Handle `:run_completed` (and error states) by finalizing the surface via `ToolStatusCoalescer.finalize_run/5` and stopping the subscriber.

### Phase 2: Wiring the Spawner
1. Decide on the handoff mechanism. Options include:
   - Having `CodingAgent.Tools.Task.Execution` broadcast a specific `{:async_task_spawned, child_run_id, surface}` event on the parent's run topic.
   - The parent's `RunProcess` listens for this event, looks up the `channel_id` from the session context, and spawns the `TaskSurfaceSubscriber`.
2. Register the subscriber under an existing or new `DynamicSupervisor` in `lemon_router` so it outlives the `RunProcess`.

### Phase 3: Cleanup
1. Remove or adapt `CodingAgent.Tools.Task.LiveBridge` if it is no longer needed (since the subscriber handles the event projection at the router boundary now).
2. Ensure the async task UI updates appear correctly in Telegram by running an end-to-end test with a long-running async task.
