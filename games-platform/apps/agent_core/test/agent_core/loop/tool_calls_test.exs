defmodule AgentCore.Loop.ToolCallsTest do
  use ExUnit.Case, async: true

  alias AgentCore.AbortSignal
  alias AgentCore.EventStream
  alias AgentCore.Loop.ToolCalls
  alias AgentCore.Test.Mocks
  alias AgentCore.Types.{AgentContext, AgentLoopConfig, AgentTool, AgentToolResult}

  alias Ai.Types.{
    StreamOptions,
    TextContent,
    UserMessage
  }

  defp simple_context(opts) do
    AgentContext.new(
      system_prompt: Keyword.get(opts, :system_prompt, "You are a helpful assistant."),
      messages: Keyword.get(opts, :messages, []),
      tools: Keyword.get(opts, :tools, [])
    )
  end

  defp simple_config(opts) do
    %AgentLoopConfig{
      model: Keyword.get(opts, :model, Mocks.mock_model()),
      convert_to_llm: Keyword.get(opts, :convert_to_llm, Mocks.simple_convert_to_llm()),
      transform_context: Keyword.get(opts, :transform_context, nil),
      get_api_key: Keyword.get(opts, :get_api_key, nil),
      get_steering_messages: Keyword.get(opts, :get_steering_messages, nil),
      get_follow_up_messages: Keyword.get(opts, :get_follow_up_messages, nil),
      max_tool_concurrency: Keyword.get(opts, :max_tool_concurrency, nil),
      stream_options: Keyword.get(opts, :stream_options, %StreamOptions{}),
      stream_fn: Keyword.get(opts, :stream_fn, nil)
    }
  end

  defp user_message(text) do
    %UserMessage{
      role: :user,
      content: text,
      timestamp: System.system_time(:millisecond)
    }
  end

  test "returns aborted tool_result messages with details when signal is pre-aborted" do
    slow_tool = %AgentTool{
      name: "slow_tool",
      description: "Sleeps for a long time",
      parameters: %{"type" => "object", "properties" => %{}},
      label: "Slow",
      execute: fn _id, _params, _signal, _on_update ->
        Process.sleep(5_000)

        %AgentToolResult{
          content: [%TextContent{type: :text, text: "done"}],
          details: nil
        }
      end
    }

    context = simple_context(tools: [slow_tool])
    steering_message = user_message("follow steering")

    config =
      simple_config(get_steering_messages: fn -> [steering_message] end)

    signal = AbortSignal.new()
    :ok = AbortSignal.abort(signal)

    tool_call = Mocks.tool_call("slow_tool", %{}, id: "call_abort_test")
    {:ok, stream} = EventStream.start_link(timeout: :infinity)

    {results, steering_messages, updated_context, updated_new_messages} =
      ToolCalls.execute_and_collect_tools(context, [], [tool_call], config, signal, stream)

    assert steering_messages == [steering_message]
    assert length(results) == 1

    [tool_result_message] = results
    assert tool_result_message.role == :tool_result
    assert tool_result_message.tool_call_id == "call_abort_test"
    assert tool_result_message.is_error == true
    assert tool_result_message.details == %{error_type: :aborted}

    assert Enum.any?(tool_result_message.content, fn
             %TextContent{text: text} when is_binary(text) -> String.contains?(text, "aborted")
             _ -> false
           end)

    assert List.last(updated_context.messages).tool_call_id == "call_abort_test"
    assert List.last(updated_new_messages).tool_call_id == "call_abort_test"

    EventStream.complete(stream, [])
    events = EventStream.events(stream) |> Enum.to_list()

    refute Enum.any?(events, &match?({:tool_execution_start, "call_abort_test", _, _}, &1))
    assert Enum.any?(events, &match?({:tool_execution_end, "call_abort_test", _, _, true}, &1))
  end

  test "emits error tool_result for tool execution errors" do
    error_tool = %AgentTool{
      name: "failing_tool",
      description: "Always fails",
      parameters: %{"type" => "object", "properties" => %{}},
      label: "Failing",
      execute: fn _id, _params, _signal, _on_update ->
        {:error, "tool failed hard"}
      end
    }

    context = simple_context(tools: [error_tool])
    config = simple_config([])
    signal = AbortSignal.new()
    tool_call = Mocks.tool_call("failing_tool", %{}, id: "call_tool_error")
    {:ok, stream} = EventStream.start_link(timeout: :infinity)

    {results, steering_messages, updated_context, updated_new_messages} =
      ToolCalls.execute_and_collect_tools(context, [], [tool_call], config, signal, stream)

    assert steering_messages == []
    assert length(results) == 1

    [tool_result_message] = results
    assert tool_result_message.role == :tool_result
    assert tool_result_message.tool_call_id == "call_tool_error"
    assert tool_result_message.tool_name == "failing_tool"
    assert tool_result_message.is_error == true
    assert tool_result_message.details == nil

    assert Enum.any?(tool_result_message.content, fn
             %TextContent{text: "tool failed hard"} -> true
             _ -> false
           end)

    assert List.last(updated_context.messages).tool_call_id == "call_tool_error"
    assert List.last(updated_new_messages).tool_call_id == "call_tool_error"

    EventStream.complete(stream, [])
    events = EventStream.events(stream) |> Enum.to_list()

    assert Enum.any?(events, &match?({:tool_execution_start, "call_tool_error", _, _}, &1))
    assert Enum.any?(events, &match?({:tool_execution_end, "call_tool_error", _, _, true}, &1))
  end

  test "respects max_tool_concurrency while executing tool calls" do
    {:ok, counter} = Agent.start_link(fn -> %{current: 0, max: 0} end)

    controlled_tool = %AgentTool{
      name: "controlled_tool",
      description: "tracks concurrent executions",
      parameters: %{"type" => "object", "properties" => %{}},
      label: "Controlled",
      execute: fn _id, _params, _signal, _on_update ->
        Agent.update(counter, fn %{current: current, max: max_seen} ->
          current = current + 1
          %{current: current, max: max(max_seen, current)}
        end)

        Process.sleep(120)

        Agent.update(counter, fn %{current: current} = state ->
          %{state | current: max(current - 1, 0)}
        end)

        %AgentToolResult{
          content: [%TextContent{type: :text, text: "ok"}],
          details: nil
        }
      end
    }

    context = simple_context(tools: [controlled_tool])
    config = simple_config(max_tool_concurrency: 2)
    signal = AbortSignal.new()
    {:ok, stream} = EventStream.start_link(timeout: :infinity)

    tool_calls =
      for i <- 1..4 do
        Mocks.tool_call("controlled_tool", %{}, id: "call_concurrency_#{i}")
      end

    {results, _steering_messages, _context, _new_messages} =
      ToolCalls.execute_and_collect_tools(context, [], tool_calls, config, signal, stream)

    assert length(results) == 4
    assert Agent.get(counter, & &1.max) <= 2
  end

  test "abort marks both running and queued tool calls as aborted when max_tool_concurrency is 1" do
    parent = self()

    slow_tool = %AgentTool{
      name: "slow_tool",
      description: "slow tool",
      parameters: %{"type" => "object", "properties" => %{}},
      label: "Slow",
      execute: fn id, _params, _signal, _on_update ->
        send(parent, {:tool_started, id})
        Process.sleep(5_000)

        %AgentToolResult{
          content: [%TextContent{type: :text, text: "done"}],
          details: nil
        }
      end
    }

    context = simple_context(tools: [slow_tool])
    config = simple_config(max_tool_concurrency: 1)
    signal = AbortSignal.new()
    {:ok, stream} = EventStream.start_link(timeout: :infinity)

    tool_calls =
      for i <- 1..3 do
        Mocks.tool_call("slow_tool", %{}, id: "call_abort_queue_#{i}")
      end

    runner =
      Task.async(fn ->
        ToolCalls.execute_and_collect_tools(context, [], tool_calls, config, signal, stream)
      end)

    assert_receive {:tool_started, "call_abort_queue_1"}, 1_000
    :ok = AbortSignal.abort(signal)

    {results, _steering_messages, _updated_context, _updated_new_messages} =
      Task.await(runner, 5_000)

    assert length(results) == 3
    assert Enum.all?(results, &(&1.is_error == true))
    assert Enum.all?(results, &(&1.details == %{error_type: :aborted}))
  end
end
