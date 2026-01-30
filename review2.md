# Review: Phase 2 (Node/TS TUI Client) — Findings and Suggestions

Date: 2026-01-30

Scope reviewed:
- `clients/lemon-tui/src/index.ts`
- `clients/lemon-tui/src/agent-connection.ts`
- `clients/lemon-tui/src/state.ts`
- `clients/lemon-tui/src/types.ts`

The focus is correctness against the debug RPC protocol, pi‑tui integration, and UI parity expectations from Phase 1.

---

## Findings (ordered by severity)

### 1) **UI status updates are ignored in the UI**
**Where**: `clients/lemon-tui/src/index.ts`

**What happens**
- `ui_status` messages are routed into `StateStore.setStatus`, which populates `state.status`.
- `updateStatusBar()` never reads `state.status`, so these updates never appear.

**Why it matters**
- `CodingAgent.UI.set_status/2` is part of the core UI contract; the client currently drops the signal and loses important user feedback (model, mode, tokens, etc.).

**Suggested fix**
- Render `state.status` in the status bar (either as key:value pairs or in a dedicated section).
- Keep `workingMessage` separate so it doesn’t get overridden.

---

### 2) **`ui_widget` signals are not handled at all**
**Where**: `clients/lemon-tui/src/index.ts` (message switch)

**What happens**
- The client does not handle `ui_widget` messages.
- Any widgets emitted by the agent are dropped.

**Why it matters**
- Widgets were explicitly part of the server‑side UI contract in Phase 1. This is a missing feature in Phase 2 and makes the overlay system incomplete.

**Suggested fix**
- Add handler for `ui_widget` and render widgets in a dedicated container (above or below the editor).

---

### 3) **Usage fields do not match Lemon’s wire schema**
**Where**: `clients/lemon-tui/src/state.ts`, `clients/lemon-tui/src/types.ts`

**What happens**
- `AssistantMessage.usage` is assumed to contain `input_tokens` / `output_tokens`.
- The Lemon schema (`Ai.Types.Usage`) provides `input`, `output`, `cache_read`, `cache_write`, `total_tokens`, `cost`.

**Why it matters**
- Usage display will always be empty or incorrect.
- This is a data‑shape mismatch against the actual protocol.

**Suggested fix**
- Update `types.ts` usage shape to match Lemon (`input`, `output`, `total_tokens`, etc.).
- Adjust normalization in `state.ts` accordingly.

---

### 4) **Overlay cancel handling only recognizes raw ``**
**Where**: `clients/lemon-tui/src/index.ts` (input/editor overlay handlers)

**What happens**
- Escape detection is implemented via `data === ''`.
- With Kitty keyboard protocol and other terminals, escape may arrive in different sequences.

**Why it matters**
- Canceling overlays may fail in real terminals, especially on Kitty or terminals using CSI‑u sequences.

**Suggested fix**
- Use pi‑tui’s `matchesKey(data, Key.escape)` for consistent key detection.
- This keeps behavior aligned with pi‑tui semantics.

---

### 5) **Multiple UI requests are not queued**
**Where**: `clients/lemon-tui/src/index.ts` (`onStateChange` + `pendingUIRequest` handling)

**What happens**
- Only one pending request is supported. If a new `ui_request` arrives while an overlay is open, it is stored but never displayed (since `pendingUIRequest` was already non‑null and the transition check only fires on null → non‑null).

**Why it matters**
- If the agent sends multiple requests back‑to‑back, the second request will be silently lost and the server will eventually time out.

**Suggested fix**
- Use a queue for `pendingUIRequests` and pop the next when an overlay closes.
- Alternatively, immediately return an error to the server when a request arrives while one is active.

---

### 6) **Tool execution events are not rendered**
**Where**: `clients/lemon-tui/src/index.ts`, `clients/lemon-tui/src/state.ts`

**What happens**
- `tool_execution_*` events are tracked in state but never shown in the UI.
- Only a generic working message is displayed.

**Why it matters**
- Tool streaming is a core part of Lemon; users will see nothing about tool activity beyond a spinner.

**Suggested fix**
- Add a tool execution panel or inline components that show:
  - tool name + args on start
  - streaming partial output
  - final result + error state

---

### 7) **Input overlays use `Editor` instead of `Input`**
**Where**: `clients/lemon-tui/src/index.ts` (`showInputOverlay`)

**What happens**
- The single‑line input overlay uses `Editor` (multi‑line) and ignores `placeholder`.

**Why it matters**
- Users can enter multi‑line text in a UI that is meant to be single‑line.
- Placeholder is silently ignored.

**Suggested fix**
- Use pi‑tui `Input` for `input` requests (single‑line). Provide placeholder via inline text if needed.

---

### 8) **Help text advertises incorrect submit shortcut**
**Where**: `clients/lemon-tui/src/index.ts` (`showHelp`)

**What happens**
- Help says “Ctrl+Enter to send message,” but `Editor` submits on Enter by default.

**Why it matters**
- This creates confusing guidance, especially for new users.

**Suggested fix**
- Update the help text to reflect actual keybindings (Enter to submit, Shift+Enter to newline).

---

## Suggestions (architecture / parity)

### A) Align UI signals with the Phase 1 spec
- If Phase 1 adopts `notify_type`, ensure the client reads that key first and only falls back to `type` for compatibility.
- If `ui_widget` becomes a first‑class signal, ensure it is implemented here.

### B) Normalize usage into a common display format
- The UI should display: input/output tokens, total tokens, and optionally cost.
- This requires mapping Lemon’s `Ai.Types.Usage` fields into something the status bar can consume.

### C) Implement a “system message” component type
- Use for notifications, errors, and UI feedback that don’t belong to user/assistant roles.
- This avoids overloading the message list with ad‑hoc Text blocks.

---

## Suggested next steps

1) **Fix protocol mismatches**
   - Update usage schema in `types.ts` and normalization in `state.ts`.
   - Honor `notify_type` if Phase 1 adopts it.

2) **Finish UI contract**
   - Render `ui_status` into the status bar.
   - Add `ui_widget` handling and display.

3) **Overlay robustness**
   - Use `matchesKey` for Escape handling.
   - Add a queue for overlapping UI requests.

4) **Tool visibility**
   - Add a tool execution panel or inline render path.

5) **Polish UX**
   - Fix help text to match actual keybindings.
   - Replace input overlay Editor with Input.

---

## Files referenced
- `clients/lemon-tui/src/index.ts`
- `clients/lemon-tui/src/agent-connection.ts`
- `clients/lemon-tui/src/state.ts`
- `clients/lemon-tui/src/types.ts`
