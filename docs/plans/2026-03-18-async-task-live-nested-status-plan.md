# Async Task Live Nested Status Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Make async `task(...)` invocations keep editing their original Telegram task-status message with live nested Codex/Claude child tool actions, instead of only showing the top-level `task(...)` line until completion or poll.

**Architecture:** Introduce a live task-progress bridge between background child runs and the parent task surface. When `task(async=true)` starts a child run, persist a binding from `task_id` / `child_run_id` to the original parent task surface (`root_action_id`, `surface`, `parent_session_key`, `parent_run_id`). Subscribe to the child run’s live bus events and project child `:engine_action` events back into the parent `ToolStatusCoalescer` as embedded child actions until the child completes.

**Tech Stack:** Elixir, Lemon router/gateway bus, ETS-backed task binding store, DynamicSupervisor-managed bridge processes, `CodingAgent.TaskStore`, `LemonRouter.RunProcess.OutputTracker`, `LemonRouter.ToolStatusCoalescer`, Telethon canary verification.

---

## Problem statement

Current behavior for async tasks in Telegram:
- top-level task line renders, e.g. `✓ task(codex): Assess March Madness EVM project`
- child Codex/Claude progress exists in `CodingAgent.TaskStore` as `AgentToolResult.details.current_action`
- Telegram does **not** continuously show the nested inner child actions under the original task message
- user only sees the final result or sporadic top-level updates

Observed evidence:
- Telethon inspection of Lemonade Stand March Madness thread showed top-level `task(codex)` / `task(claude)` messages without live nested child tool calls.
- Live `TaskStore.get(task_id)` on node `lemon@newphy` showed many nested updates for the same tasks (commands, reads, edits, etc.).
- Therefore, the source metadata exists; the missing piece is the live projection path from background task progress into the parent task surface.

Non-goal:
- Do **not** change the intended UX that task child actions should stay attached to the original task message wherever it first appears.

---

## Architecture decisions locked

1. **Async tasks keep one canonical surface**
   - The first top-level `task(...)` action creates the parent/root surface.
   - All live child activity must continue editing that same surface.

2. **Live subscription, not polling**
   - Do not build this from periodic `TaskStore` polling.
   - Use the child run’s live bus events to preserve ordering and reduce lag.

3. **Dedicated binding store**
   - Do not overload `TaskStore` with transient router subscription state.
   - Add a separate ETS-backed binding store keyed by `task_id` and `child_run_id`.

4. **Projection happens outside the parent main loop**
   - Parent run should not block on child completion.
   - Child progress should still be surfaced via a sidecar subscriber process.

5. **Use router-owned task surface metadata already present**
   - Reuse `root_action_id`, `surface`, `task_id`, `parent_tool_use_id` conventions already used by `OutputTracker` / `ToolStatusCoalescer`.

6. **Parent surface remains parent-owned**
   - Projected child actions render into the parent task surface using the **parent run id**.
   - `child_run_id` is projection metadata, not the coalescer’s owning run id.

7. **Stable projected action ids**
   - Do not generate random ids for projected child actions.
   - Use a deterministic id format so repeated child updates upsert the same nested line instead of duplicating it.

---

## Files to read first

- `apps/coding_agent/lib/coding_agent/tools/task/execution.ex`
- `apps/coding_agent/lib/coding_agent/tools/task/async.ex`
- `apps/coding_agent/lib/coding_agent/tools/task/followup.ex`
- `apps/coding_agent/lib/coding_agent/task_store.ex`
- `apps/lemon_router/lib/lemon_router/run_process/output_tracker.ex`
- `apps/lemon_router/lib/lemon_router/tool_status_coalescer.ex`
- `apps/lemon_router/lib/lemon_router/run_process.ex`
- `apps/lemon_gateway/lib/lemon_gateway/run.ex`
- `apps/lemon_core/lib/lemon_core/bus.ex`

Also inspect these user-visible confirmations before coding:
- Telethon canary notes in `memory/2026-03-18.md`
- Lemonade Stand examples around message ids `10061`, `10062`, `10063`, `10066`

---

## Proposed new modules/files

### Create
- `apps/coding_agent/lib/coding_agent/task_progress_binding_store.ex`
- `apps/coding_agent/lib/coding_agent/task_progress_binding_server.ex`
- `apps/coding_agent/lib/coding_agent/tools/task/live_bridge.ex`
- `apps/coding_agent/test/coding_agent/tools/task/live_bridge_test.exs`

### Modify
- `apps/coding_agent/lib/coding_agent/application.ex` or relevant supervisor file where `TaskStoreServer` is started
- `apps/coding_agent/lib/coding_agent/tools/task.ex`
- `apps/coding_agent/lib/coding_agent/tools/task/execution.ex`
- `apps/coding_agent/lib/coding_agent/tools/task/async.ex`
- `apps/lemon_router/lib/lemon_router/run_process/output_tracker.ex`
- `apps/lemon_router/lib/lemon_router/tool_status_coalescer.ex`
- `apps/lemon_router/test/lemon_router/tool_status_coalescer_test.exs`
- `apps/lemon_router/test/lemon_router/run_process_test.exs`
- `apps/coding_agent/AGENTS.md` if public architecture/ownership description changes materially

---

## Binding model

Add a dedicated transient record like:

```elixir
%{
  task_id: "abc123",
  child_run_id: "run_xyz",
  parent_run_id: "run_parent",
  parent_session_key: "agent:default:telegram:default:group:-1003842984060:thread:9530",
  parent_agent_id: "default",
  root_action_id: "tool_call_123",
  surface: {:status_task, "tool_call_123"},
  inserted_at_ms: 1_773_881_561_000,
  status: :running
}
```

Required lookups:
- by `task_id`
- by `child_run_id`

Cleanup policy:
- delete binding when child run completes/errors/aborts
- prune stale bindings by TTL on startup / periodic cleanup

Notes:
- `root_action_id` is the semantic anchor; `surface` is the transport/render token.
- Store both. Do not try to recover `root_action_id` from `surface` later.

---

## Locked child-run event contract

Before implementation, use this event contract exactly.

### Subscribe to

```elixir
LemonCore.Bus.run_topic(child_run_id)
```

### Consume these child events

1. **Primary live progress signal:** `:engine_action`
   - emitted on the child run topic
   - payload shape already exists today via `LemonGateway.Run`
   - this is the event type the bridge should project live into the parent surface

2. **Primary terminal cleanup signal:** `:run_completed`
   - emitted on the child run topic
   - stop bridge and delete binding when seen

3. **Secondary safety/cleanup signals:** `:task_completed`, `:task_error`, `:task_timeout`, `:task_aborted`
   - may also arrive on the child run / parent run topics
   - useful for cleanup logging and defensive shutdowns
   - do **not** use these as the main source of nested child tool lines

### Current child `:engine_action` payload shape

```elixir
%{
  engine: "codex" | "claude" | "lemon" | ...,
  action: %{
    id: child_action_id,
    kind: :tool | :command | :file_change | :web_search | :subagent,
    title: "Read: AGENTS.md",
    detail: %{...}
  },
  phase: :started | :updated | :completed,
  ok: true | false | nil,
  message: nil | String.t(),
  level: nil | atom() | String.t()
}
```

### Stable projected action id format

Use this shape unless the tests force a tighter variant:

```elixir
"taskproj:" <> child_run_id <> ":" <> child_action_id
```

Fallback only if `child_action_id` is missing:

```elixir
"taskproj:" <> child_run_id <> ":" <> normalized_kind <> ":" <> short_hash(normalized_title)
```

Do **not** use random UUIDs for projected ids.

---

## Event projection model

For child run live events, subscribe to the child run bus topic and project these events:

### Child action started / updated / completed (`:engine_action`)
Project into the parent surface as embedded child actions.

Normalized projected payload shape should match what `ToolStatusCoalescer` already knows how to expand:

```elixir
%{
  engine: "codex",
  phase: :started,
  ok: nil,
  action: %{
    id: projected_id,
    kind: :tool | :command | :file_change | :web_search | :subagent,
    title: "Read: implementation-plan.md",
    detail: %{
      parent_tool_use_id: root_action_id,
      task_id: task_id,
      child_run_id: child_run_id,
      projected_from: :child_run,
      action_detail: %{...}
    }
  }
}
```

Important:
- projected events go to the parent task surface using `parent_run_id`
- `child_run_id` stays in `detail` / metadata for dedupe and debugging
- projected ids must be stable across started → updated → completed transitions

### Child run completed (`:run_completed`)
Emit terminal update on the parent surface:
- keep parent task line attached to child completion summary
- stop subscription
- delete binding

### Race-handling rules

- If the bridge starts and the binding is already terminal / missing, exit normally.
- If a child event arrives before the parent surface can be resolved, log and retry only if binding still exists; do not busy-loop.
- If route/coalescer resolution fails permanently, log, stop bridge, and leave async task execution itself unaffected.
- Bridge failure must degrade to current behavior (top-level task line + followup/poll), not break async task execution.

---

## Concrete implementation tasks

### Task 1: Create the transient binding store

**Objective:** Add an ETS-backed store for mapping `task_id` / `child_run_id` to the original parent task surface.

**Files:**
- Create: `apps/coding_agent/lib/coding_agent/task_progress_binding_store.ex`
- Create: `apps/coding_agent/lib/coding_agent/task_progress_binding_server.ex`
- Modify: relevant CodingAgent supervisor/app startup file
- Test: `apps/coding_agent/test/coding_agent/task_progress_binding_store_test.exs`

**Step 1: Write failing tests for the store API**

Cover:
- put binding
- get by task_id
- get by child_run_id
- delete binding
- overwrite binding status
- cleanup stale bindings

**Step 2: Run targeted test**

```bash
mix test apps/coding_agent/test/coding_agent/task_progress_binding_store_test.exs
```

Expected: FAIL

**Step 3: Implement minimal store**

API shape:

```elixir
def new_binding(attrs)
def get_by_task_id(task_id)
def get_by_child_run_id(child_run_id)
def mark_completed(child_run_id)
def delete_by_child_run_id(child_run_id)
def list_all()
def cleanup_expired(ttl_seconds)
```

**Step 4: Start the server in app supervision**

Pattern should mirror `TaskStoreServer` / `ParentQuestionStoreServer`.

**Step 5: Re-run tests**

Expected: PASS

**Step 6: Commit**

```bash
git add apps/coding_agent/lib/coding_agent/task_progress_binding_* apps/coding_agent/test/coding_agent/task_progress_binding_store_test.exs
 git commit -m "feat: add async task progress binding store"
```

---

### Task 2: Capture parent task surface binding at async task creation time

**Objective:** When async `task(...)` is launched, capture the original parent task surface so later child events know where to render.

**Files:**
- Modify: `apps/coding_agent/lib/coding_agent/tools/task.ex`
- Modify: `apps/coding_agent/lib/coding_agent/tools/task/execution.ex`
- Modify: `apps/coding_agent/lib/coding_agent/tools/task/async.ex`
- Modify: `apps/lemon_router/lib/lemon_router/run_process/output_tracker.ex` (if extra metadata export is needed)
- Test: `apps/coding_agent/test/coding_agent/tools/task/execution_test.exs`

**Step 1: Add binding metadata to execution context**

Plumb through from the task tool execute boundary and/or `opts`:
- `parent_session_key`
- `parent_agent_id`
- `parent_run_id`
- `root_action_id` (**required new plumbing**)
- `surface` (**required new plumbing**)

Current code already has `parent_run_id`, `session_key`, and `agent_id`. It does **not** currently capture `root_action_id` / surface metadata from the originating top-level task action, so add that explicitly at the task tool call boundary.

**Step 2: Write failing test that async execution stores a binding**

At minimum verify:
- async task with `task_id` + `run_id` + `root_action_id`
- binding stores `parent_run_id` and `surface`
- binding exists after `run_async/5` starts

**Step 3: Implement**

Create binding during async task startup, before child run begins execution.

Binding must include:
- `task_id`
- `child_run_id`
- `parent_run_id`
- `root_action_id`
- `surface`
- `parent_session_key`

**Step 4: Ensure the binding is optional-safe**

If `root_action_id` / `surface` is unavailable, async task execution should continue unchanged; simply do not start the live bridge later.

**Step 5: Re-run targeted tests**

Expected: PASS

**Step 6: Commit**

```bash
git add apps/coding_agent/lib/coding_agent/tools/task.ex apps/coding_agent/lib/coding_agent/tools/task/execution.ex apps/coding_agent/lib/coding_agent/tools/task/async.ex apps/coding_agent/test/coding_agent/tools/task/execution_test.exs
 git commit -m "feat: persist async task parent surface binding"
```

---

### Task 2.5: Lock projection identity and event normalization

**Objective:** Remove ambiguity before bridge implementation by defining the exact child event contract and stable projected id behavior in tests.

**Files:**
- Create: `apps/coding_agent/test/coding_agent/tools/task/live_bridge_contract_test.exs`
- Modify: `apps/coding_agent/lib/coding_agent/tools/task/live_bridge.ex` (if you prefer to start with the normalizer helpers)

**Step 1: Write failing contract tests**

Cover:
- `:engine_action` started/updated/completed maps into one stable projected id
- projected event keeps `detail.parent_tool_use_id = root_action_id`
- projected event preserves `child_run_id`
- fallback id path when child action id is missing is deterministic

**Step 2: Run targeted test**

```bash
mix test apps/coding_agent/test/coding_agent/tools/task/live_bridge_contract_test.exs
```

Expected: FAIL

**Step 3: Implement/lock helper normalization**

Keep helpers pure where possible:

```elixir
def projected_action_id(child_run_id, child_action)
def normalize_child_engine_action(binding, action_event)
```

**Step 4: Re-run targeted test**

Expected: PASS

**Step 5: Commit**

```bash
git add apps/coding_agent/test/coding_agent/tools/task/live_bridge_contract_test.exs apps/coding_agent/lib/coding_agent/tools/task/live_bridge.ex
git commit -m "test: lock async task live projection contract"
```

---

### Task 3: Add a live child-run bridge process

**Objective:** Subscribe to live child run bus events and project them back into the parent task surface while the async task runs.

**Files:**
- Create: `apps/coding_agent/lib/coding_agent/tools/task/live_bridge.ex`
- Create: `apps/coding_agent/lib/coding_agent/tools/task/live_bridge_supervisor.ex`
- Modify: `apps/coding_agent/lib/coding_agent/application.ex` or relevant supervisor file
- Modify: `apps/coding_agent/lib/coding_agent/tools/task/async.ex`
- Test: `apps/coding_agent/test/coding_agent/tools/task/live_bridge_test.exs`

**Step 1: Write failing tests for live projection**

Test cases:
- given binding + child run bus action event started, bridge emits projected parent event
- given child run completed event, bridge terminates and binding is deleted
- duplicate child action updates don’t crash
- missing binding is ignored safely

**Step 2: Implement the bridge process**

Responsibilities:
- subscribe to child run topic on `LemonCore.Bus`
- consume child `:engine_action` as the main live progress source
- consume child `:run_completed` as the main terminal cleanup source
- normalize child events into projected parent-surface action events
- forward projected updates to router/parent surface pathway using the **parent run id**
- cleanup on terminal event

Minimal public API:

```elixir
def start_link(binding)
```

Internal shape:
- state carries binding + maybe last projected action ids for dedupe

**Step 3: Supervise bridges explicitly**

Start one bridge per child run under a dedicated DynamicSupervisor.

Rules:
- one bridge per child run
- normal completion should not restart the bridge
- bridge crash should not crash async task execution

**Step 4: Hook bridge startup into async task flow**

After child run id exists and before background task fully proceeds, start bridge **only if** the binding has `root_action_id` and `surface`.

**Step 5: Re-run targeted tests**

Expected: PASS

**Step 6: Commit**

```bash
git add apps/coding_agent/lib/coding_agent/tools/task/live_bridge.ex apps/coding_agent/lib/coding_agent/tools/task/live_bridge_supervisor.ex apps/coding_agent/lib/coding_agent/tools/task/async.ex apps/coding_agent/lib/coding_agent/application.ex apps/coding_agent/test/coding_agent/tools/task/live_bridge_test.exs
 git commit -m "feat: stream async child task progress live"
```

---

### Task 4: Decide the projection target API

**Objective:** Define the cleanest way for the bridge to push projected child actions into the parent task surface.

**Files:**
- Modify: `apps/lemon_router/lib/lemon_router/run_process/output_tracker.ex`
- Modify: `apps/lemon_router/lib/lemon_router/tool_status_coalescer.ex`
- Test: `apps/lemon_router/test/lemon_router/tool_status_coalescer_test.exs`

**Preferred approach:** add a small explicit API into `ToolStatusCoalescer` for external child-progress ingestion.

Proposed API:

```elixir
def ingest_projected_child_action(session_key, channel_id, parent_run_id, surface, projected_event, opts \\ [])
```

This avoids needing fake parent action events to flow through unrelated code paths.

Important:
- `parent_run_id` owns the task surface/coalescer message
- `child_run_id` stays inside projected event metadata/detail for dedupe and debugging

**Step 1: Write failing test**

Test:
- create a task surface
- inject projected child action started/completed
- assert rendered text includes nested child lines under original task root
- assert repeated projected updates with the same projected id upsert the same line

**Step 2: Implement minimal API**

Reuse existing normalization/render logic in `ToolStatusCoalescer`; do not fork rendering rules.

**Step 3: Ensure `parent_tool_use_id` is respected**

Projected child actions must set `detail.parent_tool_use_id = root_action_id`.

**Step 4: Re-run router tests**

Expected: PASS

**Step 5: Commit**

```bash
git add apps/lemon_router/lib/lemon_router/run_process/output_tracker.ex apps/lemon_router/lib/lemon_router/tool_status_coalescer.ex apps/lemon_router/test/lemon_router/tool_status_coalescer_test.exs
 git commit -m "feat: route live async child actions into task surfaces"
```

---

### Task 5: Make Telegram rendering prove the nested child actions stay attached

**Objective:** Add end-to-end regression coverage for the exact bug reported from Lemonade Stand.

**Files:**
- Modify: `apps/lemon_router/test/lemon_router/run_process_test.exs`
- Modify: `apps/lemon_router/test/lemon_router/tool_status_coalescer_test.exs`
- Possibly add: `apps/lemon_channels/test/lemon_channels/adapters/telegram/renderer_test.exs`

**Step 1: Add a run-process test for async task root + child progress**

Scenario:
- parent run emits `task(codex)` top-level action on Telegram group/thread session
- live bridge subscribes to child run topic
- async child run emits multiple `:engine_action` events (`read`, `bash`, `grep`)
- parent task surface keeps editing with child nested lines
- final answer stays separate

**Step 2: Assert message shape semantically**

Do not overfit exact markdown; assert that the surface includes something like:

```text
✓ task(codex): Assess March Madness EVM project
  ✓ Read: implementation-plan.md
  ✓ /usr/bin/zsh -c 'nl -ba src/LiquidityManager.sol'
```

**Step 3: Assert no detached generic status-only task messages appear**

**Step 4: Re-run focused tests**

```bash
mix test apps/lemon_router/test/lemon_router/run_process_test.exs apps/lemon_router/test/lemon_router/tool_status_coalescer_test.exs
```

Expected: PASS

**Step 5: Commit**

```bash
git add apps/lemon_router/test/lemon_router/run_process_test.exs apps/lemon_router/test/lemon_router/tool_status_coalescer_test.exs
 git commit -m "test: cover live nested async task tool status"
```

---

### Task 6: Preserve existing poll/join semantics without duplicate children

**Objective:** Ensure later `task action=poll` / `join` still work and do not duplicate already-streamed child lines.

**Files:**
- Modify: `apps/coding_agent/lib/coding_agent/tools/task/result.ex`
- Modify: `apps/lemon_router/lib/lemon_router/tool_status_coalescer.ex`
- Test: add poll/join dedupe tests

**Step 1: Write failing dedupe test**

Scenario:
- child action streamed live already
- user polls task afterward
- poll should not duplicate same child line in task surface
- same child action id observed as started → updated → completed should still render as one nested line

**Step 2: Implement dedupe key**

Preferred dedupe key:
- stable `projected_id`

Fallback only if projected id is unavailable:
- `child_run_id`
- normalized child `kind`
- normalized child `title`

**Step 3: Re-run focused tests**

Expected: PASS

**Step 4: Commit**

```bash
git add apps/coding_agent/lib/coding_agent/tools/task/result.ex apps/lemon_router/lib/lemon_router/tool_status_coalescer.ex
 git commit -m "fix: dedupe poll updates against live async child actions"
```

---

### Task 7: Real Telegram canary in Lemonade Stand

**Objective:** Verify the exact March Madness-thread UX with real async Codex/Claude tasks.

**Files:**
- No code required initially
- Use Telethon script(s) under `/tmp` or workspace `scripts/`

**Step 1: Hot-reload updated modules on live node**

Run via rpc-eval:

```bash
HOST=$(hostname -s)
elixir --sname lemon_reload --cookie lemon_gateway_dev_cookie \
  --rpc-eval "lemon@$HOST" \
  'Code.compile_file("/home/z80/dev/lemon/apps/coding_agent/lib/coding_agent/tools/task/async.ex");
   Code.compile_file("/home/z80/dev/lemon/apps/coding_agent/lib/coding_agent/tools/task/live_bridge.ex");
   Code.compile_file("/home/z80/dev/lemon/apps/lemon_router/lib/lemon_router/tool_status_coalescer.ex")'
```

**Step 2: Run a real Telegram canary in Lemonade Stand**

Prompt should trigger two async tasks (`codex`, `claude`) with enough inner actions to observe nesting.

**Step 3: Inspect with Telethon from the user side**

Confirm the actual Telegram messages show:
- top-level task line
- nested child actions continuously appended under it
- no detached generic status-only child stream elsewhere

**Step 4: Save findings to memory**

Update `memory/2026-03-19.md` or today’s daily note with exact Telegram message ids and observed behavior.

---

## Verification checklist

Before calling this done:
- [ ] async `task(codex)` keeps editing the original task message with child inner actions
- [ ] async `task(claude)` does the same
- [ ] child actions preserve order
- [ ] completion summary still lands correctly
- [ ] poll/join do not duplicate prior child lines
- [ ] no orphan subscriptions / stale bindings remain after completion
- [ ] Telethon confirms the real Telegram rendering in Lemonade Stand

---

## Final validation commands

```bash
mix test apps/coding_agent/test/coding_agent/task_progress_binding_store_test.exs
mix test apps/coding_agent/test/coding_agent/tools/task/live_bridge_test.exs
mix test apps/lemon_router/test/lemon_router/tool_status_coalescer_test.exs
mix test apps/lemon_router/test/lemon_router/run_process_test.exs
mix test apps/coding_agent/test/coding_agent/cli_runners/lemon_runner_test.exs
```

Recommended combined run after implementation:

```bash
mix test apps/coding_agent/test/coding_agent/tools/task/ \
         apps/lemon_router/test/lemon_router/tool_status_coalescer_test.exs \
         apps/lemon_router/test/lemon_router/run_process_test.exs
```

---

## Notes for implementer

- Do not try to solve this by polling `TaskStore` every N ms.
- Do not change the user-visible policy that child task progress belongs under the original `task(...)` line.
- Reuse existing `parent_tool_use_id`-based hierarchy wherever possible.
- Prefer a small explicit coalescer ingress API over pretending child events are parent tool events if that reduces ambiguity.
- Keep the change scoped to async task live progress projection; don’t redesign Telegram renderer or PresentationState unless the tests force it.
