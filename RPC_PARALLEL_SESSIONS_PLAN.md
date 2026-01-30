# RPC Parallel Sessions Plan (Lemon)

## Goal
Add **multi-session support** to the debug RPC layer used by Lemon TUI so that multiple CodingAgent sessions can run in parallel and be addressed by a stable `session_id` (string), not by PID. This extends the existing JSON line protocol in `scripts/debug_agent_rpc.exs` and updates Lemon TUI client contracts accordingly.

## Non-Goals (for this phase)
- No UI/UX changes beyond plumbing session ids and message routing.
- No distributed or multi-node PID exposure.
- No change to persisted session format.
- No new orchestration/coordination logic between sessions.

## Terminology
- **session_id**: A stable string from `CodingAgent.SessionManager.Session.header.id`.
- **primary session**: The session started when the RPC process boots (kept for backwards compatibility).
- **active session**: The default session id used when client messages omit `session_id`.
- **running session**: A live `CodingAgent.Session` process started under `CodingAgent.SessionSupervisor`.

---

## Wire Protocol Contracts (JSON lines)

### General rules
1) **All client commands MAY include `session_id`.** If omitted, the server uses `active_session_id`.
2) **All server responses that are session-scoped MUST include `session_id`.**
3) Existing clients remain compatible by relying on the primary session and omitting `session_id`.

### Server → Client

#### 1) Ready
Sent once at startup.
```json
{
  "type": "ready",
  "cwd": "/path",
  "model": {"provider": "anthropic", "id": "claude-..."},
  "debug": false,
  "ui": true,
  "primary_session_id": "sess-123",
  "active_session_id": "sess-123"
}
```
Notes:
- `primary_session_id` and `active_session_id` are new fields.

#### 2) Event (session-scoped)
```json
{
  "type": "event",
  "session_id": "sess-123",
  "event": {"type": "message_update", "data": [...]}
}
```

#### 3) Stats (session-scoped)
```json
{
  "type": "stats",
  "session_id": "sess-123",
  "stats": {"session_id": "sess-123", ...}
}
```

#### 4) Running session list
```json
{
  "type": "running_sessions",
  "sessions": [
    {"session_id": "sess-123", "cwd": "/path", "is_streaming": false},
    {"session_id": "sess-456", "cwd": "/path", "is_streaming": true}
  ],
  "error": null
}
```

#### 5) Session started
```json
{
  "type": "session_started",
  "session_id": "sess-789",
  "cwd": "/path",
  "model": {"provider": "anthropic", "id": "claude-..."}
}
```

#### 6) Session closed
```json
{
  "type": "session_closed",
  "session_id": "sess-789",
  "reason": "normal" | "not_found" | "error"
}
```

#### 7) Error (optionally session-scoped)
```json
{
  "type": "error",
  "message": "...",
  "session_id": "sess-123"
}
```

#### 8) Existing message types
All existing server messages remain valid. New `session_id` fields are additive.

---

### Client → Server

#### 1) Prompt
```json
{ "type": "prompt", "text": "...", "session_id": "sess-123" }
```
If `session_id` omitted → active session.

#### 2) Stats
```json
{ "type": "stats", "session_id": "sess-123" }
```

#### 3) Abort
```json
{ "type": "abort", "session_id": "sess-123" }
```

#### 4) Reset
```json
{ "type": "reset", "session_id": "sess-123" }
```

#### 5) Save
```json
{ "type": "save", "session_id": "sess-123" }
```

#### 6) List persisted sessions (existing)
```json
{ "type": "list_sessions" }
```
Unchanged; returns saved sessions on disk for current cwd.

#### 7) List running sessions (new)
```json
{ "type": "list_running_sessions" }
```

#### 8) Start new session (new)
```json
{
  "type": "start_session",
  "cwd": "/path",                 // optional; defaults to RPC cwd
  "model": "provider:model_id",  // optional; defaults to active model
  "system_prompt": "...",        // optional
  "session_file": "/path/to.jsonl", // optional
  "parent_session": "sess-123"   // optional
}
```
Response: `session_started` (and optionally set active session if requested).

#### 9) Close running session (new)
```json
{ "type": "close_session", "session_id": "sess-123" }
```
Response: `session_closed`.

#### 10) Set active session (new)
```json
{ "type": "set_active_session", "session_id": "sess-123" }
```
Response: `active_session`.
```json
{ "type": "active_session", "session_id": "sess-123" }
```

#### 11) UI response (existing)
```json
{ "type": "ui_response", "id": "...", "result": ..., "error": null }
```
Unchanged and global (not session-scoped).

#### 12) Quit (existing)
```json
{ "type": "quit" }
```
Unchanged; shuts down the RPC process (and thus all sessions).

---

## Server Implementation Plan (`scripts/debug_agent_rpc.exs`)

### 1) Session manager state
Maintain a local state map:
- `sessions: %{session_id => pid}`
- `active_session_id: session_id`
- `primary_session_id: session_id`
- `cwd`, `model`, `ui_context`

### 2) Startup
- Start **primary session** with `CodingAgent.start_session/1` (not `Session.start_link/1`).
- Register and store its `session_id` via `CodingAgent.Session.get_stats/1` or session_manager header.
- Subscribe to session events for the primary session.
- Send `ready` with `primary_session_id` + `active_session_id`.

### 3) Event routing
- For each running session, ensure the RPC process receives `{:session_event, event, session_id}` or equivalent.
- Implementation options:
  - **Option A (simple):** Track `session_id` -> `pid`, and when a session sends `{:session_event, event}`, map `pid` to `session_id` using `sessions` map and include it in emitted JSON.
  - **Option B (explicit):** Subscribe with a per-session forwarder process that tags events with `session_id` before sending to the main loop.
- Emit `event` with `session_id` field.

### 4) Command handling changes
- Update each command handler to accept `session_id` (optional) and route to the correct pid.
- For missing `session_id`, use `active_session_id`.
- For unknown `session_id`, send `error` with `session_id` and `message: "not_found"`.

### 5) New commands
- `start_session`:
  - Resolve model string to `Ai.Types.Model` (reuse existing resolve logic).
  - Start session under supervisor (`CodingAgent.start_supervised_session/1`).
  - Subscribe, store pid, emit `session_started`.
  - Optional: allow `set_active: true` in request (if desired).
- `close_session`:
  - Resolve pid, terminate via `CodingAgent.SessionSupervisor.stop_session/1`.
  - Emit `session_closed`.
- `list_running_sessions`:
  - Build from registry or internal `sessions` map.
  - Include `is_streaming` via `CodingAgent.Session.get_stats/1`.
- `set_active_session`:
  - Validate id exists, set `active_session_id`, emit `active_session`.

### 6) Backward compatibility
- If no `session_id` in incoming command, behave exactly as before with primary/active session.
- Existing response shapes remain valid; new fields are additive.

### 7) Error strategy
- Never crash on invalid commands. Respond with `{type:"error", message:"unknown command"}` or `{type:"error", message:"not_found", session_id:"..."}`.
- When a session process exits, remove from `sessions` map and emit `session_closed` with reason.

---

## Lemon TUI Client Plan

### 1) Protocol types update (`clients/lemon-tui/src/types.ts`)
- Add `session_id` to:
  - `EventMessage`
  - `StatsMessage`
  - `ErrorMessage` (optional)
  - New messages: `session_started`, `session_closed`, `running_sessions`, `active_session`
- Add new client commands:
  - `start_session`, `close_session`, `list_running_sessions`, `set_active_session`
- Add `session_id?: string` to session-scoped commands (`prompt`, `stats`, `abort`, `reset`, `save`).
- Update `ReadyMessage` to include `primary_session_id` and `active_session_id`.

### 2) AgentConnection API (`clients/lemon-tui/src/agent-connection.ts`)
- Add optional `sessionId` parameter to `prompt`, `abort`, `reset`, `save`, `stats`.
- Add methods:
  - `startSession(opts)` → sends `start_session` and returns promise of `session_started`.
  - `closeSession(sessionId)`
  - `listRunningSessions()`
  - `setActiveSession(sessionId)`
- Keep existing methods unchanged for default session.

### 3) Session tracking in UI state
- Store `active_session_id` from `ready`.
- When `session_started` arrives, add to UI session list.
- Route incoming `event` messages by `session_id` to the right session view.
- When `session_closed`, remove from list or mark closed.

---

## Compatibility & Migration
- Existing clients (no `session_id`) will continue to work against the primary session.
- Lemon TUI can roll out multi-session support incrementally:
  1) Accept `session_id` in events and store it.
  2) Send `session_id` with all commands.
  3) Add UI affordances for creating and switching sessions.

---

## Testing Plan

### Elixir (RPC script)
- Unit-ish integration (script-level) tests:
  - `ready` includes `primary_session_id`.
  - `event` includes `session_id` for both primary and spawned sessions.
  - `start_session` returns `session_started` and is independently promptable.
  - `set_active_session` switches default routing.

### Lemon TUI (TypeScript)
- Protocol decoding tests for new message types.
- AgentConnection sending `session_id` fields and new commands.

---

## Files to Update
- `scripts/debug_agent_rpc.exs`
- `clients/lemon-tui/src/types.ts`
- `clients/lemon-tui/src/agent-connection.ts`
- (optional) `LEMON_TUI_PLAN.md` to document updated wire protocol

---

## Open Questions
- Should `start_session` accept a `set_active` boolean?
- Should a session’s `model` be required or inherit from active session by default?
- Should `close_session` persist state automatically (or require explicit `save`)?

