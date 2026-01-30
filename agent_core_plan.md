# Agent Core Port Plan (pi-agent-core -> Elixir)

## Goal
Port `pi-agent-core` from `pi-mono/packages/agent` to the Elixir umbrella at `~/dev/lemon`, reusing the existing `ai` app (pi-ai port). The port should preserve:
- Agent loop semantics (turns, streaming, tools, steering, follow-up).
- Event sequencing for UI/clients.
- Agent state management and abort behavior.
- Proxy streaming support (optional but desirable).

## Source Structure (pi-mono/packages/agent)
- `src/types.ts`
  - `AgentLoopConfig`, `AgentState`, `AgentMessage`, `AgentTool`, `AgentEvent`, `ThinkingLevel`, `StreamFn`.
- `src/agent-loop.ts`
  - `agentLoop`, `agentLoopContinue`, `runLoop`, `streamAssistantResponse`, `executeToolCalls`.
- `src/agent.ts`
  - Stateful Agent wrapper: queue management, `prompt`, `continue`, `abort`, event listeners.
- `src/proxy.ts`
  - `streamProxy`: SSE parsing and partial message reconstruction for server-proxied streaming.
- `src/index.ts`
  - Re-exports.

## Target Structure (Elixir)
Create a new umbrella app (suggested name: `agent` or `agent_core`). Proposed module map:

- `AgentCore.Types`
  - Structs + types for Agent state, events, tools, config, and messages.

- `AgentCore.EventStream`
  - Generic stream for agent events (similar to `Ai.EventStream`, but returns Agent results).
  - Option: generalize `Ai.EventStream` to accept a terminal predicate + result function; then reuse for agent.

- `AgentCore.Loop`
  - Stateless loop functions:
    - `agent_loop/5` (prompts + context)
    - `agent_loop_continue/4` (resume from context)
    - private helpers: `run_loop/6`, `stream_assistant_response/6`, `execute_tool_calls/5`, `skip_tool_call/2`

- `AgentCore.Agent`
  - Stateful wrapper (GenServer) for convenient API:
    - state mutation, prompt/continue, queues, subscription, wait_for_idle, abort/reset.

- `AgentCore.Message` (optional)
  - Protocol/behaviour for custom message types (alternative to ad-hoc maps).

- `AgentCore.ToolRunner` (optional)
  - Isolate tool execution + update handling if it gets complex.

- `AgentCore.Proxy`
  - Optional `stream_proxy/3` for server-proxied streaming.

- `AgentCore` (top-level)
  - Re-exports convenience functions and types.

## Types and Data Mapping

### Message Types
Map TS message roles to Elixir conventions:
- TS: `user`, `assistant`, `toolResult` -> Elixir: `:user`, `:assistant`, `:tool_result`.
- Tool call content: TS `type: "toolCall"` -> Elixir `:tool_call` struct.

### AgentMessage
In TS, `AgentMessage` is a union of AI messages + custom app messages. In Elixir:
- Use `Ai.Types.message()` for standard messages.
- Allow custom maps/structs with `:role` via runtime checks in `convert_to_llm`.

### AgentLoopConfig
Proposed struct fields:
- `model :: Ai.Types.Model.t()`
- `convert_to_llm :: (messages -> [Ai.Types.message()])`
- `transform_context :: (messages, signal -> messages) | nil`
- `get_api_key :: (provider -> binary | nil) | nil`
- `get_steering_messages :: (() -> [AgentMessage]) | nil`
- `get_follow_up_messages :: (() -> [AgentMessage]) | nil`
- `stream_options :: Ai.Types.StreamOptions.t()` (temperature, max_tokens, api_key, session_id, reasoning, thinking_budgets, headers)
- `stream_fn :: (model, context, options -> EventStream)` (optional override for proxy)

### AgentState
Fields to mirror TS behavior:
- `system_prompt :: binary`
- `model :: Ai.Types.Model.t()`
- `thinking_level :: :off | :minimal | :low | :medium | :high | :xhigh`
- `tools :: [AgentTool.t()]`
- `messages :: [AgentMessage]`
- `is_streaming :: boolean`
- `stream_message :: AgentMessage | nil`
- `pending_tool_calls :: MapSet.t()`
- `error :: binary | nil`

### AgentTool
Extend `Ai.Types.Tool` with:
- `label :: binary`
- `execute :: (tool_call_id, params, signal, on_update -> AgentToolResult.t())`

### AgentEvent
Use tuples (or structs) for runtime simplicity. Example tuple set:
- `{:agent_start}`
- `{:agent_end, new_messages}`
- `{:turn_start}`
- `{:turn_end, assistant_message, tool_results}`
- `{:message_start, message}`
- `{:message_update, message, assistant_event}`
- `{:message_end, message}`
- `{:tool_execution_start, id, name, args}`
- `{:tool_execution_update, id, name, args, partial_result}`
- `{:tool_execution_end, id, name, result, is_error}`

## Event Semantics to Preserve
- `agentLoop` emits `agent_start`, `turn_start`, then message events for user prompts.
- Each assistant stream emits `message_start`, repeated `message_update`, then `message_end`.
- After tool execution, emit `tool_execution_start`, optional updates, then `tool_execution_end`.
- `turn_end` is emitted after tool results are inserted.
- Final `agent_end` includes only newly created messages (not original context).

## Implementation Details

### 1) AgentCore.EventStream
- Based on `Ai.EventStream` behavior.
- Must support:
  - `push/2` for events
  - `complete/2` for terminal event
  - `result/1` for final message list
  - `events/1` stream for iterative consumption
- Terminal event for agent stream is `{:agent_end, messages}`.

### 2) AgentCore.Loop
#### agent_loop(prompts, context, config, signal, stream_fn)
- Creates a stream.
- Emits `agent_start`, `turn_start`, then message start/end for each prompt.
- Extends context with prompts.
- Delegates to `run_loop`.

#### agent_loop_continue(context, config, signal, stream_fn)
- Validates context:
  - error if empty
  - error if last message role is `:assistant`
- Emits `agent_start`, `turn_start`, then `run_loop`.

#### run_loop
- Outer loop for follow-up messages.
- Inner loop for:
  - pending steering messages
  - LLM response
  - tool calls and execution
  - steering checks after tool execution
- When no more tools and no steering, check follow-up messages.

#### stream_assistant_response
- Apply optional `transform_context` (AgentMessage -> AgentMessage).
- Convert with `convert_to_llm` (AgentMessage -> LLM messages).
- Build `Ai.Types.Context` and call stream function:
  - default: `Ai.stream/3`
  - allow injected `stream_fn` for proxy
- Accumulate partial assistant message; update `context.messages` in place.
- Emit `message_start`, `message_update`, and `message_end` mirroring `Ai.EventStream` events.

#### execute_tool_calls
- For each tool call:
  - emit `tool_execution_start`
  - validate args (see below)
  - call tool.execute
  - emit `tool_execution_update` on streamed updates
  - emit `tool_execution_end`
  - create tool result message and emit message start/end
- After each tool, call `get_steering_messages`:
  - if returned, skip remaining tool calls with error results

### 3) Tool Argument Validation
TS uses TypeBox + `validateToolArguments`. Elixir options:
- **Minimal**: assume args map is correct; pass through as-is.
- **Better**: add `:ex_json_schema` and validate against JSON schema in tool params.
- **Fallback**: implement a tiny validator for object/required/type hints used in pi tools.

Recommendation: Start with minimal pass-through to unblock port, then add validation if needed.

### 4) AgentCore.Agent (GenServer)
Behavior to match TS `Agent`:
- `start_link(opts)` -> initializes state and options.
- `prompt/2`:
  - accept string (build user message), or message, or list.
  - prevent concurrent prompt while streaming.
- `continue/1`:
  - validates last message.
- `abort/1`:
  - cancels running stream task and sets error state.
- `subscribe/2`:
  - `AgentCore.Agent.subscribe(pid, listener_pid)`; broadcast events to listeners.
- `wait_for_idle/1`:
  - resolves when the current run finishes (track waiters and reply on completion).
- `reset/1`:
  - clears messages, streaming state, queues, and error.
- Steering/follow-up queue controls:
  - `steer/2`, `follow_up/2`, `clear_steering_queue/1`, `clear_follow_up_queue/1`, `clear_all_queues/1`.
- Mode controls:
  - `set_steering_mode/2` and `set_follow_up_mode/2` with `:one_at_a_time | :all`.

Concurrency model:
- `prompt` spawns a Task that consumes the agent loop stream and sends updates to GenServer.
- GenServer updates internal state and notifies listeners.
- `abort` signals Task via `Task.shutdown` (or a shared cancellation flag).
- Track subscribers with monitors and auto-cleanup on `:DOWN`.

### 5) AgentCore.Proxy
If needed for UI apps:
- `stream_proxy/3` does POST to `/api/stream`, reads SSE `data:` lines.
- Reconstructs partial assistant message (similar to TS `processProxyEvent`).
- Emits `Ai.EventStream` events (`:start`, `:text_delta`, `:tool_call_delta`, etc.).

## Suggested Implementation Order
1. Create new umbrella app: `apps/agent` (or `agent_core`).
2. Implement `AgentCore.Types`.
3. Implement `AgentCore.EventStream` or generalize `Ai.EventStream`.
4. Implement `AgentCore.Loop` (stateless core loop).
5. Add minimal tests for loop (mirrors TS tests in `agent-loop.test.ts`).
6. Implement `AgentCore.Agent` (GenServer wrapper, queues, subscribe).
7. Add tests for Agent (basic state, prompt/continue/abort).
8. Implement `AgentCore.Proxy` if needed (optional initially).

## Tests to Port (Parity Targets)
- `agent-loop` behavior:
  - event sequence
  - transform_context before convert_to_llm
  - tool call execution
  - steering queue skipping remaining tools
  - continue validation
- `agent` behavior:
  - default state
  - state mutators
  - subscribe/unsubscribe
  - prompt while streaming raises error
  - continue while streaming raises error
  - session_id forwarded to stream
  - wait_for_idle resolves after runs
  - steering/follow-up modes (`:one_at_a_time` vs `:all`)

## Open Questions / Decisions
- App name: `agent` vs `agent_core`? (Avoid `Agent` name collision in Elixir.)
- Tool validation: minimal pass-through vs JSON-schema validation.
- EventStream reuse: generalize existing `Ai.EventStream` or create dedicated `AgentCore.EventStream`.
- Should proxy streaming be in `agent` package or shared in `ai`? (pi-mono keeps proxy in agent).
- Custom message extensibility: loose maps vs protocol/behaviour.
- Event distribution: direct sends vs Registry/PubSub for multiple listeners.

## Deliverables
- New app with modules and tests.
- README for agent core explaining usage and event flow.
- Minimal dependency list: `:ai` + optional `:req` + `:jason` for proxy.
