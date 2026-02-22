# AgentCore

Elixir library for building AI agents with multi-turn conversations, tool execution, and streaming events.

## Purpose and Responsibilities

AgentCore provides the runtime foundation for AI agents in the Lemon project:

- **Agent Runtime**: Stateful GenServer-based agents with lifecycle management
- **CLI Runners**: Subprocess wrappers for external AI engines (Claude, Codex, Kimi, OpenCode, Pi)
- **Subagent Spawning**: Supervised dynamic spawning of child agents
- **Event Streaming**: Async producer/consumer event streams for real-time UI updates
- **Context Management**: Message history, tool definitions, and conversation state
- **Abort Handling**: Cooperative cancellation signals for long-running operations

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  AgentCore                                                      │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐ │
│  │    Agent    │  │    Loop     │  │  EventStream / Types    │ │
│  │  (GenServer)│  │ (core logic)│  │  (events & structures)  │ │
│  └─────────────┘  └─────────────┘  └─────────────────────────┘ │
│         │                │                                       │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐ │
│  │   Registry  │  │ Supervisor  │  │  CLI Runners            │ │
│  │  (lookup)   │  │ (subagents) │  │  (external CLIs)        │ │
│  └─────────────┘  └─────────────┘  └─────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│  Ai Library (low-level LLM abstractions)                        │
└─────────────────────────────────────────────────────────────────┘
```

## Key Modules

### Core Agent

| Module | Purpose |
|--------|---------|
| `AgentCore` | Main API - delegates to Agent GenServer and Loop |
| `AgentCore.Agent` | GenServer for stateful agent management, subscriptions, queuing |
| `AgentCore.AgentRegistry` | Registry for agent lookup by `{session_id, role, index}` keys |
| `AgentCore.SubagentSupervisor` | DynamicSupervisor for spawning subagent processes |
| `AgentCore.Application` | OTP application with supervision tree |

### Loop and Execution

| Module | Purpose |
|--------|---------|
| `AgentCore.Loop` | Stateless agent loop: streaming, tool calls, steering |
| `AgentCore.Loop.Streaming` | LLM response streaming with content block handling |
| `AgentCore.Loop.ToolCalls` | Concurrent tool execution with result collection |

### Events and Context

| Module | Purpose |
|--------|---------|
| `AgentCore.EventStream` | Async event producer/consumer with backpressure |
| `AgentCore.Context` | Context window management and message transformation |
| `AgentCore.AbortSignal` | ETS-based abort signal coordination |
| `AgentCore.Proxy` | Stream proxy for event transformation |

### Types

| Module | Purpose |
|--------|---------|
| `AgentCore.Types` | Core structs: `AgentState`, `AgentContext`, `AgentTool`, `AgentLoopConfig` |
| `AgentCore.Types.AgentTool` | Tool definition with `execute/4` callback |
| `AgentCore.Types.AgentToolResult` | Result with content blocks and trust level |

### CLI Runners

| Module | Purpose |
|--------|---------|
| `AgentCore.CliRunners.JsonlRunner` | Base behaviour for JSONL-streaming CLI tools |
| `AgentCore.CliRunners.Types` | Unified event types: `ResumeToken`, `Action`, `StartedEvent`, etc. |
| `AgentCore.CliRunners.ToolActionHelpers` | Helpers for tool/action event translation |

### Engine-Specific Runners

Each engine has a runner, schema, and subagent module:

| Engine | Runner | Schema | Subagent |
|--------|--------|--------|----------|
| Claude | `claude_runner.ex` | `claude_schema.ex` | `claude_subagent.ex` |
| Codex | `codex_runner.ex` | `codex_schema.ex` | `codex_subagent.ex` |
| Kimi | `kimi_runner.ex` | `kimi_schema.ex` | `kimi_subagent.ex` |
| OpenCode | `opencode_runner.ex` | `opencode_schema.ex` | `opencode_subagent.ex` |
| Pi | `pi_runner.ex` | `pi_schema.ex` | `pi_subagent.ex` |

## Adding a New CLI Runner

To add support for a new AI CLI tool:

### 1. Create the Runner Module

```elixir
defmodule AgentCore.CliRunners.MyEngineRunner do
  @moduledoc "MyEngine CLI runner"
  
  use AgentCore.CliRunners.JsonlRunner
  
  alias AgentCore.CliRunners.Types.{EventFactory, ResumeToken}
  
  @engine "myengine"
  
  @impl true
  def engine, do: @engine
  
  @impl true
  def init_state(_prompt, _resume, cwd, _opts) do
    # Return initial state struct
    %{factory: EventFactory.new(@engine), last_text: nil}
  end
  
  @impl true
  def build_command(prompt, resume, _state) do
    base_args = ["--json", "--output-format", "jsonl"]
    
    args = if resume do
      base_args ++ ["--resume", resume.value]
    else
      base_args
    end
    
    args = args ++ ["--", prompt]
    {"myengine", args}
  end
  
  @impl true
  def decode_line(line) do
    # Parse JSONL line
    Jason.decode(line)
  end
  
  @impl true
  def translate_event(data, state) do
    case data do
      %{"type" => "init", "session_id" => session_id} ->
        token = ResumeToken.new(@engine, session_id)
        {started_event, factory} = EventFactory.started(state.factory, token)
        state = %{state | factory: factory}
        {[started_event], state, [found_session: token]}
        
      %{"type" => "text", "content" => text} ->
        state = %{state | last_text: text}
        {[], state, []}
        
      %{"type" => "done", "result" => result} ->
        {completed_event, factory} = EventFactory.completed_ok(
          state.factory,
          result || state.last_text || "",
          resume: state.factory.resume
        )
        state = %{state | factory: factory}
        {[completed_event], state, [done: true]}
        
      _ ->
        {[], state, []}
    end
  end
  
  @impl true
  def handle_exit_error(exit_code, state) do
    message = "myengine failed (rc=#{exit_code})"
    {event, factory} = EventFactory.completed_error(state.factory, message)
    {[event], %{state | factory: factory}}
  end
  
  @impl true
  def handle_stream_end(state) do
    {event, factory} = EventFactory.completed_error(
      state.factory,
      "myengine finished without result",
      resume: state.factory.resume
    )
    {[event], %{state | factory: factory}}
  end
end
```

### 2. Create the Schema Module (if needed)

Parse engine-specific JSON output:

```elixir
defmodule AgentCore.CliRunners.MyEngineSchema do
  @moduledoc "JSON decoding for MyEngine output"
  
  def decode_event(json) do
    case Jason.decode(json) do
      {:ok, %{"type" => "init"} = data} -> 
        {:ok, struct(StreamInitMessage, data)}
      {:ok, data} -> 
        {:ok, data}
      error -> 
        error
    end
  end
  
  defmodule StreamInitMessage do
    defstruct [:type, :session_id, :tools, :model]
  end
end
```

### 3. Create the Subagent Module

Wrap the runner as an AgentCore subagent:

```elixir
defmodule AgentCore.CliRunners.MyEngineSubagent do
  @moduledoc "MyEngine subagent integration"
  
  alias AgentCore.CliRunners.MyEngineRunner
  
  def run(prompt, opts \\ []) do
    resume = Keyword.get(opts, :resume)
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    
    {:ok, pid} = MyEngineRunner.start_link(
      prompt: prompt,
      resume: resume,
      cwd: cwd,
      owner: self()
    )
    
    stream = MyEngineRunner.stream(pid)
    
    # Process events
    MyEngineRunner.stream(pid)
    |> AgentCore.EventStream.events()
    |> Enum.to_list()
  end
end
```

### 4. Add Resume Token Support

Update `AgentCore.CliRunners.Types.ResumeToken`:

```elixir
# In extract_resume/1 patterns:
{~r/`?myengine\s+--resume\s+([a-zA-Z0-9_-]+)`?/i, "myengine"},

# In format/1:
"myengine" -> "`myengine --resume #{value}`"

# In is_resume_line/1 patterns:
~r/^`?myengine\s+--resume\s+[a-zA-Z0-9_-]+`?$/i,
```

## Subagent Spawning Patterns

### Basic Subagent Spawn

```elixir
# Spawn and wait
{:ok, pid} = AgentCore.SubagentSupervisor.start_subagent(
  model: model,
  system_prompt: "You are a research assistant",
  tools: tools
)

AgentCore.prompt(pid, "Research this topic")
:ok = AgentCore.wait_for_idle(pid)
state = AgentCore.get_state(pid)
AgentCore.SubagentSupervisor.stop_subagent(pid)
```

### Registered Subagent with Registry Key

```elixir
# Spawn with registry key for lookup
{:ok, pid} = AgentCore.SubagentSupervisor.start_subagent(
  registry_key: {session_id, :research, 0},
  model: model,
  system_prompt: "Research assistant"
)

# Look up later
{:ok, pid} = AgentCore.AgentRegistry.lookup({session_id, :research, 0})
```

### Subagent with Event Subscription

```elixir
{:ok, pid} = AgentCore.SubagentSupervisor.start_subagent(
  model: model,
  system_prompt: "Coding assistant"
)

# Subscribe parent to subagent events
unsubscribe = AgentCore.subscribe(pid, parent_pid)

AgentCore.prompt(pid, "Write a function")

# Receive events in parent
receive do
  {:agent_event, {:message_update, _msg, delta}} ->
    # Stream subagent output to UI
    send_ui_update(delta)
  {:agent_event, {:agent_end, _messages}} ->
    :done
end
```

### Concurrent Subagents

```elixir
tasks = for i <- 0..2 do
  Task.async(fn ->
    {:ok, pid} = AgentCore.SubagentSupervisor.start_subagent(
      registry_key: {session_id, :worker, i},
      model: model,
      system_prompt: "Parallel worker #{i}"
    )
    
    AgentCore.prompt(pid, "Process chunk #{i}")
    :ok = AgentCore.wait_for_idle(pid)
    
    state = AgentCore.get_state(pid)
    AgentCore.SubagentSupervisor.stop_subagent(pid)
    
    state.messages
  end)
end

results = Task.await_many(tasks)
```

## Event Streaming Usage

### Basic Stream Consumption

```elixir
{:ok, agent} = AgentCore.new_agent(model: model, system_prompt: "Helpful assistant")
AgentCore.subscribe(agent, self())

AgentCore.prompt(agent, "Hello!")

# Process all events
for event <- AgentCore.EventStream.events(stream) do
  case event do
    {:agent_start} ->
      IO.puts("Agent started")
      
    {:message_start, msg} ->
      IO.puts("Message started: #{msg.role}")
      
    {:message_update, _msg, delta} ->
      IO.write(delta)  # Streaming text
      
    {:message_end, msg} ->
      IO.puts("\nMessage complete")
      
    {:tool_execution_start, id, name, args} ->
      IO.puts("Tool: #{name}(#{inspect(args)})")
      
    {:tool_execution_end, id, name, result, is_error} ->
      IO.puts("Tool #{name} completed")
      
    {:turn_end, message, tool_results} ->
      IO.puts("Turn complete")
      
    {:agent_end, messages} ->
      IO.puts("Agent finished")
  end
end
```

### Using EventStream Directly

```elixir
# Create stream with custom options
{:ok, stream} = AgentCore.EventStream.start_link(
  owner: self(),
  max_queue: 1000,
  timeout: 60_000
)

# Producer pushes events
AgentCore.EventStream.push(stream, {:custom_event, data})

# Async push (fire-and-forget)
AgentCore.EventStream.push_async(stream, {:agent_start})

# Complete successfully
AgentCore.EventStream.complete(stream, final_messages)

# Error
AgentCore.EventStream.error(stream, :reason, partial_state)

# Cancel
AgentCore.EventStream.cancel(stream, :user_requested)

# Get final result
{:ok, messages} = AgentCore.EventStream.result(stream, 30_000)
```

### Stream Backpressure

```elixir
# Handle backpressure
case AgentCore.EventStream.push(stream, event) do
  :ok -> 
    :continue
  {:error, :overflow} ->
    # Queue full, pause production
    :pause
  {:error, :canceled} ->
    # Stream canceled, stop
    :stop
end
```

## Common Tasks and Examples

### Create a Simple Agent

```elixir
# Define a tool
read_tool = AgentCore.new_tool(
  name: "read_file",
  description: "Read file contents",
  parameters: %{
    "type" => "object",
    "properties" => %{
      "path" => %{"type" => "string"}
    },
    "required" => ["path"]
  },
  execute: fn _id, %{"path" => path}, _signal, _on_update ->
    case File.read(path) do
      {:ok, content} ->
        AgentCore.new_tool_result(
          content: [%Ai.Types.TextContent{text: content}]
        )
      {:error, reason} ->
        {:error, reason}
    end
  end
)

# Create agent
{:ok, agent} = AgentCore.new_agent(
  model: %{provider: :anthropic, id: "claude-3-5-sonnet-20241022"},
  system_prompt: "You are a helpful assistant",
  tools: [read_tool]
)

# Send prompt
:ok = AgentCore.prompt(agent, "Read the README.md file")
:ok = AgentCore.wait_for_idle(agent)
```

### Use the Loop Directly

```elixir
alias AgentCore.{Loop, Types}

context = Types.AgentContext.new(
  system_prompt: "You are helpful",
  messages: [],
  tools: tools
)

config = %Types.AgentLoopConfig{
  model: model,
  convert_to_llm: &MyConverter.to_llm/1,
  stream_options: %Ai.Types.StreamOptions{max_tokens: 4000}
}

user_msg = %Ai.Types.UserMessage{
  role: :user,
  content: "Hello!",
  timestamp: System.system_time(:millisecond)
}

# Stream events
Loop.stream([user_msg], context, config)
|> Enum.each(&IO.inspect/1)
```

### Steering Messages

```elixir
# Inject message mid-run (interrupts after current tool)
:ok = AgentCore.steer(agent, %Ai.Types.UserMessage{
  role: :user,
  content: "Actually, use a different approach",
  timestamp: System.system_time(:millisecond)
})

# Follow-up messages processed after agent would stop
:ok = AgentCore.follow_up(agent, %Ai.Types.UserMessage{
  role: :user,
  content: "Now summarize the results",
  timestamp: System.system_time(:millisecond)
})
```

### Abort Handling

```elixir
# Signal abort
:ok = AgentCore.abort(agent)

# Wait for graceful shutdown
:ok = AgentCore.wait_for_idle(agent, timeout: 10_000)

# In tools, check abort signal
execute: fn _id, params, signal, _on_update ->
  for i <- 1..100 do
    if AgentCore.AbortSignal.aborted?(signal) do
      throw(:aborted)
    end
    do_work(i)
  end
  
  AgentCore.new_tool_result(content: [...])
end
```

## Testing Guidance

### Running Tests

```bash
# All agent_core tests
mix test apps/agent_core

# Specific module
mix test apps/agent_core/test/agent_core/agent_test.exs

# CLI runner tests (requires external CLIs)
mix test apps/agent_core/test/agent_core/cli_runners/claude_integration_test.exs --include integration
```

### Test Structure

```
apps/agent_core/test/
├── agent_core_test.exs              # Main API tests
├── agent_core/
│   ├── agent_test.exs               # Agent GenServer tests
│   ├── agent_queue_test.exs         # Steering/follow-up queue tests
│   ├── loop_test.exs                # Core loop tests
│   ├── event_stream_test.exs        # Event streaming tests
│   ├── abort_signal_test.exs        # Abort signal tests
│   ├── context_test.exs             # Context management tests
│   └── cli_runners/
│       ├── jsonl_runner_test.exs    # Base runner tests
│       ├── claude_runner_test.exs   # Claude-specific tests
│       └── codex_runner_test.exs    # Codex-specific tests
└── subagent_supervisor_test.exs     # Subagent supervision tests
```

### Writing Tests

```elixir
defmodule AgentCore.MyFeatureTest do
  use ExUnit.Case, async: true
  
  alias AgentCore.Types
  
  # Use mocks for LLM calls
  import AgentCore.TestSupport.Mocks
  
  setup do
    {:ok, agent} = AgentCore.new_agent(
      model: %{provider: :mock, id: "test"},
      system_prompt: "Test"
    )
    
    %{agent: agent}
  end
  
  test "handles streaming events", %{agent: agent} do
    AgentCore.subscribe(agent, self())
    AgentCore.prompt(agent, "Test")
    
    assert_receive {:agent_event, {:agent_start}}, 1000
    assert_receive {:agent_event, {:agent_end, _messages}}, 5000
  end
end
```

### Integration Test Tagging

Tests requiring external CLIs are tagged with `@tag :integration`:

```elixir
@tag :integration
test "runs real Claude session" do
  # This test only runs with: mix test --include integration
end
```

## Key Design Patterns

1. **Separation of Concerns**: `Loop` is stateless logic; `Agent` is stateful GenServer
2. **Event-Driven**: All execution emits events for UI/observability
3. **Cooperative Abort**: Abort signals are checked, not forced
4. **Session Locking**: CLI runners use ETS locks for session consistency
5. **Registry Pattern**: Agents can be looked up by structured keys
6. **Backpressure**: EventStream returns `:ok | {:error, :overflow}`

## Dependencies

- `ai` - Low-level LLM API abstractions
- `lemon_core` - Shared primitives and telemetry
- `req` - HTTP client
- `jason` - JSON encoding/decoding
