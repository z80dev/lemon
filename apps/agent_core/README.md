# AgentCore

Core agent runtime for the Lemon umbrella project. AgentCore provides OTP-native building blocks for AI agents: a supervised GenServer for stateful agent lifecycle management, a stateless agentic loop with streaming events, bounded event streams with backpressure, cooperative abort signaling, context window management, CLI subprocess runners for external AI engines, and a subagent supervision/registry infrastructure.

## Architecture Overview

```
                        +--------------------------+
                        |    Your Application      |
                        +--------------------------+
                                   |
                                   v
+-----------------------------------------------------------------+
|  AgentCore                                                      |
|                                                                 |
|  +-------------+  +-------------+  +--------------------------+ |
|  |    Agent    |  |    Loop     |  |  EventStream / Types     | |
|  |  (GenServer)|  | (stateless) |  |  (events & structures)   | |
|  +------+------+  +------+------+  +--------------------------+ |
|         |                |                                      |
|  +------+------+  +------+------+  +--------------------------+ |
|  | AgentRegistry| | SubagentSup |  |  CLI Runners             | |
|  | (lookup)    |  | (dynamic)   |  |  (external CLIs)         | |
|  +-------------+  +-------------+  +--------------------------+ |
+-----------------------------------------------------------------+
                                   |
                                   v
+-----------------------------------------------------------------+
|  Ai Library (low-level LLM abstractions: streaming, providers)  |
+-----------------------------------------------------------------+
```

AgentCore sits between application code and the low-level `Ai` library. Applications interact with agents through `AgentCore`'s public API or the `AgentCore.Agent` GenServer. The `Ai` library handles raw LLM provider communication (streaming, completions, message types).

## Supervision Tree

```
AgentCore.Supervisor (:one_for_one)
|-- AgentCore.AbortSignal.TableOwner   (GenServer, owns the abort ETS table)
|-- AgentCore.AgentRegistry            (Registry, :unique keys)
|-- AgentCore.SubagentSupervisor       (DynamicSupervisor, :temporary children)
|-- AgentCore.LoopTaskSupervisor       (Task.Supervisor for loop tasks)
+-- AgentCore.ToolTaskSupervisor       (Task.Supervisor for tool execution)
```

The supervisor uses a `:one_for_one` strategy. Each child is independent:

- **AbortSignal.TableOwner** -- A long-lived GenServer that owns the `:agent_core_abort_signals` ETS table and acts as heir so the table survives process restarts.
- **AgentRegistry** -- An Elixir `Registry` with `:unique` keys. Agents register under `{session_id, role, index}` tuples.
- **SubagentSupervisor** -- A `DynamicSupervisor` for spawning subagent `AgentCore.Agent` processes as `:temporary` children.
- **LoopTaskSupervisor** -- A `Task.Supervisor` for spawning agent loop tasks via `Task.Supervisor.async_nolink/2`.
- **ToolTaskSupervisor** -- A `Task.Supervisor` for spawning concurrent tool execution tasks.

## Module Inventory

### Core Agent

| Module | File | Purpose |
|--------|------|---------|
| `AgentCore` | `lib/agent_core.ex` | Top-level API facade. Delegates to `Agent` for lifecycle operations (`new_agent/1`, `prompt/2`, `abort/1`, `wait_for_idle/2`, `get_state/1`). Provides convenience constructors (`new_tool/1`, `new_tool_result/1`, `text_content/1`, `image_content/2`, `get_text/1`). Wraps `Loop.stream/4` and `Loop.stream_continue/3` as `agent_loop/4` and `agent_loop_continue/3`. |
| `AgentCore.Agent` | `lib/agent_core/agent.ex` | GenServer for stateful agent management. Handles prompts, streaming, subscriber broadcasting, steering/follow-up queues, abort signals, and waiter notification. |
| `AgentCore.AgentRegistry` | `lib/agent_core/agent_registry.ex` | Registry wrapper for agent lookup by `{session_id, role, index}` keys. Supports `via/1` tuples, `lookup/1`, `list_by_session/1`, `list_by_role/1`. |
| `AgentCore.SubagentSupervisor` | `lib/agent_core/subagent_supervisor.ex` | DynamicSupervisor for spawning subagent processes. `start_subagent/1`, `stop_subagent/1`, `stop_subagent_by_key/1`, `list_subagents/0`, `stop_all/0`. |
| `AgentCore.Application` | `lib/agent_core/application.ex` | OTP application with the supervision tree above. |

### Loop and Execution

| Module | File | Purpose |
|--------|------|---------|
| `AgentCore.Loop` | `lib/agent_core/loop.ex` | Stateless agent loop: `agent_loop/5`, `agent_loop_continue/4`, `stream/4`, `stream_continue/3`. Orchestrates prompt injection, LLM streaming, tool call execution, steering, and follow-up in a recursive inner/outer loop. |
| `AgentCore.Loop.Streaming` | `lib/agent_core/loop/streaming.ex` | LLM response streaming. Calls `Ai.stream/3` (or a custom `stream_fn`), processes SSE events, builds partial `AssistantMessage`, emits `message_start`/`message_update`/`message_end` events. |
| `AgentCore.Loop.ToolCalls` | `lib/agent_core/loop/tool_calls.ex` | Concurrent tool execution. Starts tool tasks under `AgentCore.ToolTaskSupervisor`, collects results, handles abort, emits `tool_execution_start`/`tool_execution_end` events. Supports configurable `max_tool_concurrency`. |

### Events and Context

| Module | File | Purpose |
|--------|------|---------|
| `AgentCore.EventStream` | `lib/agent_core/event_stream.ex` | GenServer-based async event producer/consumer. Bounded queue with backpressure (`push/2` returns `:ok` or `{:error, :overflow}`). Owner monitoring, task linking, configurable timeout. Drop strategies: `:error`, `:drop_oldest`, `:drop_newest`. |
| `AgentCore.Context` | `lib/agent_core/context.ex` | Context window management. `estimate_size/2`, `estimate_tokens/1`, `truncate/2` (sliding window and bookends strategies), `make_transform/1` for `AgentLoopConfig.transform_context`, `stats/2`, `check_size/3`. |
| `AgentCore.AbortSignal` | `lib/agent_core/abort_signal.ex` | ETS-based cooperative abort signaling. `new/0`, `abort/1`, `aborted?/1`, `clear/1`. Used by the loop and tool execution to check for cancellation. |
| `AgentCore.AbortSignal.TableOwner` | `lib/agent_core/abort_signal/table_owner.ex` | GenServer that owns the abort signal ETS table and acts as heir for table survival. |
| `AgentCore.Proxy` | `lib/agent_core/proxy.ex` | SSE proxy stream function for routing LLM calls through a server. Reconstructs partial `AssistantMessage` from bandwidth-optimized SSE events. Includes `ProxyStreamOptions` struct. |
| `AgentCore.TextGeneration` | `lib/agent_core/text_generation.ex` | Lightweight text completion bridge. `complete_text/4` wraps `Ai.complete/3` so callers stay within architecture boundaries without importing `Ai` directly. |

### Types

| Module | File | Purpose |
|--------|------|---------|
| `AgentCore.Types` | `lib/agent_core/types.ex` | Core type definitions: `thinking_level`, `agent_message`, `agent_event`. |
| `AgentCore.Types.AgentTool` | (nested in types.ex) | Tool definition: `name`, `description`, `parameters` (JSON Schema), `label`, `execute` (4-arity function). |
| `AgentCore.Types.AgentToolResult` | (nested in types.ex) | Tool result: `content` (list of text/image blocks), `details`, `trust` (`:trusted` or `:untrusted`). |
| `AgentCore.Types.AgentContext` | (nested in types.ex) | Conversation context: `system_prompt`, `messages`, `tools`. |
| `AgentCore.Types.AgentState` | (nested in types.ex) | Runtime state: `system_prompt`, `model`, `thinking_level`, `tools`, `messages`, `is_streaming`, `stream_message`, `pending_tool_calls`, `error`. |
| `AgentCore.Types.AgentLoopConfig` | (nested in types.ex) | Loop config: `model`, `convert_to_llm`, `transform_context`, `get_api_key`, `get_steering_messages`, `get_follow_up_messages`, `max_tool_concurrency`, `stream_options`, `stream_fn`. |

### CLI Runners

| Module | File | Purpose |
|--------|------|---------|
| `AgentCore.CliRunners.JsonlRunner` | `lib/agent_core/cli_runners/jsonl_runner.ex` | Base `use` macro and GenServer for JSONL-streaming CLI subprocesses. Handles subprocess spawning, stdout JSONL parsing, stderr draining, session locking, graceful shutdown. Defines the behaviour callbacks. |
| `AgentCore.CliRunners.Types` | `lib/agent_core/cli_runners/types.ex` | CLI event types: `ResumeToken` (compatibility wrapper for `LemonCore.ResumeToken`), `Action`, `StartedEvent`, `ActionEvent`, `CompletedEvent`, `EventFactory`. |
| `AgentCore.CliRunners.ToolActionHelpers` | `lib/agent_core/cli_runners/tool_action_helpers.ex` | Helpers for translating tool/action events between formats. |

### Engine-Specific Runners

Each supported external AI engine has three modules:

| Engine | Runner | Schema | Subagent |
|--------|--------|--------|----------|
| Claude | `claude_runner.ex` | `claude_schema.ex` | `claude_subagent.ex` |
| Codex | `codex_runner.ex` | `codex_schema.ex` | `codex_subagent.ex` |
| Kimi | `kimi_runner.ex` | `kimi_schema.ex` | `kimi_subagent.ex` |
| OpenCode | `opencode_runner.ex` | `opencode_schema.ex` | `opencode_subagent.ex` |
| Pi | `pi_runner.ex` | `pi_schema.ex` | `pi_subagent.ex` |

All runners implement the `AgentCore.CliRunners.JsonlRunner` behaviour via `use AgentCore.CliRunners.JsonlRunner`. Each schema module handles JSON event parsing for the specific engine format. Subagent modules wrap the runner with `AgentCore.SubagentSupervisor` integration.

## Key Concepts and Design Patterns

### Separation of Concerns: Loop vs. Agent

`AgentCore.Loop` is pure, stateless logic. It takes context, config, and callbacks, runs the agentic loop (stream LLM response, execute tools, repeat), and emits events through an `EventStream`. It has no GenServer state.

`AgentCore.Agent` is the stateful GenServer that wraps `Loop`. It manages conversation history, subscriber lists, steering/follow-up queues, and abort references. It spawns the loop as a supervised task and forwards events to subscribers.

### Event-Driven Architecture

All execution emits structured events via `AgentCore.EventStream`:

```
{:agent_start}
{:turn_start}
{:message_start, message}
{:message_update, message, assistant_event}
{:message_end, message}
{:tool_execution_start, id, name, args}
{:tool_execution_update, id, name, args, partial_result}
{:tool_execution_end, id, name, result, is_error}
{:turn_end, message, tool_results}
{:agent_end, new_messages}
{:error, reason, partial_state}
{:canceled, reason}
```

The `{:agent_end, new_messages}` event contains only messages created during the current run, not the full conversation history.

### Cooperative Abort

Abort is cooperative, not forced. `AgentCore.AbortSignal` uses an ETS table with `read_concurrency: true`. Tools check `AbortSignal.aborted?(signal)` in their execute functions. The loop checks before each LLM call and tool batch. This allows tools to clean up gracefully.

### Steering and Follow-up Queues

The Agent GenServer provides two message queues:

- **Steering** (`steer/2`): Messages injected mid-run. After the current tool batch completes, remaining tools are skipped and the steering message is processed in the next turn.
- **Follow-up** (`follow_up/2`): Messages queued for after the agent would naturally stop (no more tool calls). A 50ms long-poll closes the race where a follow-up is enqueued just as the run ends.

Both queues support two consumption modes: `:one_at_a_time` (default) or `:all`.

### Session Locking (CLI Runners)

CLI runners use an ETS-based session lock to prevent concurrent resumption of the same session. Locks are acquired on resume, released on completion, and reclaimed if the owner process dies or the lock expires (default: 15 minutes).

### Registry Pattern

Agents register in `AgentCore.AgentRegistry` under `{session_id, role, index}` tuples. This enables structured lookup across sessions and roles:

```elixir
AgentCore.AgentRegistry.lookup({session_id, :research, 0})
AgentCore.AgentRegistry.list_by_session(session_id)
AgentCore.AgentRegistry.list_by_role(:research)
```

### Backpressure

`EventStream.push/2` is synchronous and returns `:ok | {:error, :overflow | :canceled}`. Producers can use this for flow control. `push_async/2` is fire-and-forget. Drop strategies (`:error`, `:drop_oldest`, `:drop_newest`) control overflow behavior.

### Introspection

AgentCore emits introspection events via `LemonCore.Introspection.record/3` for observability. Events include `:agent_loop_started`, `:agent_turn_observed`, `:agent_loop_ended`, `:jsonl_stream_started`, `:jsonl_stream_ended`, `:tool_use_observed`, `:assistant_turn_observed`, and engine-specific events. Payloads never include prompt or response content.

### Telemetry

The library emits telemetry events under the `[:agent_core, ...]` prefix:

- `[:agent_core, :loop, :start]` / `[:agent_core, :loop, :end]` -- Agent loop lifecycle.
- `[:agent_core, :tool_task, :start]` / `[:agent_core, :tool_task, :end]` / `[:agent_core, :tool_task, :error]` -- Individual tool execution.
- `[:agent_core, :tool_result, :emit]` -- Tool result emission.
- `[:agent_core, :context, :size]` / `[:agent_core, :context, :warning]` / `[:agent_core, :context, :truncated]` -- Context management.
- `[:agent_core, :subagent, :spawn]` / `[:agent_core, :subagent, :end]` -- Subagent lifecycle.

## Configuration

Application environment keys under `:agent_core`:

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `:queue_call_timeout_ms` | `pos_integer() \| :infinity` | `1_800_000` (30 min) | GenServer call timeout for loop queue polling |
| `:cli_timeout_ms` | `pos_integer() \| :infinity` | `300_000` (5 min) | CLI subprocess timeout |
| `:cli_session_lock_max_age_ms` | `pos_integer() \| :infinity` | `900_000` (15 min) | Maximum age for CLI session locks before reclamation |
| `:cli_cancel_grace_ms` | `pos_integer()` | `1_000` (1 sec) | Grace period before force-killing a canceled CLI |
| `:event_stream_cancel_grace_ms` | `pos_integer()` | `100` | Grace period before force-killing an EventStream's attached task |

## Usage Examples

### Creating and Using an Agent

```elixir
# Define a tool
read_tool = AgentCore.new_tool(
  name: "read_file",
  description: "Read the contents of a file",
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

# Start an agent
{:ok, agent} = AgentCore.new_agent(
  model: %{provider: :anthropic, id: "claude-sonnet-4-20250514"},
  system_prompt: "You are a helpful assistant.",
  tools: [read_tool],
  convert_to_llm: fn msgs ->
    Enum.filter(msgs, &match?(%{role: role} when role in [:user, :assistant, :tool_result], &1))
  end
)

# Subscribe to events
AgentCore.subscribe(agent, self())

# Send a prompt
:ok = AgentCore.prompt(agent, "Read the README.md file")

# Wait for completion
:ok = AgentCore.wait_for_idle(agent)

# Get final state
state = AgentCore.get_state(agent)
```

### Steering and Follow-up

```elixir
# Inject a message mid-run (after current tool batch)
:ok = AgentCore.Agent.steer(agent, %Ai.Types.UserMessage{
  role: :user,
  content: "Actually, use a different approach",
  timestamp: System.system_time(:millisecond)
})

# Queue a message for after the run completes
:ok = AgentCore.Agent.follow_up(agent, %Ai.Types.UserMessage{
  role: :user,
  content: "Now summarize the results",
  timestamp: System.system_time(:millisecond)
})
```

### Using the Loop Directly

```elixir
alias AgentCore.{Loop, Types}

context = Types.AgentContext.new(
  system_prompt: "You are helpful",
  tools: tools
)

config = %Types.AgentLoopConfig{
  model: model,
  convert_to_llm: &my_convert/1,
  stream_options: %Ai.Types.StreamOptions{max_tokens: 4000}
}

user_msg = %Ai.Types.UserMessage{
  role: :user,
  content: "Hello!",
  timestamp: System.system_time(:millisecond)
}

Loop.stream([user_msg], context, config)
|> Enum.each(&IO.inspect/1)
```

### Spawning Subagents

```elixir
{:ok, pid} = AgentCore.SubagentSupervisor.start_subagent(
  registry_key: {session_id, :research, 0},
  model: model,
  system_prompt: "Research assistant",
  convert_to_llm: &my_convert/1
)

AgentCore.Agent.prompt(pid, "Research this topic")
:ok = AgentCore.Agent.wait_for_idle(pid)
state = AgentCore.Agent.get_state(pid)
AgentCore.SubagentSupervisor.stop_subagent(pid)
```

### Context Management

```elixir
transform = AgentCore.Context.make_transform(
  max_messages: 50,
  max_chars: 200_000
)

config = %AgentCore.Types.AgentLoopConfig{
  transform_context: transform,
  model: model,
  convert_to_llm: &my_convert/1
}

# Standalone usage
size = AgentCore.Context.estimate_size(messages, system_prompt)
{truncated, dropped} = AgentCore.Context.truncate(messages, max_messages: 50)
stats = AgentCore.Context.stats(messages, system_prompt)
```

### Proxy Streaming

```elixir
config = %AgentCore.Types.AgentLoopConfig{
  model: model,
  convert_to_llm: &my_convert/1,
  stream_fn: fn model, context, opts ->
    AgentCore.Proxy.stream_proxy(model, context, %AgentCore.Proxy.ProxyStreamOptions{
      auth_token: get_auth_token(),
      proxy_url: "https://genai.example.com",
      reasoning: opts.reasoning
    })
  end
}
```

### Using EventStream Directly

```elixir
{:ok, stream} = AgentCore.EventStream.start_link(
  owner: self(),
  max_queue: 1000,
  timeout: 60_000
)

AgentCore.EventStream.push(stream, {:custom_event, data})
AgentCore.EventStream.complete(stream, final_messages)

{:ok, messages} = AgentCore.EventStream.result(stream, 30_000)
%{queue_size: n, max_queue: m, dropped: d} = AgentCore.EventStream.stats(stream)
```

### Adding a New CLI Runner

Implement the `AgentCore.CliRunners.JsonlRunner` behaviour:

```elixir
defmodule AgentCore.CliRunners.MyEngineRunner do
  use AgentCore.CliRunners.JsonlRunner

  alias AgentCore.CliRunners.Types.EventFactory
  alias LemonCore.ResumeToken

  @engine "myengine"

  @impl true
  def engine, do: @engine

  @impl true
  def init_state(_prompt, _resume, cwd, _opts) do
    %{factory: EventFactory.new(@engine), last_text: nil}
  end

  @impl true
  def build_command(prompt, resume, _state) do
    args = ["--json", "--output-format", "jsonl"]
    args = if resume, do: args ++ ["--resume", resume.value], else: args
    {"myengine", args ++ ["--", prompt]}
  end

  @impl true
  def translate_event(data, state) do
    case data do
      %{"type" => "init", "session_id" => sid} ->
        token = ResumeToken.new(@engine, sid)
        {started, factory} = EventFactory.started(state.factory, token)
        {[started], %{state | factory: factory}, [found_session: token]}

      %{"type" => "done", "result" => result} ->
        {completed, factory} = EventFactory.completed_ok(state.factory, result || "")
        {[completed], %{state | factory: factory}, [done: true]}

      _ ->
        {[], state, []}
    end
  end

  @impl true
  def handle_exit_error(exit_code, state) do
    {event, factory} = EventFactory.completed_error(state.factory, "failed (rc=#{exit_code})")
    {[event], %{state | factory: factory}}
  end

  @impl true
  def handle_stream_end(state) do
    {event, factory} = EventFactory.completed_error(state.factory, "ended without result")
    {[event], %{state | factory: factory}}
  end
end
```

## Dependencies

| Dependency | Type | Purpose |
|-----------|------|---------|
| `ai` | umbrella | Low-level LLM API abstractions (streaming, providers, message types) |
| `lemon_core` | umbrella | Shared primitives (telemetry, introspection, ResumeToken) |
| `req` | hex (~> 0.5) | HTTP client used by `AgentCore.Proxy` |
| `jason` | hex (~> 1.4) | JSON encoding/decoding |
| `stream_data` | hex (~> 1.1, test only) | Property-based testing |

## Testing

### Running Tests

```bash
# All agent_core tests
mix test apps/agent_core

# Specific test file
mix test apps/agent_core/test/agent_core/agent_test.exs

# Run with integration tests (requires external CLIs installed)
mix test apps/agent_core --include integration

# Specific CLI runner integration test
mix test apps/agent_core/test/agent_core/cli_runners/claude_integration_test.exs --include integration
```

### Test Organization

Tests are organized to mirror the source structure:

```
apps/agent_core/test/
|-- agent_core_test.exs               Top-level module tests
|-- agent_core_module_test.exs         Module-level tests
|-- agent_registry_test.exs            Registry tests
|-- subagent_supervisor_test.exs       Subagent supervisor tests
|-- agent_core/
|   |-- agent_test.exs                Agent GenServer tests
|   |-- agent_queue_test.exs          Steering/follow-up queue tests
|   |-- abort_signal_test.exs         Abort signal unit tests
|   |-- abort_signal_concurrency_test.exs
|   |-- application_test.exs          Application startup tests
|   |-- application_supervision_test.exs
|   |-- context_test.exs              Context management tests
|   |-- context_property_test.exs     Property-based context tests
|   |-- event_stream_test.exs         EventStream unit tests
|   |-- event_stream_concurrency_test.exs
|   |-- event_stream_edge_cases_test.exs
|   |-- event_stream_improvements_test.exs
|   |-- event_stream_runner_test.exs
|   |-- proxy_test.exs                Proxy stream tests
|   |-- proxy_error_test.exs
|   |-- proxy_stream_integration_test.exs
|   |-- text_generation_test.exs
|   |-- types_test.exs
|   |-- property_test.exs
|   |-- supervision_test.exs
|   |-- tool_supervision_test.exs
|   |-- telemetry_test.exs
|   |-- loop/
|   |   |-- tool_calls_test.exs
|   |   |-- streaming_test.exs
|   |-- loop_test.exs
|   |-- loop_abort_test.exs
|   |-- loop_edge_cases_test.exs
|   |-- loop_additional_edge_cases_test.exs
|   +-- cli_runners/
|       |-- jsonl_runner_test.exs
|       |-- jsonl_runner_safety_test.exs
|       |-- types_test.exs
|       |-- tool_action_helpers_test.exs
|       |-- claude_runner_test.exs
|       |-- claude_schema_test.exs
|       |-- claude_subagent_test.exs
|       |-- codex_runner_test.exs
|       |-- codex_schema_test.exs
|       |-- codex_subagent_test.exs
|       |-- codex_subagent_comprehensive_test.exs
|       |-- kimi_runner_test.exs
|       |-- kimi_subagent_test.exs
|       |-- opencode_runner_test.exs
|       |-- pi_runner_test.exs
|       |-- introspection_test.exs
|       |-- claude_integration_test.exs    (@tag :integration)
|       |-- codex_integration_test.exs     (@tag :integration)
|       +-- kimi_integration_test.exs      (@tag :integration)
```

Integration tests that require external CLI tools are tagged with `@tag :integration` and excluded from the default test run.
