Yes: the reason you **see nested tool uses for sync tasks but not async tasks in Telegram** is that the sync path stays inside the parent run’s normal live event stream, while the async path historically detached into a separate child run whose `engine_action` events were **stored** but not **projected back onto the parent task surface**.

More concretely:

- Lemon already knows how to render nested tool uses when the relevant metadata lands on the parent task/status surface. `ToolStatusCoalescer` expands embedded child progress from `detail.partial_result.details.current_action`, and it also honors `detail.parent_tool_use_id` so child actions stay attached to the parent task line. citeturn0commentaryto=multi_tool_use.parallel0
- For async tasks, the repo’s own problem statement says the nested child progress **exists in `CodingAgent.TaskStore` as `AgentToolResult.details.current_action`**, but Telegram does **not** continuously show it under the original task message; only the top-level task line/final result tends to appear. citeturn0commentaryto=functions.semantic-code-search1turn0commentaryto=functions.lexical-code-search2
- The architectural fix already appears to be underway in the repo: a `CodingAgent.Tools.Task.LiveBridge` subscribes to the **child run topic**, converts child `:engine_action` events into `:task_projected_child_action`, stamps them with the parent binding metadata including `parent_tool_use_id`, and rebroadcasts them on the **parent run topic**. `RunProcess` then ingests those projected child actions into `ToolStatusCoalescer` on the chosen surface. citeturn0commentaryto=functions.lexical-code-search2

So the short answer to **“why not?”** is:

1. **Sync task path:** nested actions are naturally visible because they occur in the active parent run lifecycle and go through the normal `RunProcess -> OutputTracker -> ToolStatusCoalescer -> Telegram renderer` path. `RunProcess` handles `:engine_action` directly and feeds them into tool-status coalescing. citeturn0commentaryto=functions.lexical-code-search2
2. **Async task path:** child actions happen on a **different run/topic/process**. Without a bridge plus a binding to the original parent task surface, Telegram has nothing telling it “these child actions belong under that already-rendered `task(codex)` line.” The transport async helper in Telegram is just background execution plumbing; it does not itself preserve or project semantic child-status lineage. citeturn0commentaryto=functions.semantic-code-search1turn0commentaryto=functions.lexical-code-search0

## What is required to surface nested tool uses for async tasks?

You need these pieces, and the repo docs/code suggest that’s exactly the intended design:

- **Capture parent surface identity when async task starts**
  - `task_id`
  - `parent_run_id`
  - `parent_session_key`
  - `root_action_id`
  - `surface`

  The plan explicitly says current code had `parent_run_id`, `session_key`, and `agent_id`, but was missing `root_action_id` / surface plumbing needed to attach later child updates back to the original task message. citeturn0commentaryto=functions.lexical-code-search1

- **Persist a child→parent binding**
  - so the system can later resolve “child run X should project into parent run Y on surface Z under root action A.” citeturn0commentaryto=functions.lexical-code-search1

- **Run a live bridge process for the child run**
  - subscribe to `Bus.run_topic(child_run_id)`
  - on each child `:engine_action`, emit projected child action to the parent run
  - preserve `parent_tool_use_id`
  - stop and clean up on terminal events.
  That is what `CodingAgent.Tools.Task.LiveBridge` is doing. citeturn0commentaryto=functions.lexical-code-search2

- **Keep rendering in router/channels, not Telegram transport hacks**
  - The repo guidance is explicit: semantic output changes belong in router coalescers / `RunProcess.OutputTracker`; platform UX stays in `lemon_channels`. That’s the correct separation. citeturn0commentaryto=functions.lexical-code-search2turn0commentaryto=functions.semantic-code-search1

## Are architectural changes required?

**Small, targeted ones: yes. Big rewrite: no.**

From what I found, you do **not** need a new scheduler or a Telegram-specific reinvention. The missing capability is mostly **lineage projection**:

- async child run emits progress
- progress must be rebound to the parent task’s semantic status surface
- renderer then naturally edits the existing Telegram task message

That means the required architecture change is really:

> **Add/finish the child-run-to-parent-run projection layer with stable surface binding.**

Notably, the docs themselves warn against overcomplicating this kind of change:
- reuse existing primitives like `TaskStore`, bus events, run graph/session machinery
- avoid inventing a second scheduler/general framework when existing Lemon task infrastructure already models the lifecycle. citeturn0commentaryto=functions.lexical-code-search1

## Are you overcomplicating it?

**Possibly a little, if you’re thinking about this as a Telegram problem or as a new async framework problem.**

It looks simpler if you frame it as:

- **Sync path works** because events already arrive on the parent run/status surface.
- **Async path fails** because events arrive on the child run and stop there.
- Therefore:
  - bind child run to parent task surface at spawn time
  - bridge child `engine_action` events to parent run
  - let existing coalescer/renderer logic do the rest

So I’d say:

- **Not overcomplicated conceptually** if you implement only binding + bridge + cleanup.
- **Overcomplicated** if you try to solve it in:
  - Telegram transport,
  - ad hoc polling from `TaskStore`,
  - special-case async rendering branches,
  - or a separate status delivery system.

The cleanest architecture is already hinted by your own code/docs:
- router owns semantic delivery,
- Telegram owns presentation,
- async task system owns child→parent progress projection. citeturn0commentaryto=functions.lexical-code-search2turn0commentaryto=functions.semantic-code-search1

## My recommendation

I’d treat this as a **projection/binding bug**, not a rendering bug.

### Best approach
1. **Ensure async task creation records**
   - `root_action_id`
   - `surface`
   - `parent_run_id`
   - `parent_session_key`
   - `task_id`
   - `child_run_id` citeturn0commentaryto=functions.lexical-code-search1

2. **Ensure `LiveBridge.start_for_child_run/1` is definitely invoked**
   - at async child run startup
   - only when binding exists. citeturn0commentaryto=functions.lexical-code-search2

3. **Project child actions with stable IDs and `parent_tool_use_id`**
   - so `ToolStatusCoalescer` can keep editing the original task surface instead of creating detached entries. citeturn0commentaryto=functions.lexical-code-search0turn0commentaryto=functions.lexical-code-search2

4. **Regression-test at the router/renderer level**
   - parent task root appears once
   - child `read/bash/grep` updates append underneath
   - poll/join do not duplicate child lines
   - final answer remains separate.
   Those are explicitly called out in the async-task plan. citeturn0commentaryto=functions.semantic-code-search1

## One likely root cause to verify immediately

I would specifically inspect whether the async task path is **actually capturing and propagating `root_action_id` and `surface` at task spawn time** and whether the bridge is being started for real child runs in Telegram-triggered conversations. The planning doc says that missing root action/surface identity was the crucial gap. citeturn0commentaryto=functions.lexical-code-search1

## One caveat

The code-search results may be incomplete because the search tool returns limited results. To inspect more in GitHub UI, use code search in the repo for terms like `LiveBridge`, `root_action_id`, `task_projected_child_action`, and `parent_tool_use_id`: `https://github.com/search?q=repo%3Az80dev%2Flemon+LiveBridge+OR+root_action_id+OR+task_projected_child_action+OR+parent_tool_use_id&type=code`

If you want, I can next do a more surgical pass and tell you **exactly which modules/functions are still missing the final wiring**, likely starting with:

- `apps/coding_agent/lib/coding_agent/tools/task/execution.ex`
- `apps/coding_agent/lib/coding_agent/tools/task/async.ex`
- `apps/coding_agent/lib/coding_agent/tools/task.ex`
- `apps/lemon_router/lib/lemon_router/run_process/output_tracker.ex`
- `apps/lemon_channels/lib/lemon_channels/adapters/telegram/status_renderer.ex`

---
## Gemini's Take: Why Nested Tool Uses are Missing in Async Tasks

Based on the investigation into the codebase, specifically internal planning documentation (`docs/plans/2026-03-18-async-task-live-nested-status-plan.md`), here is a breakdown of why this happens and how to resolve it:

### 1. Why don't we see nested tool uses for async tasks?
In the current architecture, synchronous tasks run inline within the same `run_id`. Because of this, their tool actions naturally flow into the parent's `ToolStatusCoalescer` and seamlessly render as nested actions on Telegram.

Conversely, when a task is run asynchronously (`task(async=true)`), it spawns a background child run with its own isolated `run_id`. The child run emits its live `:engine_action` events to the `LemonCore.Bus` on its own distinct topic, completely detached from the parent run. While the background progress is correctly saved in `CodingAgent.TaskStore`, the Telegram channel is only listening to the parent's `ToolStatusCoalescer` stream. There is no active bridge projecting those background child events into the parent's rendering surface.

### 2. How can we surface these nested tool uses?
The documented plan outlines the introduction of a **Live Task-Progress Bridge** pattern. This works by:
1. **Binding:** When an async task is launched, persist a mapping between the `task_id` / `child_run_id` and the original parent task surface (`parent_run_id`, `root_action_id`, `surface`).
2. **Bridging:** Spawn a sidecar `LiveBridge` process that subscribes to the child run's live bus events.
3. **Projecting:** As the child run emits `:engine_action` events, the bridge normalizes them and projects them back into the parent's `ToolStatusCoalescer` as embedded child actions (routing them using the parent's `run_id`).
4. **Rendering:** The coalescer continuously edits the original top-level task message in Telegram, naturally appending the nested live updates.

### 3. Are there architectural changes required?
Yes, minor architectural changes are required to stitch the isolated systems together. It demands a new projection layer:
* **New Binding Store:** An ETS-backed store (e.g., `task_progress_binding_store.ex`) so the system can retain context on which parent Telegram message owns which background child run.
* **New Bridge Processes:** A `LiveBridge` process managed by a `DynamicSupervisor` that actively listens to the child run's topic and forwards relevant events.
* **Coalescer Ingress API:** An update to `ToolStatusCoalescer` to accept projected child actions from external sources, complete with proper deduplication logic so future `poll` or `join` actions don't result in duplicate lines.

### 4. Are we overcomplicating things somewhere that is making this hard?
To some degree, yes. The system heavily leverages a decoupled event-bus architecture (`LemonCore.Bus`). Because child tasks are treated as entirely independent entities with their own lifecycle and event topics, there is no automatic hierarchical relationship built in for rendering.

Instead of an async task intuitively bubbling its progress state up the call stack back to the parent, the system requires bridging cross-run domains, maintaining stateful ETS bindings, and establishing event projection loops just to append a line of text to a Telegram message. This level of architectural strictness—enforcing isolated parent/child domains—makes achieving basic hierarchical UI updates noticeably more complicated than in a tightly coupled, single-process execution model.
 COPILOT UPDATED
I think that explanation is **very likely correct**, and more precise than my earlier high-level framing.

## My updated take

**Yes — the real root cause is probably not “Telegram can’t render async nested tool uses.”**
It’s this:

> **The async child run is not emitting live `:engine_action` bus events on `run:<child_run_id>`, so `LiveBridge` has nothing to subscribe to and project.**

That fits the evidence extremely well.

## Why this explanation makes sense

There are three important facts in the repo:

1. **`LiveBridge` is explicitly bus-driven.**
   It subscribes to `Bus.run_topic(binding.child_run_id)` and reacts to `:engine_action`, then rebroadcasts `:task_projected_child_action` to the parent run. If no child bus events exist, it is inert.
   The code snippet you shared is consistent with the repo version:
   - subscribe to child run topic
   - on `:engine_action`, project to parent run
   - on terminal events, clean up.
   So the bridge architecture itself is fine.

2. **`RunProcess` already knows how to consume projected child actions.**
   `RunProcess.handle_info(%Event{type: :task_projected_child_action, ...})` passes them into `OutputTracker.ingest_projected_child_action_to_tool_status_coalescer/3`, which then uses `ToolStatusCoalescer.ingest_projected_child_action/6`.
   So parent-side rendering infrastructure is already in place.

3. **`TaskStore` clearly contains async child progress, but that’s not the same as bus emission.**
   The repo already documents that async child progress is present in `TaskStore` under `details.current_action`, yet Telegram doesn’t live-update. That strongly suggests the data is being captured **somewhere**, but not injected into the live event pipeline.

So the other agent’s diagnosis:

- sync path emits `:engine_action` naturally through the gateway run pipeline
- async path only appends to `TaskStore`
- `LiveBridge` listens to bus, not `TaskStore`
- therefore nothing appears live

…is a very strong match.

## So do I agree with the proposed fix?

**Yes, mostly.**
The key fix is:

> **When async child execution observes tool/action updates, also emit normalized `:engine_action` events onto `Bus.run_topic(child_run_id)`.**

That is probably the cleanest minimal repair.

## Best place to fix it

Of the two options mentioned, I’d rank them like this:

### Option A — emit from async `on_update` wrapper
If `Async.wrap_on_update/2` already receives the `AgentToolResult` partial updates and has the `run_id`, this is a very practical fix.

Why it’s attractive:
- smallest delta
- directly uses the updates already being persisted into `TaskStore`
- no need to reroute child execution through gateway
- immediately unblocks `LiveBridge`

What it must do carefully:
- only emit when there is enough structure to build a valid `:engine_action`
- preserve stable ids/phases so projected child lines upsert instead of duplicating
- emit terminal events too if bridge cleanup depends on them and they’re also missing

### Option B — emit closer to the CLI runner stream
This is architecturally a bit cleaner **if** the child runner really already has native action events in a better-structured form than `AgentToolResult`.

Why it may be better:
- closer to original source of truth
- less lossy than reconstructing from `current_action`
- mirrors sync path behavior more faithfully

Why it may be worse:
- touches lower-level execution path
- may require more plumbing
- risk of coupling async task execution too tightly to gateway-specific event shapes

## My recommendation

I would start with:

### **Emit child `:engine_action` events in the async `on_update` path**
because it is the lowest-risk and best-aligned with the existing architecture.

That means:

1. async child run continues doing what it already does
2. `on_update` still appends to `TaskStore`
3. **in addition**, it broadcasts a normalized `LemonCore.Event.new(:engine_action, payload, meta)` on `Bus.run_topic(child_run_id)`
4. `LiveBridge` receives it
5. `LiveBridge` projects it to parent run
6. parent `RunProcess` ingests projected child action
7. `ToolStatusCoalescer` updates the Telegram task surface

That is exactly the missing last mile.

## What to verify before coding

I’d verify these specific things:

### 1. Are async child runs already broadcasting terminal run events?
`LiveBridge` also stops on terminal events like `:run_completed`, `:task_completed`, `:task_error`, etc.
If child runs are also missing those on the bus, then fixing only `:engine_action` may give you live progress but leave stale bindings/subscriptions behind.

So the complete fix may be:

- emit live `:engine_action`
- ensure terminal child bus events are also emitted

### 2. Is `run_id` in async updates definitely the child run id?
The emitter must publish to the **child** run topic that `LiveBridge` subscribes to.

### 3. Are action ids stable enough?
If you synthesize ids from `current_action`, make sure updates map to one logical line:
- started
- updated
- completed

Otherwise Telegram may show duplicates instead of one evolving nested item.

### 4. Are you reconstructing enough detail?
`ToolStatusCoalescer` benefits from:
- `action.id`
- `action.kind`
- `action.title`
- `phase`
- `action.detail`

and especially parent-child metadata later on.
If the async path only has `current_action`, you may need a small normalizer.

## Does this require architectural changes?

**Not really.**
I now agree with the other agent on that point too.

This looks like a **missing event emission step**, not a broken architecture.

The architecture already seems right:

- async child has its own run identity
- binding store links child run to parent task surface
- live bridge projects child events to parent run
- router coalescer renders projected actions
- Telegram just edits the correct message

That is a clean architecture.

The problem is simply:

> one segment of the chain produces state updates but not live bus events.

So no, I don’t think you need:
- a new scheduler
- a Telegram-specific workaround
- polling `TaskStore` to fake live updates
- a redesign of `LiveBridge`

## Are you overcomplicating things?

I’d say:

- **The architecture itself is not overcomplicated.**
- **You may have slightly overbuilt the projection side before ensuring the child run actually emitted the events the bridge needed.**

That’s a very normal systems mistake:
- build the bridge
- forget to feed the bridge

But the bridge/binding approach is still the right shape.

## My bottom line

**I agree with the other agent’s diagnosis.**
If I had to bet, I’d bet the bug is:

- async child progress is persisted into `TaskStore`
- but not broadcast as live `:engine_action` events on `run:<child_run_id>`
- so `LiveBridge` never sees anything to forward
- therefore Telegram only gets top-level task/final updates, not nested live child actions

And I agree the likely fix is small:
- add child-run bus emission in async update handling
- preferably in the `on_update` wrapper or closest runner event adapter
- ensure terminal events are emitted too

## Practical next step

If you want, I can do one more pass and give you a **concrete patch plan** like:

- exact module/function to change
- exact event payload shape to emit
- whether to synthesize from `AgentToolResult.details.current_action` or emit from runner-native action events
- what tests to add to prove it works end-to-end

That would let us move from “diagnosis” to “this is the 2-file fix.”

---

# Gemini-Within-Droid's Take: Decoupling Async Task Tool Uses from Parent RunProcess

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

---

# Claude Opus Take: Two Broken Ends, Correct Middle

## Methodology

Independent codebase review tracing the full event path from async child task execution through to Telegram rendering. Read every module in the chain rather than relying on plan docs or code search summaries.

## Finding: The architecture has two independent problems, not one

The plumbing in the middle (LiveBridge, binding store, ToolStatusCoalescer) is correctly implemented but never exercised because **both endpoints are disconnected**.

### Problem 1: Child runs don't emit `:engine_action` to the bus

**Take 3a was correct about this.**

Async task execution follows two paths, neither of which goes through `LemonGateway.Run`:

- **CLI engine path** (`runner.ex:63`): Starts a `CodexSubagent`/`ClaudeSubagent` directly. Tool events arrive as `{:action, ...}` tuples via `module.events(session)`, processed by `reduce_cli_events`, which calls `on_update` → `TaskStore.append_event`. No bus emission.

- **Internal session path** (`runner.ex:229`): Starts a `CodingAgent.Session` directly via `CodingAgent.start_session`. Session events arrive via subscription, processed by `await_result`, which calls `on_update` → `TaskStore.append_event`. No bus emission.

Only `LemonGateway.Run` (`run.ex:814`, `emit_engine_event_to_bus/2`) converts engine events into `:engine_action` bus broadcasts. Async tasks bypass the gateway entirely.

**Verified:** `CodingAgent.Session` and its subdirectory contain zero references to `engine_action`, `Bus.broadcast`, or `run_topic`.

**Result:** LiveBridge subscribes to `Bus.run_topic(child_run_id)` but receives nothing. It sits idle for the entire child run lifetime.

### Problem 2: Parent RunProcess is dead before child events could arrive

**Take 3b was correct about this.**

`RunProcess` is `restart: :temporary` — when the parent run completes (`:run_completed` at `run_process.ex:310`), it terminates with `{:stop, :normal, ...}`. For async tasks, the parent completes as soon as it returns "task started" to the user. By the time the child would produce tool actions, the parent `RunProcess` is long dead.

Even if Problem 1 were fixed (child emits bus events → LiveBridge projects to parent topic), there is **no subscriber** on `Bus.run_topic(parent_run_id)` to receive the `:task_projected_child_action` events.

**Result:** LiveBridge's projected events would broadcast to a topic with zero subscribers.

### What's correctly built (the middle)

| Component | File | Status |
|-----------|------|--------|
| `TaskProgressBindingStore` | `task_progress_binding_store.ex` | Working — binding created at spawn, links child→parent |
| `LiveBridge` | `live_bridge.ex` | Working but idle — supervised under `LiveBridgeSupervisor`, started at async spawn |
| `RunProcess` handler for `:task_projected_child_action` | `run_process.ex:356-369` | Working but unreachable — routes to `SurfaceManager` |
| `ToolStatusCoalescer` | `tool_status_coalescer.ex` | Working, outlives RunProcess — under `ToolStatusSupervisor` |
| `SurfaceManager.ingest_projected_child_action` | `surface_manager.ex:117-133` | Working but never called |
| Task surfaces `{:status_task, task_id}` | `tool_status_coalescer.ex:325+` | Implemented — coalescer supports per-task surfaces |

## Scorecard of prior takes

| Take | Diagnosis | Verdict |
|------|-----------|---------|
| **1 (Claude initial)** | "Missing projection layer" | **Partially wrong** — projection layer exists, it's the emission and reception that's missing |
| **2 (Gemini)** | "Bus architecture makes this hard" | **Correct observation**, but not the root cause |
| **3a (Updated Claude)** | "Child runs don't emit bus events" | **Correct** — verified against source |
| **3b (Droid/TaskSurfaceSubscriber)** | "Parent RunProcess dies" | **Correct** — verified against source |

## Recommendation

The fix needs to address both ends:

### End 1: Emit `:engine_action` from async child execution

The `on_update` wrapper in `Async.wrap_on_update/2` already receives `AgentToolResult` with `details.current_action` containing `title`, `kind`, and `phase`. This is the natural place to also broadcast a normalized `:engine_action` event to `Bus.run_topic(child_run_id)`. Terminal events (`:run_completed` etc.) must also be emitted so whatever subscribes can clean up.

### End 2: Subscribe to child events independently of RunProcess

The `TaskSurfaceSubscriber` approach is the cleanest fix because it solves both routing problems in one shot:

1. Subscribes directly to `Bus.run_topic(child_run_id)` — no projection hop through parent topic needed
2. Feeds `ToolStatusCoalescer.ingest_action` directly — no dependency on RunProcess being alive
3. Lives under `ToolStatusSupervisor` (or a new DynamicSupervisor) — outlives parent run
4. Self-terminates on child run completion

This makes `LiveBridge` redundant for the UI-update use case. LiveBridge can be retired or repurposed once `TaskSurfaceSubscriber` is in place.

### What NOT to do

- Don't try to keep RunProcess alive longer — it owns the conversational queue and extending its lifetime creates ordering problems
- Don't poll TaskStore from Telegram — that's the ad-hoc hack the architecture was designed to avoid
- Don't add special-case async rendering in the transport layer — semantic delivery belongs in the router