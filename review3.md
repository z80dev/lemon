# Review: Phase 3 (TUI Overlays + Client Integration)

Date: 2026-01-30

Scope of review:
- `clients/lemon-tui/src/index.ts`
- `clients/lemon-tui/src/state.ts`
- `clients/lemon-tui/src/agent-connection.ts`
- `clients/lemon-tui/src/types.ts`

Focus: correctness of overlay handling, protocol shape alignment, and pi-tui integration behavior.

---

## Findings (with impact)

### 1) **Protocol type mismatches for usage + stats** (P1)
**Where**
- `clients/lemon-tui/src/types.ts`
- `clients/lemon-tui/src/state.ts` (`normalizeAssistantMessage`)

**What’s wrong**
- `AssistantMessage.usage` is typed with `input_tokens/output_tokens`, but Elixir’s `Ai.Types.Usage` uses `input/output/cache_read/cache_write/total_tokens`.
- `SessionStats` expects `total_input_tokens/total_output_tokens` and omits `cwd/thinking_level`, but `CodingAgent.Session.get_stats/0` returns `cwd` and `thinking_level`, and does not return total tokens.

**Impact**
- Any future display of usage or stats will be wrong or undefined, and type definitions are misleading for the frontend implementation.

**Suggested fix**
- Update `types.ts` to reflect the real server shape:
  - Usage: `{ input, output, cache_read, cache_write, total_tokens, cost }`
  - Stats: `{ session_id, message_count, turn_count, is_streaming, cwd, model, thinking_level }`
- Update normalization to use `message.usage.input/output` if present.

---

### 2) **`message_update` assistant event shape is wrong** (P1)
**Where**
- `clients/lemon-tui/src/types.ts`

**What’s wrong**
- The frontend defines `AssistantEvent` as objects like `{ type: "text_delta", delta: string }`.
- The server sends tuples, which are JSON-encoded into arrays (e.g., `["text_delta", 0, "Hello", {partial}]`).

**Impact**
- If we ever rely on `assistant_event` for fine-grained streaming or UI effects, this will break immediately.

**Suggested fix**
- Change `AssistantEvent` to match the tuple-array shape, or normalize it at the connection layer into an object form the UI can rely on.

---

### 3) **`ui_status` and `ui_widget` are not rendered** (P2)
**Where**
- `clients/lemon-tui/src/index.ts`
- `clients/lemon-tui/src/state.ts`

**What’s wrong**
- `ui_status` updates state but `updateStatusBar()` ignores `state.status` entirely.
- `ui_widget` is never handled at all in `handleServerMessage`.

**Impact**
- Agent-driven UI signals for status and widgets are effectively lost, which defeats part of the overlay-driven UI design.

**Suggested fix**
- Render `state.status` entries in the status bar (e.g., `key: value` entries).
- Add a handler for `ui_widget` and render widget content in a dedicated container above the editor.

---

### 4) **Escape handling for overlays is not robust** (P2)
**Where**
- `showInputOverlay` / `showEditorOverlay` in `index.ts`

**What’s wrong**
- Cancel uses `data === ''` to detect Escape.
- With Kitty keyboard protocol or multi-byte escape sequences, this may not match.

**Impact**
- Cancel behavior may be broken on terminals using Kitty protocol (which pi-tui supports).

**Suggested fix**
- Use `matchesKey(data, Key.escape)` from `@mariozechner/pi-tui` for consistent key detection.

---

### 5) **Submit hint text is incorrect** (P2)
**Where**
- `showEditorOverlay` and `showHelp` in `index.ts`

**What’s wrong**
- The hint says “Ctrl+Enter to submit”, but pi-tui’s Editor submits on Enter and uses Shift/Alt/Ctrl+Enter for **new line**.

**Impact**
- The UI is misleading and will frustrate users.

**Suggested fix**
- Update help text to match actual Editor behavior:
  - “Enter = submit; Shift/Alt/Ctrl+Enter = new line” (or adjust keybindings).

---

### 6) **Single-line input overlay uses multi-line Editor** (P3)
**Where**
- `showInputOverlay` in `index.ts`

**What’s wrong**
- Uses `Editor` rather than `Input`, allowing accidental multi-line input.

**Impact**
- Breaks expected UX for simple prompts, and can send unintended newlines to the agent.

**Suggested fix**
- Replace with `Input` component for `input` requests.

---

### 7) **Busy state doesn’t disable user input** (P3)
**Where**
- `index.ts` editor submit handler

**What’s wrong**
- While `state.busy` is true, the editor still submits prompts.
- The server will reject with `:already_streaming`, but the UX does not prevent the action.

**Impact**
- Users can fire prompts that will fail; may cause confusing errors.

**Suggested fix**
- Disable submit while busy (`inputEditor.disableSubmit = true`) and re-enable on `agent_end`.

---

## Suggested fixes (concrete)

### A) Align stats + usage types
- Update `clients/lemon-tui/src/types.ts` to match Elixir fields.
- Update `state.ts` normalization:
  - `message.usage?.input` / `output` / `total_tokens`

### B) Normalize assistant_event
- In `agent-connection.ts` or `state.ts`, map assistant event arrays into objects if you want typed access, or loosen the type to `unknown[]`.

### C) Render `ui_status` and `ui_widget`
- Add a widget container in UI layout and render widget content there.
- Append status entries to `updateStatusBar()`.

### D) Robust escape handling
- Use `matchesKey` and `Key.escape` for overlay cancellation.

### E) Fix submit hints
- Update overlay and help text to reflect actual keybindings.

### F) Use `Input` for single-line overlays
- Replace `Editor` with `Input` for `input` requests.

### G) Disable submit while busy
- Toggle `inputEditor.disableSubmit` on `agent_start`/`agent_end`.

---

## Suggested next steps

1) **Fix protocol type alignment** (stats + usage + assistant_event). This removes future data surprises.
2) **Implement status/widget rendering** so agent-driven UI signals actually show up.
3) **Harden overlay key handling** with pi-tui’s `matchesKey` and `Key`.
4) **Fix UX hints and input components** to match actual pi-tui Editor behavior.
5) **Add basic tests** for overlay request/response and cancellation in the TUI client (using pi-tui’s VirtualTerminal).

---

## Positive notes

- Overlay flow and response wiring is structurally correct.
- The UI request/response flow matches the intended protocol extension.
- State normalization correctly extracts text/thinking/tool calls at a high level.

