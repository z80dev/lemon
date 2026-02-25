# PLN-20260223 Instance Monitoring Frontend

## Summary

Build an instance-wide monitoring console for Lemon that shows:

- All user-facing chats/sessions (active and historical)
- All active runs and run lifecycle state
- All agent activity (main runs + subagent/task-related activity)
- A live event feed for operational debugging

This plan targets a **read-first observability experience** with optional operator actions (abort, open session, filter), using existing control-plane APIs/events where possible and adding minimal backend APIs/events for missing visibility.

---

## Goals

1. Provide a single UI where operators can observe all activity in one Lemon instance.
2. Support both snapshot and streaming views:
- Snapshot for current state and historical context
- Streaming for near-real-time updates
3. Keep the first release low risk by reusing existing control-plane methods.
4. Add explicit backend support for subagent/task/run-graph visibility gaps.

## Non-Goals (V1)

1. Full distributed multi-instance aggregation.
2. Advanced analytics/BI dashboards.
3. Persistent custom alerting/notification rules.
4. Replacing existing session chat UIs.

---

## Existing Foundation (Already in Repo)

### Control-plane methods

- `introspection.snapshot`
- `agent.directory.list`
- `sessions.list`
- `sessions.active.list`
- `chat.history`
- `status`
- `logs.tail`

### Control-plane event stream

- `agent` (started/completed/tool_use)
- `chat` (delta)
- `presence`
- `health`, `heartbeat`, `talk.mode`
- `cron`, node/device pairing, approval events

### Frontend candidates

- `apps/lemon_web` (Phoenix LiveView): currently single-session focused.
- `clients/lemon-web` (React): richer client architecture and state handling, currently wired to debug RPC bridge.

---

## Recommended Implementation Strategy

Use **`clients/lemon-web`** as the base and add a **control-plane transport mode**.

Rationale:

1. Already has robust client store/reducer/component structure and testing harness.
2. Avoids major Phoenix LiveView redesign for a global, multi-pane observability UI.
3. Lets us iterate on UI/UX quickly while reusing existing backend methods/events.

Keep `apps/lemon_web` for lightweight chat workflows; use `clients/lemon-web` for operator monitoring.

---

## Data Model (UI View-Model)

Introduce a dedicated monitoring domain state in the React store:

1. `instance`
- health, uptime, memory, connection counts, run counters

2. `agents`
- agent directory, status, active session count, latest activity

3. `sessions`
- active sessions (live)
- historical sessions (paginated)
- selected session details + recent chat history

4. `runs`
- active runs indexed by `runId`
- recent completed runs with status/duration/answer summary

5. `tasks` (new backend support required)
- subagent/task records, lifecycle state, parent-child relations

6. `eventFeed`
- normalized event log with filtering and time windowing

7. `ui`
- filters: agent/channel/session/run/status/time range
- selected entities: session, run, task

---

## Backend Gaps and Required Additions

Current APIs cover most session/run basics but do not fully expose all task/subagent execution internals for a true "everything happening" console.

### Add new control-plane methods

1. `runs.active.list`
- Return active runs with sessionKey, agentId, startedAt, engine, route metadata.

2. `runs.recent.list`
- Return recent completed/error runs with duration/outcome summary.

3. `tasks.active.list`
- Surface active subagent/task records from task store/coordinator context.

4. `tasks.recent.list`
- Return recent completed/error/lost tasks.

5. `run.graph.get`
- Return parent/child structure and statuses for a run tree.

### Add/extend event mapping

Map run-graph and task-store lifecycle events into websocket events:

- `run.graph.changed`
- `task.started`
- `task.completed`
- `task.error`
- `task.timeout`
- `task.aborted`

### Preserve compatibility

- Keep existing event names unchanged.
- Add new events as additive fields/endpoints.

---

## UI/UX Plan

### Layout

1. Top: instance health/status strip (uptime, connections, active runs, heartbeat).
2. Left column: agents + active sessions list.
3. Center: selected session/run detail (chat history + run timeline).
4. Right column: live global event feed with filters.
5. Bottom dock/panel: task/subagent tree for selected run/session.

### Core screens

1. **Overview**
- system health, active counts, recent failures, quick drill-down.

2. **Sessions Explorer**
- searchable table/list for all sessions, active badge, route metadata.

3. **Run Inspector**
- run lifecycle events, tool-use sequence, final outcome.

4. **Task/Subagent Inspector**
- parent/child graph and statuses for spawned work.

5. **Live Event Stream**
- global stream, pause/resume, level/type filters, JSON payload view.

### Operator actions (V1 minimal)

- Open session details
- Copy IDs/keys
- Abort active run
- Filter and bookmark filter presets (client-side only)

---

## Phased Delivery Plan

## Phase 0: Alignment + contract design

1. Define canonical payload schemas for new methods/events.
2. Add protocol docs in control-plane and client shared contract.
3. Confirm auth scopes for operator read vs write actions.

**Exit criteria:** approved payload contract and method/event names.

## Phase 1: Client control-plane transport foundation

1. Add control-plane websocket client mode in `clients/lemon-web`.
2. Implement connect handshake and request/response framing.
3. Support `hello-ok`, event routing, reconnect, backoff, auth token handling.

**Exit criteria:** client can connect to `/ws`, call existing methods, and receive events.

## Phase 2: Snapshot + live monitoring MVP

1. Implement initial fetch sequence:
- `status`
- `introspection.snapshot`
- `sessions.list`
- `sessions.active.list`
2. Build Overview + Sessions Explorer + Live Event Stream screens.
3. Add chat history drill-down via `chat.history`.

**Exit criteria:** operator can monitor system/sessions in real time without new backend methods.

## Phase 3: Run/task deep visibility

1. Implement backend `runs.*` and `tasks.*` methods.
2. Extend EventBridge mappings for task/run-graph events.
3. Build Run Inspector + Task/Subagent Inspector views.

**Exit criteria:** operator can trace main runs and spawned tasks end-to-end.

## Phase 4: Hardening and operations

1. Add large-volume event feed safeguards (windowing/capping).
2. Add API pagination/cursor patterns for historical lists.
3. Add UX polish: empty/error/loading states, keyboard navigation, resilient reconnection UX.

**Exit criteria:** stable under sustained activity and long-running operator sessions.

---

## Testing Plan

### Backend tests

1. Method tests for new `runs.*`, `tasks.*`, `run.graph.get`.
2. EventBridge mapping tests for new event types.
3. Authorization scope tests for each method.

### Frontend tests

1. Transport tests:
- handshake
- reconnect
- event ordering
- dropped connection recovery
2. Store reducer tests for snapshot merge + incremental event updates.
3. Component tests for overview, tables, event feed filters, detail panels.

### End-to-end checks

1. Start instance and synthetic workload.
2. Verify active sessions/runs appear within expected latency.
3. Verify task/subagent tree matches backend run graph.
4. Verify abort action propagates and UI state converges.

---

## Performance and Reliability Considerations

1. Event buffering
- Cap in-memory event feed window (e.g., 2k-10k events) with pruning.

2. Backpressure
- Batch UI updates on bursty streams (animation-frame or short debounce).

3. Ordering
- Use event sequence metadata where available; fallback to timestamp + insertion order.

4. Pagination
- Never fetch full session/run/task history unbounded.

5. Failure modes
- Separate transport status from data status; stale data banner when disconnected.

---

## Security and Access

1. Reuse control-plane auth and scoped permissions.
2. Monitoring UI should default to read-only operations.
3. Gate write actions (abort/reset) by scope checks.
4. Avoid exposing sensitive payload fields by default in compact list views.

---

## Documentation Updates Required During Implementation

1. Update `apps/lemon_control_plane/AGENTS.md` with new methods/events and payload examples.
2. Add/extend docs under `docs/` for monitoring architecture and operator workflow.
3. Update `clients/lemon-web` docs (README + protocol contract docs).
4. Keep shared protocol contract (`clients/lemon-web/shared`) in sync with wire changes.

---

## Risks and Mitigations

1. **Risk:** High event volume causes UI lag.
- **Mitigation:** bounded event windows, incremental rendering, list virtualization.

2. **Risk:** Incomplete subagent/task visibility from backend internals.
- **Mitigation:** explicit `tasks.*` methods and run-graph integration.

3. **Risk:** Drift between backend payloads and frontend assumptions.
- **Mitigation:** shared protocol contract + schema validation tests.

4. **Risk:** Operator confusion due to dense data.
- **Mitigation:** opinionated defaults, filter presets, clear entity hierarchy.

---

## Rough Work Breakdown (Engineering)

1. Transport + protocol adaptation: 2-3 days
2. MVP monitoring UI with existing methods/events: 3-5 days
3. Backend run/task API + events: 3-5 days
4. Inspector UI for run/task graph: 2-4 days
5. Hardening/tests/docs: 2-4 days

Total: ~12-21 engineering days depending on desired depth and polish.

---

## Definition of Done

1. Operator can see all active sessions and active runs instance-wide.
2. Operator can inspect recent history for sessions/runs without CLI access.
3. Operator can observe tool/run lifecycle events in near real time.
4. Operator can inspect spawned task/subagent chains for selected runs.
5. End-to-end tests cover snapshot + streaming state convergence.
6. AGENTS/README/docs are updated to reflect new monitoring surfaces.
