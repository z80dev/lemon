defmodule LemonAgent.Loop.ToolCallsTelemetryTest do
  use ExUnit.Case, async: false

  alias LemonAgent.{AbortSignal, EventStream}
  alias LemonAgent.Loop.ToolCalls
  alias LemonAgent.Types.{AgentContext, AgentLoopConfig, AgentTool, AgentToolResult}
  alias LemonAi.Types.{TextContent, ToolCall}

  @events for event <- [:start, :stop, :exception], do: [:lemon_agent, :tool_call, event]

  setup do
    id = "tool-call-telemetry-#{System.unique_integer([:positive])}"
    :ok = :telemetry.attach_many(id, @events, &__MODULE__.handle_event/4, self())
    on_exit(fn -> :telemetry.detach(id) end)
    :ok
  end

  @doc false
  def handle_event(event, measurements, metadata, pid) do
    send(pid, {:telemetry, List.last(event), measurements, metadata})
  end

  test "success and returned error report outcome without args or results" do
    for {name, result, error} <- [
          {"success",
           %AgentToolResult{
             content: [%TextContent{text: "secret result"}],
             details: %{secret: "private"}
           }, false},
          {"error", {:error, "secret failure"}, true}
        ] do
      run(tool(name, fn -> result end))
      assert_pair(name, :stop, error, false)
    end
  end

  test "raise, throw, exit and a killed worker emit exception exactly once" do
    for {name, execute} <- [
          {"raise", fn -> raise "secret exception" end},
          {"throw", fn -> throw("secret thrown value") end},
          {"exit", fn -> exit("secret exit") end},
          {"kill", fn -> Process.exit(self(), :kill) end}
        ] do
      run(tool(name, execute))
      assert_pair(name, :exception, true, false)
    end
  end

  test "loop deadline emits a timeout exception even though the worker is killed" do
    run(tool("deadline", fn -> Process.sleep(200) end), %AgentLoopConfig{tool_timeout_ms: 20})
    assert_pair("deadline", :exception, true, true)
  end

  test "tool-owned timeout remains a returned error with its timeout flag" do
    run(
      tool("owned-timeout", fn ->
        %AgentToolResult{content: [], is_error: true, details: %{timed_out: true}}
      end)
    )

    assert_pair("owned-timeout", :stop, true, true)
  end

  test "task admission failure has a terminal exception" do
    run(tool("start-failure", fn -> %AgentToolResult{} end), %AgentLoopConfig{
      tool_task_supervisor: LemonAgent.MissingTelemetrySupervisor
    })

    assert_pair("start-failure", :exception, true, false)
  end

  test "unknown tool and invalid arguments have paired error stops" do
    execute(
      [],
      [%ToolCall{id: "unknown", name: "unknown", arguments: %{}}],
      %AgentLoopConfig{},
      nil
    )

    assert_pair("unknown", :stop, true, false)

    invalid = %{
      tool("invalid", fn -> flunk("must not run") end)
      | parameters: %{"type" => "object", "required" => ["missing"]}
    }

    run(invalid)
    assert_pair("invalid", :stop, true, false)
  end

  test "pre-aborted calls also produce a content-free paired outcome" do
    signal = AbortSignal.new()
    AbortSignal.abort(signal)
    on_exit(fn -> AbortSignal.clear(signal) end)
    tool = tool("aborted", fn -> flunk("must not run") end)

    execute(
      [tool],
      [%ToolCall{id: "aborted", name: tool.name, arguments: %{}}],
      %AgentLoopConfig{},
      signal
    )

    assert_pair("aborted", :stop, true, false)
  end

  defp assert_pair(name, event, error, timeout) do
    assert_receive {:telemetry, :start, %{system_time: system_time}, start}
    assert is_integer(system_time)
    assert start == %{tool_name: name, is_error: false, timeout: false}
    assert_receive {:telemetry, ^event, %{duration: duration}, metadata}
    assert is_integer(duration) and duration >= 0
    assert metadata == %{tool_name: name, is_error: error, timeout: timeout}
    refute_receive {:telemetry, _, _, %{tool_name: ^name}}, 10
  end

  defp tool(name, execute) do
    %AgentTool{
      name: name,
      label: name,
      description: "telemetry fixture",
      parameters: %{"type" => "object", "properties" => %{}},
      execute: fn _, _, _, _ -> execute.() end
    }
  end

  defp run(tool, config \\ %AgentLoopConfig{}) do
    execute(
      [tool],
      [%ToolCall{id: tool.name, name: tool.name, arguments: %{"private" => "secret argument"}}],
      config,
      nil
    )
  end

  defp execute(tools, calls, config, signal) do
    {:ok, stream} = EventStream.start_link(timeout: :infinity)

    result =
      ToolCalls.execute_and_collect_tools(
        AgentContext.new(tools: tools),
        [],
        calls,
        config,
        signal,
        stream
      )

    EventStream.complete(stream, [])
    result
  end
end
