defmodule LemonAgent.Loop.StreamingTest do
  use ExUnit.Case, async: true

  alias LemonAgent.AbortSignal
  alias LemonAgent.EventStream
  alias LemonAgent.Loop.Streaming
  alias LemonAgent.Test.Mocks
  alias LemonAgent.Types.{AgentContext, AgentLoopConfig}

  alias LemonAi.Types.{
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
      max_retries: Keyword.get(opts, :max_retries, 3),
      retry_base_delay_ms: Keyword.get(opts, :retry_base_delay_ms, 1),
      retry_max_delay_ms: Keyword.get(opts, :retry_max_delay_ms, 30_000),
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
      {:ok, ai_stream} = LemonAi.EventStream.start_link()

      Task.start(fn ->
        LemonAi.EventStream.push(ai_stream, {:start, partial})
        LemonAi.EventStream.push(ai_stream, {:error, :api_error, final})
        LemonAi.EventStream.complete(ai_stream, final)
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
      {:ok, ai_stream} = LemonAi.EventStream.start_link()

      Task.start(fn ->
        LemonAi.EventStream.push(ai_stream, {:start, %{partial | content: []}})
        LemonAi.EventStream.push(ai_stream, {:text_delta, 0, "streamed answer", partial})
        LemonAi.EventStream.push(ai_stream, {:done, :stop, final})
        LemonAi.EventStream.complete(ai_stream, final)
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
      {:ok, ai_stream} = LemonAi.EventStream.start_link()

      Task.start(fn ->
        LemonAi.EventStream.push(ai_stream, {:start, %{partial | content: []}})
        LemonAi.EventStream.push(ai_stream, {:tool_call_start, 0, partial})
        LemonAi.EventStream.push(ai_stream, {:tool_call_end, 0, tool_call, partial})
        LemonAi.EventStream.push(ai_stream, {:done, :tool_use, final})
        LemonAi.EventStream.complete(ai_stream, final)
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
      {:ok, ai_stream} = LemonAi.EventStream.start_link()

      Task.start(fn ->
        LemonAi.EventStream.push(ai_stream, {:start, %{started_partial | content: []}})
        LemonAi.EventStream.push(ai_stream, {:tool_call_start, 0, started_partial})

        LemonAi.EventStream.push(
          ai_stream,
          {:tool_call_delta, 0, ~s({"path":"mix"), delta_partial}
        )

        LemonAi.EventStream.push(ai_stream, {:tool_call_delta, 0, ~s(.exs"}), completed_partial})

        LemonAi.EventStream.push(
          ai_stream,
          {:tool_call_end, 0, final_tool_call, completed_partial}
        )

        LemonAi.EventStream.push(ai_stream, {:done, :tool_use, final})
        LemonAi.EventStream.complete(ai_stream, final)
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
      {:ok, ai_stream} = LemonAi.EventStream.start_link()

      Task.start(fn ->
        LemonAi.EventStream.push(ai_stream, {:start, partial})
        LemonAi.EventStream.push(ai_stream, {:canceled, :user_abort})
        LemonAi.EventStream.complete(ai_stream, partial)
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

  test "retries a metadata-only failure without committing a transcript start" do
    parent = self()
    context = simple_context(messages: [user_message("run")])

    failed = %{
      Mocks.assistant_message("")
      | stop_reason: :error,
        content: [],
        error_message: "Service temporarily unavailable (HTTP 503)"
    }

    final = Mocks.assistant_message("recovered")
    {:ok, responses} = Agent.start_link(fn -> [failed, final] end)

    stream_fn = fn _model, llm_context, _options ->
      send(parent, {:retry_context, llm_context.messages})
      response = Agent.get_and_update(responses, fn [response | rest] -> {response, rest} end)
      {:ok, ai_stream} = LemonAi.EventStream.start_link()
      LemonAi.EventStream.push(ai_stream, {:start, response})

      if response.stop_reason == :error do
        LemonAi.EventStream.error(ai_stream, response)
      else
        LemonAi.EventStream.complete(ai_stream, response)
      end

      {:ok, ai_stream}
    end

    config = simple_config(stream_fn: stream_fn)
    {:ok, stream} = EventStream.start_link(timeout: :infinity)

    assert {:ok, ^final, updated_context} =
             Streaming.stream_assistant_response(context, config, nil, nil, stream)

    assert updated_context.messages == context.messages ++ [final]
    assert_receive {:retry_context, first_context}
    assert_receive {:retry_context, ^first_context}

    EventStream.complete(stream, [])
    events = Enum.to_list(EventStream.events(stream))
    refute Enum.any?(events, &match?({:message_end, %{stop_reason: :error}}, &1))
    assert Enum.count(events, &match?({:message_start, _}, &1)) == 1
    assert Enum.count(events, &match?({:message_end, _}, &1)) == 1

    assert {:provider_retry, %{attempt: 1, delay_ms: 1}} =
             Enum.find(events, &match?({:provider_retry, _}, &1))

    assert {:provider_retry_end, %{attempt: 1, success: true, canceled: false}} in events
  end

  test "request failures back off exponentially and exhaust a bounded retry budget" do
    parent = self()
    context = simple_context(messages: [user_message("run")])

    stream_fn = fn _, _, _ ->
      send(parent, :request_attempt)
      {:error, :timeout}
    end

    config = simple_config(stream_fn: stream_fn, max_retries: 2, retry_base_delay_ms: 2)
    {:ok, stream} = EventStream.start_link(timeout: :infinity)

    assert {:error, :timeout} =
             Streaming.stream_assistant_response(context, config, nil, nil, stream)

    assert_receive :request_attempt
    assert_receive :request_attempt
    assert_receive :request_attempt
    refute_received :request_attempt

    EventStream.complete(stream, [])
    events = Enum.to_list(EventStream.events(stream))
    assert for({:provider_retry, %{delay_ms: delay}} <- events, do: delay) == [2, 4]
    assert {:provider_retry_end, %{attempt: 2, success: false, canceled: false}} in events
  end

  test "context overflow and authentication failures do not consume retry attempts" do
    for error <- ["maximum context length exceeded", "Invalid API key"] do
      parent = self()
      response = %{Mocks.assistant_message("") | stop_reason: :error, error_message: error}

      stream_fn = fn _, _, _ ->
        send(parent, :request_attempt)
        Mocks.mock_stream_fn_single_direct(response).(nil, nil, nil)
      end

      config = simple_config(stream_fn: stream_fn)
      context = simple_context(messages: [user_message("run")])
      {:ok, stream} = EventStream.start_link(timeout: :infinity)

      assert {:ok, %{stop_reason: :error}, _} =
               Streaming.stream_assistant_response(context, config, nil, nil, stream)

      assert_receive :request_attempt
      refute_received :request_attempt
      EventStream.complete(stream, [])
      refute Enum.any?(EventStream.events(stream), &match?({:provider_retry, _}, &1))
    end
  end

  test "abort interrupts an idle provider stream and removes unpaired partial tool calls" do
    parent = self()

    partial =
      Mocks.assistant_message_with_tool_calls([
        Mocks.tool_call("echo", %{"text" => "unfinished"}, id: "unfinished_call")
      ])

    signal = AbortSignal.new()
    on_exit(fn -> AbortSignal.clear(signal) end)

    stream_fn = fn _, _, _ ->
      {:ok, ai_stream} = LemonAi.EventStream.start_link(timeout: :infinity)
      LemonAi.EventStream.push(ai_stream, {:start, partial})
      send(parent, {:idle_stream, ai_stream})
      {:ok, ai_stream}
    end

    config = simple_config(stream_fn: stream_fn)
    {:ok, stream} = EventStream.start_link(timeout: :infinity)

    runner =
      Task.async(fn ->
        Streaming.stream_assistant_response(
          simple_context(messages: [user_message("run")]),
          config,
          signal,
          nil,
          stream
        )
      end)

    assert_receive {:idle_stream, ai_stream}
    monitor = Process.monitor(ai_stream)
    AbortSignal.abort(signal)

    assert {:ok, %{stop_reason: :aborted, content: content}, updated_context} =
             Task.await(runner, 1_000)

    refute Enum.any?(content, &match?(%ToolCall{}, &1))
    assert LemonAgent.Loop.TranscriptValidator.validate(updated_context.messages) == :ok
    assert_receive {:DOWN, ^monitor, :process, ^ai_stream, _}, 1_000
    EventStream.complete(stream, [])
  end

  test "abort during retry backoff prevents another provider request" do
    parent = self()
    signal = AbortSignal.new()
    on_exit(fn -> AbortSignal.clear(signal) end)

    stream_fn = fn _, _, _ ->
      send(parent, :request_attempt)
      {:error, :timeout}
    end

    config = simple_config(stream_fn: stream_fn, retry_base_delay_ms: 5_000)
    {:ok, stream} = EventStream.start_link(timeout: :infinity)

    runner =
      Task.async(fn ->
        Streaming.stream_assistant_response(
          simple_context(messages: [user_message("run")]),
          config,
          signal,
          nil,
          stream
        )
      end)

    assert_receive :request_attempt
    AbortSignal.abort(signal)
    assert {:ok, %{stop_reason: :aborted}, _} = Task.await(runner, 1_000)
    refute_received :request_attempt
    EventStream.complete(stream, [])

    assert {:provider_retry_end, %{attempt: 1, success: false, canceled: true}} in Enum.to_list(
             EventStream.events(stream)
           )
  end

  test "parsed limits and raw HTTP retry-after headers recover, but quota exhaustion does not" do
    parent = self()
    final = Mocks.assistant_message("recovered")

    for error <- [
          %{
            category: :rate_limit,
            retryable: true,
            message: "rate limited",
            rate_limit_info: %{retry_after: 10}
          },
          {:http_error, 503, "Service unavailable", [{"retry-after-ms", "10"}]}
        ] do
      {:ok, responses} = Agent.start_link(fn -> [error, final] end)

      stream_fn = fn _, _, _ ->
        case Agent.get_and_update(responses, fn [response | rest] -> {response, rest} end) do
          ^final -> Mocks.mock_stream_fn_single_direct(final).(nil, nil, nil)
          reason -> {:error, reason}
        end
      end

      {:ok, stream} = EventStream.start_link(timeout: :infinity)

      assert {:ok, ^final, _} =
               Streaming.stream_assistant_response(
                 simple_context(messages: [user_message("run")]),
                 simple_config(stream_fn: stream_fn),
                 nil,
                 nil,
                 stream
               )

      EventStream.complete(stream, [])

      assert Enum.any?(EventStream.events(stream), fn
               {:provider_retry, %{delay_ms: 10}} -> true
               _ -> false
             end)
    end

    for error <- [
          %{category: :rate_limit, retryable: false, message: "account quota exhausted"},
          "Rate limit exceeded: insufficient_quota",
          "maximum context length exceeded; temporarily unavailable"
        ] do
      stream_fn = fn _, _, _ ->
        send(parent, :quota_attempt)
        {:error, error}
      end

      {:ok, stream} = EventStream.start_link(timeout: :infinity)

      assert {:error, ^error} =
               Streaming.stream_assistant_response(
                 simple_context(messages: [user_message("run")]),
                 simple_config(stream_fn: stream_fn),
                 nil,
                 nil,
                 stream
               )

      assert_receive :quota_attempt
      refute_received :quota_attempt
      EventStream.complete(stream, [])
      refute Enum.any?(EventStream.events(stream), &match?({:provider_retry, _}, &1))
    end
  end

  test "disabled retries and excessive retry-after hints surface the original failure immediately" do
    parent = self()

    for {error, max_retries} <- [
          {:timeout, 0},
          {%{category: :rate_limit, retryable: true, rate_limit_info: %{retry_after: 120_001}}, 3}
        ] do
      stream_fn = fn _, _, _ ->
        send(parent, :request_attempt)
        {:error, error}
      end

      {:ok, stream} = EventStream.start_link(timeout: :infinity)

      assert {:error, ^error} =
               Streaming.stream_assistant_response(
                 simple_context(messages: [user_message("run")]),
                 simple_config(stream_fn: stream_fn, max_retries: max_retries),
                 nil,
                 nil,
                 stream
               )

      assert_receive :request_attempt
      refute_received :request_attempt
      EventStream.complete(stream, [])
      refute Enum.any?(EventStream.events(stream), &match?({:provider_retry, _}, &1))
    end
  end

  test "each output event blocks replay even when the provider reports empty content" do
    parent = self()
    empty = %{Mocks.assistant_message("") | content: []}
    failed = %{empty | stop_reason: :error, error_message: "overloaded_error"}

    for {event, terminal} <- [
          {{:text_start, 0, empty}, :error},
          {{:text_delta, 0, " ", empty}, :done},
          {{:text_end, 0, "", empty}, :error},
          {{:thinking_start, 0, empty}, :error},
          {{:thinking_delta, 0, " ", empty}, :done},
          {{:thinking_end, 0, "", empty}, :error},
          {{:tool_call_start, 0, empty}, :error},
          {{:tool_call_delta, 0, "{}", empty}, :done},
          {{:tool_call_end, 0, Mocks.tool_call("echo", %{}), empty}, :error}
        ] do
      stream_fn = fn _, _, _ ->
        send(parent, :committed_attempt)
        {:ok, ai_stream} = LemonAi.EventStream.start_link()
        LemonAi.EventStream.push(ai_stream, {:start, empty})
        LemonAi.EventStream.push(ai_stream, event)
        LemonAi.EventStream.push(ai_stream, {terminal, :error, failed})
        LemonAi.EventStream.complete(ai_stream, failed)
        {:ok, ai_stream}
      end

      {:ok, stream} = EventStream.start_link(timeout: :infinity)
      context = simple_context(messages: [user_message("run")])

      assert {:ok, message, updated_context} =
               Streaming.stream_assistant_response(
                 context, simple_config(stream_fn: stream_fn), nil, nil, stream
               )

      assert message.stop_reason == :error
      assert message.error_message == failed.error_message
      assert updated_context.messages == context.messages ++ [message]
      assert_receive :committed_attempt
      refute_received :committed_attempt
      EventStream.complete(stream, [])
      events = Enum.to_list(EventStream.events(stream))
      refute Enum.any?(events, &match?({:provider_retry, _}, &1))
      assert Enum.count(events, &match?({:message_start, _}, &1)) == 1
      assert Enum.count(events, &match?({:message_end, _}, &1)) == 1
    end
  end

  test "terminal text, whitespace, thinking and tools block replay without deltas" do
    parent = self()

    for content <- [
          [%LemonAi.Types.TextContent{text: " "}],
          [%LemonAi.Types.ThinkingContent{thinking: "private reasoning"}],
          [Mocks.tool_call("echo", %{}, id: "unexecuted")]
        ],
        shape <- [:stream, :direct] do
      failed = %{
        Mocks.assistant_message("")
        | content: content,
          stop_reason: :error,
          error_message: "Service temporarily unavailable (HTTP 503)"
      }

      stream_fn = fn _, _, _ ->
        send(parent, :terminal_attempt)

        case shape do
          :direct ->
            {:error, failed}

          :stream ->
            {:ok, ai_stream} = LemonAi.EventStream.start_link()
            LemonAi.EventStream.error(ai_stream, failed)
            {:ok, ai_stream}
        end
      end

      {:ok, stream} = EventStream.start_link(timeout: :infinity)

      assert {:ok, message, updated_context} =
               Streaming.stream_assistant_response(
                 simple_context(messages: [user_message("run")]),
                 simple_config(stream_fn: stream_fn), nil, nil, stream
               )

      assert message.stop_reason == :error
      refute Enum.any?(message.content, &match?(%ToolCall{}, &1))
      assert LemonAgent.Loop.TranscriptValidator.validate(updated_context.messages) == :ok
      assert_receive :terminal_attempt
      refute_received :terminal_attempt
      EventStream.complete(stream, [])
      refute Enum.any?(EventStream.events(stream), &match?({:provider_retry, _}, &1))
    end
  end
end
