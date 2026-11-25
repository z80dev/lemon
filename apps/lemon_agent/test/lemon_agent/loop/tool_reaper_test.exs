defmodule LemonAgent.Loop.ToolReaperTest do
  @moduledoc """
  Tool tasks never outlive the loop that owns them: a killed loop, a loop that
  raises, a stopped `Loop.stream/4` consumer and a stalled loop all leave the
  tool supervisor empty, and cooperative tools observe the abort.
  """
  use ExUnit.Case, async: true

  import LemonCore.Testing.AsyncHelpers, only: [assert_eventually: 2]

  alias LemonAgent.{AbortSignal, EventStream, Loop}
  alias LemonAgent.Test.Mocks
  alias LemonAgent.Types.{AgentContext, AgentLoopConfig, AgentTool, AgentToolResult}
  alias LemonAi.Types.{StreamOptions, TextContent, UserMessage}

  setup do
    supervisor = start_supervised!({Task.Supervisor, max_children: 16})
    %{supervisor: supervisor}
  end

  # Records the abort it observes, then returns cooperatively.
  defp cooperative_tool(test_pid) do
    tool("cooperative", fn signal ->
      AbortSignal.subscribe(signal)
      send(test_pid, {:tool_started, :cooperative, self(), signal})

      receive do
        {:lemon_abort, ^signal, :abort} -> send(test_pid, {:tool_cancelled, :cooperative})
      after
        30_000 -> :ok
      end

      %AgentToolResult{content: [%TextContent{type: :text, text: "stopped"}]}
    end)
  end

  # Ignores cancellation entirely; only termination stops it.
  defp stubborn_tool(test_pid) do
    tool("stubborn", fn signal ->
      send(test_pid, {:tool_started, :stubborn, self(), signal})
      Process.sleep(30_000)
      %AgentToolResult{content: [%TextContent{type: :text, text: "late"}]}
    end)
  end

  defp tool(name, run) do
    %AgentTool{
      name: name,
      description: name,
      parameters: %{},
      label: name,
      parallel_safe: true,
      execute: fn _id, _params, signal, _on_update -> run.(signal) end
    }
  end

  defp config(supervisor, stream_fn, opts \\ []) do
    %AgentLoopConfig{
      model: Mocks.mock_model(),
      convert_to_llm: Mocks.simple_convert_to_llm(),
      stream_options: %StreamOptions{},
      stream_fn: stream_fn,
      tool_task_supervisor: supervisor,
      tool_timeout_ms: Keyword.get(opts, :tool_timeout_ms, 300_000)
    }
  end

  defp context(tools) do
    AgentContext.new(system_prompt: "You are helpful.", messages: [], tools: tools)
  end

  defp prompt do
    %UserMessage{role: :user, content: "go", timestamp: System.system_time(:millisecond)}
  end

  defp tool_turn(names) do
    calls = Enum.map(names, &Mocks.tool_call(&1, %{}, id: "call_#{&1}"))

    Mocks.mock_stream_fn([
      Mocks.assistant_message_with_tool_calls(calls),
      Mocks.assistant_message("done")
    ])
  end

  defp loop_task(stream) do
    Enum.find_value(1..100, fn _ ->
      case :sys.get_state(stream).task_pid do
        pid when is_pid(pid) ->
          pid

        _ ->
          Process.sleep(5)
          nil
      end
    end) || flunk("loop task was not attached")
  end

  defp assert_no_tool_tasks(supervisor, timeout) do
    assert_eventually(fn -> Task.Supervisor.children(supervisor) == [] end, timeout: timeout)
  end

  test "killing the loop mid-batch aborts the signal and reaps every tool task", %{
    supervisor: supervisor
  } do
    signal = AbortSignal.new()
    tools = [cooperative_tool(self()), stubborn_tool(self())]
    config = config(supervisor, tool_turn(["cooperative", "stubborn"]))

    stream = Loop.agent_loop([prompt()], context(tools), config, signal, nil)
    assert_receive {:tool_started, :cooperative, _pid, ^signal}, 2_000
    assert_receive {:tool_started, :stubborn, _pid, ^signal}, 2_000
    assert length(Task.Supervisor.children(supervisor)) == 2

    Process.exit(loop_task(stream), :kill)

    assert_receive {:tool_cancelled, :cooperative}, 1_000
    assert_no_tool_tasks(supervisor, 1_000)
    assert AbortSignal.aborted?(signal)
  end

  test "a stream_fn that raises aborts the signal and leaves no tool task", %{
    supervisor: supervisor
  } do
    signal = AbortSignal.new()
    test_pid = self()

    fast_tool =
      tool("fast", fn _signal ->
        send(test_pid, :fast_tool_ran)
        %AgentToolResult{content: [%TextContent{type: :text, text: "ok"}]}
      end)

    {:ok, calls} = Agent.start_link(fn -> 0 end)
    turn = tool_turn(["fast"])

    stream_fn = fn model, ctx, options ->
      if Agent.get_and_update(calls, &{&1, &1 + 1}) == 0,
        do: turn.(model, ctx, options),
        else: raise("provider exploded")
    end

    stream =
      Loop.agent_loop(
        [prompt()],
        context([fast_tool]),
        config(supervisor, stream_fn),
        signal,
        nil
      )

    assert_receive :fast_tool_ran, 2_000
    assert {:error, {:exception, "provider exploded"}, _} = EventStream.result(stream, 5_000)
    assert AbortSignal.aborted?(signal)
    assert_no_tool_tasks(supervisor, 1_000)
  end

  test "Loop.stream/4 terminates pending tools when its consumer stops", %{
    supervisor: supervisor
  } do
    test_pid = self()
    tools = [cooperative_tool(test_pid), stubborn_tool(test_pid)]
    config = config(supervisor, tool_turn(["cooperative", "stubborn"]))

    consumer =
      spawn(fn ->
        Loop.stream([prompt()], context(tools), config) |> Stream.run()
      end)

    assert_receive {:tool_started, :cooperative, _pid, signal}, 2_000
    assert is_reference(signal)
    assert_receive {:tool_started, :stubborn, _pid, ^signal}, 2_000

    Process.exit(consumer, :kill)

    assert_receive {:tool_cancelled, :cooperative}, 1_000
    assert_no_tool_tasks(supervisor, 1_000)
  end

  test "the tool deadline is enforced even while the loop cannot run", %{
    supervisor: supervisor
  } do
    signal = AbortSignal.new()
    config = config(supervisor, tool_turn(["stubborn"]), tool_timeout_ms: 200)

    stream = Loop.agent_loop([prompt()], context([stubborn_tool(self())]), config, signal, nil)
    assert_receive {:tool_started, :stubborn, tool_pid, ^signal}, 2_000

    loop = loop_task(stream)
    :erlang.suspend_process(loop)
    ref = Process.monitor(tool_pid)

    try do
      assert_receive {:DOWN, ^ref, :process, ^tool_pid, _reason}, 1_000
      assert Task.Supervisor.children(supervisor) == []
    after
      :erlang.resume_process(loop)
    end

    # The resumed loop records the timeout and finishes the run.
    assert {:ok, messages} = EventStream.result(stream, 5_000)

    assert Enum.any?(messages, fn message ->
             match?(
               %{role: :tool_result, is_error: true, details: %{error_type: :tool_task_timeout}},
               message
             )
           end)
  end
end
