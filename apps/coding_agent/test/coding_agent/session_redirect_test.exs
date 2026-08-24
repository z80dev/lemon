defmodule CodingAgent.SessionRedirectTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Session

  alias LemonAi.Types.{
    AssistantMessage,
    Cost,
    Model,
    ModelCost,
    TextContent,
    Usage
  }

  # ============================================================================
  # Helpers
  # ============================================================================

  defp mock_model(opts \\ []) do
    %Model{
      id: Keyword.get(opts, :id, "mock-model-1"),
      name: Keyword.get(opts, :name, "Mock Model"),
      api: Keyword.get(opts, :api, :mock),
      provider: Keyword.get(opts, :provider, :mock_provider),
      base_url: Keyword.get(opts, :base_url, "https://api.mock.test"),
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.01, output: 0.03},
      context_window: 128_000,
      max_tokens: 4096,
      headers: %{},
      compat: nil
    }
  end

  defp mock_usage do
    %Usage{
      input: 100,
      output: 50,
      cache_read: 0,
      cache_write: 0,
      total_tokens: 150,
      cost: %Cost{input: 0.001, output: 0.0015, total: 0.0025}
    }
  end

  defp assistant_message(text, opts \\ []) do
    %AssistantMessage{
      role: :assistant,
      content: [%TextContent{type: :text, text: text}],
      api: :mock,
      provider: :mock_provider,
      model: "mock-model-1",
      usage: mock_usage(),
      stop_reason: Keyword.get(opts, :stop_reason, :stop),
      error_message: nil,
      timestamp: System.system_time(:millisecond)
    }
  end

  defp response_to_event_stream(response) do
    {:ok, stream} = LemonAi.EventStream.start_link()

    Task.start(fn ->
      LemonAi.EventStream.push(stream, {:start, response})

      response.content
      |> Enum.with_index()
      |> Enum.each(fn {content, idx} ->
        case content do
          %TextContent{text: text} ->
            LemonAi.EventStream.push(stream, {:text_start, idx, response})
            LemonAi.EventStream.push(stream, {:text_delta, idx, text, response})
            LemonAi.EventStream.push(stream, {:text_end, idx, response})

          _ ->
            :ok
        end
      end)

      LemonAi.EventStream.push(stream, {:done, response.stop_reason, response})
      LemonAi.EventStream.complete(stream, response)
    end)

    stream
  end

  defp mock_stream_fn_single(response) do
    fn _model, _context, _options ->
      {:ok, response_to_event_stream(response)}
    end
  end

  # First call streams slowly (notifying the test per chunk); later calls
  # return `retry_response` immediately.
  defp slow_then_quick_stream_fn(parent, retry_response) do
    counter = :counters.new(1, [:atomics])

    fn _model, _context, _options ->
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)

      if n == 1 do
        {:ok, stream} = LemonAi.EventStream.start_link()

        Task.start(fn ->
          response = assistant_message("Partial before redirect")
          LemonAi.EventStream.push(stream, {:start, response})

          for i <- 1..30 do
            send(parent, {:streaming_chunk, i})
            Process.sleep(30)
            LemonAi.EventStream.push(stream, {:text_delta, 0, "chunk #{i}", response})
          end

          LemonAi.EventStream.push(stream, {:done, :stop, response})
          LemonAi.EventStream.complete(stream, response)
        end)

        {:ok, stream}
      else
        {:ok, response_to_event_stream(retry_response)}
      end
    end
  end

  defp start_session(opts \\ []) do
    opts =
      Keyword.merge(
        [
          cwd: System.tmp_dir!(),
          model: mock_model(),
          stream_fn: mock_stream_fn_single(assistant_message("Hello!"))
        ],
        opts
      )

    {:ok, session} = Session.start_link(opts)
    session
  end

  defp wait_for_streaming_complete(session) do
    state = Session.get_state(session)

    if state.is_streaming do
      Process.sleep(10)
      wait_for_streaming_complete(session)
    else
      :ok
    end
  end

  defp agent_messages(session) do
    state = Session.get_state(session)
    LemonAgent.Agent.get_state(state.agent).messages
  end

  defp user_content?(message, text) do
    Map.get(message, :role) == :user and
      (message.content == text or
         (is_list(message.content) and
            Enum.any?(message.content, fn
              %TextContent{text: t} -> is_binary(t) and String.contains?(t, text)
              _ -> false
            end)) or
         (is_binary(message.content) and String.contains?(message.content, text)))
  end

  # ============================================================================
  # Tests
  # ============================================================================

  describe "redirect/2 while idle" do
    test "redirect messages are queued" do
      session = start_session()

      :ok = Session.redirect(session, "Change of plans")
      state = Session.get_state(session)

      assert :queue.len(state.steering_queue) == 1
    end
  end

  describe "redirect/2 mid-run" do
    test "cancels the in-flight model call, applies the correction, and completes" do
      parent = self()
      retry_response = assistant_message("After redirect")

      session =
        start_session(stream_fn: slow_then_quick_stream_fn(parent, retry_response))

      :ok = Session.prompt(session, "Start working")

      assert_receive {:streaming_chunk, 2}, 3000

      :ok = Session.redirect(session, "Actually, switch approach")

      wait_for_streaming_complete(session)

      messages = agent_messages(session)

      # The correction landed in the transcript
      assert Enum.any?(messages, &user_content?(&1, "Actually, switch approach"))

      # The retried model call produced the final answer
      assert Enum.any?(messages, fn msg ->
               Map.get(msg, :role) == :assistant and Map.get(msg, :stop_reason) == :stop and
                 is_list(msg.content) and
                 Enum.any?(msg.content, fn
                   %TextContent{text: "After redirect"} -> true
                   _ -> false
                 end)
             end)

      # The session is idle and not errored
      state = Session.get_state(session)
      refute state.is_streaming
    end
  end
end
