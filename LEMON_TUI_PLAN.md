# Lemon TUI (pi-tui) Plan — Agent-Driven Overlays

This plan describes how to build a Node/TS TUI client using `@mariozechner/pi-tui`, and how to extend Lemon’s debug RPC protocol so the agent can request overlays (select/confirm/input/editor) in a client-agnostic way.

## 0) Goals and Constraints

**Goals**
- A full-featured TUI client for Lemon using `@mariozechner/pi-tui`.
- Agent-driven overlays (select/confirm/input/editor) over the existing RPC channel.
- Clean separation: Elixir agent controls behavior; TUI handles presentation and input.
- Maintain compatibility with existing `debug_agent_rpc.exs` protocol consumers.

**Constraints**
- TUI client can be a Node/TS binary.
- Inline images and autocomplete can be deferred (v1 optional).
- Overlays must be supported in the client (modal UI).
- The JSON line protocol remains the transport (stdio for spawned child).

## 1) Current Lemon Architecture (What Exists)

**Protocol bridge**
- `scripts/debug_agent_rpc.exs` starts a `CodingAgent.Session`, subscribes to session events, and prints JSON lines to stdout.
- Reads JSON commands from stdin and calls session methods.

**Current commands (stdin → Elixir)**
- `prompt`, `abort`, `reset`, `save`, `stats`, `ping`, `debug`, `quit`.

**Current outputs (stdout → client)**
- `ready`, `event`, `stats`, `pong`, `debug`, `error`.

**Event stream**
- Emitted by `AgentCore.Loop` via `CodingAgent.Session.subscribe`.
- Includes `message_start`, `message_update`, `message_end`, `tool_execution_start/update/end`, `turn_start/end`, `agent_start/end`, `error`.

**UI abstraction**
- `CodingAgent.UI` behaviour exists with methods like `select/confirm/input/editor/notify/set_status/set_widget`.
- `CodingAgent.UI.RPC` implements JSON over stdio (request/response). The `debug_agent_rpc.exs` now starts with UI enabled by default using `CodingAgent.UI.DebugRPC`.

## 2) Target Design (Agent-Driven Overlays)

### 2.1 Protocol Extension (JSON Lines)
We extend the existing `debug_agent_rpc` stream with **UI requests** and **UI responses**.

**New server → client message**
```json
{"type":"ui_request","id":"uuid","method":"select|confirm|input|editor","params":{...}}
```

**New client → server message**
```json
{"type":"ui_response","id":"uuid","result":...,"error":null}
```

**Backward compatibility**
- Existing clients that ignore `ui_request` should still work (but will cause timeouts in the agent if UI is required). For safety, allow a configurable timeout and a fallback (e.g., return nil / false).

### 2.2 UI Request/Response Semantics
Map directly to `CodingAgent.UI` behaviour:

- **select**: `result` is `option.value` (string) or `null` if canceled.
- **confirm**: `result` is boolean `true/false`.
- **input**: `result` is string or `null` if canceled.
- **editor**: `result` is string or `null` if canceled.

For errors:
```json
{"type":"ui_response","id":"uuid","error":"message","result":null}
```

### 2.3 Other UI Signals (Agent → Client)
These aren’t overlays but should be supported for parity:
- `notify`: info/warn/error/success (render inline or banner)
- `set_status`: update status line fields (e.g., streaming, model, tokens)
- `set_working_message`: show progress indicator or banner
- `set_widget`: render small blocks above/below editor
- `set_title`: set terminal title
- `set_editor_text`: set editor contents (e.g., “edit this text”)

We implement these using the same extension mechanism. **Exact wire shapes:**

```json
{"type":"ui_notify","params":{"message":"...","notify_type":"info|warn|error|success"}}
{"type":"ui_status","params":{"key":"...","text":"..."}}
{"type":"ui_widget","params":{"key":"...","content":"...","opts":{}}}
{"type":"ui_working","params":{"message":"..."}}
{"type":"ui_set_title","params":{"title":"..."}}
{"type":"ui_set_editor_text","params":{"text":"..."}}
```

**Notes:**
- `ui_notify.params.notify_type` uses `notify_type` (not `type`) to avoid confusion with the envelope `type`.
- `ui_widget.params.opts` is always a map (not an array), normalized from Elixir keyword lists.

### 2.4 Frontend Data Contract (Wire Shape + Normalized Shape)
This is the exact shape the TUI client should expect and how it should normalize data before rendering.

**Wire envelope (all messages)**  
Each line is a single JSON object. The top-level always includes `type`.

```json
{"type":"ready","cwd":"/path","model":{"provider":"anthropic","id":"claude-3-5"},"debug":false}
{"type":"event","event":{"type":"message_update","data":[<message>, <assistant_event>]}}
{"type":"ui_request","id":"uuid","method":"select","params":{...}}
{"type":"ui_response","id":"uuid","result":"value","error":null}
{"type":"stats","stats":{...}}
{"type":"error","message":"..."}
```

**Important: `event.data` is always an array**  
`debug_agent_rpc.exs` converts Elixir tuples to `{"type": <atom>, "data": [rest...]}`.  
The client must **not** assume named fields inside `event.data`.

**Struct serialization**  
Elixir structs are serialized as maps and include `"__struct__": "Elixir.Module.Name"` in the JSON.  
Atoms are serialized as strings. The client should treat these as plain objects and not depend on atom semantics.

#### 2.4.1 Event Shapes (wire)
Below are the raw `event.type` values and their `data` arrays as emitted today:

- `agent_start`  
  - `data`: `[]`

- `agent_end`  
  - `data`: `[messages]`  
  - `messages`: list of message structs (see Message Shapes)

- `turn_start`  
  - `data`: `[]`

- `turn_end`  
  - `data`: `[message, tool_results]`

- `message_start`  
  - `data`: `[message]`

- `message_update`  
  - `data`: `[message, assistant_event]`  
  - `assistant_event` is one of: `text_delta`, `thinking_delta`, `tool_call_delta`, etc., but the message already contains the updated partial content.

- `message_end`  
  - `data`: `[message]`

- `tool_execution_start`  
  - `data`: `[id, name, args]`

- `tool_execution_update`  
  - `data`: `[id, name, args, partial_result]`

- `tool_execution_end`  
  - `data`: `[id, name, result, is_error]`

- `error`  
  - `data`: `[reason, partial_state]`

#### 2.4.2 Message Shapes (wire)
All messages are serialized `Ai.Types` structs. The client should treat `role` and `content` as the primary fields.

**UserMessage** (`Ai.Types.UserMessage`)
```json
{
  "__struct__":"Elixir.Ai.Types.UserMessage",
  "role":"user",
  "content":"string OR [content blocks]",
  "timestamp":1700000000000
}
```

**AssistantMessage** (`Ai.Types.AssistantMessage`)
```json
{
  "__struct__":"Elixir.Ai.Types.AssistantMessage",
  "role":"assistant",
  "content":[ {text/thinking/tool_call blocks...} ],
  "provider":"anthropic",
  "model":"claude-3-5",
  "api":"bedrock_converse_stream",
  "usage":{...},
  "stop_reason":"stop|length|tool_use|error|aborted",
  "error_message":null,
  "timestamp":1700000000000
}
```

**ToolResultMessage** (`Ai.Types.ToolResultMessage`)
```json
{
  "__struct__":"Elixir.Ai.Types.ToolResultMessage",
  "role":"tool_result",
  "tool_call_id":"call_123",
  "tool_name":"read",
  "content":[ {text/image blocks...} ],
  "details":{...},
  "is_error":false,
  "timestamp":1700000000000
}
```

#### 2.4.3 Content Block Shapes (wire)
Content blocks appear in `message.content` or `tool_result.content`.

**TextContent** (`Ai.Types.TextContent`)
```json
{"__struct__":"Elixir.Ai.Types.TextContent","type":"text","text":"...","text_signature":null}
```

**ThinkingContent** (`Ai.Types.ThinkingContent`)
```json
{"__struct__":"Elixir.Ai.Types.ThinkingContent","type":"thinking","thinking":"...","thinking_signature":null}
```

**ToolCall** (`Ai.Types.ToolCall`)
```json
{"__struct__":"Elixir.Ai.Types.ToolCall","type":"tool_call","id":"call_1","name":"read","arguments":{...}}
```

**ImageContent** (optional in v1)
```json
{"__struct__":"Elixir.Ai.Types.ImageContent","type":"image","data":"<base64>","mime_type":"image/png"}
```

#### 2.4.4 Tool Execution Result Shapes (wire)
Tool execution updates use `AgentCore.Types.AgentToolResult`:
```json
{
  "__struct__":"Elixir.AgentCore.Types.AgentToolResult",
  "content":[ {text/image blocks...} ],
  "details":{...}
}
```

#### 2.4.5 Client Normalization (pi-tui expectations)
The TUI should normalize wire data into an internal shape for rendering:

- `Message` objects should be keyed by a stable `id`:
  - Prefer `tool_call_id` for tool results.
  - Otherwise use `timestamp` + `role` + running index.
- `AssistantMessage` rendering:
  - Text blocks → `Markdown` component.
  - Thinking blocks → dim/italic Markdown or hidden based on settings.
  - Tool calls → show inline summary (name + args) or defer to tool execution panel.
- `ToolResultMessage` rendering:
  - Text blocks → `Markdown` or `Text`.
  - Image blocks → ignore in v1 (render placeholder).
- `message_update`:
  - Always replace the in-progress assistant message with the updated partial message in `data[0]`.
  - Ignore `assistant_event` for rendering unless needed for fine-grained effects.

This normalization layer is the core compatibility boundary between Lemon’s event stream and `@mariozechner/pi-tui` components.

## 3) Elixir Work (Server Side)

### 3.1 Implement a UI Adapter for the Debug RPC
Create a new UI module in `apps/coding_agent_ui` (or in scripts) that:
- Implements `CodingAgent.UI`.
- Emits `ui_request` messages on stdout via the debug RPC stream.
- Waits for `ui_response` with the matching `id`.
- Provides timeouts and cancellation behavior.

**Proposed location**
- `apps/coding_agent_ui/lib/coding_agent/ui/debug_rpc.ex`

**Key responsibilities**
- Keep an `output_device` (stdio) and `input_pid` (debug agent process).
- Serialize JSON in the same line-oriented protocol.
- Maintain pending requests map `{id => from}`.
- Accept `ui_response` messages from `debug_agent_rpc.exs` and resolve waiting calls.
- Timeout strategy (default: 30s or configurable).

### 3.2 Extend `scripts/debug_agent_rpc.exs`
Add:
- A new input handler for `type == "ui_response"` that forwards to the UI adapter (GenServer or process mailbox).
- Start the session with `ui_context: CodingAgent.UI.Context.new(CodingAgent.UI.DebugRPC)` or a provided UI adapter process.

**UI is enabled by default.** Use `--no-ui` flag to disable UI requests for headless/backward-compatible usage. The `ready` payload includes `ui: true/false` for the client to know the UI state.

### 3.3 Optional: Upgrade/Reuse `CodingAgent.UI.RPC`
If possible, reuse its structure:
- It already does request/response over stdio.
- We may adapt it to share logic with the debug protocol or wrap it.

### 3.4 Tests (Elixir)
- Unit tests for the new UI adapter:
  - request emits correct JSON
  - timeout behavior
  - correct mapping of `select`/`confirm`/`input`/`editor` results
- Integration test for debug agent RPC:
  - simulate client `ui_response` lines
  - ensure UI calls resolve

## 4) Node/TS TUI Client Work (pi-tui)

### 4.1 Process Management
- Spawn `mix run scripts/debug_agent_rpc.exs -- ...` with stdin/stdout pipes.
- Read stdout line-by-line; parse JSON; route by `type`.

### 4.2 Core UI Layout
Using `@mariozechner/pi-tui`:
- Header (cwd/model/connection)
- Chat container (messages)
- Pending tool execution container (optional)
- Status line/footer
- Editor (multi-line)
- Overlays stack for dialogs

### 4.3 Event → UI Mapping
- `message_start` → create message component (user/assistant/tool_result)
- `message_update` → update the assistant component with partial content
- `message_end` → finalize component
- `tool_execution_start/update/end` → show tool execution component with progress
- `agent_start` → set “busy” status
- `agent_end` → clear busy status
- `error` → show error message/banner

### 4.4 UI Requests (Overlays)
Handle `ui_request`:
- `select`: show `SelectList` overlay, return selected value
- `confirm`: show overlay with Yes/No options (SelectList)
- `input`: show `Input` overlay (single-line)
- `editor`: show `Editor` overlay (multi-line)

Cancel behavior:
- Escape or Ctrl+C in overlay sends `ui_response` with `result: null` and `error: null`.

### 4.5 UI Signals
Implement handler for:
- `ui_notify`: show inline banner or add system message
- `ui_status`: update status line fields
- `ui_working`: show spinner + message
- `ui_set_title`: call TUI terminal `setTitle`
- `ui_set_editor_text`: set editor contents

### 4.6 Commands in the Editor
Client-side commands (not agent-driven):
- `/abort`, `/reset`, `/save`, `/stats`, `/ping`, `/quit`
- Each command sends the corresponding `type` to server.

### 4.7 Packaging
- Node CLI entrypoint: `lemon-tui`
- Build via `tsup` or `esbuild` to a single executable JS file.
- Optional `pkg` or `nexe` to build a standalone binary.

## 5) Testing Strategy

### 5.1 Elixir Tests
- **Unit**: UI adapter request/response
- **Integration**: debug RPC script with simulated client (stdin/stdout)

### 5.2 Node/TS Tests
- Use `VirtualTerminal` from `@mariozechner/pi-tui` for component rendering tests.
- Unit tests for JSON parsing and state machine.
- Snapshot tests for message rendering.

### 5.3 Manual Tests
- Launch TUI client; run prompts; verify streaming updates.
- Trigger tool calls; verify tool execution overlay/panel.
- Use `/abort` while streaming.
- Simulate UI requests (select/confirm/input/editor) from Elixir side.

### 5.4 Backward Compatibility
- Ensure old `debug_cli.py` still works (ignores `ui_request`).
- Ensure `debug_agent_rpc.exs` can be run without UI adapter (flag or default fallback).

## 6) Implementation Phases

**Phase 1 — Protocol + UI Adapter**
- Add UI adapter in Elixir.
- Extend debug RPC protocol with `ui_request`/`ui_response`.
- Tests for adapter + protocol.

**Phase 2 — Node TUI Skeleton**
- Basic TUI layout
- Spawn + connect to debug RPC
- Render messages + streaming

**Phase 3 — Overlays**
- Implement UI overlay rendering for select/confirm/input/editor
- Send `ui_response`

**Phase 4 — Polish**
- Status line updates, working messages, notify banners
- Tool execution visualization
- Terminal title updates

## 7) Risks + Mitigations

- **Protocol drift**: Keep versioned messages or include `protocol_version` in `ready`.
- **UI request deadlocks**: enforce timeouts and send cancellation on client disconnect.
- **Streaming performance**: update only active message component, avoid full re-render when possible.
- **Message ordering**: rely on `message_start/update/end` semantics; if out-of-order, fallback to full message replacement.

## 8) Deliverables

- `apps/coding_agent_ui/lib/coding_agent/ui/debug_rpc.ex` (new)
- Updated `scripts/debug_agent_rpc.exs`
- Tests for Elixir adapter and protocol
- Node/TS TUI client (new package / folder)
- Documentation: how to run the TUI and protocol summary
