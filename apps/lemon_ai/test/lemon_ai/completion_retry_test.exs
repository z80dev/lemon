defmodule LemonAi.CompletionRetryTest do
  use ExUnit.Case, async: false

  alias LemonAi.{EventStream, ProviderRegistry}
  alias LemonAi.Types.{AssistantMessage, Context, Cost, Model, TextContent, Usage}

  defmodule FakeProvider do
    @behaviour LemonAi.Provider
    alias LemonAi.{EventStream, Error}
    alias LemonAi.Providers.RetryHelper
    alias LemonAi.Types.{AssistantMessage, StreamOptions}

    @impl true
    def api_id, do: :completion_retry_test
    @impl true
    def provider_id, do: :completion_retry_test

    @impl true
    def stream(_model, _context, %StreamOptions{} = options) do
      policy = RetryHelper.policy(options)
      request(options, policy, 0)
    end

    defp request(options, policy, attempt) do
      send(options.provider_options.parent, :http_request)

      result =
        Agent.get_and_update(options.provider_options.queue, fn
          [result] -> {result, [result]}
          [result | rest] -> {result, rest}
        end)

      case result do
        {:request_error, error} ->
          if RetryHelper.retry_allowed?(attempt, policy) and Error.retryable?(error) do
            request(options, policy, attempt + 1)
          else
            {:error, error}
          end

        {message, events} ->
          {:ok, stream} = EventStream.start_link()
          send(options.provider_options.parent, {:private_stream, stream})
          EventStream.push(stream, {:start, %{message | content: []}})
          Enum.each(events, &EventStream.push(stream, &1))

          if message.stop_reason == :error do
            EventStream.error(stream, message)
          else
            EventStream.complete(stream, message)
          end

          {:ok, stream}

        %AssistantMessage{} = message ->
          {:ok, stream} = EventStream.start_link()
          send(options.provider_options.parent, {:private_stream, stream})
          # Providers can resolve a message with stop_reason :error as {:ok, _}.
          EventStream.complete(stream, message)
          {:ok, stream}
      end
    end
  end

  setup do
    ProviderRegistry.register(:completion_retry_test, FakeProvider)
    on_exit(fn -> ProviderRegistry.unregister(:completion_retry_test) end)
    :ok
  end

  defp message(reason, retry_after \\ nil) do
    %AssistantMessage{
      api: :completion_retry_test,
      provider: :completion_retry_test,
      model: "fake",
      usage: %Usage{cost: %Cost{}},
      stop_reason: if(reason, do: :error, else: :stop),
      content: if(reason, do: [], else: [%TextContent{text: "ok"}]),
      error_message: if(reason, do: LemonAi.Error.format_error(reason)),
      error_details: if(reason, do: LemonAi.Error.to_error_details(reason)),
      retry_after_ms: retry_after
    }
  end

  defp invocation(results, provider) do
    {:ok, queue} = Agent.start_link(fn -> results end)
    LemonAi.CircuitBreaker.reset(provider)
    model = %Model{id: "fake", name: "Fake", api: :completion_retry_test, provider: provider}
    parent = self()

    options = %{
      provider_options: %{queue: queue, parent: parent},
      retry: [
        base_delay_ms: 2,
        sleep_fun: fn ms ->
          send(parent, {:sleep, ms})
          :ok
        end
      ]
    }

    {model, Context.new(), options}
  end

  test "public complete honors a 429 hint on a resolved AssistantMessage error" do
    failed = message({:http_error, 429, "Rate limited"}, 1234)
    success = message(nil)
    {model, context, options} = invocation([failed, success], :oneshot_hint_test)

    assert LemonAi.complete(model, context, options) == {:ok, success}
    assert_receive {:sleep, 1234}
    assert_receive :http_request
    assert_receive :http_request
    refute_received :http_request

    for _ <- 1..2 do
      assert_receive {:private_stream, stream}
      monitor = Process.monitor(stream)
      assert_receive {:DOWN, ^monitor, :process, ^stream, _}, 1_000
    end
  end

  test "public complete handles overloaded terminal errors" do
    failed = message({:http_error, 529, %{"error" => %{"type" => "overloaded_error"}}})
    success = message(nil)
    {model, context, options} = invocation([{failed, []}, success], :oneshot_overload_test)

    assert LemonAi.complete(model, context, options) == {:ok, success}
    assert_receive {:sleep, 2}
    assert_receive :http_request
    assert_receive :http_request
    refute_received :http_request
  end

  test "public complete shares its bounded attempt budget with HTTP retrying providers" do
    error = {:http_error, 503, "Service unavailable"}
    {model, context, options} = invocation([{:request_error, error}], :oneshot_budget_test)
    options = %{options | retry: Keyword.put(options.retry, :max_attempts, 3)}

    assert LemonAi.complete(model, context, options) == {:error, error}

    for _ <- 1..3 do
      assert_receive :http_request
    end

    refute_received :http_request
    assert_receive {:sleep, 2}
    assert_receive {:sleep, delay}
    assert delay in 3..4
    refute_received {:sleep, _}
  end

  test "public complete does not retry a nonretryable 400" do
    error = {:http_error, 400, "Invalid request"}
    {model, context, options} = invocation([{:request_error, error}], :oneshot_client_test)

    assert LemonAi.complete(model, context, options) == {:error, error}
    assert_receive :http_request
    refute_received :http_request
    refute_received {:sleep, _}
  end

  test "public complete surfaces excessive hints instead of replaying early" do
    failed = message({:http_error, 429, "Rate limited"}, 30_001)
    {model, context, options} = invocation([failed], :oneshot_long_hint_test)

    assert LemonAi.complete(model, context, options) == {:ok, failed}
    assert_receive :http_request
    refute_received :http_request
    refute_received {:sleep, _}
  end

  test "public complete respects cancellation during backoff" do
    error = {:http_error, 503, "Service unavailable"}
    {model, context, options} = invocation([{:request_error, error}], :oneshot_cancel_test)
    options = %{options | retry: [sleep_fun: fn _ -> {:error, :user_cancel} end]}

    assert LemonAi.complete(model, context, options) == {:error, :user_cancel}
    assert_receive :http_request
    refute_received :http_request
  end
end
