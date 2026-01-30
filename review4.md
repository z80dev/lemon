# Review: Phase 4 (TUI Polish) — Findings and Suggestions

Date: 2026-01-30

Scope reviewed:
- `clients/lemon-tui/src/index.ts`
- `clients/lemon-tui/src/agent-connection.ts`
- `clients/lemon-tui/src/state.ts`
- `clients/lemon-tui/src/types.ts`

This review focuses on Phase 4 expectations: status/working messages, notify banners, tool execution visualization, and terminal title updates, plus any correctness issues discovered during inspection.

---

## Findings (ordered by severity)

### 1) **ESM runtime break: `require()` used in ESM module**
**Where**: `clients/lemon-tui/src/agent-connection.ts` (`findLemonPath`)

**What happens**
- The project is ESM (`package.json` has `"type": "module"`).
- `findLemonPath` uses `require('node:fs')` and `require('node:path')`. In ESM, `require` is undefined and will throw at runtime.

**Impact**
- The TUI fails to start unless `lemonPath` is explicitly provided, because `findLemonPath()` crashes.

**Suggested fix**
- Use ESM imports at the top:
  - `import fs from 'node:fs';`
  - `import path from 'node:path';`
- Replace `require(...)` calls with the imported modules.

---

### 2) **UI status signals are still ignored in the status bar**
**Where**: `clients/lemon-tui/src/index.ts` (`updateStatusBar`)

**What happens**
- `ui_status` updates are stored in `state.status` but never rendered.

**Impact**
- The agent can emit structured status updates, but users never see them.

**Suggested fix**
- Render `state.status` in the status bar (e.g., `key=value` pairs appended after working message).

---

### 3) **`ui_widget` signals not handled**
**Where**: `clients/lemon-tui/src/index.ts` (message switch)

**What happens**
- `ui_widget` messages are ignored completely.

**Impact**
- Any widgets emitted by the agent (tool lists, file lists, resource panels, etc.) are dropped.

**Suggested fix**
- Add a widget container (above or below editor) and render `ui_widget` content into it.

---

### 4) **Working message is overwritten by tool execution lifecycle**
**Where**: `clients/lemon-tui/src/state.ts`

**What happens**
- `tool_execution_start` sets `workingMessage` to `"Running <tool>..."`.
- `tool_execution_end` unconditionally clears `workingMessage`.
- If the server sets its own working message via `ui_working`, it can be cleared prematurely by a tool end event.

**Impact**
- Agent-driven working messages (e.g., “Summarizing branch…”) can disappear unexpectedly.

**Suggested fix**
- Keep separate fields for **tool working message** and **agent working message**, and decide priority in `updateStatusBar`.

---

### 5) **Usage shape mismatch (still present)**
**Where**: `clients/lemon-tui/src/state.ts`, `clients/lemon-tui/src/types.ts`

**What happens**
- `usage` expects `input_tokens` / `output_tokens`, but Lemon uses `input` / `output` / `total_tokens`.

**Impact**
- Any future token usage display will be wrong or blank.

**Suggested fix**
- Align usage shape with `Ai.Types.Usage` and normalize accordingly.

---

### 6) **Tool execution visualization still missing**
**Where**: `clients/lemon-tui/src/index.ts` / `state.ts`

**What happens**
- Tool execution state is tracked but not rendered in the UI.

**Impact**
- Users cannot see tool arguments, streaming output, or final tool results beyond the generic working message.

**Suggested fix**
- Add a tool execution panel (similar to pi) or inline tool execution components in the message flow.

---

### 7) **Terminal title is updated with raw escape codes**
**Where**: `clients/lemon-tui/src/index.ts`

**What happens**
- The code writes `]0;...` directly instead of using pi‑tui’s Terminal interface.

**Impact**
- Works in most terminals, but bypasses pi‑tui’s terminal abstraction and makes testing harder.

**Suggested fix**
- Use `this.tui.terminal.setTitle(title)` instead of direct writes.

---

### 8) **Help text still claims Ctrl+Enter submits**
**Where**: `clients/lemon-tui/src/index.ts` (`showHelp`)

**What happens**
- Help says Ctrl+Enter sends a message, but the editor submits on Enter by default.

**Impact**
- Mismatched UX guidance.

**Suggested fix**
- Update help text to match actual keybindings (Enter to submit, Shift+Enter to newline).

---

## Suggestions (Phase 4 polish)

### A) Add a dedicated “system/status” message component
Use a consistent component for notifications and system status (instead of raw `Text` added to the chat list). This keeps UI noise separate from conversation history.

### B) Implement widget rendering and a basic tool panel
- Render `ui_widget` content in a fixed container (like pi’s “widgetContainerAbove/Below”).
- Add a simple tool panel showing active tool name + recent output.

### C) Improve overlay cancel handling
Use `matchesKey` + `Key.escape` from pi‑tui for reliability with Kitty keyboard protocol.

---

## Suggested next steps

1) **Fix ESM runtime errors** (`require` → ESM imports).
2) **Render `ui_status` + `ui_widget`** in the UI.
3) **Separate working message sources** (tool vs agent).
4) **Implement tool execution visualization** (basic panel is enough for v1).
5) **Polish UX** (help text, terminal title via TUI, consistent notify component).

---

## Files referenced
- `clients/lemon-tui/src/index.ts`
- `clients/lemon-tui/src/agent-connection.ts`
- `clients/lemon-tui/src/state.ts`
- `clients/lemon-tui/src/types.ts`
