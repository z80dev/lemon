defmodule AgentCore.Loop.StreamingTest do
  use ExUnit.Case, async: true

  alias AgentCore.AbortSignal
  alias AgentCore.EventStream
  alias AgentCore.Loop.Streaming
  alias AgentCore.Test.Mocks
  alias AgentCore.Types.{AgentContext, AgentLoopConfig}

  alias Ai.Types.{
    StreamOptions,
    ToolCall,
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

  test "short-circuits before stream_fn when signal is already aborted" do
    context = simple_context(messages: [user_message("hi")])
    signal = AbortSignal.new()
    :ok = AbortSignal.abort(signal)

    test_pid = self()

    stream_fn = fn _model, _context, _options ->
      send(test_pid, :stream_fn_called)
      {:error, :should_not_be_called}
    end

    config = simple_config(stream_fn: stream_fn)
    {:ok, stream} = EventStream.start_link(timeout: :infinity)

    assert {:ok, message, updated_context} =
             Streaming.stream_assistant_response(context, config, signal, stream_fn, stream)

    assert message.stop_reason == :aborted
    assert List.last(updated_context.messages).stop_reason == :aborted
    refute_receive :stream_fn_called, 100

    EventStream.complete(stream, [])

    events = EventStream.events(stream) |> Enum.to_list()

    assert Enum.any?(events, fn
             {:message_start, %{role: :assistant, stop_reason: :aborted}} -> true
             _ -> false
           end)

    assert Enum.any?(events, fn
             {:message_end, %{role: :assistant, stop_reason: :aborted}} -> true
             _ -> false
           end)
  end

  test "handles terminal :error stream event" do
    context = simple_context(messages: [user_message("hi")])
    signal = AbortSignal.new()
    partial = Mocks.assistant_message("partial")
    final = %{partial | stop_reason: :error, error_message: "upstream_error"}

    stream_fn = fn _model, _llm_context, _options ->
      {:ok, ai_stream} = Ai.EventStream.start_link()

      Task.start(fn ->
        Ai.EventStream.push(ai_stream, {:start, partial})
        Ai.EventStream.push(ai_stream, {:error, :api_error, final})
        Ai.EventStream.complete(ai_stream, final)
      end)

      {:ok, ai_stream}
    end

    config = simple_config(stream_fn: stream_fn)
    {:ok, stream} = EventStream.start_link(timeout: :infinity)

    assert {:ok, message, updated_context} =
             Streaming.stream_assistant_response(context, config, signal, stream_fn, stream)

    assert message.stop_reason == :error
    assert message.error_message == "upstream_error"
    assert List.last(updated_context.messages).stop_reason == :error

    EventStream.complete(stream, [])
    events = EventStream.events(stream) |> Enum.to_list()

    assert Enum.any?(events, fn
             {:message_start, %{role: :assistant}} -> true
             _ -> false
           end)

    assert Enum.any?(events, fn
             {:message_end, %{role: :assistant, stop_reason: :error}} -> true
             _ -> false
           end)
  end

  test "preserves streamed content when final provider message is empty" do
    context = simple_context(messages: [user_message("hi")])
    signal = AbortSignal.new()
    partial = Mocks.assistant_message("streamed answer")
    final = %{partial | content: [], stop_reason: :stop}

    stream_fn = fn _model, _llm_context, _options ->
      {:ok, ai_stream} = Ai.EventStream.start_link()

      Task.start(fn ->
        Ai.EventStream.push(ai_stream, {:start, %{partial | content: []}})
        Ai.EventStream.push(ai_stream, {:text_delta, 0, "streamed answer", partial})
        Ai.EventStream.push(ai_stream, {:done, :stop, final})
        Ai.EventStream.complete(ai_stream, final)
      end)

      {:ok, ai_stream}
    end

    config = simple_config(stream_fn: stream_fn)
    {:ok, stream} = EventStream.start_link(timeout: :infinity)

    assert {:ok, message, updated_context} =
             Streaming.stream_assistant_response(context, config, signal, stream_fn, stream)

    assert [%{text: "streamed answer"}] = message.content
    assert [%{text: "streamed answer"}] = List.last(updated_context.messages).content

    EventStream.complete(stream, [])
    events = EventStream.events(stream) |> Enum.to_list()

    assert Enum.any?(events, fn
             {:message_end, %{role: :assistant, content: [%{text: "streamed answer"}]}} -> true
             _ -> false
           end)
  end

  test "preserves streamed tool call when final provider message is empty" do
    context = simple_context(messages: [user_message("read mix")])
    signal = AbortSignal.new()
    tool_call = Mocks.tool_call("read_file", %{"path" => "mix.exs"}, id: "call_read")
    partial = Mocks.assistant_message_with_tool_calls([tool_call])
    final = %{partial | content: [], stop_reason: :tool_use}

    stream_fn = fn _model, _llm_context, _options ->
      {:ok, ai_stream} = Ai.EventStream.start_link()

      Task.start(fn ->
        Ai.EventStream.push(ai_stream, {:start, %{partial | content: []}})
        Ai.EventStream.push(ai_stream, {:tool_call_start, 0, partial})
        Ai.EventStream.push(ai_stream, {:tool_call_end, 0, tool_call, partial})
        Ai.EventStream.push(ai_stream, {:done, :tool_use, final})
        Ai.EventStream.complete(ai_stream, final)
      end)

      {:ok, ai_stream}
    end

    config = simple_config(stream_fn: stream_fn)
    {:ok, stream} = EventStream.start_link(timeout: :infinity)

    assert {:ok, message, updated_context} =
             Streaming.stream_assistant_response(context, config, signal, stream_fn, stream)

    assert [%ToolCall{name: "read_file", arguments: %{"path" => "mix.exs"}}] = message.content

    assert [%ToolCall{name: "read_file", arguments: %{"path" => "mix.exs"}}] =
             List.last(updated_context.messages).content

    EventStream.complete(stream, [])
    events = EventStream.events(stream) |> Enum.to_list()

    assert Enum.any?(events, fn
             {:message_end, %{role: :assistant, content: [%ToolCall{name: "read_file"}]}} ->
               true

             _ ->
               false
           end)
  end

  test "preserves streamed partial tool arguments when final provider message is empty" do
    context = simple_context(messages: [user_message("read mix")])
    signal = AbortSignal.new()

    empty_tool_call = Mocks.tool_call("read_file", %{}, id: "call_read_args")
    partial_tool_call = Mocks.tool_call("read_file", %{"path" => "mix"}, id: "call_read_args")
    final_tool_call = Mocks.tool_call("read_file", %{"path" => "mix.exs"}, id: "call_read_args")

    started_partial = Mocks.assistant_message_with_tool_calls([empty_tool_call])
    delta_partial = Mocks.assistant_message_with_tool_calls([partial_tool_call])
    completed_partial = Mocks.assistant_message_with_tool_calls([final_tool_call])
    final = %{completed_partial | content: [], stop_reason: :tool_use}

    stream_fn = fn _model, _llm_context, _options ->
      {:ok, ai_stream} = Ai.EventStream.start_link()

      Task.start(fn ->
        Ai.EventStream.push(ai_stream, {:start, %{started_partial | content: []}})
        Ai.EventStream.push(ai_stream, {:tool_call_start, 0, started_partial})
        Ai.EventStream.push(ai_stream, {:tool_call_delta, 0, ~s({"path":"mix"), delta_partial})
        Ai.EventStream.push(ai_stream, {:tool_call_delta, 0, ~s(.exs"}), completed_partial})
        Ai.EventStream.push(ai_stream, {:tool_call_end, 0, final_tool_call, completed_partial})
        Ai.EventStream.push(ai_stream, {:done, :tool_use, final})
        Ai.EventStream.complete(ai_stream, final)
      end)

      {:ok, ai_stream}
    end

    config = simple_config(stream_fn: stream_fn)
    {:ok, stream} = EventStream.start_link(timeout: :infinity)

    assert {:ok, message, updated_context} =
             Streaming.stream_assistant_response(context, config, signal, stream_fn, stream)

    assert [%ToolCall{id: "call_read_args", name: "read_file", arguments: %{"path" => "mix.exs"}}] =
             message.content

    assert [%ToolCall{id: "call_read_args", arguments: %{"path" => "mix.exs"}}] =
             List.last(updated_context.messages).content

    EventStream.complete(stream, [])
    events = EventStream.events(stream) |> Enum.to_list()

    assert Enum.any?(events, fn
             {:message_update, %{content: [%ToolCall{arguments: %{"path" => "mix"}}]},
              {:tool_call_delta, 0, ~s({"path":"mix"), _}} ->
               true

             _ ->
               false
           end)

    assert Enum.any?(events, fn
             {:message_end,
              %{role: :assistant, content: [%ToolCall{arguments: %{"path" => "mix.exs"}}]}} ->
               true

             _ ->
               false
           end)
  end

  test "converts terminal :canceled stream event into aborted assistant message" do
    context = simple_context(messages: [user_message("cancel me")])
    signal = AbortSignal.new()
    partial = Mocks.assistant_message("in progress")

    stream_fn = fn _model, _llm_context, _options ->
      {:ok, ai_stream} = Ai.EventStream.start_link()

      Task.start(fn ->
        Ai.EventStream.push(ai_stream, {:start, partial})
        Ai.EventStream.push(ai_stream, {:canceled, :user_abort})
        Ai.EventStream.complete(ai_stream, partial)
      end)

      {:ok, ai_stream}
    end

    config = simple_config(stream_fn: stream_fn)
    {:ok, stream} = EventStream.start_link(timeout: :infinity)

    assert {:ok, message, updated_context} =
             Streaming.stream_assistant_response(context, config, signal, stream_fn, stream)

    assert message.stop_reason == :aborted
    assert message.error_message == "Stream canceled: :user_abort"
    assert List.last(updated_context.messages).stop_reason == :aborted

    EventStream.complete(stream, [])
    events = EventStream.events(stream) |> Enum.to_list()

    assert Enum.any?(events, fn
             {:message_end, %{role: :assistant, stop_reason: :aborted}} -> true
             _ -> false
           end)
  end
end
