defmodule LemonAi.ModelCallTelemetryTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias LemonAi.{CallDispatcher, CircuitBreaker, EventStream, ProviderRegistry, RateLimiter}
  alias LemonAi.Types.{AssistantMessage, Context, Model, Usage}

  @events [
    [:lemon_ai, :model_call, :start],
    [:lemon_ai, :model_call, :stop],
    [:lemon_ai, :model_call, :exception]
  ]

  defmodule FakeProvider do
    @behaviour LemonAi.Provider

    @impl true
    def api_id, do: :model_call_telemetry_test
    @impl true
    def provider_id, do: :model_call_telemetry_test

    @impl true
    def stream(_model, _context, _options) do
      {:ok, stream} = LemonAi.EventStream.start_link()
      message = LemonAi.ModelCallTelemetryTest.message()
      LemonAi.EventStream.push(stream, {:text_delta, 0, "hi", message})
      LemonAi.EventStream.complete(stream, message)
      {:ok, stream}
    end
  end

  def message do
    %AssistantMessage{
      stop_reason: :stop,
      usage: %Usage{input: 10, output: 5, cache_read: 3, cache_write: 2}
    }
  end

  setup do
    provider = :"model_call_telemetry_#{System.unique_integer([:positive])}"
    start_supervised!({RateLimiter, provider: provider, tokens_per_second: 100, max_tokens: 100})
    start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 5})

    parent = self()
    handler = "model-call-telemetry-#{inspect(make_ref())}"

    :telemetry.attach_many(
      handler,
      @events,
      fn event, measurements, metadata, _config ->
        send(parent, {:model_call, List.last(event), measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    {:ok, provider: provider}
  end

  defp labels, do: [model_call: %{model: "model-x", api: :test_api, call_kind: :stream}]

  defp open_stream(provider, opts \\ []) do
    {:ok, stream} =
      CallDispatcher.dispatch(
        provider,
        fn -> EventStream.start_link(owner: self()) end,
        labels() ++ opts
      )

    stream
  end

  test "a completed stream emits start then stop with duration, first event and usage", %{
    provider: provider
  } do
    stream = open_stream(provider)

    assert_receive {:model_call, :start, start_measurements, start_metadata}, 1_000
    assert is_integer(start_measurements.system_time)
    assert is_integer(start_measurements.monotonic_time)
    assert start_metadata.provider == provider
    assert start_metadata.model == "model-x"
    assert start_metadata.api == :test_api
    assert start_metadata.call_kind == :stream
    assert is_reference(start_metadata.telemetry_span_context)

    # dispatch/3 already returned: the span must stay open until the terminal event.
    refute_received {:model_call, :stop, _, _}

    :ok = EventStream.push(stream, {:text_start, 0, message()})
    :ok = EventStream.push(stream, {:text_delta, 0, "hello", message()})
    EventStream.complete(stream, message())

    assert_receive {:model_call, :stop, measurements, metadata}, 1_000
    assert metadata.telemetry_span_context == start_metadata.telemetry_span_context
    assert metadata.provider == provider
    assert metadata.model == "model-x"
    assert metadata.outcome == :ok
    assert metadata.stop_reason == :stop
    refute Map.has_key?(metadata, :error_category)

    assert is_integer(measurements.duration) and measurements.duration >= 0
    assert is_integer(measurements.first_event_duration)
    assert measurements.first_event_duration >= 0
    assert measurements.first_event_duration <= measurements.duration
    assert measurements.input_tokens == 10
    assert measurements.output_tokens == 5
    assert measurements.cache_read_tokens == 3
    assert measurements.cache_write_tokens == 2

    refute_receive {:model_call, _, _, _}, 50
  end

  test "a first event pushed before tracking subscribes is still reported", %{
    provider: provider
  } do
    {:ok, stream} =
      CallDispatcher.dispatch(
        provider,
        fn ->
          {:ok, stream} = EventStream.start_link(owner: self())
          :ok = EventStream.push(stream, {:thinking_delta, 0, "hm", message()})
          {:ok, stream}
        end,
        labels()
      )

    EventStream.complete(stream, message())

    assert_receive {:model_call, :stop, measurements, %{outcome: :ok}}, 1_000
    assert is_integer(measurements.first_event_duration)
  end

  test "a stream without content deltas has no first_event_duration and unknown usage is omitted",
       %{provider: provider} do
    stream = open_stream(provider)
    :ok = EventStream.push(stream, {:start, message()})
    EventStream.complete(stream, %AssistantMessage{stop_reason: :stop, usage: %Usage{input: nil}})

    assert_receive {:model_call, :stop, measurements, %{outcome: :ok}}, 1_000
    refute Map.has_key?(measurements, :first_event_duration)
    refute Map.has_key?(measurements, :input_tokens)
    assert measurements.output_tokens == 0
  end

  test "a canceled stream emits a single stop with outcome :canceled", %{provider: provider} do
    stream = open_stream(provider)
    assert_receive {:model_call, :start, _, _}, 1_000

    EventStream.cancel(stream, :user_requested)

    assert_receive {:model_call, :stop, measurements, metadata}, 1_000
    assert metadata.outcome == :canceled
    assert metadata.error_category == :canceled
    assert is_integer(measurements.duration)
    refute Map.has_key?(measurements, :first_event_duration)

    refute_receive {:model_call, _, _, _}, 50
  end

  test "idle and hard stream timeouts stop the span with their own categories", %{
    provider: provider
  } do
    _idle = open_stream(provider, stream_idle_timeout: 50, stream_timeout: :infinity)
    assert_receive {:model_call, :stop, _, idle_metadata}, 1_000
    assert idle_metadata.outcome == :canceled
    assert idle_metadata.error_category == :idle_timeout

    _hard = open_stream(provider, stream_idle_timeout: :infinity, stream_timeout: 50)
    assert_receive {:model_call, :stop, _, hard_metadata}, 1_000
    assert hard_metadata.outcome == :canceled
    assert hard_metadata.error_category == :timeout
  end

  test "an aborted final message reports outcome :aborted", %{provider: provider} do
    stream = open_stream(provider)
    EventStream.error(stream, %AssistantMessage{stop_reason: :aborted, error_message: "stopped"})

    assert_receive {:model_call, :stop, _, metadata}, 1_000
    assert metadata.outcome == :aborted
    assert metadata.stop_reason == :aborted
  end

  test "a terminal stream error reports a bounded category, not the raw reason", %{
    provider: provider
  } do
    stream = open_stream(provider)

    EventStream.error(stream, %AssistantMessage{
      stop_reason: :error,
      error_message: "token=sk-secret https://secret.example rejected",
      usage: %Usage{input: 7, output: 0}
    })

    assert_receive {:model_call, :stop, measurements, metadata}, 1_000
    assert metadata.outcome == :error
    assert metadata.stop_reason == :error
    assert is_atom(metadata.error_category)
    assert measurements.input_tokens == 7
    refute inspect(metadata) =~ "sk-secret"
    refute inspect(metadata) =~ "secret.example"
  end

  test "a crashing producer closes the span with an error stop", %{provider: provider} do
    {:ok, stream} =
      CallDispatcher.dispatch(
        provider,
        fn ->
          {:ok, stream} = EventStream.start_link(owner: self())
          producer = spawn(fn -> Process.sleep(:infinity) end)
          EventStream.attach_task(stream, producer)
          send(self(), {:producer, producer})
          {:ok, stream}
        end,
        labels()
      )

    assert_receive {:producer, producer}
    # Ensure the attach_task cast was processed before the producer dies.
    _ = :sys.get_state(stream)
    Process.exit(producer, :kill)

    assert_receive {:model_call, :stop, _, metadata}, 1_000
    assert metadata.outcome == :error
    assert is_atom(metadata.error_category)
    refute_receive {:model_call, _, _, _}, 50
  end

  test "a raising callback emits :exception and no :stop", %{provider: provider} do
    assert_raise RuntimeError, "boom with sk-secret", fn ->
      CallDispatcher.dispatch(provider, fn -> raise "boom with sk-secret" end, labels())
    end

    assert_receive {:model_call, :start, _, start_metadata}, 1_000
    assert_receive {:model_call, :exception, measurements, metadata}, 1_000
    assert is_integer(measurements.duration) and measurements.duration >= 0
    assert metadata.telemetry_span_context == start_metadata.telemetry_span_context
    assert metadata.kind == :error
    assert metadata.reason == RuntimeError
    refute inspect(metadata) =~ "sk-secret"
    refute_receive {:model_call, _, _, _}, 50
  end

  test "a throwing callback still closes the span exactly once", %{provider: provider} do
    assert catch_throw(CallDispatcher.dispatch(provider, fn -> throw(:nope) end, labels())) ==
             :nope

    assert_receive {:model_call, :start, _, _}, 1_000
    assert_receive {:model_call, :exception, _, %{kind: :throw, reason: :throw}}, 1_000
    refute_receive {:model_call, _, _, _}, 50
  end

  test "non-stream results stop immediately with a bounded error category", %{
    provider: provider
  } do
    assert {:ok, %AssistantMessage{}} =
             CallDispatcher.dispatch(provider, fn -> {:ok, message()} end, labels())

    assert_receive {:model_call, :start, _, _}, 1_000
    assert_receive {:model_call, :stop, ok_measurements, %{outcome: :ok}}, 1_000
    assert ok_measurements.input_tokens == 10

    secret = "token=sk-secret https://secret.example"
    reason = {:http_error, 401, secret}
    assert {:error, ^reason} = CallDispatcher.dispatch(provider, fn -> {:error, reason} end)

    assert_receive {:model_call, :start, _, start_metadata}, 1_000
    refute Map.has_key?(start_metadata, :model)
    assert_receive {:model_call, :stop, _, metadata}, 1_000
    assert metadata.outcome == :error
    assert metadata.error_category == :auth
    refute inspect(metadata) =~ "sk-secret"
  end

  test "rejected dispatches emit no model_call events", %{provider: provider} do
    # Concurrency rejection
    CallDispatcher.set_concurrency_cap(provider, 1)
    stream = open_stream(provider)
    assert_receive {:model_call, :start, _, _}, 1_000

    assert {:error, :max_concurrency} =
             CallDispatcher.dispatch(provider, fn -> {:ok, :never} end,
               queue_timeout_ms: 0,
               model_call: %{model: "model-x"}
             )

    refute_receive {:model_call, _, _, _}, 50
    EventStream.cancel(stream, :done_testing)
    assert_receive {:model_call, :stop, _, _}, 1_000

    # Circuit rejection
    for _ <- 1..5, do: CircuitBreaker.record_failure(provider)

    assert {:error, :circuit_open} =
             CallDispatcher.dispatch(provider, fn -> {:ok, :never} end, labels())

    refute_receive {:model_call, _, _, _}, 50
  end

  test "malformed labels are ignored rather than copied into metadata", %{provider: provider} do
    CallDispatcher.dispatch(provider, fn -> {:ok, :done} end,
      model_call: %{model: %{prompt: "secret"}, api: {:url, "x"}, call_kind: :other, extra: 1}
    )

    assert_receive {:model_call, :start, _, metadata}, 1_000
    assert Map.keys(metadata) |> Enum.sort() == [:provider, :telemetry_span_context]
  end

  describe "public API labels" do
    setup do
      ProviderRegistry.register(:model_call_telemetry_test, FakeProvider)
      on_exit(fn -> ProviderRegistry.unregister(:model_call_telemetry_test) end)

      provider = :"model_call_api_#{System.unique_integer([:positive])}"

      model = %Model{
        id: "fake-model",
        name: "Fake",
        api: :model_call_telemetry_test,
        provider: provider
      }

      {:ok, model: model}
    end

    test "stream/3 labels the span :stream and complete/3 labels it :complete", %{model: model} do
      {:ok, stream} = LemonAi.stream(model, Context.new())
      assert {:ok, _} = EventStream.result(stream, 1_000)

      assert_receive {:model_call, :start, _, %{call_kind: :stream, model: "fake-model"} = meta},
                     1_000

      assert meta.api == :model_call_telemetry_test
      assert_receive {:model_call, :stop, %{first_event_duration: _}, %{outcome: :ok}}, 1_000

      assert {:ok, _message} = LemonAi.complete(model, Context.new())
      assert_receive {:model_call, :start, _, %{call_kind: :complete}}, 1_000
      assert_receive {:model_call, :stop, %{input_tokens: 10}, %{outcome: :ok}}, 1_000
    end
  end
end
