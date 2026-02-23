# AgentCore

Elixir library for building AI agents with multi-turn conversations, tool execution, and streaming events.

## Purpose and Responsibilities

AgentCore provides the runtime foundation for AI agents in the Lemon project:

- **Agent Runtime**: Stateful GenServer-based agents with lifecycle management
- **CLI Runners**: Subprocess wrappers for external AI engines (Claude, Codex, Kimi, OpenCode, Pi)
- **Subagent Spawning**: Supervised dynamic spawning of child agents
- **Event Streaming**: Async producer/consumer event streams for real-time UI updates
- **Context Management**: Message history sizing, truncation, and token estimation
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

## Supervision Tree

```
AgentCore.Supervisor (:one_for_one)
├── AgentCore.AbortSignal.TableOwner  (owns the abort ETS table)
├── AgentCore.AgentRegistry           (Registry, :unique keys)
├── AgentCore.SubagentSupervisor      (DynamicSupervisor)
├── AgentCore.LoopTaskSupervisor      (Task.Supervisor for loop tasks)
└── AgentCore.ToolTaskSupervisor      (Task.Supervisor for tool execution)
```

## Key Modules

### Core Agent

| Module | Purpose |
|--------|---------|
| `AgentCore` | Main API - convenience wrappers, `new_agent/1`, `new_tool/1`, `new_tool_result/1`, `text_content/1`, `image_content/2`, `get_text/1`, `agent_loop/4`, `agent_loop_continue/3` |
| `AgentCore.Agent` | GenServer for stateful agent management, subscriptions, steering/follow-up queues |
| `AgentCore.AgentRegistry` | Registry wrapper for agent lookup by `{session_id, role, index}` keys |
| `AgentCore.SubagentSupervisor` | DynamicSupervisor for spawning subagent processes (`:temporary` children) |
| `AgentCore.Application` | OTP application with supervision tree |

### Loop and Execution

| Module | Purpose |
|--------|---------|
| `AgentCore.Loop` | Stateless agent loop: `agent_loop/6`, `agent_loop_continue/5`, `stream/4`, `stream_continue/3` |
| `AgentCore.Loop.Streaming` | LLM response streaming with content block handling |
| `AgentCore.Loop.ToolCalls` | Concurrent tool execution with result collection |

### Events and Context

| Module | Purpose |
|--------|---------|
| `AgentCore.EventStream` | Async event producer/consumer with backpressure, owner monitoring, task linking |
| `AgentCore.Context` | Context size estimation, truncation, and `make_transform/1` for `AgentLoopConfig` |
| `AgentCore.AbortSignal` | ETS-based abort signal coordination (`new/0`, `abort/1`, `aborted?/1`, `clear/1`) |
| `AgentCore.Proxy` | SSE proxy stream function for routing LLM calls through a server |
| `AgentCore.TextGeneration` | Shared helper to run simple provider/model/prompt text completions for umbrella callers while keeping direct `Ai.*` usage inside `agent_core` |

### Types

| Module | Purpose |
|--------|---------|
| `AgentCore.Types` | Core types: `AgentState`, `AgentContext`, `AgentTool`, `AgentLoopConfig`, `agent_event()` |
| `AgentCore.Types.AgentTool` | Tool definition with `execute/4` callback |
| `AgentCore.Types.AgentToolResult` | Result with content blocks, details, and trust level |
| `AgentCore.Types.AgentLoopConfig` | Loop config: model, convert_to_llm, transform_context, get_api_key, max_tool_concurrency, stream_fn |

### CLI Runners

| Module | Purpose |
|--------|---------|
| `AgentCore.CliRunners.JsonlRunner` | Base `use` macro and GenServer for JSONL-streaming CLI subprocesses |
| `AgentCore.CliRunners.Types` | Event types: `ResumeToken`, `Action`, `StartedEvent`, `ActionEvent`, `CompletedEvent`, `EventFactory` |
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

## AgentCore.Agent - Full API

Beyond what `AgentCore` delegates, `AgentCore.Agent` exposes:

**Lifecycle:**
- `start_link(opts)` - Start the GenServer
- `prompt(agent, message)` - Start a run; returns `{:error, :already_streaming}` if busy
- `continue(agent)` - Continue from existing context (retry/after tool results)
- `abort(agent)` - Send abort signal (async, cooperative)
- `wait_for_idle(agent, opts \\ [])` - Block until idle; accepts `timeout:` option
- `reset(agent)` - Clear messages, queues, and error state

**Subscriptions:**
- `subscribe(agent, pid)` - Returns an unsubscribe function; subscriber gets `{:agent_event, event}` messages

**Steering and Follow-up:**
- `steer(agent, message)` - Inject message mid-run (delivered after current tool batch, skipping remaining tools)
- `follow_up(agent, message)` - Queue message for after the agent would naturally stop
- `clear_steering_queue(agent)` / `clear_follow_up_queue(agent)` / `clear_all_queues(agent)`
- `set_steering_mode(agent, :all | :one_at_a_time)` - Default: `:one_at_a_time`
- `set_follow_up_mode(agent, :all | :one_at_a_time)` - Default: `:one_at_a_time`

**State Mutators (callable while idle):**
- `set_system_prompt(agent, prompt)` / `set_model(agent, model)` / `set_thinking_level(agent, level)`
- `set_tools(agent, tools)` / `replace_messages(agent, messages)` / `append_message(agent, message)`
- `set_session_id(agent, id)` / `get_session_id(agent)`

**Getters:**
- `get_state(agent)` - Returns `AgentState` struct with `messages`, `tools`, `is_streaming`, `error`, etc.
- `get_steering_mode(agent)` / `get_follow_up_mode(agent)`

**Note:** `steer/2` and `follow_up/2` are on `AgentCore.Agent`, not on the top-level `AgentCore` module.

## AgentLoopConfig Fields

```elixir
%AgentCore.Types.AgentLoopConfig{
  # Required
  model: my_model,
  convert_to_llm: fn messages -> {:ok, llm_messages} end,

  # Optional
  transform_context: fn messages, signal -> {:ok, transformed} end,
  get_api_key: fn provider -> api_key end,
  get_steering_messages: fn -> [] end,
  get_follow_up_messages: fn -> [] end,
  max_tool_concurrency: nil,   # nil/:infinity = unbounded, or pos_integer
  stream_options: %Ai.Types.StreamOptions{},
  stream_fn: nil               # custom stream function, defaults to Ai.stream_simple/3
}
```

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

### 2. Add Resume Token Support

Update `AgentCore.CliRunners.Types.ResumeToken`:

```elixir
# In extract_resume/1 patterns:
{~r/`?myengine\s+--resume\s+([a-zA-Z0-9_-]+)`?/i, "myengine"},

# In format/1:
"myengine" -> "`myengine --resume #{value}`"

# In is_resume_line/1 patterns:
~r/^`?myengine\s+--resume\s+[a-zA-Z0-9_-]+`?$/i,
```

### 3. CLI Runner Event Format

CLI runner events are wrapped before being pushed to the EventStream:

```elixir
{:cli_event, %StartedEvent{...}}
{:cli_event, %ActionEvent{...}}
{:cli_event, %CompletedEvent{...}}
```

Consumers receive `{:cli_event, event}` tuples when iterating `EventStream.events/1`.

## Subagent Spawning Patterns

### Basic Subagent Spawn

```elixir
{:ok, pid} = AgentCore.SubagentSupervisor.start_subagent(
  model: model,
  system_prompt: "You are a research assistant",
  tools: tools,
  convert_to_llm: &MyApp.convert/1
)

AgentCore.Agent.prompt(pid, "Research this topic")
:ok = AgentCore.Agent.wait_for_idle(pid)
state = AgentCore.Agent.get_state(pid)
AgentCore.SubagentSupervisor.stop_subagent(pid)
```

### Registered Subagent with Registry Key

```elixir
{:ok, pid} = AgentCore.SubagentSupervisor.start_subagent(
  registry_key: {session_id, :research, 0},
  model: model,
  system_prompt: "Research assistant",
  convert_to_llm: &MyApp.convert/1
)

# Look up later
{:ok, pid} = AgentCore.AgentRegistry.lookup({session_id, :research, 0})
```

### Subagent with Event Subscription

```elixir
{:ok, pid} = AgentCore.SubagentSupervisor.start_subagent(
  model: model,
  system_prompt: "Coding assistant",
  convert_to_llm: &MyApp.convert/1
)

unsubscribe = AgentCore.Agent.subscribe(pid, self())
AgentCore.Agent.prompt(pid, "Write a function")

receive do
  {:agent_event, {:message_update, _msg, delta}} ->
    send_ui_update(delta)
  {:agent_event, {:agent_end, _messages}} ->
    :done
end

unsubscribe.()
```

### Concurrent Subagents

```elixir
tasks = for i <- 0..2 do
  Task.async(fn ->
    {:ok, pid} = AgentCore.SubagentSupervisor.start_subagent(
      registry_key: {session_id, :worker, i},
      model: model,
      system_prompt: "Parallel worker #{i}",
      convert_to_llm: &MyApp.convert/1
    )

    AgentCore.Agent.prompt(pid, "Process chunk #{i}")
    :ok = AgentCore.Agent.wait_for_idle(pid)
    state = AgentCore.Agent.get_state(pid)
    AgentCore.SubagentSupervisor.stop_subagent(pid)
    state.messages
  end)
end

results = Task.await_many(tasks)
```

## Event Streaming Usage

### Basic Stream Consumption

```elixir
{:ok, agent} = AgentCore.new_agent(
  model: model,
  system_prompt: "Helpful assistant",
  convert_to_llm: &MyApp.convert/1
)
AgentCore.subscribe(agent, self())
AgentCore.prompt(agent, "Hello!")

# Receive events as messages
receive do
  {:agent_event, {:agent_start}} -> IO.puts("Agent started")
  {:agent_event, {:message_update, _msg, delta}} -> IO.write(delta)
  {:agent_event, {:agent_end, messages}} -> IO.puts("Done")
end
```

### Events Reference

```elixir
{:agent_start}
{:turn_start}
{:message_start, message}
{:message_update, message, assistant_event}   # streaming text delta
{:message_end, message}
{:tool_execution_start, id, name, args}
{:tool_execution_update, id, name, args, partial_result}
{:tool_execution_end, id, name, result, is_error}
{:turn_end, message, tool_results}
{:agent_end, new_messages}                     # terminal
{:error, reason, partial_state}                # terminal
{:canceled, reason}                            # terminal
```

`new_messages` in `{:agent_end, ...}` contains only messages from the current run, not the full history.

### Using EventStream Directly

```elixir
{:ok, stream} = AgentCore.EventStream.start_link(
  owner: self(),
  max_queue: 1000,
  timeout: 60_000
)

AgentCore.EventStream.push(stream, {:custom_event, data})
AgentCore.EventStream.push_async(stream, {:agent_start})
AgentCore.EventStream.complete(stream, final_messages)
AgentCore.EventStream.error(stream, :reason, partial_state)
AgentCore.EventStream.cancel(stream, :user_requested)

{:ok, messages} = AgentCore.EventStream.result(stream, 30_000)
%{queue_size: n, max_queue: m, dropped: d} = AgentCore.EventStream.stats(stream)
```

### Stream Backpressure

```elixir
case AgentCore.EventStream.push(stream, event) do
  :ok -> :continue
  {:error, :overflow} -> :pause   # queue full (with :error drop_strategy)
  {:error, :canceled} -> :stop
end
```

Drop strategies: `:error` (default, returns `{:error, :overflow}`), `:drop_oldest`, `:drop_newest`.

## Common Tasks and Examples

### Create a Simple Agent

```elixir
read_tool = AgentCore.new_tool(
  name: "read_file",
  description: "Read file contents",
  parameters: %{
    "type" => "object",
    "properties" => %{"path" => %{"type" => "string"}},
    "required" => ["path"]
  },
  execute: fn _id, %{"path" => path}, _signal, _on_update ->
    case File.read(path) do
      {:ok, content} ->
        AgentCore.new_tool_result(content: [AgentCore.text_content(content)])
      {:error, reason} ->
        {:error, reason}
    end
  end
)

{:ok, agent} = AgentCore.new_agent(
  model: %{provider: :anthropic, id: "claude-3-5-sonnet-20241022"},
  system_prompt: "You are a helpful assistant",
  tools: [read_tool],
  convert_to_llm: &MyApp.convert/1
)

:ok = AgentCore.prompt(agent, "Read the README.md file")
:ok = AgentCore.wait_for_idle(agent)
state = AgentCore.get_state(agent)
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
  convert_to_llm: &MyApp.convert/1,
  stream_options: %Ai.Types.StreamOptions{max_tokens: 4000}
}

user_msg = %Ai.Types.UserMessage{
  role: :user,
  content: "Hello!",
  timestamp: System.system_time(:millisecond)
}

# Returns an Enumerable of events
Loop.stream([user_msg], context, config)
|> Enum.each(&IO.inspect/1)

# Or get the raw EventStream (with signal/owner control)
event_stream = Loop.agent_loop([user_msg], context, config, signal, stream_fn)
EventStream.events(event_stream) |> Enum.to_list()
```

### Steering and Follow-up Messages

```elixir
# Inject message mid-run (interrupts after current tool batch)
:ok = AgentCore.Agent.steer(agent, %Ai.Types.UserMessage{
  role: :user,
  content: "Actually, use a different approach",
  timestamp: System.system_time(:millisecond)
})

# Queue message processed after agent would naturally stop
:ok = AgentCore.Agent.follow_up(agent, %Ai.Types.UserMessage{
  role: :user,
  content: "Now summarize the results",
  timestamp: System.system_time(:millisecond)
})
```

### Context Management

```elixir
# Use AgentCore.Context for context window management
transform = AgentCore.Context.make_transform(
  max_messages: 50,
  max_chars: 200_000
)

config = %AgentCore.Types.AgentLoopConfig{
  transform_context: transform,
  ...
}

# Or use standalone
size = AgentCore.Context.estimate_size(messages, system_prompt)
{truncated, dropped} = AgentCore.Context.truncate(messages, max_messages: 50)
stats = AgentCore.Context.stats(messages, system_prompt)
# => %{message_count: 10, char_count: 5000, estimated_tokens: 1250, by_role: %{user: 5, ...}}
```

### Abort Handling

```elixir
:ok = AgentCore.abort(agent)
:ok = AgentCore.wait_for_idle(agent, timeout: 10_000)

# In tool execute functions, check the signal:
execute: fn _id, params, signal, _on_update ->
  for i <- 1..100 do
    if AgentCore.AbortSignal.aborted?(signal) do
      throw(:aborted)
    end
    do_work(i)
  end
  AgentCore.new_tool_result(content: [AgentCore.text_content("done")])
end
```

### Proxy Stream (LLM calls through a server)

```elixir
config = %AgentLoopConfig{
  model: model,
  convert_to_llm: &MyApp.convert/1,
  stream_fn: fn model, context, opts ->
    AgentCore.Proxy.stream_proxy(model, context, %AgentCore.Proxy.ProxyStreamOptions{
      auth_token: get_auth_token(),
      proxy_url: "https://genai.example.com",
      reasoning: opts.reasoning
    })
  end
}
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
├── agent_core_test.exs
├── agent_core_module_test.exs
├── agent_registry_test.exs
├── subagent_supervisor_test.exs
├── support/
└── agent_core/
    ├── agent_test.exs
    ├── agent_queue_test.exs
    ├── abort_signal_test.exs
    ├── abort_signal_concurrency_test.exs
    ├── application_test.exs
    ├── application_supervision_test.exs
    ├── context_test.exs
    ├── context_property_test.exs
    ├── event_stream_test.exs
    ├── event_stream_concurrency_test.exs
    ├── event_stream_edge_cases_test.exs
    ├── event_stream_improvements_test.exs
    ├── event_stream_runner_test.exs
    ├── proxy_test.exs
    ├── proxy_error_test.exs
    ├── proxy_stream_integration_test.exs
    ├── telemetry_test.exs
    ├── types_test.exs
    ├── property_test.exs
    ├── supervision_test.exs
    ├── tool_supervision_test.exs
    ├── loop/
    │   ├── loop_test.exs
    │   ├── loop_abort_test.exs
    │   ├── loop_edge_cases_test.exs
    │   └── loop_additional_edge_cases_test.exs
    └── cli_runners/
        ├── jsonl_runner_test.exs
        ├── jsonl_runner_safety_test.exs
        ├── types_test.exs
        ├── tool_action_helpers_test.exs
        ├── claude_runner_test.exs
        ├── claude_schema_test.exs
        ├── claude_subagent_test.exs
        ├── codex_runner_test.exs
        ├── codex_schema_test.exs
        ├── codex_subagent_test.exs
        ├── codex_subagent_comprehensive_test.exs
        ├── kimi_runner_test.exs
        ├── kimi_subagent_test.exs
        ├── opencode_runner_test.exs
        ├── pi_runner_test.exs
        ├── claude_integration_test.exs    # @tag :integration
        ├── codex_integration_test.exs     # @tag :integration
        └── kimi_integration_test.exs      # @tag :integration
```

### Writing Tests

```elixir
defmodule AgentCore.MyFeatureTest do
  use ExUnit.Case, async: true

  alias AgentCore.Types

  setup do
    {:ok, agent} = AgentCore.new_agent(
      model: %{provider: :mock, id: "test"},
      system_prompt: "Test",
      convert_to_llm: fn msgs -> Enum.filter(msgs, &match?(%{role: role} when role in [:user, :assistant, :tool_result], &1)) end
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
  # Only runs with: mix test --include integration
end
```

## Key Design Patterns

1. **Separation of Concerns**: `Loop` is stateless logic; `Agent` is stateful GenServer
2. **Event-Driven**: All execution emits events for UI/observability
3. **Cooperative Abort**: Abort signals are checked in tools, not forced
4. **Session Locking**: CLI runners use ETS locks to prevent concurrent resumption of the same session
5. **Registry Pattern**: Agents registered by `{session_id, role, index}` tuples for structured lookup
6. **Backpressure**: `EventStream.push/2` returns `:ok | {:error, :overflow | :canceled}`
7. **Long-poll Follow-up**: Agent uses a 50ms long-poll to catch follow-up messages queued just as a run ends
8. **Queue Modes**: Steering/follow-up queues consume `:one_at_a_time` (default) or `:all` per turn

## Dependencies

- `ai` - Low-level LLM API abstractions
- `lemon_core` - Shared primitives and telemetry
- `req` - HTTP client (used by Proxy)
- `jason` - JSON encoding/decoding
- `stream_data` - Property-based testing (test only)
