# BEAM Agent Architecture and Invariants

This document describes the BEAM/OTP architecture for agent management in the Lemon codebase.

## Table of Contents

1. [Core Invariants](#core-invariants)
2. [Supervision Tree](#supervision-tree)
3. [Event Flow](#event-flow)
4. [Telemetry Events](#telemetry-events)
5. [Baseline Documentation (Phase 0)](#baseline-documentation-phase-0)
   - [Current Tool Execution Path](#current-tool-execution-path)
   - [Failure Handling](#failure-handling)
   - [Session Event Fan-Out](#session-event-fan-out)
   - [Current Supervision Structure](#current-supervision-structure)
6. [Regression Testing Checklist](#regression-testing-checklist)

---

## Core Invariants

All agent implementations must adhere to these invariants:

### 1. Agent Loops Must Be Supervised Tasks

All agent loop executions must run under a `Task.Supervisor`. This ensures:

- Crash visibility through supervisor monitoring
- Proper resource cleanup on termination
- Observable lifecycle through OTP tooling

**Implementation:**
- `AgentCore.LoopTaskSupervisor` - Task.Supervisor for agent loop tasks
- Agent loops started via `Task.Supervisor.async_nolink/2` or `start_child/2`

### 2. Agent Event Streams Must Be Bounded and Cancelable

Event streams must have:

- **Bounded queues** - Configurable `max_queue` to prevent unbounded memory growth
- **Backpressure** - `push/2` provides feedback for flow control
- **Cancellation** - Explicit `cancel/2` API for clean termination
- **Owner monitoring** - Streams auto-cancel when owner process dies
- **Timeout support** - Configurable stream timeout with automatic cancellation

**Implementation:**
- `AgentCore.EventStream` - Provides bounded, cancelable event streaming
- Options: `:owner`, `:max_queue`, `:drop_strategy`, `:timeout`

### 3. Subagents Must Be Registered, Discoverable, and Supervised

All subagents (child agent processes) must:

- Register in `AgentCore.AgentRegistry` for discoverability
- Run under `AgentCore.SubagentSupervisor` for supervision
- Use structured keys like `{session_id, role, index}` for identification

**Implementation:**
- `AgentCore.AgentRegistry` - Registry for agent process lookup
- `AgentCore.SubagentSupervisor` - DynamicSupervisor for subagent lifecycle

### 4. Coordinators Must Cancel Subagents on Timeout or Parent Termination

Coordinator processes that spawn subagents must:

- Track all spawned subagents by ID
- Monitor subagent processes for crashes
- Cancel all subagents when the coordinator terminates
- Enforce timeouts and cancel remaining subagents when one completes

**Implementation:**
- `CodingAgent.Coordinator` - Orchestrates subagent execution
- Uses process monitoring and timeout-based cancellation

---

## Supervision Tree

```
AgentCore.Supervisor (:one_for_one)
+-- AgentCore.AgentRegistry (Registry)
+-- AgentCore.SubagentSupervisor (DynamicSupervisor)
+-- AgentCore.LoopTaskSupervisor (Task.Supervisor)
```

---

## Event Flow

```
+------------------------------------------------------------------+
| Client Application                                                |
+-----------------------------+------------------------------------+
                              |
                              v
        +------------------------------------------------------+
        | AgentCore.Agent (GenServer)                          |
        | - Manages state                                      |
        | - Subscribers + monitoring                           |
        | - Queue management (steering/follow-up)              |
        | - Task lifecycle (supervised)                        |
        +-------------------------+----------------------------+
                                  |
         Task.Supervisor.async_nolink (LoopTaskSupervisor)
                                  |
                                  v
        +------------------------------------------------------+
        | AgentCore.Loop (Supervised Task)                     |
        | - agent_loop / agent_loop_continue                   |
        | - Creates EventStream (bounded, cancelable)          |
        | - Runs stateless loop logic                          |
        | - Manages LLM calls + tool execution                 |
        +-------------------------+---------------+------------+
                                  |               |
                       Emits Events via       Spawns Tools
                       EventStream.push()      (Parallel)
                                  |               |
                   +--------------+--+     +------+------+
                   | EventStream     |     | Tool Tasks  |
                   | (GenServer)     |     |             |
                   | - Bounded       |     | Monitored   |
                   | - Cancelable    |     |             |
                   +-----------------+     +-------------+
```

---

## Telemetry Events

The following telemetry events are emitted:

- `[:agent_core, :loop, :start]` - Agent loop started
- `[:agent_core, :loop, :end]` - Agent loop completed
- `[:agent_core, :subagent, :spawn]` - Subagent spawned
- `[:agent_core, :subagent, :end]` - Subagent completed
- `[:agent_core, :event_stream, :queue_depth]` - Queue depth measurement
- `[:ai, :dispatcher, :queue_depth]` - Dispatcher queue measurement
- `[:ai, :dispatcher, :rejected]` - Request rejected (rate limit/circuit open)

---

## Baseline Documentation (Phase 0)

This section provides detailed baseline documentation for the current BEAM agent
implementation. It serves as Phase 0 of the BEAM Agent Sessions Plan, establishing
a reference point for understanding current behavior before making architectural
changes.

### Current Tool Execution Path

Tool execution is handled in `apps/agent_core/lib/agent_core/loop.ex`.

#### Entry Point

Tool calls are extracted from assistant messages and executed in parallel:

```elixir
# Line 674-679
defp execute_and_collect_tools(context, new_messages, tool_calls, config, signal, stream) do
  {results, steering_messages, context, new_messages} =
    execute_tool_calls(context, new_messages, tool_calls, config, signal, stream)

  {results, steering_messages, context, new_messages}
end
```

#### Parallel Execution

The `execute_tool_calls_parallel/5` function (line 690) spawns tool tasks:

```elixir
# Line 690-716
defp execute_tool_calls_parallel(context, new_messages, tool_calls, signal, stream) do
  parent = self()

  {pending_by_ref, pending_by_mon} =
    Enum.reduce(tool_calls, {%{}, %{}}, fn tool_call, {by_ref, by_mon} ->
      tool = find_tool(context.tools, tool_call.name)

      EventStream.push(stream, {:tool_execution_start, tool_call.id, tool_call.name, tool_call.arguments})

      ref = make_ref()

      pid =
        spawn(fn ->  # <-- NOT supervised, uses raw spawn/1
          {result, is_error} = execute_tool_call(tool, tool_call, signal, stream)
          send(parent, {:tool_task_result, ref, tool_call, result, is_error})
        end)

      mon_ref = Process.monitor(pid)  # <-- Monitor for crash detection

      {
        Map.put(by_ref, ref, %{tool_call: tool_call, mon_ref: mon_ref}),
        Map.put(by_mon, mon_ref, ref)
      }
    end)

  collect_parallel_tool_results(context, new_messages, pending_by_ref, pending_by_mon, [], stream)
end
```

#### Key Implementation Details

| Aspect | Implementation | Location |
|--------|---------------|----------|
| Process creation | `spawn/1` (unsupervised) | Line 702 |
| Crash detection | `Process.monitor(pid)` | Line 707 |
| Result tracking | `pending_by_ref` and `pending_by_mon` maps | Lines 693, 709-711 |
| Result message | `{:tool_task_result, ref, tool_call, result, is_error}` | Line 704 |

#### Result Collection

Results are collected in `collect_parallel_tool_results/6` (lines 718-783):

```elixir
receive do
  {:tool_task_result, ref, tool_call, result, is_error} ->
    # Normal completion - process result
    ...

  {:DOWN, mon_ref, :process, _pid, reason} ->
    # Process crashed - convert to error result
    ...
end
```

---

### Failure Handling

#### Process Crash Handling

When a tool task process crashes, the DOWN message is handled at lines 745-780:

```elixir
# Lines 745-780
{:DOWN, mon_ref, :process, _pid, reason} ->
  case Map.get(pending_by_mon, mon_ref) do
    nil ->
      # Unknown monitor, continue collecting
      collect_parallel_tool_results(...)

    ref ->
      %{tool_call: tool_call} = Map.fetch!(pending_by_ref, ref)
      {pending_by_ref, pending_by_mon} = drop_pending_task(pending_by_ref, pending_by_mon, ref)

      {context, new_messages, results} =
        emit_tool_result(
          tool_call,
          error_to_result("Tool task crashed: #{inspect(reason)}"),  # <-- Error conversion
          true,  # is_error = true
          context,
          new_messages,
          results,
          stream
        )

      collect_parallel_tool_results(...)
  end
```

#### Exception Handling in Tool Execution

Tool execution includes try/rescue at lines 844-857:

```elixir
# Lines 844-857
defp execute_single_tool(tool, tool_call, signal, stream) do
  # ... on_update callback setup ...

  try do
    case tool.execute.(tool_call.id, tool_call.arguments, signal, on_update) do
      {:ok, result} -> {result, false}
      {:error, reason} -> {error_to_result(reason), true}
      %AgentToolResult{} = result -> {result, false}
      other -> {error_to_result("Unexpected tool result: #{inspect(other)}"), true}
    end
  rescue
    e ->
      {error_to_result(Exception.message(e)), true}
  catch
    kind, value ->
      {error_to_result("#{kind}: #{inspect(value)}"), true}
  end
end
```

#### Missing Tool Handling

When a tool is not found, an error result is returned (lines 820-826):

```elixir
# Lines 820-827
defp execute_tool_call(nil, tool_call, _signal, _stream) do
  error_result = %AgentToolResult{
    content: [%TextContent{type: :text, text: "Tool #{tool_call.name} not found"}],
    details: nil
  }

  {error_result, true}
end
```

#### Error Result Conversion

The `error_to_result/1` helper converts errors to `AgentToolResult` structs:

```elixir
# Lines 1067-1079
defp error_to_result(reason) when is_binary(reason) do
  %AgentToolResult{
    content: [%TextContent{type: :text, text: reason}],
    details: nil
  }
end

defp error_to_result(reason) do
  %AgentToolResult{
    content: [%TextContent{type: :text, text: inspect(reason)}],
    details: nil
  }
end
```

---

### Session Event Fan-Out

Event broadcasting is handled in `apps/coding_agent/lib/coding_agent/session.ex`.

#### Broadcast Implementation

The `broadcast_event/2` function (lines 1031-1040):

```elixir
# Lines 1031-1040
@spec broadcast_event(t(), AgentCore.Types.agent_event()) :: :ok
defp broadcast_event(state, event) do
  session_event = {:session_event, state.session_manager.header.id, event}

  Enum.each(state.event_listeners, fn {pid, _ref} ->
    send(pid, session_event)  # <-- Fire and forget
  end)

  :ok
end
```

#### Subscriber Management

Subscribers are tracked as `{pid, monitor_ref}` tuples:

```elixir
# Line 83 (state definition)
event_listeners: [{pid(), reference()}],

# Lines 504-514 (subscription)
def handle_call({:subscribe, pid}, _from, state) do
  monitor_ref = Process.monitor(pid)
  new_listeners = [{pid, monitor_ref} | state.event_listeners]
  # ...
end
```

#### Potential Issues

| Issue | Description | Risk |
|-------|-------------|------|
| No backpressure | `send/2` is fire-and-forget | Mailbox can grow unboundedly |
| Slow consumers | Fast event emission with slow processing | Memory pressure |
| No batching | Each event sent individually | Overhead with many subscribers |

#### Dead Subscriber Cleanup

Subscribers are removed when they die (lines 791-799):

```elixir
# Lines 791-799
def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
  # Subscriber died, remove from listeners
  new_listeners =
    Enum.reject(state.event_listeners, fn {listener_pid, monitor_ref} ->
      listener_pid == pid and monitor_ref == ref
    end)

  {:noreply, %{state | event_listeners: new_listeners}}
end
```

---

### Current Supervision Structure

#### AgentCore.Application

File: `apps/agent_core/lib/agent_core/application.ex`

```
AgentCore.Supervisor (:one_for_one)
+-- AgentCore.AgentRegistry (Registry, keys: :unique)
+-- AgentCore.SubagentSupervisor (DynamicSupervisor)
+-- AgentCore.LoopTaskSupervisor (Task.Supervisor)
```

```elixir
# Lines 24-36
def start(_type, _args) do
  children = [
    # Registry for agent process lookup and discovery
    {Registry, keys: :unique, name: AgentCore.AgentRegistry},
    # DynamicSupervisor for subagent processes
    {AgentCore.SubagentSupervisor, name: AgentCore.SubagentSupervisor},
    # Task.Supervisor for agent loop tasks
    {Task.Supervisor, name: AgentCore.LoopTaskSupervisor}
  ]

  opts = [strategy: :one_for_one, name: AgentCore.Supervisor]
  Supervisor.start_link(children, opts)
end
```

#### CodingAgent.Application

File: `apps/coding_agent/lib/coding_agent/application.ex`

```
CodingAgent.Supervisor (:one_for_one)
+-- CodingAgent.SessionRegistry (Registry, keys: :unique)
+-- CodingAgent.SessionSupervisor (DynamicSupervisor)
```

```elixir
# Lines 8-14
def start(_type, _args) do
  children = [
    {Registry, keys: :unique, name: CodingAgent.SessionRegistry},
    CodingAgent.SessionSupervisor
  ]

  opts = [strategy: :one_for_one, name: CodingAgent.Supervisor]
  # ...
end
```

#### Agent Loop Tasks

Agent loop tasks ARE supervised via `Task.Supervisor`:

```elixir
# apps/agent_core/lib/agent_core/loop.ex, Lines 115-134
case Task.Supervisor.start_child(AgentCore.LoopTaskSupervisor, fn ->
    try do
      run_agent_loop(prompts, context, config, signal, stream_fn, stream)
    rescue
      e ->
        EventStream.error(stream, {:exception, Exception.message(e)}, nil)
    catch
      kind, value ->
        EventStream.error(stream, {kind, value}, nil)
    end
  end) do
  {:ok, pid} ->
    EventStream.attach_task(stream, pid)
  # ...
end
```

#### Tool Tasks - NOT Supervised

**Critical Note**: Individual tool execution tasks use raw `spawn/1` and are NOT
under supervision:

```elixir
# apps/agent_core/lib/agent_core/loop.ex, Line 702
pid =
  spawn(fn ->  # <-- NOT supervised
    {result, is_error} = execute_tool_call(tool, tool_call, signal, stream)
    send(parent, {:tool_task_result, ref, tool_call, result, is_error})
  end)
```

This means:
- Tool task crashes are detected via monitors but not automatically restarted
- No supervisor visibility into running tool tasks
- No graceful shutdown coordination for tool tasks

---

## Regression Testing Checklist

Use this checklist to verify BEAM agent behavior after making changes:

### Tool Execution

- [ ] Tool tasks complete normally and return results
- [ ] Tool task crashes are handled gracefully (converted to error results)
- [ ] Missing tools return appropriate error message
- [ ] Tool exceptions are caught and converted to error results
- [ ] Parallel tool execution completes all tools
- [ ] Tool execution events are emitted: `tool_execution_start`, `tool_execution_update`, `tool_execution_end`

### Abort Handling

- [ ] Abort mid-tools terminates running tasks
- [ ] Abort signal is respected during tool execution
- [ ] Partial results are handled correctly on abort
- [ ] Agent loop exits cleanly on abort

### Event Broadcasting

- [ ] Session events reach all subscribers
- [ ] Slow subscribers don't block session
- [ ] Dead subscribers are cleaned up automatically
- [ ] Events are delivered in order to each subscriber
- [ ] Event format: `{:session_event, session_id, event}`

### Registry Operations

- [ ] Main agent appears in AgentCore.AgentRegistry
- [ ] Subagents appear in AgentCore.AgentRegistry
- [ ] Sessions appear in CodingAgent.SessionRegistry
- [ ] Registry cleanup occurs on process termination

### Session Isolation

- [ ] Session crash doesn't affect other sessions
- [ ] Each session maintains independent state
- [ ] Session supervisor restarts failed sessions (if configured)
- [ ] Session events are scoped to their session_id

### Supervision Tree

- [ ] AgentCore.Supervisor starts successfully
- [ ] CodingAgent.Supervisor starts successfully
- [ ] Child process failures are handled per supervision strategy
- [ ] Application restart brings up all required processes

### Message Persistence

- [ ] User messages are persisted on `message_end`
- [ ] Assistant messages are persisted on `message_end`
- [ ] Tool result messages are persisted on `message_end`
- [ ] Session can be restored from persisted messages

---

## File Reference

| Component | File Path |
|-----------|-----------|
| Tool execution loop | `apps/agent_core/lib/agent_core/loop.ex` |
| Agent GenServer | `apps/agent_core/lib/agent_core/agent.ex` |
| AgentCore supervisor | `apps/agent_core/lib/agent_core/application.ex` |
| Event stream | `apps/agent_core/lib/agent_core/event_stream.ex` |
| Session GenServer | `apps/coding_agent/lib/coding_agent/session.ex` |
| CodingAgent supervisor | `apps/coding_agent/lib/coding_agent/application.ex` |
| Session supervisor | `apps/coding_agent/lib/coding_agent/session_supervisor.ex` |
| Session registry | `apps/coding_agent/lib/coding_agent/session_registry.ex` |

---

## Known Limitations

1. **Unsupervised tool tasks**: Tool execution processes use `spawn/1`, making them
   invisible to the supervision tree and preventing graceful shutdown coordination.

2. **No event backpressure**: Event broadcasting uses fire-and-forget `send/2`,
   which can cause mailbox growth with slow consumers.

3. **No event batching**: Each event is sent individually to each subscriber,
   creating overhead with many subscribers or high event frequency.

4. **Monitor-only crash detection**: Tool crashes are detected but not automatically
   retried or escalated to supervisors.
