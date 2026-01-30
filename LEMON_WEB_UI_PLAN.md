# Lemon Web UI (Vite + React) — Full RPC Feature Plan

> Goal: build a **fully featured** web client for Lemon that supports **every feature exposed by the debug RPC layer** (`scripts/debug_agent_rpc.exs` + `CodingAgent.UI.DebugRPC`), presented as a natural web chat UI. This is a **complete, end‑to‑end plan**; implementation is intentionally deferred.

---

## Progress Update (January 30, 2026)

**Milestone 1 — Repo Scaffolding (complete)**  
- Created `clients/lemon-web` workspace with `web/`, `server/`, and `shared/` packages.
- Vite + React + TypeScript app scaffolded at `clients/lemon-web/web`.
- Workspace scripts added in `clients/lemon-web/package.json` to run dev/build/typecheck.
- Vite dev server proxies `/ws` to `ws://localhost:3939` for local bridge access.

**Milestone 2 — Shared RPC Protocol Layer (complete, initial cut)**  
- Added `clients/lemon-web/shared/src/types.ts` (ported from `clients/lemon-tui/src/types.ts` + bridge messages).  
- Added `clients/lemon-web/shared/src/codec.ts` with JSON line encoder/decoder for stdio streams.  
- Added `server_time` field (optional) on all server→client messages for deterministic ordering in the web UI.  

**Bridge Server (initial implementation)**  
- Implemented Node/TS bridge at `clients/lemon-web/server/src/index.ts`.  
- Spawns `mix run scripts/debug_agent_rpc.exs --` and forwards JSON line messages to the browser via WebSocket.  
- WebSocket endpoint: `/ws`. Default port: `3939` (overridable with `--port`).  
- Supports flags: `--cwd`, `--model`, `--base-url`, `--system-prompt`, `--session-file`, `--debug`, `--no-ui`, `--lemon-path`, `--static-dir`.  
- Adds local bridge events: `bridge_status`, `bridge_error`, `bridge_stderr` (for UI diagnostics).  
- Auto‑restart with backoff on RPC exit; restart counter resets on `ready` messages.  
- Latest bridge status is pushed to newly connected WebSocket clients.  

**Notes / Next Adjustments**  
- Static web serving is implemented opportunistically if `web/dist` exists; otherwise the server responds with a plain status message.  
  
**Web App (core UI now implemented)**  
- Zustand store + WebSocket hook handle all RPC message types and UI signals.  
- Chat, tool timeline, status bar, widget dock, composer, session panels, and UI request modals are wired.  
- Toast notifications and working banner are implemented.  
- Vite dev proxy configured for `/ws`.  

**Milestones now functionally covered**  
- Milestone 3 (State model + normalization) implemented in `web/src/store/useLemonStore.ts`.  
- Milestone 4 (Shell + layout) implemented in `web/src/App.tsx` + `web/src/App.css`.  
- Milestone 5 (Message rendering + streaming updates) implemented in `MessageCard` + `ContentBlockRenderer`.  
- Milestone 6 (Tool timeline) implemented in `ToolTimeline`.  
- Milestone 7 (UI requests) implemented in `UIRequestModal`.  
- Milestone 8 (UI signals) implemented via status bar, widgets, notifications, working banner, title + editor text panel.  
- Milestone 9/10 (Session management + composer) implemented in `Sidebar` and `Composer`.  
- Remaining items are polish: tests, docs, and UX refinements.  

## 1) Scope & Success Criteria

### 1.1 Must‑Have Functional Coverage (RPC Parity)
The web UI must implement **all** client‑side responsibilities implied by the RPC protocol:

**Client → Server commands** (stdin JSON lines):
- `prompt` (send user text)
- `stats`
- `ping`
- `debug`
- `abort`
- `reset`
- `save`
- `list_sessions`
- `list_running_sessions`
- `list_models`
- `start_session`
- `close_session`
- `set_active_session`
- `quit`
- `ui_response` (responses to UI requests)

**Server → Client events/messages** (stdout JSON lines):
- `ready`
- `event` (session events: message/tool/turn lifecycle)
- `stats`
- `pong`
- `debug`
- `error`
- `save_result`
- `sessions_list`
- `running_sessions`
- `models_list`
- `session_started`
- `session_closed`
- `active_session`
- `ui_request` (select/confirm/input/editor)
- `ui_notify`, `ui_status`, `ui_widget`, `ui_working`, `ui_set_title`, `ui_set_editor_text`

**Session event types** (rendered and stored):
- `agent_start`, `agent_end`, `turn_start`, `turn_end`
- `message_start`, `message_update`, `message_end`
- `tool_execution_start`, `tool_execution_update`, `tool_execution_end`
- `error`

**Content block types** (rendered in messages/tool results):
- `text`, `thinking`, `tool_call`, `image`

### 1.2 UX/Behavior Outcomes
- A single web UI can control **multiple concurrent sessions** and switch active sessions.
- Message streaming is **incremental and smooth** (use `message_update` events).
- Tool execution lifecycle is visible (start/update/end) with partial results.
- Overlays for `select/confirm/input/editor` are fully functional and block until resolved.
- Status/widgets/working/notifications are displayed and updated immediately.
- Errors are surfaced clearly and never crash the UI.

### 1.3 Non‑Goals (for now)
- Multi‑user collaboration.
- Remote deployment (initial target is local developer machine).
- Persistent cloud sync of sessions (only uses existing Lemon persistence via RPC).

---

## 2) Proposed Architecture

### 2.1 High‑Level Topology
```
Browser (Vite + React)  <—WebSocket—>  Local Bridge Server (Node/TS)
                                              |
                                              | stdio JSON lines
                                              v
                                   scripts/debug_agent_rpc.exs
```

**Concrete bridge defaults (current scaffold)**  
- WebSocket path: `/ws`  
- Default port: `3939`  
- Outbound messages are decorated with `server_time` (ms since epoch).  
- Bridge emits local diagnostics: `bridge_status`, `bridge_error`, `bridge_stderr`.  

**Why a bridge?** The RPC protocol is JSON lines over stdio. The browser needs a WebSocket/HTTP intermediary that spawns and supervises the RPC process.

### 2.2 Package Layout (new)
```
clients/
  lemon-web/
    web/                # Vite React app
    server/             # Node bridge (WS + process manager)
    shared/             # Shared RPC types + helpers
```

### 2.3 Transport & Process Management
- The Node server spawns `mix run scripts/debug_agent_rpc.exs -- [args]`.
- It reads stdout lines, parses JSON, and forwards messages to the web app over WebSocket.
- It accepts WebSocket messages and writes JSON lines to stdin.
- It handles process lifecycle (crash/exit/restart) and forwards status to UI.

---

## 3) Detailed Milestones & Tasks

> Each milestone is deliverable, testable, and builds toward full parity.

### Milestone 0 — Discovery & Protocol Capture
**Goal:** lock down the contract and reduce ambiguity.

- Inventory all RPC messages from:
  - `scripts/debug_agent_rpc.exs`
  - `apps/coding_agent_ui/lib/coding_agent/ui/rpc.ex`
  - `clients/lemon-tui/src/types.ts`
- Document:
  - exact wire shapes
  - required client behaviors
  - error handling expectations
- Decide a single source of truth for protocol types (likely `clients/lemon-web/shared`).

**Deliverable:** `clients/lemon-web/shared/protocol.md` with canonical schema summary.

---

### Milestone 1 — Repo Scaffolding (Vite + Bridge)
**Goal:** set up the project skeleton and dev loop.

**Tasks**
1. **Create `clients/lemon-web/web`**
   - Vite + React + TypeScript
   - ESLint + Prettier (or Biome)
   - Basic app shell route
2. **Create `clients/lemon-web/server`**
   - Node/TS server (Express + ws or Fastify + ws)
   - CLI args for:
     - `--cwd`
     - `--model`
     - `--system-prompt`
     - `--session-file`
     - `--debug`
     - `--no-ui`
   - Environment variable support (mirroring `debug_agent_rpc.exs`)
3. **Dev wiring**
   - Vite dev server proxies `/ws` to local bridge
   - Simple connection status in UI
4. **Build/Run scripts**
   - `npm run dev` (starts server + Vite in parallel)
   - `npm run build` (builds web, bundles server)
   - `npm run start` (runs server + serves static web)

**Deliverable:** `clients/lemon-web` compiles and opens a stub UI with a connected WebSocket.

---

### Milestone 2 — Shared RPC Protocol Layer
**Goal:** create a reliable transport + message codec.

**Tasks**
1. **Type system**
   - Port `clients/lemon-tui/src/types.ts` into `clients/lemon-web/shared/types.ts`.
   - Add Web‑specific `ConnectionState` and `TransportError` types.
2. **JSON line codec**
   - Server: stream parser that handles partial chunks, UTF‑8, and newline splitting.
   - Client: WebSocket message codec (JSON parse + schema validation).
3. **Protocol router**
   - Server: map WS messages to RPC stdin (JSON line)
   - Server: map RPC stdout to WS messages
   - Include a monotonic `server_time` on forwarded messages (for UI ordering)
4. **Resilience**
   - Auto‑restart RPC process on unexpected exit (configurable)
   - Debounced reconnect from UI
   - Explicit “connection lost” banner when RPC is down

**Deliverable:** a stable, testable transport with full RPC message passthrough.

---

### Milestone 3 — Core State Model (Web App)
**Goal:** normalize RPC messages into a robust local state tree.

**State slices**
- `connection`: status, errors, last ping time
- `sessions`:
  - running sessions (by id)
  - persisted sessions list
  - active session id
  - primary session id
- `messages`:
  - per session message list
  - per message: role, content blocks, timestamps, usage
- `toolExecutions`:
  - per session tool call lifecycles
- `uiRequests`:
  - queue of pending overlays (select/confirm/input/editor)
- `uiSignals`:
  - status fields (map of key→text)
  - widgets (map of key→content/opts)
  - working message
  - title override
  - editor text (and dirty state)
- `notifications`:
  - toast list + severity

**Tasks**
- Decide state management library (Zustand recommended for clarity + minimal boilerplate).
- Build reducers/handlers for each message type:
  - `ready` → populate base state
  - `event` → map event to message/tool execution changes
  - `stats` → update per‑session stats
  - `sessions_list`, `running_sessions`, `models_list` → update catalog data
  - `session_started/closed`, `active_session` → update session registry
  - `ui_request` → enqueue overlay
  - `ui_*` signals → update relevant UI slice
- Introduce **event ordering rules**:
  - Always apply server_time ordering within a session
  - Ignore out‑of‑order tool updates if final state already known

**Deliverable:** message normalization system with unit tests.

---

### Milestone 4 — Core UI Shell & Navigation
**Goal:** layout that supports all features, not just chat.

**Layout structure**
```
┌───────────────────────────────────────────────────────────────┐
│ Top Bar: title + connection + session controls + model        │
├───────────────┬───────────────────────────────────────────────┤
│ Sidebar       │ Main Chat                                     │
│ - Sessions    │ - Message feed                                │
│ - Models      │ - Tool execution timeline                     │
│ - Saved list  │ - Status/widgets dock                          │
│ - Debug panel │                                               │
├───────────────┴───────────────────────────────────────────────┤
│ Composer: text input + actions + working indicator            │
└───────────────────────────────────────────────────────────────┘
```

**Tasks**
- Create app shell with responsive grid (desktop + mobile).
- Implement routing or view toggles for:
  - Chat view
  - Sessions view
  - Settings/Debug view
- Add a dedicated area for status + widgets from RPC.

**Deliverable:** an interactive shell with placeholder components wired to state.

---

### Milestone 5 — Message Rendering & Streaming
**Goal:** display all message types with correct streaming behavior.

**Tasks**
1. **Message list rendering**
   - Virtualized list for long conversations.
   - Sticky “latest message” and auto‑scroll with manual override.
2. **Content block renderer**
   - Text blocks (markdown, code blocks, links)
   - Thinking blocks (collapsible/inline toggle)
   - Tool calls (structured view: name, args, id)
   - Image blocks (base64 data + mime type)
3. **Streaming updates**
   - On `message_update`, update relevant content block.
   - Add “typing/streaming” indicator on assistant messages.
4. **Tool results**
   - Render `tool_result` messages in timeline or as inline system cards.

**Deliverable:** full chat rendering with streaming assistant updates.

---

### Milestone 6 — Tool Execution Timeline
**Goal:** surface tool usage with start/update/end details.

**Tasks**
- Timeline panel per session:
  - show tool name, args, status, elapsed time
  - updates on `tool_execution_update` with partial output
  - “copy” and “expand” for result payloads
- Correlate tool executions with tool_result messages via `tool_call_id` when possible.
- Provide per‑tool filtering/search in timeline.

**Deliverable:** a dedicated tool execution view integrated in the chat page.

---

### Milestone 7 — UI Requests (Overlays)
**Goal:** implement the full `select/confirm/input/editor` overlay system.

**Tasks**
1. **Modal Manager**
   - Queue behavior: only one modal open at a time
   - Timeout indicator (based on server default timeout)
   - Cancel button sends `result: null`
2. **Select Modal**
   - List with label + optional description
   - keyboard navigation + search filter
3. **Confirm Modal**
   - “Confirm / Cancel” with emphasis styling
4. **Input Modal**
   - Single‑line text field with placeholder
5. **Editor Modal**
   - Multi‑line editor with syntax highlighting (optional v1)
   - Supports prefill + returns full text
6. **Response dispatch**
   - All modals respond via `ui_response`
   - Error path sends `error` string + `result: null`

**Deliverable:** functional overlay system integrated with RPC.

---

### Milestone 8 — UI Signals + Status Widgets
**Goal:** implement all “signal” style UI commands.

**Tasks**
- `ui_notify`: toast stack with severity styles
- `ui_status`: key→value status bar with inline updates
- `ui_widget`: render small widget blocks in a dock (above/below chat)
- `ui_working`: prominent banner + spinner (clears when message is null)
- `ui_set_title`: set document title + top bar title
- `ui_set_editor_text`: update editor panel + “dirty” state indicator

**Deliverable:** full signal support and visual feedback.

---

### Milestone 9 — Session Management UI
**Goal:** allow multi‑session control and discovery.

**Tasks**
- **Running Sessions Panel**
  - list all running sessions with streaming status
  - switch active session
  - close session
- **Persisted Sessions Panel**
  - list sessions from `sessions_list`
  - open (start session w/ `session_file`)
- **New Session Workflow**
  - choose cwd, model, system prompt
  - select parent session
- **Session Stats View**
  - render `stats` responses: counts, streaming, model
  - provide “refresh stats” action

**Deliverable:** full session lifecycle control in UI.

---

### Milestone 10 — Compose & Actions
**Goal:** provide a natural, powerful composer.

**Tasks**
- Multi‑line input with:
  - `Enter` send
  - `Shift+Enter` newline
- Action buttons:
  - Send, Abort, Reset, Save
  - Ping, Debug
- Input history (per session) with ↑/↓ navigation
- Optional slash commands (map to RPC commands)

**Deliverable:** polished input composer integrated with RPC actions.

---

### Milestone 11 — Styling & Visual Design
**Goal:** deliver a clean, intentional web UI (not a generic chat clone).

**Design system**
- Typography:
  - Headers: `Space Grotesk`
  - Body: `IBM Plex Sans`
  - Mono/code: `IBM Plex Mono`
- Color palette (example):
  - Background: warm off‑white gradient (`#f7f4ef` → `#efe8dd`)
  - Primary accent: citrus green (`#8fdc3b`)
  - Secondary accent: deep teal (`#145f60`)
  - Neutral text: `#1b1b1b`
  - Muted text: `#6b6b6b`
- Layout tokens:
  - Spacing scale: 4/8/12/16/24/32
  - Radius: 12px for cards, 20px for chat bubbles
  - Shadows: subtle, directional (avoid heavy drop shadows)

**Component styling**
- Message cards have soft background and left/right alignment by role.
- Assistant messages include tool/usage metadata in a compact footer.
- Tool execution panel has a “timeline chip” style.
- Status bar uses pill‑shaped badges per status key.
- Widgets render in a docked grid with subtle borders.

**Deliverable:** a cohesive, branded Lemon web UI visual language.

---

### Milestone 12 — Testing & QA
**Goal:** ensure stability and protocol compliance.

**Tasks**
- Unit tests for:
  - protocol parsing and normalization
  - event ordering
  - UI request/response flow
- Component tests for:
  - modals
  - message rendering
  - tool timeline
- E2E tests (Playwright) with a mocked RPC server

**Deliverable:** passing tests for core flows.

---

### Milestone 13 — Docs & Developer Experience
**Goal:** make it easy to run and extend.

**Tasks**
- `README.md` for web client
- `docs/rpc.md` for protocol quick reference
- “Troubleshooting” section for common connection issues

**Deliverable:** complete docs for contributors.

---

## 4) Component Breakdown (Detailed)

### 4.1 App Shell
- **`AppRoot`**
  - Initializes connection
  - Injects store + theme
  - Renders `AppLayout`

- **`AppLayout`**
  - Defines grid: sidebar + main + composer
  - Houses top bar + global modals

### 4.2 Top Bar
- **`TopBar`**
  - Title (from `ui_set_title` or fallback)
  - Connection badge (connected/connecting/error)
  - Active session + model summary
  - Quick actions (abort/reset/save)

### 4.3 Sidebar
- **`SessionsPanel`**
  - Running sessions list
  - Active session toggle
  - Close session button

- **`ModelsPanel`**
  - Provider/model picker

- **`SavedSessionsPanel`**
  - List from `sessions_list`

- **`DebugPanel`** (toggleable)
  - Raw event log
  - Connection state details

### 4.4 Chat Area
- **`MessageFeed`**
  - Virtualized list
  - Auto‑scroll controls

- **`MessageCard`**
  - Role‑based layout
  - Footer metadata (timestamp, usage)

- **`ContentBlockRenderer`**
  - `TextBlock`
  - `ThinkingBlock`
  - `ToolCallBlock`
  - `ImageBlock`

- **`ToolExecutionTimeline`**
  - Structured list of tool lifecycle events

### 4.5 Composer
- **`Composer`**
  - Text input + send
  - Slash commands
  - Abort/reset/save buttons
  - Working indicator (from `ui_working`)

### 4.6 Modals (UI Requests)
- **`UIRequestModal`** (switches by `method`)
  - `SelectModal`
  - `ConfirmModal`
  - `InputModal`
  - `EditorModal`

### 4.7 Status/Widgets/Notifications
- **`StatusBar`**
  - Renders `ui_status` key/value pills

- **`WidgetDock`**
  - Renders `ui_widget` blocks

- **`ToastStack`**
  - Renders `ui_notify` messages

---

## 5) State & Data Flow (Concrete)

### 5.1 Message Normalization
- `event.type === message_start|update|end` → ensure:
  - `messages[sessionId][messageId]` is created
  - content blocks are updated in place on update
- `tool_execution_*` → ensure:
  - `toolExecutions[sessionId][toolId]` updated
  - track `status: running|complete|error`

### 5.2 Session Switching
- When `active_session` changes:
  - update chat feed
  - update composer context
  - update tool timeline and stats

### 5.3 UI Request Lifecycle
- `ui_request` → enqueue modal
- user responds → send `ui_response`
- modal closes only after send confirmation

---

## 6) Styling + UX Details (Implementation Guidance)

### 6.1 Layout & Spacing
- Use CSS variables for spacing, colors, fonts.
- Compose with CSS grid for large screens; collapse to stacked layout on mobile.

### 6.2 Message Styling
- **User**: right‑aligned bubble, muted background.
- **Assistant**: left‑aligned card with subtle border.
- **Tool result**: compact system card (neutral background).

### 6.3 Tool Timeline Styling
- Pill‑style header with tool name + status color.
- Collapsible body for args/result JSON.

### 6.4 Status + Widgets
- Status pills inline; newest updates briefly highlight.
- Widgets arranged in two columns in dock area; each has title + content.

---

## 7) Risk & Mitigation

- **RPC process crashes** → server auto‑restart + UI reconnect.
- **Out‑of‑order events** → ordering rules based on server_time and session id.
- **Large message history** → use virtualization + lazy loading.
- **High update frequency** → batch UI updates with requestAnimationFrame or debounce.

---

## 8) Acceptance Checklist

- [ ] All RPC command types are issued from UI.
- [ ] All RPC message types are handled in UI.
- [ ] All content block types render correctly.
- [ ] UI request overlays respond correctly.
- [ ] Tool execution timeline updates live.
- [ ] Multi‑session switching is stable.
- [ ] No UI crash on malformed or unknown events.

---

## 9) Next Steps (After Plan Approval)

1. Create `clients/lemon-web` scaffolding.
2. Build the Node bridge + WebSocket transport.
3. Implement protocol types + store.
4. Incrementally build UI milestones.
