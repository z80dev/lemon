# LemonAgent

Elixir library for building AI agents with multi-turn conversations, tool execution, and streaming events.

## Purpose and Responsibilities

LemonAgent provides the runtime foundation for AI agents in the Lemon project:

- **Agent Runtime**: Stateful GenServer-based agents with lifecycle management
- **Subagent Spawning**: Supervised dynamic spawning of child agents
- **Event Streaming**: Async producer/consumer event streams for real-time UI updates
- **Context Management**: Message history sizing, truncation, and token estimation
- **Abort Handling**: Cooperative cancellation signals for long-running operations

## Quick Orientation

This is an Elixir umbrella app at `apps/lemon_agent/`. It depends on `ai` (LLM abstractions) and `lemon_core` (shared primitives). Applications that need AI agents depend on `agent_core` rather than calling `LemonAi` directly.

The two main entry points are:
1. **`LemonAgent` module** (`lib/agent_core.ex`) -- High-level API facade. Most callers use `LemonAgent.new_agent/1`, `LemonAgent.prompt/2`, `LemonAgent.wait_for_idle/2`.
2. **`LemonAgent.Agent` module** (`lib/agent_core/agent.ex`) -- Full GenServer API including `steer/2`, `follow_up/2`, queue controls, and state mutators.

## Architecture

```
LemonAgent.Supervisor (:one_for_one)
|-- LemonAgent.AbortSignal.TableOwner  (owns the abort ETS table)
|-- LemonAgent.AgentRegistry           (Registry, :unique keys)
|-- LemonAgent.SubagentSupervisor      (DynamicSupervisor)
|-- LemonAgent.LoopTaskSupervisor      (Task.Supervisor for loop tasks)
+-- LemonAgent.ToolTaskSupervisor      (Task.Supervisor for tool execution)
```

## Key Files and Their Purposes

### Core (read these first)

| File | What It Does |
|------|-------------|
| `lib/agent_core.ex` | Public API facade. Delegates lifecycle ops to `Agent`, provides convenience constructors (`new_tool/1`, `new_tool_result/1`, `text_content/1`), wraps `Loop.stream/4`. |
| `lib/agent_core/agent.ex` | **The GenServer.** ~1260 lines. Manages state, subscribers, steering/follow-up queues, abort refs, waiter lists. Spawns loop tasks under `LoopTaskSupervisor`. Broadcasts events to listeners. |
| `lib/agent_core/types.ex` | All core structs: `AgentState`, `AgentContext`, `AgentTool`, `AgentToolResult`, `AgentLoopConfig`. Type union for `agent_event()`. |
| `lib/agent_core/loop.ex` | Stateless agentic loop. Recursive inner/outer loop: stream LLM response -> execute tools -> check steering -> repeat. Outer loop checks follow-up messages after inner loop exits. |
| `lib/agent_core/loop/streaming.ex` | Handles the LLM streaming call. Transforms context, converts messages, calls `LemonAi.stream/3` (or custom `stream_fn`), processes SSE events into `message_start`/`message_update`/`message_end`. |
| `lib/agent_core/loop/transcript_validator.ex` | Enforces tool transcript invariants before provider calls: each assistant tool call must be followed by exactly one matching tool result before the next model turn. |
| `lib/agent_core/loop/tool_calls.ex` | Parallel tool execution under `ToolTaskSupervisor`. Respects `max_tool_concurrency`. Handles abort by terminating pending tasks. Returns tool results in the original assistant tool-call order. |

### Infrastructure

| File | What It Does |
|------|-------------|
| `lib/agent_core/event_stream.ex` | GenServer-based bounded event queue. Producer pushes with backpressure, consumer reads via `events/1` (lazy `Stream.resource`). Handles owner death, task death, timeout. |
| `lib/agent_core/context.ex` | Context window management. `estimate_size/2` counts chars (~4 chars/token). `truncate/2` preserves retained order, applies both message/character limits to bookends, and keeps assistant tool-call/result transcript groups atomic. `make_transform/1` creates a function for `AgentLoopConfig.transform_context`. |
| `lib/agent_core/abort_signal.ex` | ETS-based abort flag. `new/0` creates a ref, `abort/1` sets it, `aborted?/1` checks it. Fast reads via `read_concurrency: true`. |
| `lib/agent_core/proxy.ex` | SSE proxy for routing LLM calls through an HTTP server. Reconstructs partial `AssistantMessage` from stripped delta events. |
| `lib/agent_core/text_generation.ex` | Simple `complete_text/4` bridge so callers don't import `LemonAi` directly. |
| `lib/agent_core/agent_registry.ex` | Thin wrapper around `Registry`. Keys are `{session_id, role, index}` tuples. `via/1`, `lookup/1`, `list_by_session/1`, `list_by_role/1`. |
| `lib/agent_core/subagent_supervisor.ex` | `DynamicSupervisor` for subagent processes. Children are `:temporary`. `start_subagent/1` accepts `registry_key:` option. |
| `lib/agent_core/application.ex` | OTP app. Starts the supervision tree. |

### Adding a new tool

Define a tool struct and pass it to `LemonAgent.new_agent/1`:

```elixir
my_tool = LemonAgent.new_tool(
  name: "my_tool",
  description: "Does something",
  parameters: %{"type" => "object", "properties" => %{...}, "required" => [...]},
  execute: fn tool_call_id, params, signal, on_update ->
    # Check abort: LemonAgent.AbortSignal.aborted?(signal)
    # Report progress: on_update.(partial_result)
    LemonAgent.new_tool_result(content: [LemonAgent.text_content("result")])
  end
)
```

The execute function signature is `(String.t(), map(), reference() | nil, (AgentToolResult.t() -> :ok) | nil) -> AgentToolResult.t() | {:ok, AgentToolResult.t()} | {:error, term()}`.

### Adding a new agent event type

1. Add the type to the `agent_event()` union in `lib/agent_core/types.ex`.
2. Emit via `EventStream.push(stream, {:my_event, ...})` in the loop or tool calls module.
3. Handle in `LemonAgent.Agent.handle_agent_event/2` if state updates are needed.
4. Update subscriber code to handle the new event pattern.

### Modifying the agent loop behavior

The loop is in `lib/agent_core/loop.ex`. The inner loop (`do_inner_loop/10`) handles tool calls and steering. The outer loop (`do_run_loop/8`) handles follow-up messages. LLM streaming is delegated to `Loop.Streaming`. Tool execution is delegated to `Loop.ToolCalls`.

Key change points:
- **Before each LLM call**: `Loop.Streaming.stream_assistant_response/5` calls `transform_messages`, validates tool transcript shape, calls `convert_messages`, then calls the stream function.
- **After tool execution**: `Loop.ToolCalls.execute_and_collect_tools/6` returns results and any steering messages.
- **Loop exit**: The outer loop checks `get_follow_up_messages` before emitting `{:agent_end, new_messages}`.

### Modifying the Agent GenServer

`lib/agent_core/agent.ex` has clearly separated sections:
- Client API (lines ~117-457): public functions.
- GenServer Callbacks (lines ~463-834): `handle_call`, `handle_cast`, `handle_info`.
- Private Functions (lines ~840-1262): `start_loop`, `build_loop_config`, `run_agent_loop`, event handling, task completion.

The `start_loop/2` function builds the `AgentLoopConfig`, creates an abort signal, and spawns a task under `LoopTaskSupervisor`. The task runs `run_agent_loop/6` which calls `LemonAgent.Loop.agent_loop/6` or `agent_loop_continue/5`, then consumes the `EventStream` and forwards events to the GenServer via `send(agent_pid, {:agent_event, event})`.

## LemonAgent.Agent - Full API Reference

**Lifecycle:**
- `start_link(opts)` -- Start the GenServer.
- `prompt(agent, message)` -- Start a run. Returns `{:error, :already_streaming}` if busy. Message can be string, map, or list.
- `continue(agent)` -- Continue from existing context (retry/after tool results). Returns `{:error, :already_streaming | :no_messages | :cannot_continue}`.
- `abort(agent)` -- Async cast. Sets abort signal.
- `wait_for_idle(agent, opts \\ [])` -- Block until idle. Accepts `timeout:` option.
- `reset(agent)` -- Clear messages, queues, and error state. Does not change config.

**Subscriptions:**
- `subscribe(agent, pid)` -- Returns an unsubscribe function `(-> :ok)`. Subscriber gets `{:agent_event, event}` messages. Monitored; auto-removed on death.

**Steering and Follow-up:**
- `steer(agent, message)` -- Cast. Inject message mid-run.
- `follow_up(agent, message)` -- Cast. Queue message for after natural stop.
- `clear_steering_queue(agent)` / `clear_follow_up_queue(agent)` / `clear_all_queues(agent)`.
- `set_steering_mode(agent, :all | :one_at_a_time)` / `set_follow_up_mode(agent, :all | :one_at_a_time)`.

**State Mutators (callable while idle):**
- `set_system_prompt(agent, prompt)` / `set_model(agent, model)` / `set_thinking_level(agent, level)`.
- `set_tools(agent, tools)` / `replace_messages(agent, messages)` / `append_message(agent, message)`.
- `set_session_id(agent, id)` / `get_session_id(agent)`.

**Getters:**
- `get_state(agent)` -- Returns `AgentState` struct.
- `get_steering_mode(agent)` / `get_follow_up_mode(agent)`.

**Note:** `steer/2` and `follow_up/2` are on `LemonAgent.Agent`, not on the top-level `LemonAgent` module.

## AgentLoopConfig Fields

```elixir
%LemonAgent.Types.AgentLoopConfig{
  # Required
  model: my_model,                          # LemonAi.Types.Model.t()
  convert_to_llm: fn messages -> {:ok, llm_messages} end,

  # Optional
  transform_context: fn messages, signal -> {:ok, transformed} end,
  get_api_key: fn provider -> api_key end,
  get_steering_messages: fn -> [] end,       # Wired by Agent GenServer
  get_follow_up_messages: fn -> [] end,      # Wired by Agent GenServer
  max_tool_concurrency: nil,                 # nil/:infinity = unbounded, or pos_integer
  tool_timeout_ms: nil,                      # nil/:infinity = unbounded, or pos_integer ms
  stream_options: %LemonAi.Types.StreamOptions{},
  stream_fn: nil                             # custom stream fn, defaults to LemonAi.stream/3
}
```

## Events Reference

```elixir
# Agent lifecycle (terminal: agent_end, error, canceled)
{:agent_start}
{:turn_start}
{:message_start, message}
{:message_update, message, assistant_event}   # streaming text delta
{:message_end, message}
{:tool_execution_start, id, name, args}
{:tool_execution_update, id, name, args, partial_result}
{:tool_execution_end, id, name, result, is_error}
{:turn_end, message, tool_results}
{:agent_end, new_messages}                     # terminal - only new messages, not full history
{:error, reason, partial_state}                # terminal
{:canceled, reason}                            # terminal
```

## Testing Guidance

### Running Tests

```bash
mix test apps/lemon_agent                    # All tests
mix test apps/lemon_agent/test/lemon_agent/agent_test.exs  # Specific file
mix test apps/lemon_agent --include integration            # Include integration tests
```

### Writing Tests

Most tests use `async: true`. The standard pattern:

```elixir
defmodule LemonAgent.MyFeatureTest do
  use ExUnit.Case, async: true

  alias LemonAgent.Test.Mocks  # if it exists in test/support/

  setup do
    {:ok, agent} = LemonAgent.new_agent(
      model: %{provider: :mock, id: "test"},
      system_prompt: "Test",
      convert_to_llm: fn msgs ->
        Enum.filter(msgs, &match?(%{role: role} when role in [:user, :assistant, :tool_result], &1))
      end
    )
    %{agent: agent}
  end

  test "handles streaming events", %{agent: agent} do
    LemonAgent.subscribe(agent, self())
    LemonAgent.prompt(agent, "Test")
    assert_receive {:agent_event, {:agent_start}}, 1000
    assert_receive {:agent_event, {:agent_end, _messages}}, 5000
  end
end
```

Integration tests requiring external services use `@tag :integration`:
```elixir
@tag :integration
test "runs real Claude session" do
  # Only runs with: mix test --include integration
end
```

### Key Test Files

- `test/agent_core/agent_test.exs` -- Agent GenServer lifecycle, state, subscriptions, queues.
- `test/agent_core/agent_queue_test.exs` -- Steering and follow-up queue behavior.
- `test/agent_core/event_stream_test.exs` -- EventStream push/take/backpressure/cancel.
- `test/agent_core/loop_test.exs` -- Loop execution flow.
- `test/agent_core/loop/tool_calls_test.exs` -- Tool execution, concurrency, abort.
- `test/agent_core/abort_signal_test.exs` -- Abort signal ETS operations.
- `test/agent_core/context_test.exs` -- Context estimation and truncation.

## Gotchas and Important Invariants

1. **`convert_to_llm` is required.** If not provided, `Agent` uses a default that filters to `:user`, `:assistant`, `:tool_result` roles. But most callers should provide their own since custom message types need explicit handling.

2. **`{:agent_end, new_messages}` contains only new messages**, not the full conversation history. The full history is in `LemonAgent.Agent.get_state(agent).messages`.

3. **`steer/2` and `follow_up/2` are on `LemonAgent.Agent`**, not on the top-level `LemonAgent` module. The top-level module delegates lifecycle ops but not queue operations.

4. **Abort is cooperative.** Calling `abort/1` sets a flag; it does not kill anything. Tools must check `AbortSignal.aborted?(signal)` themselves. The loop checks before each LLM call and tool batch.

5. **Queue call timeout.** The loop's steering/follow-up polling uses a GenServer call back to the Agent with a configurable timeout (default 30 minutes). If your loops run longer, set `:queue_call_timeout` in `start_link` opts or `:lemon_agent, :queue_call_timeout_ms` in app config.

6. **Follow-up long-poll.** The Agent long-polls for 50ms (`@follow_up_poll_timeout_ms`) when checking for follow-up messages. This closes a race where a follow-up is enqueued just as the loop finishes. Do not remove this without understanding the timing implications.

7. **EventStream owner death.** If the EventStream's owner process dies, the stream cancels and shuts down its attached task. Consumers that outlive a producer should set the owner to the caller, not the producer.

8. **Tool execution runs under `ToolTaskSupervisor`.** If a tool task crashes, it is caught and reported as an error result. It does not crash the loop.

9. **The AbortSignal ETS table** is created by `AbortSignal.TableOwner` at app startup. The `AbortSignal` module has a fallback `ensure_table` that creates it if needed (for test environments where the app may not be started). The table uses `{:heir, TableOwner, :ok}` so it survives process restarts.

10. **Context truncation preserves transcript structure.** Sliding-window output stays in original chronological order. Both strategies retain an assistant tool-call message and its contiguous tool results as one unit, dropping the whole unit when it cannot fit; bookends treats both `max_messages` and `max_chars` as hard limits.

11. **Kanban terminal writes are lease-guarded.** Automation dispatchers must
    retain the leased task's `kanbanLease.id` and use
    `KanbanStore.complete_leased_task/3`, `fail_leased_task/4`, or
    `reclaim_task_lease/3`. A stale lease returns `{:error, :stale_lease}` and
    must not mutate a newer worker's task. Dispatcher restart paths use
    `reclaim_worker_leases/3` before leasing new work for the same worker ID.
    Kanban task read-modify-write operations share a board-scoped global lock,
    so concurrent dispatchers cannot both claim one available task and a lease
    check cannot race a newer lease write.


## How This App Connects to Other Umbrella Apps

- **Depends on `ai`**: Uses `LemonAi.stream/3`, `LemonAi.complete/3`, `LemonAi.Types.*` (message types, model types, stream options), `LemonAi.EventStream`, `LemonAi.PromptDiagnostics`.
- **Depends on `lemon_core`**: Uses `LemonCore.Telemetry.emit/3`, `LemonCore.Introspection.record/3`, `LemonCore.ResumeToken`.
- **Depended on by `coding_agent`**: The coding agent app uses `LemonAgent` for its agent runtime.
- **Depended on by `lemon_automation`**: Automation uses `LemonAgent` for scheduled/triggered agent runs.
- **Depended on by other apps**: Any umbrella app that needs AI agent capabilities depends on `agent_core`.

## Introspection Events

LemonAgent emits introspection events via `LemonCore.Introspection.record/3`. Payloads never include prompt or response content.

### Agent Loop Events

| Event Type | Provenance | Emitted By | When |
|---|---|---|---|
| `:agent_loop_started` | `:direct` | `LemonAgent.Agent` | Agent loop begins (`start_loop`) |
| `:agent_turn_observed` | `:inferred` | `LemonAgent.Agent` | Each turn completes (`{:turn_end, ...}`) |
| `:agent_loop_ended` | `:direct` | `LemonAgent.Agent` | Agent loop finishes (`handle_task_completion`) |

## Subagent Spawning Patterns

### Basic Subagent

```elixir
{:ok, pid} = LemonAgent.SubagentSupervisor.start_subagent(
  model: model,
  system_prompt: "Research assistant",
  tools: tools,
  convert_to_llm: &MyApp.convert/1
)
LemonAgent.Agent.prompt(pid, "Research this topic")
:ok = LemonAgent.Agent.wait_for_idle(pid)
state = LemonAgent.Agent.get_state(pid)
LemonAgent.SubagentSupervisor.stop_subagent(pid)
```

### Registered Subagent (lookup by key)

```elixir
{:ok, pid} = LemonAgent.SubagentSupervisor.start_subagent(
  registry_key: {session_id, :research, 0},
  model: model,
  system_prompt: "Research assistant",
  convert_to_llm: &MyApp.convert/1
)

# Later lookup:
{:ok, pid} = LemonAgent.AgentRegistry.lookup({session_id, :research, 0})
```

### Concurrent Subagents

```elixir
tasks = for i <- 0..2 do
  Task.async(fn ->
    {:ok, pid} = LemonAgent.SubagentSupervisor.start_subagent(
      registry_key: {session_id, :worker, i},
      model: model,
      system_prompt: "Parallel worker #{i}",
      convert_to_llm: &MyApp.convert/1
    )
    LemonAgent.Agent.prompt(pid, "Process chunk #{i}")
    :ok = LemonAgent.Agent.wait_for_idle(pid)
    state = LemonAgent.Agent.get_state(pid)
    LemonAgent.SubagentSupervisor.stop_subagent(pid)
    state.messages
  end)
end
results = Task.await_many(tasks)
```

## Dependencies

- `ai` -- Low-level LLM API abstractions
- `lemon_core` -- Shared primitives, telemetry, and introspection
- `req` -- HTTP client (used by Proxy)
- `jason` -- JSON encoding/decoding
- `stream_data` -- Property-based testing (test only)
