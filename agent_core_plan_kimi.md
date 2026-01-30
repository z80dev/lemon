# Pi-Agent-Core Port Analysis

## Overview

This document outlines the plan for porting `pi-agent-core` from TypeScript to Elixir as part of the `lemon` umbrella application. The port depends on the already-completed `ai` app (pi-ai port).

---

## Source Structure (TypeScript)

```
packages/agent/src/
├── index.ts          # Re-exports
├── types.ts          # AgentMessage, AgentTool, AgentEvent, AgentLoopConfig
├── agent.ts          # Agent class (orchestrator, state, events)
├── agent-loop.ts     # Core loop (streaming, tool execution, steering)
└── proxy.ts          # Backend proxy streaming
```

**Package:** `@mariozechner/pi-agent-core` v0.50.2
**Location:** `/home/z80/dev/pi-mono/packages/agent`

---

## Target Structure (Elixir)

```
apps/agent/
├── lib/agent/
│   ├── agent.ex              # Main facade module
│   ├── types.ex              # AgentMessage, AgentTool, AgentEvent, etc.
│   ├── agent_server.ex       # GenServer for stateful agent (replaces Agent class)
│   ├── agent_loop.ex         # Core loop logic
│   ├── proxy.ex              # Proxy streaming (optional)
│   └── application.ex        # OTP Application
├── test/
└── mix.exs
```

---

## Key Mapping: TypeScript → Elixir

| TypeScript Concept | Elixir Equivalent |
|--------------------|-------------------|
| `Agent` class with state | `GenServer` with state struct |
| `agentLoop()` async generator | Process + `Ai.EventStream` |
| `EventEmitter` pattern | `GenServer` callbacks + subscriptions |
| `AbortSignal` | Process monitoring + `Process.exit/2` |
| Declaration merging for types | Behaviours + protocol extensions |
| `Promise<T>` | `{:ok, T} \| {:error, reason}` or `Task` |
| Mutable state updates | Functional state updates in GenServer |

---

## TypeScript Architecture Summary

### Agent Class (`agent.ts`)

High-level orchestrator for agent conversations.

**Responsibilities:**
- State management (system prompt, model, tools, messages, thinking level)
- Message queueing (user prompts, steering messages, follow-up messages)
- Event emission for UI updates
- Control flow (abort, wait for idle, reset)
- Session ID and API key management

**Core Methods:**
- `prompt(message, images?)` - Send new message to LLM
- `continue()` - Resume from current context
- `setSystemPrompt()`, `setModel()`, `setThinkingLevel()`, `setTools()` - State mutation
- `steer(message)` - Queue interruption message while agent is running tools
- `followUp(message)` - Queue message to process after agent finishes
- `subscribe(listener)` - Listen for agent events
- `abort()` - Cancel current operation
- `reset()` - Clear all state

**Internal State:**
```typescript
interface AgentState {
  systemPrompt: string;
  model: Model<any>;
  thinkingLevel: "off" | "minimal" | "low" | "medium" | "high" | "xhigh";
  tools: AgentTool<any>[];
  messages: AgentMessage[];
  isStreaming: boolean;
  streamMessage: AgentMessage | null;
  pendingToolCalls: Set<string>;
  error?: string;
}
```

### Agent Loop (`agent-loop.ts`)

Core state machine for multi-turn agent execution.

**Architecture:**
```
Outer Loop: Handles follow-up messages
  └─ Inner Loop: Processes tool calls and steering messages
      ├─ streamAssistantResponse()   // Get LLM response
      ├─ executeToolCalls()          // Run tool functions
      └─ Check for steering messages // Allow interruption
```

**Key Functions:**
- `agentLoop(prompts, context, config, signal, streamFn)` - Start new conversation
- `agentLoopContinue(context, config, signal, streamFn)` - Continue from existing context

**Message Flow:**
```
AgentMessage[]
  ↓ transformContext() [optional]
AgentMessage[]
  ↓ convertToLlm() [required]
Message[]
  ↓ streamSimple()
LLM
  ↓
AssistantMessageEventStream
```

### Types (`types.ts`)

**AgentMessage:**
- Union of LLM messages (user, assistant, toolResult) + custom app types
- Extensible via TypeScript declaration merging

**AgentTool:**
```typescript
interface AgentTool<TParameters, TDetails = any> {
  name: string;
  label: string;           // For UI display
  description: string;
  parameters: TParameters;  // JSON Schema
  execute(
    toolCallId: string,
    params: Static<TParameters>,
    signal?: AbortSignal,
    onUpdate?: AgentToolUpdateCallback<TDetails>,
  ): Promise<AgentToolResult<TDetails>>;
}
```

**AgentEvent (Union Type):**
- `agent_start` / `agent_end`
- `turn_start` / `turn_end`
- `message_start` / `message_update` / `message_end`
- `tool_execution_start` / `tool_execution_update` / `tool_execution_end`

### Proxy Streaming (`proxy.ts`)

Client-side proxy for backend LLM routing:
- Sends requests to `/api/stream` endpoint
- Reconstructs partial messages from delta events
- Reduces bandwidth by stripping redundant partial fields

---

## Dependencies on pi-ai

**Core Types Imported:**
- `Model<TApi>` - LLM provider/model configuration
- `Message` types: `UserMessage`, `AssistantMessage`, `ToolResultMessage`
- `Tool<TParameters>` - Base tool interface
- `Context` - LLM context (systemPrompt, messages, tools)
- `AssistantMessageEvent` - Streaming event types
- `streamSimple()` - Stream function for unified LLM API
- `EventStream<T, R>` - Generic async iterable event stream
- `validateToolArguments()` - Tool parameter validation

**Note:** `@mariozechner/pi-tui` is listed as a dependency but **not used** anywhere in the source.

---

## Elixir Implementation Design

### 1. Agent.Types (~200 lines)

```elixir
defmodule Agent.Types do
  # AgentMessage - union type via tagged tuples
  @type agent_message ::
    Ai.Types.UserMessage.t() |
    Ai.Types.AssistantMessage.t() |
    Ai.Types.ToolResultMessage.t() |
    custom_message()

  @type custom_message :: %{
    role: atom(),  # :notification, :artifact, etc.
    # ... custom fields
  }

  # AgentTool - extends Ai.Types.Tool with execute callback
  defmodule AgentTool do
    @type t :: %__MODULE__{
      name: String.t(),
      label: String.t(),           # UI display name
      description: String.t(),
      parameters: map(),           # JSON Schema
      execute: execute_fn()
    }

    @type execute_fn ::
      (tool_call_id :: String.t(),
       params :: map(),
       opts :: keyword()) ->
        {:ok, AgentToolResult.t()} | {:error, term()}

    defstruct [:name, :label, :description, :parameters, :execute]
  end

  # AgentToolResult
  defmodule AgentToolResult do
    @type t :: %__MODULE__{
      content: [Ai.Types.TextContent.t() | Ai.Types.ImageContent.t()],
      details: map()
    }
    defstruct content: [], details: %{}
  end

  # AgentEvent - tagged tuples for event stream
  @type agent_event ::
    {:agent_start} |
    {:agent_end, [agent_message()]} |
    {:turn_start} |
    {:turn_end} |
    {:message_start, agent_message()} |
    {:message_update, agent_message()} |
    {:message_end, agent_message()} |
    {:tool_execution_start, String.t(), String.t(), map()} |
    {:tool_execution_update, String.t(), term()} |
    {:tool_execution_end, String.t(), AgentToolResult.t()}

  # AgentState
  defmodule AgentState do
    @type t :: %__MODULE__{
      system_prompt: String.t(),
      model: Ai.Types.Model.t(),
      thinking_level: thinking_level(),
      tools: [AgentTool.t()],
      messages: [agent_message()],
      is_streaming: boolean(),
      stream_message: agent_message() | nil,
      pending_tool_calls: MapSet.t(String.t()),
      error: String.t() | nil
    }

    @type thinking_level :: :off | :minimal | :low | :medium | :high | :xhigh

    defstruct [
      system_prompt: "",
      model: nil,
      thinking_level: :off,
      tools: [],
      messages: [],
      is_streaming: false,
      stream_message: nil,
      pending_tool_calls: MapSet.new(),
      error: nil
    ]
  end
end
```

### 2. Agent.Server (GenServer - ~300 lines)

Replaces the TypeScript `Agent` class:

```elixir
defmodule Agent.Server do
  use GenServer

  alias Agent.Types.{AgentState, AgentTool}
  alias Agent.Loop

  # Client API
  def start_link(opts \\ [])
  def prompt(agent, message, opts \\ [])
  def continue(agent)
  def steer(agent, message)
  def follow_up(agent, message)
  def abort(agent)
  def reset(agent)
  def subscribe(agent, callback)
  def get_state(agent)

  # Setters
  def set_system_prompt(agent, prompt)
  def set_model(agent, model)
  def set_tools(agent, tools)
  def set_thinking_level(agent, level)

  # GenServer callbacks
  @impl true
  def init(opts) do
    state = %{
      agent_state: struct(AgentState, opts[:initial_state] || %{}),
      subscribers: [],
      steering_queue: :queue.new(),
      follow_up_queue: :queue.new(),
      current_task: nil,
      convert_to_llm: opts[:convert_to_llm] || &default_convert/1,
      transform_context: opts[:transform_context],
      steering_mode: opts[:steering_mode] || :one_at_a_time,
      follow_up_mode: opts[:follow_up_mode] || :one_at_a_time,
      stream_fn: opts[:stream_fn],
      session_id: opts[:session_id],
      get_api_key: opts[:get_api_key],
      thinking_budgets: opts[:thinking_budgets]
    }
    {:ok, state}
  end

  @impl true
  def handle_call({:prompt, message, opts}, _from, state) do
    # Start agent loop in separate process
    # Return event stream to caller
  end

  @impl true
  def handle_call({:steer, message}, _from, state) do
    # Add to steering queue
    state = %{state | steering_queue: :queue.in(message, state.steering_queue)}
    {:reply, :ok, state}
  end

  # Event emission to subscribers
  defp emit(state, event) do
    for sub <- state.subscribers, do: send(sub, {:agent_event, event})
    state
  end
end
```

### 3. Agent.Loop (~400 lines)

Core loop logic - the heart of the agent:

```elixir
defmodule Agent.Loop do
  @moduledoc """
  Core agent loop state machine.

  Outer loop: handles follow-up messages
    Inner loop: processes tool calls and steering messages
      - Stream assistant response
      - Execute tool calls
      - Check for steering messages
  """

  alias Ai.EventStream
  alias Agent.Types.{AgentTool, AgentToolResult}

  defmodule Config do
    @type t :: %__MODULE__{
      model: Ai.Types.Model.t(),
      convert_to_llm: (list() -> list()),
      transform_context: (list() -> list()) | nil,
      get_api_key: (String.t() -> String.t() | nil) | nil,
      get_steering_messages: (() -> list()) | nil,
      get_follow_up_messages: (() -> list()) | nil,
      tools: [AgentTool.t()],
      stream_options: Ai.Types.StreamOptions.t()
    }
    defstruct [:model, :convert_to_llm, :transform_context,
               :get_api_key, :get_steering_messages, :get_follow_up_messages,
               :tools, :stream_options]
  end

  @doc """
  Start agent loop with initial prompts.
  Returns an EventStream that emits AgentEvents.
  """
  @spec run(prompts :: list(), messages :: list(), Config.t()) ::
    {:ok, EventStream.t()}
  def run(prompts, messages, config) do
    {:ok, stream} = EventStream.start_link()

    Task.start(fn ->
      try do
        EventStream.push(stream, {:agent_start})

        # Add prompts as messages
        messages = add_prompts_to_messages(messages, prompts, stream)

        # Run the loop
        final_messages = do_loop(messages, config, stream)

        EventStream.push(stream, {:agent_end, final_messages})
        EventStream.complete(stream, final_messages)
      rescue
        e ->
          EventStream.push(stream, {:error, Exception.message(e)})
          EventStream.error(stream, e)
      end
    end)

    {:ok, stream}
  end

  defp do_loop(messages, config, stream) do
    # Outer loop: follow-up messages
    case run_turn(messages, config, stream) do
      {:continue, messages} ->
        case get_follow_ups(config) do
          [] -> messages
          follow_ups ->
            messages = add_messages(messages, follow_ups, stream)
            do_loop(messages, config, stream)
        end

      {:done, messages} ->
        messages
    end
  end

  defp run_turn(messages, config, stream) do
    EventStream.push(stream, {:turn_start})

    # Transform context (optional pruning, injection)
    context_messages = transform_context(messages, config)

    # Convert to LLM format (filter custom message types)
    llm_messages = config.convert_to_llm.(context_messages)

    # Build context and stream
    context = build_context(config, llm_messages)
    {:ok, llm_stream} = Ai.stream(config.model, context, config.stream_options)

    # Process stream, emit events
    assistant_message = stream_response(llm_stream, stream)
    messages = messages ++ [assistant_message]

    # Execute tool calls
    case Ai.get_tool_calls(assistant_message) do
      [] ->
        EventStream.push(stream, {:turn_end})
        {:done, messages}

      tool_calls ->
        {messages, steering?} = execute_tools(tool_calls, messages, config, stream)
        EventStream.push(stream, {:turn_end})

        if steering? do
          run_turn(messages, config, stream)
        else
          {:continue, messages}
        end
    end
  end

  defp execute_tools(tool_calls, messages, config, stream) do
    Enum.reduce_while(tool_calls, {messages, false}, fn tc, {msgs, _} ->
      case get_steering(config) do
        nil ->
          result = execute_single_tool(tc, config, stream)
          tool_result_msg = build_tool_result_message(tc, result)
          {:cont, {msgs ++ [tool_result_msg], false}}

        steering_msgs ->
          msgs = add_messages(msgs, steering_msgs, stream)
          {:halt, {msgs, true}}
      end
    end)
  end

  defp execute_single_tool(tool_call, config, stream) do
    tool = find_tool(config.tools, tool_call.name)

    EventStream.push(stream, {:tool_execution_start,
                               tool_call.id, tool_call.name, tool_call.arguments})

    update_fn = fn details ->
      EventStream.push(stream, {:tool_execution_update, tool_call.id, details})
    end

    result = case tool.execute.(tool_call.id, tool_call.arguments, on_update: update_fn) do
      {:ok, result} -> result
      {:error, reason} -> %AgentToolResult{content: [%{type: :text, text: "Error: #{reason}"}], details: %{is_error: true}}
    end

    EventStream.push(stream, {:tool_execution_end, tool_call.id, result})
    result
  end
end
```

### 4. Agent.Proxy (~150 lines, optional)

For backend routing:

```elixir
defmodule Agent.Proxy do
  @moduledoc """
  Proxy streaming through backend server.
  Reduces bandwidth by reconstructing partial messages client-side.
  """

  def stream(model, context, opts) do
    url = opts[:proxy_url] || raise "proxy_url required"
    auth_token = opts[:auth_token]

    {:ok, stream} = Ai.EventStream.start_link()

    Task.start(fn ->
      body = Jason.encode!(%{
        model: model.id,
        context: serialize_context(context),
        options: serialize_options(opts)
      })

      Req.post!(url <> "/api/stream",
        body: body,
        headers: [{"authorization", "Bearer #{auth_token}"}],
        into: fn {:data, chunk}, acc ->
          handle_chunk(chunk, stream, acc)
        end
      )

      EventStream.complete(stream, :ok)
    end)

    {:ok, stream}
  end

  defp handle_chunk(chunk, stream, acc) do
    # Parse SSE events
    # Reconstruct partial messages from deltas
    # Push events to stream
    # Return updated accumulator
  end
end
```

### 5. Main Facade (`agent.ex`)

```elixir
defmodule Agent do
  @moduledoc """
  High-level API for agent interactions.
  """

  alias Agent.{Server, Loop, Types}

  defdelegate start_link(opts), to: Server
  defdelegate prompt(agent, message, opts \\ []), to: Server
  defdelegate continue(agent), to: Server
  defdelegate steer(agent, message), to: Server
  defdelegate follow_up(agent, message), to: Server
  defdelegate abort(agent), to: Server
  defdelegate reset(agent), to: Server
  defdelegate subscribe(agent, callback), to: Server
  defdelegate get_state(agent), to: Server

  defdelegate set_system_prompt(agent, prompt), to: Server
  defdelegate set_model(agent, model), to: Server
  defdelegate set_tools(agent, tools), to: Server
  defdelegate set_thinking_level(agent, level), to: Server

  # Convenience for one-shot agent runs
  def run(prompts, opts) do
    config = %Loop.Config{
      model: opts[:model],
      tools: opts[:tools] || [],
      convert_to_llm: opts[:convert_to_llm] || &default_convert/1,
      transform_context: opts[:transform_context],
      stream_options: build_stream_options(opts)
    }

    Loop.run(prompts, [], config)
  end

  defp default_convert(messages) do
    Enum.filter(messages, fn msg ->
      msg.role in [:user, :assistant, :tool_result]
    end)
  end
end
```

---

## Dependencies

The port depends on the `ai` app (already ported):

- `Ai.stream/3` - LLM streaming
- `Ai.EventStream` - Async event delivery
- `Ai.Types.*` - Message, Model, Tool, Context types
- `Ai.get_tool_calls/1`, `Ai.get_text/1` - Message helpers

**mix.exs:**
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
      elixir: "~> 1.17",
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
      {:req, "~> 0.5"},   # HTTP client (if proxy needed)
      {:jason, "~> 1.4"}  # JSON (already a dep)
    ]
  end
end
```

---

## Implementation Phases

### Phase 1: Types (~1 day)
- Define `Agent.Types` module with all structs
- `AgentTool`, `AgentToolResult`, `AgentState`, `AgentEvent`
- Type specs for all public functions

### Phase 2: Agent Loop (~2-3 days)
- Core loop logic in `Agent.Loop`
- Tool execution with streaming updates
- Steering and follow-up message handling
- Integration with `Ai.EventStream`
- Error handling and propagation

### Phase 3: Agent Server (~2 days)
- GenServer wrapping the loop
- State management (tools, model, messages)
- Subscription/event emission
- Abort/reset functionality
- Queue management for steering/follow-up

### Phase 4: Proxy (~1 day, if needed)
- HTTP streaming client
- SSE parsing and event reconstruction
- Backend integration

### Phase 5: Testing (~1-2 days)
- Unit tests for types and loop logic
- Integration tests with mock LLM responses
- End-to-end tests with real providers

---

## Key Considerations

### 1. Supervision Strategy

The `Agent.Server` should be supervised. Options:
- **DynamicSupervisor** for on-demand agents (per-request)
- **Registry** for named agent lookup
- Simple supervision for long-lived agents

### 2. Steering/Follow-up Modes

TypeScript has `"one-at-a-time"` vs `"all"` modes:
- `:one_at_a_time` - Process one message per turn
- `:all` - Process all queued messages together

Implement as config options in `Agent.Server`.

### 3. Tool Parameter Validation

Options:
- Port the JSON Schema validation from pi-ai
- Use `ExJsonSchema` library
- Simple map validation for MVP

### 4. Abort Handling

Elixir approach:
- Monitor the loop Task from GenServer
- On abort, call `Task.shutdown/2`
- Clean up partial state
- Emit error event to subscribers

### 5. Custom Message Types

Unlike TypeScript's declaration merging, Elixir options:
- Open union types (any map with `:role` key)
- Behaviour for custom message handlers
- Protocol for message conversion

Recommend: Open union with `:role` key pattern matching.

---

## Testing Strategy

### Unit Tests
- `Agent.Types` struct creation and validation
- `Agent.Loop` logic with mock streams
- Message conversion functions

### Integration Tests
- Full loop with mock LLM provider
- Tool execution flow
- Steering interruption
- Follow-up message processing

### E2E Tests (tagged `:integration`)
- Real provider calls
- Multi-turn conversations
- Complex tool scenarios

---

## Open Questions

1. **Should `Agent.Server` use Registry for named lookup?**
   - Depends on usage patterns (per-request vs long-lived)

2. **How to handle thinking budgets?**
   - Pass through to `Ai.stream/3` options

3. **Should proxy be a separate app?**
   - Probably not for initial port; can extract later

4. **Custom message type extensibility?**
   - Start with open union, add protocols if needed

---

## References

### Source Files
- `/home/z80/dev/pi-mono/packages/agent/src/agent.ts`
- `/home/z80/dev/pi-mono/packages/agent/src/agent-loop.ts`
- `/home/z80/dev/pi-mono/packages/agent/src/types.ts`
- `/home/z80/dev/pi-mono/packages/agent/src/proxy.ts`
- `/home/z80/dev/pi-mono/packages/agent/README.md`

### Existing Elixir Patterns
- `/home/z80/dev/lemon/apps/ai/lib/ai/event_stream.ex`
- `/home/z80/dev/lemon/apps/ai/lib/ai/types.ex`
- `/home/z80/dev/lemon/apps/ai/lib/ai/provider.ex`
