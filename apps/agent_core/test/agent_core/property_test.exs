defmodule AgentCore.PropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  import StreamData

  alias AgentCore.EventStream
  alias AgentCore.Loop
  alias AgentCore.Types.AgentContext
  alias AgentCore.Types.AgentLoopConfig
  alias AgentCore.Test.Mocks
  alias Ai.Types.{StreamOptions, ToolResultMessage, UserMessage}

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

  property "EventStream preserves event order and terminates with agent_end" do
    check all events <- list_of(term(), max_length: 25) do
      {:ok, stream} = EventStream.start_link()

      Enum.each(events, fn event ->
        EventStream.push(stream, event)
      end)

      EventStream.complete(stream, [])

      received = EventStream.events(stream) |> Enum.to_list()

      assert List.last(received) == {:agent_end, []}
      assert Enum.take(received, length(events)) == events
    end
  end

  property "tool calls emit matching start/end events and tool_result messages" do
    check all texts <- list_of(string(:alphanumeric, min_length: 1), min_length: 1, max_length: 5) do
      tool_calls =
        texts
        |> Enum.with_index()
        |> Enum.map(fn {text, idx} ->
          Mocks.tool_call("echo", %{"text" => text}, id: "call_#{idx}")
        end)

      tool_response = Mocks.assistant_message_with_tool_calls(tool_calls)
      final_response = Mocks.assistant_message("Done")

      context = simple_context(tools: [Mocks.echo_tool()])

      config =
        simple_config(
          stream_fn: Mocks.mock_stream_fn([tool_response, final_response])
        )

      events = Loop.stream([user_message("Run tools")], context, config) |> Enum.to_list()

      start_ids =
        for {:tool_execution_start, id, _name, _args} <- events, do: id

      end_ids =
        for {:tool_execution_end, id, _name, _result, _is_error} <- events, do: id

      expected_ids = Enum.map(0..(length(texts) - 1), &"call_#{&1}")

      assert Enum.sort(start_ids) == Enum.sort(expected_ids)
      assert Enum.sort(end_ids) == Enum.sort(expected_ids)

      tool_result_messages =
        Enum.filter(events, fn
          {:message_end, %ToolResultMessage{}} -> true
          _ -> false
        end)

      assert length(tool_result_messages) == length(tool_calls)
    end
  end
end
