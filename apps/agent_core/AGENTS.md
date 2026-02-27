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

## Quick Orientation

This is an Elixir umbrella app at `apps/agent_core/`. It depends on `ai` (LLM abstractions) and `lemon_core` (shared primitives). Applications that need AI agents depend on `agent_core` rather than calling `Ai` directly.

The two main entry points are:
1. **`AgentCore` module** (`lib/agent_core.ex`) -- High-level API facade. Most callers use `AgentCore.new_agent/1`, `AgentCore.prompt/2`, `AgentCore.wait_for_idle/2`.
2. **`AgentCore.Agent` module** (`lib/agent_core/agent.ex`) -- Full GenServer API including `steer/2`, `follow_up/2`, queue controls, and state mutators.

## Architecture

```
AgentCore.Supervisor (:one_for_one)
|-- AgentCore.AbortSignal.TableOwner  (owns the abort ETS table)
|-- AgentCore.AgentRegistry           (Registry, :unique keys)
|-- AgentCore.SubagentSupervisor      (DynamicSupervisor)
|-- AgentCore.LoopTaskSupervisor      (Task.Supervisor for loop tasks)
+-- AgentCore.ToolTaskSupervisor      (Task.Supervisor for tool execution)
```

## Key Files and Their Purposes

### Core (read these first)

| File | What It Does |
|------|-------------|
| `lib/agent_core.ex` | Public API facade. Delegates lifecycle ops to `Agent`, provides convenience constructors (`new_tool/1`, `new_tool_result/1`, `text_content/1`), wraps `Loop.stream/4`. |
| `lib/agent_core/agent.ex` | **The GenServer.** ~1260 lines. Manages state, subscribers, steering/follow-up queues, abort refs, waiter lists. Spawns loop tasks under `LoopTaskSupervisor`. Broadcasts events to listeners. |
| `lib/agent_core/types.ex` | All core structs: `AgentState`, `AgentContext`, `AgentTool`, `AgentToolResult`, `AgentLoopConfig`. Type union for `agent_event()`. |
| `lib/agent_core/loop.ex` | Stateless agentic loop. Recursive inner/outer loop: stream LLM response -> execute tools -> check steering -> repeat. Outer loop checks follow-up messages after inner loop exits. |
| `lib/agent_core/loop/streaming.ex` | Handles the LLM streaming call. Transforms context, converts messages, calls `Ai.stream/3` (or custom `stream_fn`), processes SSE events into `message_start`/`message_update`/`message_end`. |
| `lib/agent_core/loop/tool_calls.ex` | Parallel tool execution under `ToolTaskSupervisor`. Respects `max_tool_concurrency`. Handles abort by terminating pending tasks. |

### Infrastructure

| File | What It Does |
|------|-------------|
| `lib/agent_core/event_stream.ex` | GenServer-based bounded event queue. Producer pushes with backpressure, consumer reads via `events/1` (lazy `Stream.resource`). Handles owner death, task death, timeout. |
| `lib/agent_core/context.ex` | Context window management. `estimate_size/2` counts chars (~4 chars/token). `truncate/2` with sliding window or bookends strategy. `make_transform/1` creates a function for `AgentLoopConfig.transform_context`. |
| `lib/agent_core/abort_signal.ex` | ETS-based abort flag. `new/0` creates a ref, `abort/1` sets it, `aborted?/1` checks it. Fast reads via `read_concurrency: true`. |
| `lib/agent_core/proxy.ex` | SSE proxy for routing LLM calls through an HTTP server. Reconstructs partial `AssistantMessage` from stripped delta events. |
| `lib/agent_core/text_generation.ex` | Simple `complete_text/4` bridge so callers don't import `Ai` directly. |
| `lib/agent_core/agent_registry.ex` | Thin wrapper around `Registry`. Keys are `{session_id, role, index}` tuples. `via/1`, `lookup/1`, `list_by_session/1`, `list_by_role/1`. |
| `lib/agent_core/subagent_supervisor.ex` | `DynamicSupervisor` for subagent processes. Children are `:temporary`. `start_subagent/1` accepts `registry_key:` option. |
| `lib/agent_core/application.ex` | OTP app. Starts the supervision tree. |

### CLI Runners

| File | What It Does |
|------|-------------|
| `lib/agent_core/cli_runners/jsonl_runner.ex` | Base behaviour + GenServer for JSONL-streaming CLI subprocesses. ~1230 lines. Handles port spawning, JSONL line buffering, session locking, stderr capture, graceful shutdown. |
| `lib/agent_core/cli_runners/types.ex` | CLI event types: `ResumeToken`, `Action`, `StartedEvent`, `ActionEvent`, `CompletedEvent`, `EventFactory`. |
| `lib/agent_core/cli_runners/tool_action_helpers.ex` | Helpers for mapping between tool events and action events. |
| `lib/agent_core/cli_runners/{claude,codex,kimi,opencode,pi}_runner.ex` | Engine-specific runners implementing `JsonlRunner` behaviour. |
| `lib/agent_core/cli_runners/{claude,codex,kimi,opencode,pi}_schema.ex` | JSON event parsing for each engine's output format. |
| `lib/agent_core/cli_runners/{claude,codex,kimi,opencode,pi}_subagent.ex` | Subagent wrappers integrating runners with `SubagentSupervisor`. |

## Common Modification Patterns

### Adding a new tool

Define a tool struct and pass it to `AgentCore.new_agent/1`:

```elixir
my_tool = AgentCore.new_tool(
  name: "my_tool",
  description: "Does something",
  parameters: %{"type" => "object", "properties" => %{...}, "required" => [...]},
  execute: fn tool_call_id, params, signal, on_update ->
    # Check abort: AgentCore.AbortSignal.aborted?(signal)
    # Report progress: on_update.(partial_result)
    AgentCore.new_tool_result(content: [AgentCore.text_content("result")])
  end
)
```

The execute function signature is `(String.t(), map(), reference() | nil, (AgentToolResult.t() -> :ok) | nil) -> AgentToolResult.t() | {:ok, AgentToolResult.t()} | {:error, term()}`.

### Adding a new agent event type

1. Add the type to the `agent_event()` union in `lib/agent_core/types.ex`.
2. Emit via `EventStream.push(stream, {:my_event, ...})` in the loop or tool calls module.
3. Handle in `AgentCore.Agent.handle_agent_event/2` if state updates are needed.
4. Update subscriber code to handle the new event pattern.

### Adding a new CLI runner engine

1. Create `lib/agent_core/cli_runners/myengine_runner.ex` with `use AgentCore.CliRunners.JsonlRunner`.
2. Implement callbacks: `engine/0`, `build_command/3`, `init_state/4`, `translate_event/2`, `handle_exit_error/2`, `handle_stream_end/1`.
3. Create `lib/agent_core/cli_runners/myengine_schema.ex` for JSON event parsing if the engine format is complex.
4. Create `lib/agent_core/cli_runners/myengine_subagent.ex` to integrate with `SubagentSupervisor`.
5. Add resume token support in `LemonCore.ResumeToken` (extract/format/is_resume_line patterns).
6. Add tests: `test/agent_core/cli_runners/myengine_runner_test.exs`.

### Modifying the agent loop behavior

The loop is in `lib/agent_core/loop.ex`. The inner loop (`do_inner_loop/10`) handles tool calls and steering. The outer loop (`do_run_loop/8`) handles follow-up messages. LLM streaming is delegated to `Loop.Streaming`. Tool execution is delegated to `Loop.ToolCalls`.

Key change points:
- **Before each LLM call**: `Loop.Streaming.stream_assistant_response/5` calls `transform_messages` then `convert_messages` then the stream function.
- **After tool execution**: `Loop.ToolCalls.execute_and_collect_tools/6` returns results and any steering messages.
- **Loop exit**: The outer loop checks `get_follow_up_messages` before emitting `{:agent_end, new_messages}`.

### Modifying the Agent GenServer

`lib/agent_core/agent.ex` has clearly separated sections:
- Client API (lines ~117-457): public functions.
- GenServer Callbacks (lines ~463-834): `handle_call`, `handle_cast`, `handle_info`.
- Private Functions (lines ~840-1262): `start_loop`, `build_loop_config`, `run_agent_loop`, event handling, task completion.

The `start_loop/2` function builds the `AgentLoopConfig`, creates an abort signal, and spawns a task under `LoopTaskSupervisor`. The task runs `run_agent_loop/6` which calls `AgentCore.Loop.agent_loop/6` or `agent_loop_continue/5`, then consumes the `EventStream` and forwards events to the GenServer via `send(agent_pid, {:agent_event, event})`.

## AgentCore.Agent - Full API Reference

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

**Note:** `steer/2` and `follow_up/2` are on `AgentCore.Agent`, not on the top-level `AgentCore` module.

## AgentLoopConfig Fields

```elixir
%AgentCore.Types.AgentLoopConfig{
  # Required
  model: my_model,                          # Ai.Types.Model.t()
  convert_to_llm: fn messages -> {:ok, llm_messages} end,

  # Optional
  transform_context: fn messages, signal -> {:ok, transformed} end,
  get_api_key: fn provider -> api_key end,
  get_steering_messages: fn -> [] end,       # Wired by Agent GenServer
  get_follow_up_messages: fn -> [] end,      # Wired by Agent GenServer
  max_tool_concurrency: nil,                 # nil/:infinity = unbounded, or pos_integer
  stream_options: %Ai.Types.StreamOptions{},
  stream_fn: nil                             # custom stream fn, defaults to Ai.stream/3
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

CLI runner events are wrapped:
```elixir
{:cli_event, %StartedEvent{...}}
{:cli_event, %ActionEvent{...}}
{:cli_event, %CompletedEvent{...}}
```

## Testing Guidance

### Running Tests

```bash
mix test apps/agent_core                    # All tests
mix test apps/agent_core/test/agent_core/agent_test.exs  # Specific file
mix test apps/agent_core --include integration            # Include CLI integration tests
```

### Writing Tests

Most tests use `async: true`. The standard pattern:

```elixir
defmodule AgentCore.MyFeatureTest do
  use ExUnit.Case, async: true

  alias AgentCore.Test.Mocks  # if it exists in test/support/

  setup do
    {:ok, agent} = AgentCore.new_agent(
      model: %{provider: :mock, id: "test"},
      system_prompt: "Test",
      convert_to_llm: fn msgs ->
        Enum.filter(msgs, &match?(%{role: role} when role in [:user, :assistant, :tool_result], &1))
      end
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

Integration tests requiring external CLIs use `@tag :integration`:
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
- `test/agent_core/cli_runners/jsonl_runner_test.exs` -- Base runner behavior.

## Gotchas and Important Invariants

1. **`convert_to_llm` is required.** If not provided, `Agent` uses a default that filters to `:user`, `:assistant`, `:tool_result` roles. But most callers should provide their own since custom message types need explicit handling.

2. **`{:agent_end, new_messages}` contains only new messages**, not the full conversation history. The full history is in `AgentCore.Agent.get_state(agent).messages`.

3. **`steer/2` and `follow_up/2` are on `AgentCore.Agent`**, not on the top-level `AgentCore` module. The top-level module delegates lifecycle ops but not queue operations.

4. **Abort is cooperative.** Calling `abort/1` sets a flag; it does not kill anything. Tools must check `AbortSignal.aborted?(signal)` themselves. The loop checks before each LLM call and tool batch.

5. **Queue call timeout.** The loop's steering/follow-up polling uses a GenServer call back to the Agent with a configurable timeout (default 30 minutes). If your loops run longer, set `:queue_call_timeout` in `start_link` opts or `:agent_core, :queue_call_timeout_ms` in app config.

6. **Follow-up long-poll.** The Agent long-polls for 50ms (`@follow_up_poll_timeout_ms`) when checking for follow-up messages. This closes a race where a follow-up is enqueued just as the loop finishes. Do not remove this without understanding the timing implications.

7. **EventStream owner death.** If the EventStream's owner process dies, the stream cancels and shuts down its attached task. The CLI runner addresses this by setting the owner to the caller (not the runner itself) so the stream outlives the runner.

8. **Session locks are ETS-based.** CLI runner session locks use a simple ETS table (`AgentCore.CliRunners.JsonlRunner.SessionLocks`). Locks are reclaimed if the owner process dies or the lock exceeds `cli_session_lock_max_age_ms`.

9. **Tool execution runs under `ToolTaskSupervisor`.** If a tool task crashes, it is caught and reported as an error result. It does not crash the loop.

10. **The AbortSignal ETS table** is created by `AbortSignal.TableOwner` at app startup. The `AbortSignal` module has a fallback `ensure_table` that creates it if needed (for test environments where the app may not be started). The table uses `{:heir, TableOwner, :ok}` so it survives process restarts.

11. **CLI runners use shell wrappers.** Even when there is no stdin, the runner wraps the command in `bash -c` to properly redirect stderr and handle stdin EOF. This means `build_command/3` returns the bare executable and args, not a shell command.

12. **Exit finalization debounce.** CLI runners debounce exit finalization by 100ms (`@exit_finalize_debounce_ms`) because `:exit_status` messages can arrive before trailing stdout `:data` chunks. The timer resets on each new data chunk.

## How This App Connects to Other Umbrella Apps

- **Depends on `ai`**: Uses `Ai.stream/3`, `Ai.complete/3`, `Ai.Types.*` (message types, model types, stream options), `Ai.EventStream`, `Ai.PromptDiagnostics`.
- **Depends on `lemon_core`**: Uses `LemonCore.Telemetry.emit/3`, `LemonCore.Introspection.record/3`, `LemonCore.ResumeToken`.
- **Depended on by `coding_agent`**: The coding agent app uses `AgentCore` for its agent runtime.
- **Depended on by `lemon_automation`**: Automation uses `AgentCore` for scheduled/triggered agent runs.
- **Depended on by other apps**: Any umbrella app that needs AI agent capabilities depends on `agent_core`.

## Introspection Events

AgentCore emits introspection events via `LemonCore.Introspection.record/3`. Payloads never include prompt or response content.

### Agent Loop Events

| Event Type | Provenance | Emitted By | When |
|---|---|---|---|
| `:agent_loop_started` | `:direct` | `AgentCore.Agent` | Agent loop begins (`start_loop`) |
| `:agent_turn_observed` | `:inferred` | `AgentCore.Agent` | Each turn completes (`{:turn_end, ...}`) |
| `:agent_loop_ended` | `:direct` | `AgentCore.Agent` | Agent loop finishes (`handle_task_completion`) |

### JSONL Runner Events

| Event Type | Provenance | Emitted By | When |
|---|---|---|---|
| `:jsonl_stream_started` | `:direct` | `JsonlRunner` | CLI subprocess stream begins |
| `:tool_use_observed` | `:inferred` | `JsonlRunner` | Tool call detected in engine output |
| `:assistant_turn_observed` | `:inferred` | `JsonlRunner` | Assistant text turn detected |
| `:jsonl_stream_ended` | `:direct` | `JsonlRunner` | CLI subprocess stream ends |

### CLI Runner Engine Events (provenance: `:inferred`)

| Event Type | Engines | When |
|---|---|---|
| `:engine_subprocess_started` | codex, claude, kimi, opencode, pi | Engine session/subprocess initialized |
| `:engine_output_observed` | codex, kimi, opencode, pi | Engine produces a final answer or output |
| `:engine_subprocess_exited` | codex, claude, kimi, opencode, pi | Engine subprocess exits with error |

## Subagent Spawning Patterns

### Basic Subagent

```elixir
{:ok, pid} = AgentCore.SubagentSupervisor.start_subagent(
  model: model,
  system_prompt: "Research assistant",
  tools: tools,
  convert_to_llm: &MyApp.convert/1
)
AgentCore.Agent.prompt(pid, "Research this topic")
:ok = AgentCore.Agent.wait_for_idle(pid)
state = AgentCore.Agent.get_state(pid)
AgentCore.SubagentSupervisor.stop_subagent(pid)
```

### Registered Subagent (lookup by key)

```elixir
{:ok, pid} = AgentCore.SubagentSupervisor.start_subagent(
  registry_key: {session_id, :research, 0},
  model: model,
  system_prompt: "Research assistant",
  convert_to_llm: &MyApp.convert/1
)

# Later lookup:
{:ok, pid} = AgentCore.AgentRegistry.lookup({session_id, :research, 0})
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

## Dependencies

- `ai` -- Low-level LLM API abstractions
- `lemon_core` -- Shared primitives, telemetry, and introspection
- `req` -- HTTP client (used by Proxy)
- `jason` -- JSON encoding/decoding
- `stream_data` -- Property-based testing (test only)
