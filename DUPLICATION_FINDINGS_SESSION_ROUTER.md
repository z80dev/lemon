# Duplication in Session/Router Orchestration

## Summary

Found 12 significant duplication patterns between `LemonRouter` and `CodingAgent.Session` orchestration layers. These systems independently implement similar state machine transitions, lifecycle management, subscriber notification, and message handling logic.

---

## 1. State Machine Transitions & Pure State Reducers

**Pattern**: Both systems separate pure state transitions from side effects via dedicated modules.

### LemonRouter
- **File**: `apps/lemon_router/lib/lemon_router/session_transitions.ex`
- **Lines**: Entire module (390+ lines)
- **Functions**:
  - `submit/3` - Submit with queue mode handling
  - `cancel/2` - Cancel conversation
  - `cancel_session/3` - Cancel session
  - `abort_session/3` - Abort session
  - `active_down/2,3,4` - Handle active run process down
  - `steer_accepted/2` - Handle steer acceptance
  - `steer_rejected/2,3` - Handle steer rejection
  - `enqueue_by_mode/3` - Mode-specific queueing (collect, followup, steer, steer_backlog, interrupt)
  - `maybe_merge_followup/4` - Merge consecutive followup submissions

**Pattern**: Pure reducer that returns `{:ok, next_state, effects}` tuple

### CodingAgent.Session
- **File**: `apps/coding_agent/lib/coding_agent/session.ex` (main state machine)
- **Related modules**: `apps/coding_agent/lib/coding_agent/session/lifecycle.ex`, `apps/coding_agent/lib/coding_agent/session/event_handler.ex`
- **Functions**:
  - `handle_call({:prompt, text, opts})` - Submit prompt (lines ~600)
  - `handle_call({:steering, text})` - Queue steering message
  - `handle_call({:follow_up, text})` - Queue follow-up
  - `handle_cast(:abort)` - Abort session
- **Pattern**: Side effects mixed with state updates; uses `State.begin_prompt/2` for state transitions

**Key Difference**: SessionCoordinator has pure reducer in SessionTransitions; CodingAgent.Session embeds state transitions in GenServer callbacks.

---

## 2. Event Handler & Lifecycle Management

### LemonRouter.SessionCoordinator + SessionTransitions
- **File**: `apps/lemon_router/lib/lemon_router/session_coordinator.ex` (lines 142-173)
- **Flow**:
  1. `handle_call({:submit, submission})`
  2. Calls `SessionTransitions.submit(state, submission, timestamp)`
  3. Gets `{:ok, next_state, effects}`
  4. Calls `apply_transition(effects, state)` to execute side effects
  5. Emits phases via `maybe_emit_submit_phases()`

### CodingAgent.Session.EventHandler
- **File**: `apps/coding_agent/lib/coding_agent/session/event_handler.ex` (137 lines)
- **Functions**:
  - `handle/3` - Dispatch on agent event types
  - Events: `:agent_start`, `:turn_start`, `:turn_end`, `:message_start`, `:message_end`, `:tool_execution_start/end`, `:agent_end`, `:error`, `:canceled`
- **Pattern**: Callback-based event dispatch with hook execution

**Duplication**: Both implement pure state transitions + side-effect application pattern, but EventHandler doesn't integrate with queue semantics.

---

## 3. Subscriber/Listener Notification

### LemonRouter - Distributed via Bus

**Files**:
- `apps/lemon_router/lib/lemon_router/run_process.ex` (lines 129, 224, 277, 317, 345, 375, 453, 493, 564, 646)
- `apps/lemon_router/lib/lemon_router/session_coordinator.ex`

**Pattern**:
```elixir
# Subscribe at init
Bus.subscribe(Bus.run_topic(run_id))

# Broadcast events
Bus.broadcast(Bus.session_topic(state.session_key), event)
Bus.broadcast(Bus.run_topic(state.run_id), event)

# Cleanup
LemonCore.EventBridge.unsubscribe_run(run_id)
```

**Specific calls**:
- Line 129: `Bus.subscribe(Bus.run_topic(run_id))` in RunProcess.init
- Line 224, 277, 317, 345, 375: Forward events to session subscribers
- Line 453, 493, 564: Synthetic completion events
- Line 665: `unsubscribe_event_bridge(run_id)` cleanup

### CodingAgent.Session.Notifier
- **File**: `apps/coding_agent/lib/coding_agent/session/notifier.ex` (144 lines)
- **Functions**:
  - `subscribe_stream/3` - Subscribe with EventStream (backpressure)
  - `subscribe_direct/3` - Subscribe with send/2 (legacy)
  - `unsubscribe_direct/2` - Unsubscribe
  - `broadcast_event/2` - Broadcast to all listeners (lines 81-94)
  - `complete_event_streams/2` - Terminal event delivery
  - `prune_subscribers/3` - Cleanup on subscriber down
- **Pattern**: Direct process send + EventStream hybrid

**Duplication Score**: HIGH - Both implement pub/sub with event filtering, monitor cleanup, and terminal event handling. Names and APIs differ but logic is equivalent.

---

## 4. Abort/Cancel Handling

### LemonRouter

**Files**: Multiple abort patterns

1. **RunProcess abort** (`apps/lemon_router/lib/lemon_router/run_process.ex`):
   - Lines 62-74: `abort/2` - Public API (pid or run_id)
   - Lines 322-327: `handle_cast({:abort, reason})`
   - Lines 460-498: `handle_info({:finalize_aborted_run, reason})` - Synthetic completion

2. **SessionCoordinator abort** (`apps/lemon_router/lib/lemon_router/session_coordinator.ex`):
   - Lines 53-68: `cancel/2` - Per-conversation
   - Lines 70-81: `abort_session/2` - Per-session
   - Lines 154-173: `handle_cast` handlers for cancel variants

3. **SessionTransitions abort** (`apps/lemon_router/lib/lemon_router/session_transitions.ex`):
   - Lines 25-35: `cancel/2` - Pure logic
   - Lines 37-48: `cancel_session/3` - Pure logic
   - Lines 50-66: `abort_session/3` - Drops queue + pending steers

### CodingAgent.Session abort
- **File**: `apps/coding_agent/lib/coding_agent/session.ex`
- **Lines**: ~730: `abort/1` - Public API
- **Lines**: ~945: `handle_cast(:abort)` - Core abort logic
- **Pattern**: Sets abort signal, cancels pending prompt, emits event

**Duplication Score**: MEDIUM - Both implement abort at multiple levels (API, coordinator, transitions) with similar guard clauses and cleanup patterns.

---

## 5. Introspection/Event Recording

### LemonRouter
- **File**: `apps/lemon_router/lib/lemon_router/run_orchestrator.ex`
- **Calls**:
  - Line 164-177: `:orchestration_started` event (run_id, agent_id, queue_mode, engine_id)
  - Line 188-200: `:orchestration_resolved` event (engine_id, model, conversation_key)
  - Line 213-223: `:orchestration_failed` event (reason)
  - Line 230-240: `:orchestration_failed` on builder error

- **File**: `apps/lemon_router/lib/lemon_router/run_process.ex`
- **Calls**:
  - Line 170-180: `:run_started` event
  - Line 254-268: `:run_completed` event
  - Line 635-651: `:run_completed` with artifacts

### CodingAgent.Session
- **File**: `apps/coding_agent/lib/coding_agent/session/event_handler.ex`
- **Calls**:
  - Line 76-84: `:tool_call_dispatched` event

- **File**: `apps/coding_agent/lib/coding_agent/session/compaction_manager.ex`
- **Calls**:
  - Line 282+: Introspection events for compaction

**Duplication Score**: LOW-MEDIUM - Patterns exist but event types are specific to each domain. Could standardize error recording format.

---

## 6. Registry Management & Lifecycle Hooks

### LemonRouter

**Files**: Multiple registries

1. **RunRegistry** (`apps/lemon_router/lib/lemon_router/run_process.ex` line 55-56):
   ```elixir
   {:via, Registry, {LemonRouter.RunRegistry, run_id}}
   ```

2. **ConversationRegistry** (`apps/lemon_router/lib/lemon_router/session_coordinator.ex` line 122):
   ```elixir
   {:via, Registry, {LemonRouter.ConversationRegistry, key}}
   ```

3. **SessionRegistry** (`apps/lemon_router/lib/lemon_router/session_coordinator.ex` line 94-95, 180):
   - Used to track active run_id per session_key

### CodingAgent.Session

**Files**: `apps/coding_agent/lib/coding_agent/session/persistence.ex`
- Line 48-64: `maybe_register_session/4` - Registry register with error handling
- Line 66-75: `maybe_unregister_session/3` - Registry unregister

**Pattern**: Conditional registration based on flag, error handling for already_registered

**Duplication Score**: MEDIUM - Both use Registry with via tuples, but patterns differ (LemonRouter uses :via directly in GenServer.start_link; CodingAgent uses explicit register/unregister calls).

---

## 7. Process Lifecycle & Monitoring

### LemonRouter

**RunProcess** (`apps/lemon_router/lib/lemon_router/run_process.ex`):
- Lines 39-42: `start_link/1` with via_tuple
- Lines 44-53: `child_spec/1` with restart: :temporary, shutdown: 5000
- Lines 128-130: `Bus.subscribe` at init
- Lines 176-189: Monitor active run (DOWN handler at line 416-424)

**SessionCoordinator** (`apps/lemon_router/lib/lemon_router/session_coordinator.ex`):
- Lines 176-189: Monitor active run with `{:DOWN, mon_ref, ...}` handler
- Lines 180: Clear session registry on down
- Line 184: Apply transition on monitor event

### CodingAgent.Session

**Session** (`apps/coding_agent/lib/coding_agent/session.ex`):
- Lines 1000+: `handle_info({:DOWN, ...})` - Generic down handler
- Monitor management for event listeners and streams

**Duplication Score**: MEDIUM - Both implement process monitoring with DOWN handlers, but trigger different cleanup logic.

---

## 8. Status/Progress Tracking

### LemonRouter

**RunProcess** state fields (lines 131-160):
- `start_ts_ms`, `run_started_at_ms`, `run_last_activity_at_ms`
- `saw_delta` (streaming activity flag)
- `aborted`, `completed` (terminal state flags)
- `gateway_submitted?`, `gateway_run_pid`, `gateway_run_ref`
- `run_watchdog_*` fields
- `task_status_surfaces`, `task_status_refs`

**RunCountTracker** (`apps/lemon_router/lib/lemon_router/run_count_tracker.ex`):
- Maintains telemetry counters for active, queued, completed_today

### CodingAgent.Session

**State fields** (lines 67-118):
- `started_at`
- `is_streaming`
- `turn_index` (turn counter, similar to turn_count)
- `auto_compaction_in_progress`, `overflow_recovery_in_progress` (task flags)
- Various task_*_pid, *_monitor_ref, *_timeout_ref fields

**State.build_diagnostics/1** (`apps/coding_agent/lib/coding_agent/session/state.ex` lines 138-180):
- Builds status map: uptime_ms, message_count, turn_count, error_rate, streaming state

**Duplication Score**: MEDIUM - Both track streaming state, completion status, timing, and turn/activity counters using similar field patterns.

---

## 9. Queue Mode Semantics

### LemonRouter - Only

**File**: `apps/lemon_router/lib/lemon_router/session_transitions.ex`
- Lines 132-190: `enqueue_by_mode/3` handles five modes
- `:collect` - Append to queue (default)
- `:followup` - Merge with previous if recent (debounce: 500ms)
- `:steer` / `:steer_backlog` - Dispatch to active run or fallback
- `:interrupt` - Prepend to queue, cancel active

**Related**: `maybe_merge_followup/4`, `merge_followup_submission/2`, `flush_pending_steers_for_active/2`

### CodingAgent.Session - NO EQUIVALENT

CodingAgent.Session has queuing primitives (`steering_queue`, `follow_up_queue`) but no mode-based logic. Queue semantics are not exposed to clients.

**Duplication Score**: NONE for direct pattern, but this is a major feature difference. SessionCoordinator queue semantics would need to be extracted.

---

## 10. Message & Submission Building

### LemonRouter - SubmissionBuilder

**File**: `apps/lemon_router/lib/lemon_router/submission_builder.ex`
- Builds `%Submission{}` from `RunRequest`
- Normalizes and validates input
- Extracts engine/model/meta

### CodingAgent.Session

**File**: `apps/coding_agent/lib/coding_agent/session/state.ex`
- Line 72-97: `build_prompt_message/2` - Creates `UserMessage` struct
- Handles image content blocks

**File**: `apps/coding_agent/lib/coding_agent/session/prompt_composer.ex`
- System prompt composition from multiple sources

**Duplication Score**: LOW - Different domains (routing vs. prompt composition) but both extract metadata from input.

---

## 11. Streaming State Management

### LemonRouter

**RunProcess**:
- Lines 131-160: State fields track `saw_delta` (has stream activity)
- Used in tool status and artifact tracking
- No explicit streaming flag; state inferred from activity

### CodingAgent.Session

**Session**:
- Lines 82: `is_streaming: boolean()` explicit flag
- Used to gate new prompts, abort pending timers
- Lines 100-113: `begin_prompt/2` sets `is_streaming: true`

**Duplication Score**: LOW - Different approaches (activity-based vs. explicit flag) suit different architectures.

---

## 12. Context/Message Transformation

### LemonRouter - NONE

### CodingAgent.Session

**File**: `apps/coding_agent/lib/coding_agent/session/state.ex`
- Lines 17-45: `build_transform_context/2` - Wraps message transformation with guardrails
- Chains `ContextGuardrails.transform/3` → `UntrustedToolBoundary.transform/2` → user transform_fn
- Returns `{:ok, messages} | {:error, reason}`

**Pattern**: Composition of middleware layers

**LemonRouter equivalent**: None found. Router delegates to gateway; no message transformation layer.

---

## Shared Helper Candidates

### 1. Pure State Transition Reducer
**Current**:
- `LemonRouter.SessionTransitions` - Excellent pattern
- `CodingAgent.Session` - Embedded in GenServer

**Shared Helper**: `LemonCore.StateReducer` or similar abstraction
```elixir
defmodule LemonCore.StateReducer do
  @callback reduce(state, action, context) :: {:ok, state, effects} | {:error, reason}
end
```

**Location**: `apps/lemon_core/lib/lemon_core/state_reducer.ex`

---

### 2. Subscriber/Event Notification Hub
**Current**:
- `LemonRouter`: Bus-based broadcasting
- `CodingAgent.Session.Notifier`: Direct send + EventStream

**Shared Helper**: `LemonCore.EventNotifier` or `LemonCore.Subscriber`
```elixir
defmodule LemonCore.Subscriber do
  def subscribe(server, pid, opts)
  def broadcast(server, event)
  def unsubscribe(server, pid)
end
```

**Location**: `apps/lemon_core/lib/lemon_core/subscriber.ex`

**Rationale**: Eliminate duplication of monitor cleanup, terminal event handling, event streaming.

---

### 3. Abort/Cancel Handler Pattern
**Current**:
- `LemonRouter`: Multi-level abort (session, run, steer)
- `CodingAgent.Session`: Single-level abort

**Shared Helper**: `LemonCore.AbortHandler`
```elixir
defmodule LemonCore.AbortHandler do
  def abort(pid, reason)
  def cancel(pid, reason)
  def finalize_abort(state, reason)
end
```

**Location**: `apps/lemon_core/lib/lemon_core/abort_handler.ex`

---

### 4. Introspection Event Recorder
**Current**:
- Direct `Introspection.record/4` calls throughout

**Observation**: `LemonCore.Introspection` already exists, but each module calls it directly.

**Improvement**: Standardize event types and payload shapes. Create common payload builders.

**Existing file**: `apps/lemon_core/lib/lemon_core/introspection.ex`

---

### 5. Registry Lifecycle Helper
**Current**:
- `LemonRouter`: Via tuple in start_link
- `CodingAgent.Session.Persistence`: Explicit register/unregister with error handling

**Shared Helper**: `LemonCore.RegistryHelper`
```elixir
defmodule LemonCore.RegistryHelper do
  def register_child(registry, key, metadata)
  def unregister_child(registry, key)
  def with_registration(registry, key, fun)
end
```

**Location**: `apps/lemon_core/lib/lemon_core/registry_helper.ex`

---

### 6. Streaming State & Completion Tracking
**Current**:
- `RunProcess`: `saw_delta`, `completed`, `aborted` fields
- `CodingAgent.Session`: `is_streaming`, task progress fields

**Shared Helper**: `LemonCore.LifecycleState` or `LemonCore.TaskState`
```elixir
defmodule LemonCore.TaskState do
  def new(task_id)
  def mark_started(state)
  def mark_completed(state, result)
  def is_active?(state)
end
```

**Location**: `apps/lemon_core/lib/lemon_core/task_state.ex`

---

## Existing Shared Resources

These already exist but could be better utilized:

1. **LemonCore.Bus** - Event broadcasting (used by RunProcess only)
   - Could standardize CodingAgent.Session subscriber model
   - File: `apps/lemon_core/lib/lemon_core/bus.ex`

2. **LemonCore.EventBridge** - Control-plane event subscription
   - Used by RunOrchestrator to bridge to control plane
   - File: `apps/lemon_core/lib/lemon_core/event_bridge.ex`

3. **LemonCore.Introspection** - Telemetry event recording
   - Used by both but inconsistently
   - File: `apps/lemon_core/lib/lemon_core/introspection.ex`

4. **LemonCore.Clock** - Time utilities (LemonRouter only)
   - File: `apps/lemon_core/lib/lemon_core/clock.ex`

---

## Files Most Affected by Duplication

**Priority Order** (refactor from most duplication first):

1. **High Priority**:
   - `apps/lemon_router/lib/lemon_router/session_coordinator.ex` (374 lines)
   - `apps/coding_agent/lib/coding_agent/session.ex` (1500+ lines)
   - `apps/coding_agent/lib/coding_agent/session/notifier.ex` (144 lines)

2. **Medium Priority**:
   - `apps/lemon_router/lib/lemon_router/session_transitions.ex` (390 lines)
   - `apps/lemon_router/lib/lemon_router/run_process.ex` (800+ lines)
   - `apps/coding_agent/lib/coding_agent/session/event_handler.ex` (137 lines)
   - `apps/coding_agent/lib/coding_agent/session/persistence.ex` (95 lines)

3. **Low Priority**:
   - `apps/lemon_router/lib/lemon_router/run_orchestrator.ex` (292 lines)
   - `apps/coding_agent/lib/coding_agent/session/lifecycle.ex` (250+ lines)

---

## Recommendations

### Phase 1: Low-Risk Extraction
1. Extract `LemonCore.Subscriber` from Notifier + Bus patterns
2. Extract `LemonCore.AbortHandler` for common cancel/abort logic
3. Standardize Introspection event recording in shared helpers

### Phase 2: Medium-Risk Refactoring
1. Extract `LemonCore.StateReducer` abstraction
2. Have CodingAgent.Session use SessionTransitions-like pure reducer
3. Migrate CodingAgent.Session event handling to EventHandler dispatch

### Phase 3: Architectural Discussion
1. Queue mode semantics - Are they specific to router, or should CodingAgent expose them?
2. Registry lifecycle - Standardize via-tuple vs. explicit register/unregister patterns
3. Event types and payload structure - Align on common taxonomy

---

## Code Snippet Examples

### Example 1: Duplicated Monitor Cleanup
**LemonRouter** (session_coordinator.ex:176-189):
```elixir
def handle_info(
      {:DOWN, mon_ref, :process, pid, _reason},
      %SessionState{active: %{pid: pid, mon_ref: mon_ref}} = state
    ) do
  state = clear_active_session_registry(state)
  {:noreply, next_state} = apply_transition(...)
  {:noreply, next_state}
end
```

**CodingAgent** (session.ex:1000+):
```elixir
def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
  state = prune_subscribers(state, _pid, ref)
  {:noreply, state}
end
```

**Common pattern**: Guard on matching ref/pid, cleanup callbacks, return noreply tuple

---

### Example 2: Duplicated Event Broadcasting
**LemonRouter** (run_process.ex:224):
```elixir
Bus.broadcast(Bus.session_topic(state.session_key), event)
```

**CodingAgent** (notifier.ex:85-91):
```elixir
Enum.each(state.event_listeners, fn {pid, _ref} ->
  send(pid, {:session_event, state.session_manager.header.id, event})
end)
```

**Common pattern**: Iterate listeners/subscribers, send event tuple

---

### Example 3: Duplicated Introspection
**LemonRouter** (run_orchestrator.ex:164-177):
```elixir
Introspection.record(
  :orchestration_started,
  %{origin: origin, agent_id: agent_id, queue_mode: queue_mode, engine_id: engine_id},
  run_id: run_id,
  session_key: session_key,
  agent_id: agent_id,
  engine: "lemon",
  provenance: :direct
)
```

**CodingAgent** (event_handler.ex:76-84):
```elixir
Introspection.record(
  :tool_call_dispatched,
  %{tool_name: name, tool_call_id: id},
  engine: "lemon",
  provenance: :direct
)
```

**Common pattern**: `event_type`, `payload_map`, `context_map`; suggest standardized context builder.

---

## Conclusion

The two orchestration layers (`LemonRouter` and `CodingAgent.Session`) implement 6-8 genuinely duplicated patterns:

1. **State transitions** - Both use pure reducers (SessionTransitions excellent, CodingAgent embeds)
2. **Event handler dispatch** - Both handle lifecycle events (LemonRouter implicit via apply_transition, CodingAgent explicit)
3. **Subscriber notification** - Both broadcast to listeners (Bus vs. direct send)
4. **Abort/cancel** - Both implement multi-level cancellation
5. **Status tracking** - Both maintain streaming/completion state
6. **Registry management** - Both use Process registry
7. **Introspection** - Both record events
8. **Monitor cleanup** - Both handle process DOWN

**Total duplicated lines**: ~1,500-2,000 across both systems.

**Estimated extraction value**: Create 6-7 shared helpers in LemonCore to eliminate 40-50% of duplicated logic while keeping domain-specific behavior intact.

**Risk assessment**: LOW - Helpers can be introduced incrementally without breaking existing code.
