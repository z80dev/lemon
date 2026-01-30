# Porting pi-agent-core to Elixir - Analysis & Plan

## Overview

This document outlines the plan for porting `pi-agent-core` (TypeScript) from the pi-mono repository to Elixir in the lemon project.

**Source:** `~/dev/pi-mono/packages/agent/`
**Target:** `~/dev/lemon/apps/agent/`

**Dependencies Verified:**
- Only depends on `pi-ai` (already ported as `apps/ai/`)
- `pi-tui` is listed but unused in the source code - can be omitted

---

## Source Structure Analysis

### TypeScript Files (packages/agent/src/)

| File | Lines | Purpose |
|------|-------|---------|
| `index.ts` | 9 | Re-exports |
| `types.ts` | 195 | Type definitions (AgentState, AgentEvent, AgentTool, etc.) |
| `agent.ts` | 481 | Main Agent class with state management |
| `agent-loop.ts` | 418 | Core agent loop logic |
| `proxy.ts` | 341 | Proxy streaming for server deployments |

**Total:** ~1,435 lines of TypeScript

### Key Dependencies from pi-ai

- `EventStream` - Generic async iterable event stream
- `streamSimple` - Default streaming function
- `validateToolArguments` - Tool argument validation
- Core types: `AssistantMessage`, `ToolResultMessage`, `Context`, `Model`, etc.

---

## Target Structure

```
apps/agent/
├── lib/
│   ├── agent.ex                    # Main public API
│   ├── agent/
│   │   ├── types.ex                # Structs and type definitions
│   │   ├── server.ex               # GenServer (Agent state machine)
│   │   ├── loop.ex                 # Agent loop logic
│   │   ├── proxy.ex                # Proxy streaming
│   │   ├── tool_runner.ex          # Tool execution with updates
│   │   └── message_protocol.ex     # Protocol for custom messages
│   └── agent/application.ex        # OTP Application
├── mix.exs
└── test/
```

---

## Type Mappings

### Core Types

| TypeScript | Elixir |
|------------|--------|
| `AgentState` | `%Agent.Types.State{}` |
| `AgentContext` | `%Agent.Types.Context{}` |
| `AgentEvent` | Tagged tuple or `%Agent.Types.Event{}` |
| `AgentTool<T>` | `%Agent.Types.Tool{}` with function capture |
| `AgentMessage` | `Agent.Types.message()` type union |
| `ThinkingLevel` | Atom: `:off \| :minimal \| :low \| :medium \| :high \| :xhigh` |
| `StreamFn` | Function capture or MFA tuple |
| `EventStream<T>` | `Ai.EventStream` (reused from ai app) |

### Event Type Mapping

TypeScript discriminated unions become tagged tuples:

```typescript
// TypeScript
{ type: "agent_start" } | { type: "agent_end"; messages: AgentMessage[] }
```

```elixir
# Elixir
{:agent_start} | {:agent_end, [message()]}
```

Full event type:

```elixir
@type event ::
    {:agent_start}
  | {:agent_end, [message()]}
  | {:turn_start}
  | {:turn_end, AssistantMessage.t(), [ToolResultMessage.t()]}
  | {:message_start, message()}
  | {:message_update, AssistantMessage.t(), Ai.EventStream.event()}
  | {:message_end, message()}
  | {:tool_execution_start, String.t(), String.t(), map()}
  | {:tool_execution_update, String.t(), String.t(), map(), any()}
  | {:tool_execution_end, String.t(), String.t(), any(), boolean()}
```

---

## Key Patterns to Translate

### 1. The Agent Class → GenServer

**TypeScript:**
```typescript
export class Agent {
  private _state: AgentState
  private listeners = new Set<(e: AgentEvent) => void>()
  private abortController?: AbortController
  private steeringQueue: AgentMessage[] = []
  private followUpQueue: AgentMessage[] = []
  private runningPrompt?: Promise<void>

  async prompt(message: AgentMessage | AgentMessage[]): Promise<void>
  steer(m: AgentMessage)
  followUp(m: AgentMessage)
  abort()
  subscribe(fn: (e: AgentEvent) => void): () => void
}
```

**Elixir:**
```elixir
defmodule Agent.Server do
  use GenServer

  defstruct [
    :state,               # %Agent.Types.State{}
    :listeners,           # %{pid() => reference()} - monitors
    :abort_ref,           # For task cancellation
    :steering_queue,      # [message()]
    :follow_up_queue,     # [message()]
    :running_task,        # Task.t() | nil
    :waiters,             # [GenServer.from()] for wait_for_idle
    :config               # %Agent.Types.Config{}
  ]

  # Public API
  def start_link(opts \\ [])
  def prompt(pid, message_or_messages)
  def steer(pid, message)
  def follow_up(pid, message)
  def abort(pid)
  def subscribe(pid, listener_pid)
  def wait_for_idle(pid, timeout \\ :infinity)
end
```

### 2. Event Subscription Pattern

**TypeScript:**
```typescript
subscribe(fn: (e: AgentEvent) => void): () => void {
  this.listeners.add(fn)
  return () => this.listeners.delete(fn)
}

private emit(e: AgentEvent) {
  for (const listener of this.listeners) {
    listener(e)
  }
}
```

**Elixir Options:**

Option A - Direct message passing:
```elixir
def subscribe(server, listener_pid) do
  GenServer.call(server, {:subscribe, listener_pid})
end

# Listener receives {:agent_event, event}
def handle_call({:subscribe, pid}, _from, state) do
  ref = Process.monitor(pid)
  {:reply, {:ok, ref}, %{state | listeners: Map.put(state.listeners, pid, ref)}}
end

defp emit(event, state) do
  Enum.each(state.listeners, fn {pid, _ref} ->
    send(pid, {:agent_event, event})
  end)
end
```

Option B - Registry/PubSub (if multiple listeners needed):
```elixir
# Using Registry for fan-out
Registry.register(Agent.EventRegistry, state.session_id, [])
Registry.dispatch(Agent.EventRegistry, state.session_id, fn listeners ->
  Enum.each(listeners, fn {pid, _} -> send(pid, {:agent_event, event}) end)
end)
```

### 3. Async Agent Loop

**TypeScript:**
```typescript
async _runLoop(messages?: AgentMessage[]) {
  this.runningPrompt = new Promise<void>((resolve) => {
    this.resolveRunningPrompt = resolve
  })

  const stream = agentLoop(messages, context, config, signal, streamFn)

  for await (const event of stream) {
    // Handle events, update state
    this.emit(event)
  }

  this.resolveRunningPrompt?.()
}
```

**Elixir:**
```elixir
defp run_loop(server_state, messages) do
  # Create promise-like structure for wait_for_idle
  {waiters, running_task} = start_loop_task(server_state, messages)

  # Task runs the actual loop asynchronously
  task = Task.async(fn ->
    {:ok, stream} = Agent.Loop.run(messages, context, config)

    stream
    |> Ai.EventStream.events()
    |> Enum.reduce(context, fn event, ctx ->
      # Send events to GenServer for state updates and fan-out
      GenServer.cast(self(), {:loop_event, event})
      Agent.Loop.update_context(ctx, event)
    end)
  end)

  %{server_state | running_task: task, waiters: waiters}
end
```

### 4. Abort/Cancellation

**TypeScript:**
```typescript
abort() {
  this.abortController?.abort()
}

// Passed to stream functions
const response = await streamFunction(config.model, llmContext, {
  ...config,
  signal: this.abortController.signal,
})
```

**Elixir:**
```elixir
def abort(pid) do
  GenServer.call(pid, :abort)
end

def handle_call(:abort, _from, state) do
  if state.running_task do
    Task.shutdown(state.running_task, :brutal_kill)
  end
  {:reply, :ok, %{state | running_task: nil, state: %{state.state | is_streaming: false}}}
end

# Alternative: message-based cancellation in the loop
# Pass a cancellation reference to the loop that it checks periodically
```

### 5. Custom Message Types (Declaration Merging Replacement)

**TypeScript uses declaration merging:**
```typescript
export interface CustomAgentMessages {
  // Empty by default - apps extend via declaration merging
}
export type AgentMessage = Message | CustomAgentMessages[keyof CustomAgentMessages];
```

**Elixir - Use a Protocol:**

```elixir
defprotocol Agent.Message do
  @doc "Convert to LLM-compatible message"
  def to_llm(msg)

  @doc "Get the role of the message"
  def role(msg)

  @doc "Convert to Agent.Types.message() struct"
  def normalize(msg)
end

# Default implementations for Ai types
alias Ai.Types.{UserMessage, AssistantMessage, ToolResultMessage}

defimpl Agent.Message, for: UserMessage do
  def to_llm(msg), do: msg  # Already LLM-compatible
  def role(msg), do: :user
  def normalize(msg), do: msg
end

# Apps implement for custom types
defimpl Agent.Message, for: MyApp.ArtifactMessage do
  def to_llm(msg) do
    %UserMessage{content: msg.summary, timestamp: msg.timestamp}
  end
  def role(_msg), do: :user
  def normalize(msg), do: ...
end
```

### 6. The Agent Loop Logic

**TypeScript structure:**
```typescript
async function runLoop(
  currentContext: AgentContext,
  newMessages: AgentMessage[],
  config: AgentLoopConfig,
  signal: AbortSignal,
  stream: EventStream<AgentEvent, AgentMessage[]>,
): Promise<void> {
  // Outer loop: Follow-up message handling
  while (true) {
    // Inner loop: Tool execution + steering
    while (hasMoreToolCalls || pendingMessages.length > 0) {
      const message = await streamAssistantResponse(...)
      const toolResults = await executeToolCalls(...)
      // Check for steering messages
    }
    // Check for follow-up messages
  }
}
```

**Elixir structure:**

The loop should be implemented as a state machine that can yield events:

```elixir
defmodule Agent.Loop do
  @doc """
  Run the agent loop, returning an EventStream that emits AgentEvents.
  """
  def run(prompts, context, config, opts \\ []) do
    {:ok, stream} = Ai.EventStream.start_link()

    Task.start(fn ->
      do_run_loop(stream, prompts, context, config, opts)
    end)

    {:ok, stream}
  end

  defp do_run_loop(stream, prompts, context, config, opts) do
    new_messages = prompts
    current_context = add_messages(context, prompts)

    Ai.EventStream.push(stream, {:agent_start})
    # ... emit events, handle loops

    # Outer loop for follow-up messages
    loop_outer(stream, current_context, new_messages, config, opts)
  end

  defp loop_outer(stream, context, new_messages, config, opts) do
    # Similar structure to TypeScript
    # Use recursion instead of while loops
  end
end
```

### 7. Tool Execution with Streaming Updates

**TypeScript:**
```typescript
result = await tool.execute(toolCall.id, validatedArgs, signal, (partialResult) => {
  stream.push({
    type: "tool_execution_update",
    toolCallId: toolCall.id,
    partialResult,
  })
})
```

**Elixir:**

Option A - Stream PID passed to tool:
```elixir
defp execute_tool(tool, tool_call, stream_pid, signal) do
  # Tool implementation sends updates to stream
  on_update = fn partial_result ->
    Ai.EventStream.push(stream_pid, {
      :tool_execution_update,
      tool_call.id,
      tool.name,
      tool_call.arguments,
      partial_result
    })
  end

  tool.execute.(tool_call.id, validated_args, signal, on_update)
end
```

Option B - Use Elixir Stream for progressive results:
```elixir
# If tool returns a Stream of partial results
tool.execute(tool_call.id, args, signal)
|> Enum.each(fn partial ->
  push_update(stream, tool_call, partial)
end)
```

---

## Dependencies

### mix.exs

```elixir
defmodule Agent.MixProject do
  use Mix.Project

  def project do
    [
      app: :agent,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Agent.Application, []}
    ]
  end

  defp deps do
    [
      {:ai, in_umbrella: true},
      {:nimble_options, "~> 1.1"}
    ]
  end
end
```

---

## Configuration Types

The `AgentLoopConfig` from TypeScript:

```typescript
interface AgentLoopConfig extends SimpleStreamOptions {
  model: Model<any>
  convertToLlm: (messages: AgentMessage[]) => Message[] | Promise<Message[]>
  transformContext?: (messages: AgentMessage[], signal?: AbortSignal) => Promise<AgentMessage[]>
  getApiKey?: (provider: string) => Promise<string | undefined> | string | undefined
  getSteeringMessages?: () => Promise<AgentMessage[]>
  getFollowUpMessages?: () => Promise<AgentMessage[]>
}
```

Becomes in Elixir:

```elixir
defmodule Agent.Types.Config do
  @moduledoc "Configuration for the agent loop"

  @type t :: %__MODULE__{
    model: Ai.Types.Model.t(),
    convert_to_llm: ([Agent.Message.t()] -> [Ai.Types.message()]),
    transform_context: (([Agent.Message.t()], pid() | nil) -> [Agent.Message.t()]) | nil,
    get_api_key: (String.t() -> String.t() | nil) | nil,
    get_steering_messages: (() -> [Agent.Message.t()]) | nil,
    get_follow_up_messages: (() -> [Agent.Message.t()]) | nil,
    stream_fn: Ai.Types.StreamOptions.t() | nil,
    reasoning: atom() | nil,
    thinking_budgets: map() | nil,
    session_id: String.t() | nil,
    temperature: float() | nil,
    max_tokens: non_neg_integer() | nil,
    api_key: String.t() | nil
  }

  defstruct [
    :model,
    :convert_to_llm,
    :transform_context,
    :get_api_key,
    :get_steering_messages,
    :get_follow_up_messages,
    :stream_fn,
    :reasoning,
    :thinking_budgets,
    :session_id,
    :temperature,
    :max_tokens,
    :api_key
  ]
end
```

---

## Complex Translation Areas

### 1. AbortSignal Cancellation

TypeScript's `AbortSignal` is a standard cancellation primitive. In Elixir, use:
- Task.shutdown/2 for brute force cancellation
- Message passing for cooperative cancellation
- Process.monitor for detecting parent death

### 2. Promise-based waitForIdle

The `waitForIdle()` method returns a promise that resolves when done. In Elixir:
- Store `GenServer.from()` references of waiting callers
- Reply to them when the loop completes
- Or use `Process.monitor` on the task

### 3. Partial Message Building

During streaming, the TypeScript code maintains a partial message:
```typescript
let partialMessage: AssistantMessage | null = null
for await (const event of response) {
  partialMessage = event.partial
  // Update in-place
}
```

In Elixir, pass the partial through the reduce/loop:
```elixir
Enum.reduce(events, nil, fn event, partial ->
  new_partial = update_partial(partial, event)
  # ...
  new_partial
end)
```

### 4. Tool Validation

TypeScript uses TypeBox for runtime validation:
```typescript
const validatedArgs = validateToolArguments(tool, toolCall)
```

In Elixir, options:
- Use `NimbleOptions` for simple cases
- Use `Ecto.Changeset` for complex validation
- Use `json_schema` library for JSON Schema validation
- Or defer to pi-ai's validation if already done there

---

## Implementation Order

1. **Types (`Agent.Types`)**
   - Define all structs first
   - Establish the `Agent.Message` protocol

2. **Message Protocol (`Agent.Message`)**
   - Protocol definition
   - Implementations for Ai types

3. **Loop Module (`Agent.Loop`)**
   - Pure function implementation
   - Returns EventStream like providers do
   - Can be tested independently

4. **Server (`Agent.Server`)**
   - GenServer with state management
   - Queue management (steering/follow-up)
   - Subscription handling
   - Task management

5. **Public API (`Agent`)**
   - Clean interface like the `Ai` module
   - Functions: `prompt/3`, `continue/2`, `steer/2`, `abort/1`, etc.

6. **Proxy Module (`Agent.Proxy`)**
   - Optional - only needed for server deployments

7. **Tests**
   - Port existing TypeScript tests
   - Property-based tests for loop logic

---

## Design Decisions Needed

| Decision | Options | Recommendation |
|----------|---------|----------------|
| Event distribution | Direct messages vs Registry vs PubSub | Direct messages for simplicity, Registry if fan-out needed |
| Custom messages | Protocol vs Tagged tuples | Protocol - matches TypeScript extensibility |
| Tool definition | Struct with fun vs Behaviour | Struct with execute function capture |
| Queue mode | All vs one-at-a-time | Support both as in original |
| Loop concurrency | Task per loop vs GenStage | Task per loop (simpler, matches ai app) |
| Error handling | Exceptions vs Tagged tuples | Tagged tuples throughout |

---

## Compatibility Notes

- The pi-ai Elixir port uses tagged tuples for events: `{:text_delta, idx, delta, partial}`
- This differs slightly from TypeScript's object style
- Agent events should follow the same pattern for consistency

---

## Estimated Effort

| Component | Lines (TS) | Complexity | Est. Lines (Elixir) |
|-----------|------------|------------|---------------------|
| Types | 195 | Low | ~150 |
| Message Protocol | - | Medium | ~100 |
| Server (GenServer) | 481 | Medium | ~400 |
| Loop | 418 | Medium | ~350 |
| Proxy | 341 | Low | ~200 |
| Tests | - | - | ~400 |
| **Total** | **~1,435** | | **~1,600** |

---

## References

- Original TypeScript: `~/dev/pi-mono/packages/agent/src/`
- Existing Elixir patterns: `~/dev/lemon/apps/ai/lib/ai/`
- EventStream implementation: `~/dev/lemon/apps/ai/lib/ai/event_stream.ex`
- Type definitions: `~/dev/lemon/apps/ai/lib/ai/types.ex`
