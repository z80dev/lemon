defmodule LemonAgent.Loop.ToolDefaultsTest do
  use ExUnit.Case, async: true
  alias LemonAgent.{EventStream, Loop.ToolCalls}
  alias LemonAgent.Types.{AgentContext, AgentLoopConfig, AgentTool, AgentToolResult}
  alias LemonAgent.Test.Mocks
  alias LemonAi.Types.TextContent

  test "loop and agent defaults are bounded and infinity remains explicit" do
    assert %AgentLoopConfig{tool_timeout_ms: 300_000, max_tool_concurrency: 8} =
             %AgentLoopConfig{}

    agent = start_supervised!({LemonAgent.Agent, []})
    assert %{tool_timeout_ms: 300_000, max_tool_concurrency: 8} = :sys.get_state(agent)

    assert LemonAgent.new_tool(
             name: "own",
             description: "own",
             timeout_ms: :infinity,
             execute: fn _, _, _, _ -> result() end
           ).timeout_ms == :infinity
  end

  test "hung tools use their declared deadline and return an error-shaped timeout" do
    tool = %AgentTool{
      name: "hung",
      timeout_ms: 15,
      execute: fn _, _, _, _ -> Process.sleep(:infinity) end
    }

    {[message], _, _, _} = run(tool, 1, %AgentLoopConfig{tool_timeout_ms: 200})
    assert message.is_error
    assert message.details == %{error_type: :tool_task_timeout, timeout_ms: 15}
    assert [%TextContent{text: "Tool task timed out after 15ms"}] = message.content
  end

  test "deadline-owning tools and explicit infinity config are not killed" do
    for {override, config} <- [{:infinity, 10}, {nil, :infinity}] do
      tool = %AgentTool{
        name: "long",
        timeout_ms: override,
        execute: fn _, _, _, _ ->
          Process.sleep(40)
          result()
        end
      }

      {[message], _, _, _} = run(tool, 1, %AgentLoopConfig{tool_timeout_ms: config})
      refute message.is_error
    end
  end

  test "nil config inherits a concurrency bound of eight" do
    exercise_concurrency(nil, 8)
  end

  test "infinity config explicitly opts out of the concurrency bound" do
    exercise_concurrency(:infinity, 12)
  end

  defp exercise_concurrency(limit, first_wave) do
    parent = self()

    tool = %AgentTool{
      name: "blocked",
      parallel_safe: true,
      execute: fn id, _, _, _ ->
        send(parent, {:started, id, self()})

        receive do
          :finish -> result()
        end
      end
    }

    runner = Task.async(fn -> run(tool, 12, %AgentLoopConfig{max_tool_concurrency: limit}) end)

    workers =
      for _ <- 1..first_wave do
        assert_receive {:started, _, worker}, 1_000
        worker
      end

    refute_receive {:started, _, _}, 50
    Enum.each(workers, &send(&1, :finish))

    for _ <- 1..(12 - first_wave)//1 do
      assert_receive {:started, _, worker}, 1_000
      send(worker, :finish)
    end

    {messages, _, _, _} = Task.await(runner, 2_000)
    assert length(messages) == 12
    assert Enum.all?(messages, &(not &1.is_error))
  end

  defp run(tool, count, config) do
    {:ok, stream} = EventStream.start_link(timeout: :infinity)
    context = %AgentContext{tools: [tool]}
    calls = for i <- 1..count, do: Mocks.tool_call(tool.name, %{}, id: "call-#{i}")

    try do
      ToolCalls.execute_and_collect_tools(context, [], calls, config, nil, stream)
    after
      EventStream.complete(stream, [])
    end
  end

  defp result, do: %AgentToolResult{content: [%TextContent{text: "done"}]}
end
