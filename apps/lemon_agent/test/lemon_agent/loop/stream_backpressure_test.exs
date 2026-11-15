defmodule LemonAgent.Loop.StreamBackpressureTest do
  use ExUnit.Case, async: true

  alias LemonAgent.{AbortSignal, EventStream}
  alias LemonAgent.Loop.{Streaming, ToolCalls}
  alias LemonAgent.Test.Mocks
  alias LemonAgent.Types.{AgentContext, AgentLoopConfig, AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent

  test "response forwarding stops its provider when the agent output overflows" do
    {:ok, output} = EventStream.start_link(max_queue: 1, timeout: :infinity)
    {:ok, provider} = LemonAi.EventStream.start_link(timeout: :infinity)
    message = Mocks.assistant_message("partial")

    {:ok, producer} =
      Task.start(fn ->
        receive do
          :produce ->
            :ok = LemonAi.EventStream.push(provider, {:start, message})
            :ok = LemonAi.EventStream.push(provider, {:text_delta, 0, "partial", message})

            receive do
              :finish -> :ok
            end
        end
      end)

    monitor = Process.monitor(producer)
    LemonAi.EventStream.attach_task(provider, producer)
    on_exit(fn -> Process.exit(producer, :kill) end)
    send(producer, :produce)
    stream_fn = fn _, _, _ -> {:ok, provider} end
    config = config(stream_fn: stream_fn)

    assert catch_throw(
             Streaming.stream_assistant_response(
               AgentContext.new(),
               config,
               nil,
               stream_fn,
               output
             )
           ) == {:event_stream_push_failed, :overflow}

    assert {:error, :overflow, nil} = EventStream.result(output)
    assert_receive {:DOWN, ^monitor, :process, ^producer, _}, 1_000
    assert List.last(Enum.to_list(EventStream.events(output))) == {:error, :overflow, nil}
  end

  test "overflow while starting a batch stops already-started workers, even without a signal" do
    supervisor = start_supervised!(Task.Supervisor)
    tool = blocking_tool(self())
    context = AgentContext.new(tools: [tool])
    calls = Enum.map(["first", "second"], &Mocks.tool_call(tool.name, %{}, id: &1))
    {:ok, output} = EventStream.start_link(max_queue: 1, timeout: :infinity)
    config = config(tool_task_supervisor: supervisor, max_tool_concurrency: 2)

    collector =
      Task.async(fn ->
        catch_throw(ToolCalls.execute_and_collect_tools(context, [], calls, config, nil, output))
      end)

    assert_receive {:tool_started, "first", worker}, 1_000
    monitor = Process.monitor(worker)
    assert Task.await(collector) == {:event_stream_push_failed, :overflow}
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1_000
    assert Task.Supervisor.children(supervisor) == []
    refute_received {:tool_started, "second", _}
    assert {:error, :overflow, nil} = EventStream.result(output)
  end

  test "overflow while emitting a result cancels the remaining parallel workers" do
    supervisor = start_supervised!(Task.Supervisor)
    tool = blocking_tool(self())
    context = AgentContext.new(tools: [tool])
    calls = Enum.map(["first", "second"], &Mocks.tool_call(tool.name, %{}, id: &1))
    signal = AbortSignal.new()
    {:ok, output} = EventStream.start_link(max_queue: 2, timeout: :infinity)
    config = config(tool_task_supervisor: supervisor, max_tool_concurrency: 2)

    collector =
      Task.async(fn ->
        catch_throw(
          ToolCalls.execute_and_collect_tools(context, [], calls, config, signal, output)
        )
      end)

    assert_receive {:tool_started, "first", first}, 1_000
    assert_receive {:tool_started, "second", second}, 1_000
    monitor = Process.monitor(second)
    send(first, :finish)

    assert Task.await(collector) == {:event_stream_push_failed, :overflow}
    assert_receive {:DOWN, ^monitor, :process, ^second, _}, 1_000
    assert AbortSignal.aborted?(signal)
    assert Task.Supervisor.children(supervisor) == []
    assert {:error, :overflow, nil} = EventStream.result(output)
  end

  test "an overflowing tool update stops the callback and does not start queued work" do
    parent = self()
    supervisor = start_supervised!(Task.Supervisor)
    signal = AbortSignal.new()

    tool = %AgentTool{
      name: "updates",
      description: "Emits a partial result",
      parameters: %{"type" => "object", "properties" => %{}},
      label: "Updates",
      execute: fn id, _, _, on_update ->
        send(parent, {:tool_started, id})
        on_update.(%AgentToolResult{content: [%TextContent{text: "partial"}]})
        send(parent, {:continued_after_update, id})
        %AgentToolResult{content: []}
      end
    }

    context = AgentContext.new(tools: [tool])
    calls = Enum.map(["first", "second"], &Mocks.tool_call(tool.name, %{}, id: &1))
    {:ok, output} = EventStream.start_link(max_queue: 1, timeout: :infinity)
    config = config(tool_task_supervisor: supervisor, max_tool_concurrency: 1)

    assert {:event_stream_push_failed, reason} =
             catch_throw(
               ToolCalls.execute_and_collect_tools(context, [], calls, config, signal, output)
             )

    assert reason in [:overflow, :canceled]

    assert_received {:tool_started, "first"}
    refute_received {:tool_started, "second"}
    refute_received {:continued_after_update, _}
    assert AbortSignal.aborted?(signal)
    assert Task.Supervisor.children(supervisor) == []
    assert {:error, :overflow, nil} = EventStream.result(output)
  end

  defp config(opts) do
    struct!(
      %AgentLoopConfig{
        model: Mocks.mock_model(),
        convert_to_llm: Mocks.simple_convert_to_llm(),
        max_retries: 0
      },
      opts
    )
  end

  defp blocking_tool(parent) do
    %AgentTool{
      name: "blocks",
      description: "Waits for the test",
      parameters: %{"type" => "object", "properties" => %{}},
      label: "Blocks",
      parallel_safe: true,
      execute: fn id, _, _, _ ->
        send(parent, {:tool_started, id, self()})

        receive do
          :finish -> %AgentToolResult{content: [%TextContent{text: "finished"}]}
        end
      end
    }
  end
end
