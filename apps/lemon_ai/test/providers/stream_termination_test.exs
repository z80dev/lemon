defmodule LemonAi.Providers.StreamTerminationTest do
  @moduledoc """
  Every streaming provider fails a response that ends, idles out or loses its
  connection before the provider's terminal event, over a real HTTP connection.
  """
  use ExUnit.Case, async: false

  alias LemonAi.EventStream
  alias LemonAi.Test.StreamServer

  alias LemonAi.Providers.{
    AzureOpenAIResponses,
    Bedrock,
    Google,
    GoogleGeminiCli,
    GoogleVertex,
    OpenAICodexResponses,
    OpenAICompletions,
    OpenAIResponses,
    StreamTransport
  }

  alias LemonAi.Types.{AssistantMessage, Context, Model, ModelCost, StreamOptions, UserMessage}

  @providers [
    :google,
    :google_vertex,
    :google_gemini_cli,
    :openai_completions,
    :openai_responses,
    :openai_codex_responses,
    :bedrock,
    :azure_openai_responses
  ]

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_ai)
    defaults = Req.default_options()
    on_exit(fn -> Req.default_options(defaults) end)
    :ok
  end

  for provider <- @providers do
    describe "#{provider}" do
      test "completes only after the terminal event" do
        provider = unquote(provider)

        server =
          serve(fn _n ->
            [:headers, {:chunk, partial(provider)}, {:chunk, terminal(provider)}, :finish]
          end)

        {stream, events} = run(provider, server)

        assert {:ok, %AssistantMessage{stop_reason: :stop} = message} =
                 EventStream.result(stream, 5_000)

        assert LemonAi.get_text(message) == "Hello"
        assert Enum.any?(events, &match?({:text_delta, _, "Hel"}, &1))
        assert Enum.any?(events, &match?({:done, :stop, _}, &1))
      end

      test "fails a body that ends cleanly before the terminal event" do
        provider = unquote(provider)
        server = serve(fn _n -> [:headers, {:chunk, partial(provider)}, :finish] end)
        {stream, events} = run(provider, server)

        assert {:error, %AssistantMessage{stop_reason: :error} = message} =
                 EventStream.result(stream, 5_000)

        assert %{category: :transient, retryable: true} = message.error_details
        assert Enum.any?(events, &match?({:text_delta, _, "Hel"}, &1))
        refute Enum.any?(events, &match?({:done, _, _}, &1))
      end

      test "fails a connection lost before the terminal event" do
        provider = unquote(provider)
        server = serve(fn _n -> [:headers, {:chunk, partial(provider)}, :close] end)
        {stream, events} = run(provider, server)

        assert {:error, %AssistantMessage{stop_reason: :error} = message} =
                 EventStream.result(stream, 5_000)

        assert %{category: :transient, retryable: true} = message.error_details
        refute Enum.any?(events, &match?({:done, _, _}, &1))
      end

      test "fails and closes an idle connection before the terminal event" do
        provider = unquote(provider)
        server = serve(fn _n -> [:headers, {:chunk, partial(provider)}, :stall] end)
        {stream, events} = run(provider, server, %{stream_idle_timeout: 1_000})

        assert {:error, %AssistantMessage{stop_reason: :error} = message} =
                 EventStream.result(stream, 5_000)

        assert %{category: :transient, retryable: true} = message.error_details
        refute Enum.any?(events, &match?({:done, _, _}, &1))
        assert_receive {:stream_server, :client_closed, 0}, 5_000
      end

      test "killing the connection process mid-stream emits no stop" do
        provider = unquote(provider)
        server = serve(fn _n -> [:headers, {:chunk, partial(provider)}, :stall] end)
        {:ok, stream} = start(provider, server, %{})

        events =
          stream
          |> EventStream.events()
          |> Enum.map(fn
            {:text_delta, _, _} = event ->
              Process.exit(connection_process(stream), :kill)
              event

            event ->
              event
          end)

        assert Enum.any?(events, &match?({:text_delta, _, "Hel"}, &1))
        refute Enum.any?(events, &match?({:done, _, _}, &1))
        assert {:error, %{stop_reason: :error}} = EventStream.result(stream, 5_000)
        assert_receive {:stream_server, :client_closed, 0}, 5_000
      end
    end
  end

  for provider <- [:openai_completions, :azure_openai_responses] do
    test "#{provider}: unrelated async messages in the caller mailbox neither end nor fail a stream" do
      provider = unquote(provider)
      test_pid = self()

      server =
        serve(fn _n ->
          [:headers, {:chunk, partial(provider)}, {:sleep, 200}]
          |> Kernel.++([{:chunk, terminal(provider)}, :finish])
        end)

      {:ok, stream} = start(provider, server, %{})

      events =
        stream
        |> EventStream.events()
        |> Enum.map(fn
          {:text_delta, _, "Hel"} = event ->
            task = :sys.get_state(stream).task_pid
            send(task, {make_ref(), :done})
            send(task, {:error, :boom})
            send(task, {:DOWN, make_ref(), :process, test_pid, :normal})
            event

          event ->
            event
        end)

      assert {:ok, %AssistantMessage{stop_reason: :stop} = message} =
               EventStream.result(stream, 5_000)

      assert LemonAi.get_text(message) == "Hello"
      assert Enum.any?(events, &match?({:done, :stop, _}, &1))
    end
  end

  test "a stalled response is canceled on idle timeout and early halt with no mailbox leftovers" do
    server = serve(fn _n -> [:headers, {:chunk, partial(:openai_completions)}, :stall] end)
    policy = LemonAi.Retry.policy(max_attempts: 1)

    for {consume, n} <- [{&Enum.to_list/1, 0}, {&Enum.take(&1, 1), 1}] do
      {:links, before} = Process.info(self(), :links)

      assert {:ok, events} =
               StreamTransport.post_sse(server.url, [], %{}, policy, idle_timeout: 300)

      {:links, links} = Process.info(self(), :links)
      [connection] = links -- before
      items = consume.(events)

      assert %{"choices" => _} = hd(items)
      if n == 0, do: assert({:stream_error, %{category: :transient}} = List.last(items))
      assert_receive {:stream_server, :client_closed, ^n}, 5_000
      refute Process.alive?(connection)
      {:messages, messages} = Process.info(self(), :messages)
      refute Enum.any?(messages, &match?({{_pool, ^connection}, _}, &1))
    end
  end

  test "Completions retries a stalled uncommitted response only after canceling it" do
    parent = self()

    server =
      serve(fn
        0 ->
          [:headers, {:chunk, sse(%{"choices" => [%{"delta" => %{}}]})}, :stall]

        _ ->
          [
            :headers,
            {:chunk, partial(:openai_completions)},
            {:chunk, terminal(:openai_completions)},
            :finish
          ]
      end)

    # The retry wait runs in the provider task: report its mailbox there.
    sleep = fn _ms ->
      {:messages, messages} = Process.info(self(), :messages)
      send(parent, {:retry_mailbox, messages})
      :ok
    end

    overrides = %{
      stream_idle_timeout: 1_000,
      provider_retry: %{max_attempts: 2, sleep_fun: sleep}
    }

    {:ok, stream} = start(:openai_completions, server, overrides)

    assert {:ok, %AssistantMessage{stop_reason: :stop}} = EventStream.result(stream, 10_000)
    assert_receive {:stream_server, :client_closed, 0}
    assert_receive {:retry_mailbox, messages}
    refute Enum.any?(messages, &match?({{Finch.HTTP1.Pool, _}, _}, &1))
    assert_receive {:stream_server, :request, 1, _}
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp serve(script) do
    server = StreamServer.start(script)
    on_exit(fn -> StreamServer.stop(server) end)
    Req.default_options(adapter: StreamServer.redirect_adapter(server))
    server
  end

  defp run(provider, server, overrides \\ %{}) do
    {:ok, stream} = start(provider, server, overrides)
    events = Enum.to_list(EventStream.events(stream))
    {stream, events}
  end

  defp start(provider, _server, overrides) do
    {module, model, opts} = request(provider)
    opts = Map.merge(opts, Map.put_new(overrides, :provider_retry, %{max_attempts: 1}))
    context = Context.new(messages: [%UserMessage{content: "Hi"}])
    module.stream(model, context, opts)
  end

  # The Req HTTP/1 connection process is linked to the provider task.
  defp connection_process(stream) do
    task = :sys.get_state(stream).task_pid
    {:links, links} = Process.info(task, :links)

    Enum.find(links, fn pid ->
      is_pid(pid) and Process.info(pid, :initial_call) == {:initial_call, {:erlang, :apply, 2}}
    end)
  end

  defp model(api, provider, id) do
    %Model{
      id: id,
      name: id,
      api: api,
      provider: provider,
      base_url: "https://provider.example.test/v1",
      input: [:text],
      cost: %ModelCost{},
      max_tokens: 1024
    }
  end

  defp request(:google),
    do:
      {Google, model(:google_generative_ai, :google, "gemini-2.5-flash"),
       %StreamOptions{api_key: "test-key"}}

  defp request(:google_vertex) do
    opts = %StreamOptions{project: "p", location: "us-central1", access_token: "token"}
    {GoogleVertex, model(:google_vertex, :google_vertex, "gemini-2.5-flash"), opts}
  end

  defp request(:google_gemini_cli) do
    key = Jason.encode!(%{"token" => "token", "projectId" => "project"})

    {GoogleGeminiCli, model(:google_gemini_cli, :google_gemini_cli, "gemini-2.5-pro"),
     %StreamOptions{api_key: key}}
  end

  defp request(:openai_completions),
    do:
      {OpenAICompletions, model(:openai_completions, :openai, "gpt-test"),
       %StreamOptions{api_key: "test-key"}}

  defp request(:openai_responses),
    do:
      {OpenAIResponses, model(:openai_responses, :openai, "gpt-test"),
       %StreamOptions{api_key: "test-key"}}

  defp request(:openai_codex_responses) do
    claims = %{"https://api.openai.com/auth" => %{"chatgpt_account_id" => "acc_test"}}
    token = "header." <> Base.url_encode64(Jason.encode!(claims), padding: false) <> ".sig"

    {OpenAICodexResponses, model(:openai_codex_responses, :openai_codex, "gpt-test"),
     %StreamOptions{api_key: token}}
  end

  defp request(:azure_openai_responses) do
    opts = %StreamOptions{
      provider_options: %{
        azure_openai_responses: %{
          api_key: "test-key",
          base_url: "https://r.openai.azure.com/openai/v1"
        }
      }
    }

    {AzureOpenAIResponses, model(:azure_openai_responses, :"azure-openai-responses", "gpt-test"),
     opts}
  end

  defp request(:bedrock) do
    headers = %{
      "aws_access_key_id" => "AKIA_TEST",
      "aws_secret_access_key" => "SECRET",
      "aws_region" => "us-east-1"
    }

    {Bedrock, model(:bedrock_converse_stream, :amazon, "anthropic.claude-test"),
     %StreamOptions{headers: headers}}
  end

  # A first frame with visible output and no terminal event.
  defp partial(provider) when provider in [:google, :google_vertex],
    do: sse(%{"candidates" => [%{"content" => %{"parts" => [%{"text" => "Hel"}]}}]})

  defp partial(:google_gemini_cli),
    do:
      sse(%{
        "response" => %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "Hel"}]}}]}
      })

  defp partial(:openai_completions),
    do: sse(%{"choices" => [%{"delta" => %{"content" => "Hel"}}]})

  defp partial(provider)
       when provider in [:openai_responses, :openai_codex_responses, :azure_openai_responses] do
    sse(%{"type" => "response.output_item.added", "item" => %{"type" => "message", "id" => "m"}}) <>
      sse(%{"type" => "response.output_text.delta", "delta" => "Hel"})
  end

  defp partial(:bedrock),
    do: frame("contentBlockDelta", %{"contentBlockIndex" => 0, "delta" => %{"text" => "Hel"}})

  # The rest of the response including its terminal event.
  defp terminal(provider) when provider in [:google, :google_vertex] do
    sse(%{
      "candidates" => [
        %{"content" => %{"parts" => [%{"text" => "lo"}]}, "finishReason" => "STOP"}
      ]
    })
  end

  defp terminal(:google_gemini_cli) do
    sse(%{
      "response" => %{
        "candidates" => [
          %{"content" => %{"parts" => [%{"text" => "lo"}]}, "finishReason" => "STOP"}
        ]
      }
    })
  end

  defp terminal(:openai_completions) do
    sse(%{"choices" => [%{"delta" => %{"content" => "lo"}, "finish_reason" => "stop"}]}) <>
      "data: [DONE]\n\n"
  end

  defp terminal(provider)
       when provider in [:openai_responses, :openai_codex_responses, :azure_openai_responses] do
    sse(%{"type" => "response.output_text.delta", "delta" => "lo"}) <>
      sse(%{
        "type" => "response.output_item.done",
        "item" => %{
          "type" => "message",
          "id" => "m",
          "content" => [%{"type" => "output_text", "text" => "Hello"}]
        }
      }) <>
      sse(%{"type" => "response.completed", "response" => %{"status" => "completed"}})
  end

  defp terminal(:bedrock) do
    frame("contentBlockDelta", %{"contentBlockIndex" => 0, "delta" => %{"text" => "lo"}}) <>
      frame("messageStop", %{"stopReason" => "end_turn"}) <>
      frame("metadata", %{"usage" => %{"inputTokens" => 1, "outputTokens" => 2}})
  end

  defp sse(event), do: "data: " <> Jason.encode!(event) <> "\r\n\r\n"

  # An AWS event-stream frame; Bedrock does not verify the CRCs.
  defp frame(event_type, payload) do
    headers =
      [{":message-type", "event"}, {":event-type", event_type}]
      |> Enum.map(fn {name, value} ->
        <<byte_size(name)::8, name::binary, 7::8, byte_size(value)::16, value::binary>>
      end)
      |> IO.iodata_to_binary()

    payload = Jason.encode!(payload)
    total = 12 + byte_size(headers) + byte_size(payload) + 4

    <<total::32, byte_size(headers)::32, 0::32, headers::binary, payload::binary, 0::32>>
  end
end
