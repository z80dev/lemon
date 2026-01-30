# Lemon TUI RPC Parallel Sessions Implementation Plan

This document is the **meticulous, step-by-step plan** for implementing the multi-session RPC protocol in the Lemon TUI client. It is intended to be executed after `RPC_PARALLEL_SESSIONS_PLAN.md` (server + wire contract) and includes TypeScript API surface changes, internal state routing, UI integration hooks, and tests.

---

## Objectives

1. **Session-aware protocol**: Add `session_id` to all session-scoped client commands and server responses.
2. **Multi-session lifecycle**: Support creating, switching, listing, and closing running sessions.
3. **Event routing**: Dispatch incoming `event` messages to the correct session view/model based on `session_id`.
4. **Backward compatibility**: Existing workflows should still work with the primary/active session when no `session_id` is sent.

---

## A. Protocol Type Updates (TypeScript)

### A1. Update `clients/lemon-tui/src/types.ts`

#### A1.1 Add `session_id` to server messages
- **ReadyMessage**: add `primary_session_id: string`, `active_session_id: string`.
- **EventMessage**: add `session_id: string`.
- **StatsMessage**: add `session_id: string`.
- **ErrorMessage**: add `session_id?: string` (optional, only when session-scoped).
- **SaveResultMessage**: add `session_id?: string` for symmetry (optional).
- **SessionsListMessage**: unchanged (persisted sessions on disk, not running sessions).

#### A1.2 Define new server message shapes
- **RunningSessionsMessage**
  ```ts
  interface RunningSessionsMessage {
    type: 'running_sessions';
    sessions: { session_id: string; cwd: string; is_streaming: boolean }[];
    error?: string | null;
  }
  ```
- **SessionStartedMessage**
  ```ts
  interface SessionStartedMessage {
    type: 'session_started';
    session_id: string;
    cwd: string;
    model: { provider: string; id: string };
  }
  ```
- **SessionClosedMessage**
  ```ts
  interface SessionClosedMessage {
    type: 'session_closed';
    session_id: string;
    reason: 'normal' | 'not_found' | 'error';
  }
  ```
- **ActiveSessionMessage**
  ```ts
  interface ActiveSessionMessage {
    type: 'active_session';
    session_id: string;
  }
  ```

Add these to `ServerMessage` union.

#### A1.3 Add `session_id?: string` to client commands
Apply to:
- PromptCommand
- StatsCommand
- AbortCommand
- ResetCommand
- SaveCommand

#### A1.4 Add new client commands
- **StartSessionCommand**
  ```ts
  interface StartSessionCommand {
    type: 'start_session';
    cwd?: string;
    model?: string;
    system_prompt?: string;
    session_file?: string;
    parent_session?: string;
  }
  ```
- **CloseSessionCommand**
  ```ts
  interface CloseSessionCommand {
    type: 'close_session';
    session_id: string;
  }
  ```
- **ListRunningSessionsCommand**
  ```ts
  interface ListRunningSessionsCommand {
    type: 'list_running_sessions';
  }
  ```
- **SetActiveSessionCommand**
  ```ts
  interface SetActiveSessionCommand {
    type: 'set_active_session';
    session_id: string;
  }
  ```

Add these to `ClientCommand` union.

#### A1.5 Update `SessionStats` contract (if needed)
- If server returns `session_id` already in stats (it does), ensure it remains required in `SessionStats`.
- No change unless server adds extra fields.

---

## B. AgentConnection API Surface (TypeScript)

### B1. Update `clients/lemon-tui/src/agent-connection.ts`

#### B1.1 Accept `sessionId` in API methods
Modify methods to accept an optional `sessionId`:
- `prompt(text: string, sessionId?: string)`
- `abort(sessionId?: string)`
- `reset(sessionId?: string)`
- `save(sessionId?: string)`
- `stats(sessionId?: string)`

Implementation detail:
- When `sessionId` provided, attach `session_id` field to command.
- When not provided, omit `session_id` to use server active session.

#### B1.2 Add lifecycle methods
Add methods:
- `startSession(opts)` → sends `start_session`.
- `closeSession(sessionId)` → sends `close_session`.
- `listRunningSessions()` → sends `list_running_sessions`.
- `setActiveSession(sessionId)` → sends `set_active_session`.

Each should send JSON line commands and return `void` (or optionally a Promise resolved by a matching message at caller level).

#### B1.3 Update Ready handling
- When `ready` message arrives, store `primary_session_id` + `active_session_id` in AgentConnection instance state.
- Expose getters if needed (optional).

#### B1.4 Update event handling
- Ensure `handleLine` passes through `session_id` included in messages.
- No filtering at AgentConnection layer (keep it a transport).

---

## C. UI State & Event Routing (Lemon TUI)

### C1. Identify current session state management
- Find existing session model in the UI (likely in a store/controller).
- Determine where events are appended to the chat transcript.

### C2. Introduce multi-session state map
Maintain a structure similar to:
```ts
const sessions = new Map<string, SessionState>();
let activeSessionId: string | null = null;
```
Each `SessionState` contains:
- message transcript
- tool events
- streaming flags
- stats
- last activity timestamp

### C3. Event routing by `session_id`
- On `EventMessage`, route to `sessions.get(session_id)`.
- If missing, create a new session entry in state (lazy creation).
- UI should only render the `activeSessionId`’s state by default.

### C4. Handling lifecycle messages
- `session_started`: create session state + optionally auto-switch
- `session_closed`: mark closed or remove session state
- `running_sessions`: reconcile local state (merge, add missing, remove stale)
- `active_session`: update `activeSessionId`

### C5. Handling ready message
- Set `activeSessionId = ready.active_session_id`.
- Initialize a session record for `ready.primary_session_id` if missing.

### C6. Command dispatch in UI
- When the user sends a prompt, call `agent.prompt(text, activeSessionId)`.
- When switching sessions, call `agent.setActiveSession(newId)` (optional server sync) and update local active state.

---

## D. Minimal UI Affordances (if in scope)

If not already present, add a very small UI path to manage sessions:

1) **Session selector**
- A dropdown/list of session IDs (or friendly names if available).
- Selecting a session switches `activeSessionId`.

2) **Start session**
- A button that issues `start_session` with optional parameters.
- Optionally defaults to current model and cwd.

3) **Close session**
- A button that sends `close_session` for active session.

These are optional and can be deferred if you only need plumbing first.

---

## E. Backward Compatibility Strategy

- If no `session_id` is used by the UI, everything still flows through the active session.
- Client commands should only include `session_id` when known. Never send `session_id: null`.
- The UI should tolerate missing `session_id` in server responses (older servers). In that case, use `activeSessionId` fallback.

---

## F. Validation & Testing

### F1. Type-level tests (TypeScript)
- Update any protocol tests to include new message types.
- If there are no tests, add minimal ones to ensure the unions accept the new messages.

### F2. Integration tests (if present)
- Mock server messages for:
  - `ready` with `active_session_id`
  - `event` with `session_id`
  - `session_started`, `session_closed`, `running_sessions`
- Verify UI state creates and routes per session.

### F3. Manual test flow (dev)
1) Start TUI → verify ready includes active session id.
2) Send prompt → server events include session_id.
3) Start new session → prompt in new session does not interleave with old transcript.
4) Switch active session → ensure input goes to selected session.
5) Close session → session removed or marked closed.

---

## G. Incremental Delivery Phases

### Phase 1: Protocol + AgentConnection
- Update `types.ts` + `agent-connection.ts`.
- Do not change UI yet; just ensure commands can carry session_id.

### Phase 2: Session routing in UI
- Implement session map and per-session event routing.
- Add active session tracking.

### Phase 3: Session lifecycle UI controls (optional)
- Add basic UI controls for start/switch/close.

---

## H. File-by-File Checklist

1) `clients/lemon-tui/src/types.ts`
- Add new message interfaces and command interfaces.
- Add `session_id` fields.
- Extend union types.

2) `clients/lemon-tui/src/agent-connection.ts`
- Add session_id to command senders.
- Add new lifecycle methods.
- Track ready’s active/primary session ids.

3) UI state/store files (identify and update)
- Add session map
- Route events
- Update active session

4) Optional UI components
- Add session list / start / close controls

---

## I. Open Questions to Resolve Before Coding

1) **Should the client always send `set_active_session` when switching locally?**
   - Yes if the server uses active session as default. If we always include `session_id`, then it is optional.

2) **Do we want a human-friendly session name?**
   - Not required. Can use `session_id` for now.

3) **Should `start_session` auto-switch?**
   - If yes, include `set_active: true` in protocol (add if desired).

4) **Should closing a session auto-save?**
   - If yes, add a `save: true` flag to close_session or call `save` first.

---

## Completion Criteria

- All commands and events can target a specific session via `session_id`.
- Multi-session UI can display and route events without mixing transcripts.
- Backward compatibility preserved for single-session usage.

