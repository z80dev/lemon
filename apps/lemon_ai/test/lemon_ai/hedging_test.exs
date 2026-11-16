defmodule LemonAi.HedgingTest do
  use ExUnit.Case, async: false

  alias LemonAi.{CallDispatcher, EventStream}
  alias LemonAi.Types.{AssistantMessage, Usage}

  setup do
    previous = Application.get_env(:lemon_ai, CallDispatcher, [])
    on_exit(fn -> Application.put_env(:lemon_ai, CallDispatcher, previous) end)
    provider = "hedging-#{System.unique_integer([:positive])}"
    :ok = CallDispatcher.set_concurrency_cap(provider, 2)
    %{provider: provider}
  end

  defp options do
    [
      model_call: %{model: "fake-model", api: :fake, call_kind: :stream},
      hedge_input_tokens: fn -> 17 end
    ]
  end

  defp enable(provider) do
    Application.put_env(:lemon_ai, CallDispatcher, hedging: %{provider => true})
  end

  defp warm(provider) do
    # Seed an observed latency window and nine requests, without wall-clock races.
    Enum.each(1..9, fn _ ->
      assert {:ok, :warm} = CallDispatcher.dispatch(provider, fn -> {:ok, :warm} end, options())
    end)

    :ok = GenServer.call(CallDispatcher, {:hedge_sample, {provider, "fake-model"}, 20})
  end

  test "duplicate starts after p90, first content wins, loser cancels and input is accounted", %{
    provider: provider
  } do
    warm(provider)
    enable(provider)
    parent = self()
    counter = :atomics.new(1, [])

    callback = fn ->
      attempt = :atomics.add_get(counter, 1, 1)
      {:ok, stream} = EventStream.start_link()
      Process.unlink(stream)
      send(parent, {:attempt, attempt, stream, System.monotonic_time(:millisecond)})

      if attempt == 2 do
        :ok = EventStream.push(stream, {:text_delta, 0, "winner", nil})
        EventStream.complete(stream, %AssistantMessage{usage: %Usage{input: 3, total_tokens: 3}})
      end

      {:ok, stream}
    end

    begun = System.monotonic_time(:millisecond)
    assert {:ok, output} = CallDispatcher.dispatch(provider, callback, options())
    assert_receive {:attempt, 1, primary, _started}
    monitor = Process.monitor(primary)
    assert_receive {:attempt, 2, _duplicate, duplicated}, 1_000
    assert duplicated - begun >= 20

    assert {:ok, %AssistantMessage{usage: %Usage{input: 20, total_tokens: 20}}} =
             EventStream.result(output)

    assert_receive {:DOWN, ^monitor, :process, ^primary, _}
    assert CallDispatcher.hedging_state(provider, "fake-model").hedges == 1
    assert CallDispatcher.hedging_state(provider, "fake-model").duplicate_input_tokens == 17
    ref = make_ref()

    :ok =
      :telemetry.attach(
        ref,
        [:lemon_ai, :dispatcher, :hedge_skipped],
        fn _, _, metadata, _ ->
          if metadata.provider == provider, do: send(parent, {:skipped, metadata.reason})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(ref) end)
    assert {:ok, next} = CallDispatcher.dispatch(provider, callback, options())
    assert_receive {:attempt, 3, next_primary, _}
    assert_receive {:skipped, :budget_exhausted}, 1_000
    EventStream.complete(next_primary, %AssistantMessage{})
    assert {:ok, _} = EventStream.result(next)
    assert :atomics.get(counter, 1) == 3
  end

  test "off by default and never applied to non-model callbacks", %{provider: provider} do
    warm(provider)
    parent = self()

    callback = fn ->
      send(parent, :called)
      {:ok, stream} = EventStream.start_link()
      EventStream.complete(stream, %AssistantMessage{})
      {:ok, stream}
    end

    assert {:ok, stream} = CallDispatcher.dispatch(provider, callback, options())
    assert {:ok, _} = EventStream.result(stream)
    assert_receive :called
    assert CallDispatcher.hedging_state(provider, "fake-model").hedges == 0
    enable(provider)
    assert {:ok, :tool} = CallDispatcher.dispatch(provider, fn -> {:ok, :tool} end)
    assert CallDispatcher.hedging_state(provider, "fake-model").requests == 10
  end

  test "the original can win after the duplicate starts and cancels its provider worker", %{
    provider: provider
  } do
    warm(provider)
    enable(provider)
    parent = self()
    counter = :atomics.new(1, [])

    callback = fn ->
      attempt = :atomics.add_get(counter, 1, 1)
      {:ok, stream} = EventStream.start_link()
      Process.unlink(stream)

      worker =
        spawn(fn ->
          receive do
            :finish -> :ok
          end
        end)

      EventStream.attach_task(stream, worker)
      send(parent, {:attempt, attempt, stream, worker})
      {:ok, stream}
    end

    assert {:ok, output} = CallDispatcher.dispatch(provider, callback, options())
    assert_receive {:attempt, 1, primary, _}
    assert_receive {:attempt, 2, duplicate, duplicate_worker}, 1_000
    duplicate_ref = Process.monitor(duplicate)
    worker_ref = Process.monitor(duplicate_worker)
    :ok = EventStream.push(primary, {:text_delta, 0, "original", nil})
    assert_receive {:DOWN, ^duplicate_ref, :process, ^duplicate, _}
    assert_receive {:DOWN, ^worker_ref, :process, ^duplicate_worker, _}
    EventStream.complete(primary, %AssistantMessage{usage: %Usage{input: 3, total_tokens: 3}})

    assert {:ok, %AssistantMessage{usage: %Usage{input: 20, total_tokens: 20}}} =
             EventStream.result(output)

    assert [{:text_delta, 0, "original", nil}, {:done, _, _}] =
             Enum.to_list(EventStream.events(output))
  end

  test "hedging preserves absent and unknown reported usage while tracking its estimate" do
    Enum.each([nil, %Usage{input: nil, total_tokens: nil}], fn usage ->
      # Each independent scenario gets a fresh provider budget, including the
      # rate limiter: nine warm-up requests plus primary and duplicate use 11.
      provider = "hedging-#{System.unique_integer([:positive])}"
      :ok = CallDispatcher.set_concurrency_cap(provider, 2)
      warm(provider)
      enable(provider)
      counter = :atomics.new(1, [])

      callback = fn ->
        attempt = :atomics.add_get(counter, 1, 1)
        {:ok, stream} = EventStream.start_link()
        Process.unlink(stream)

        if attempt == 2 do
          :ok = EventStream.push(stream, {:text_delta, 0, "winner", nil})
          EventStream.complete(stream, %AssistantMessage{usage: usage})
        end

        {:ok, stream}
      end

      assert {:ok, output} = CallDispatcher.dispatch(provider, callback, options())
      assert {:ok, %AssistantMessage{usage: ^usage}} = EventStream.result(output)
      assert CallDispatcher.hedging_state(provider, "fake-model").duplicate_input_tokens == 17
    end)
  end

  test "latency windows are bounded and isolated per model", %{provider: provider} do
    Enum.each(1..101, fn latency ->
      :ok = GenServer.call(CallDispatcher, {:hedge_sample, {provider, "fake-model"}, latency})
    end)

    assert length(CallDispatcher.hedging_state(provider, "fake-model").samples) == 100
    assert CallDispatcher.hedging_state(provider, "other").samples == []
  end

  test "hedge admission cannot queue", %{provider: provider} do
    warm(provider)
    enable(provider)
    :ok = CallDispatcher.set_concurrency_cap(provider, 1)
    parent = self()
    ref = make_ref()

    :ok =
      :telemetry.attach(
        ref,
        [:lemon_ai, :dispatcher, :hedge_skipped],
        fn _, _, metadata, _ ->
          if metadata.provider == provider, do: send(parent, {:skipped, metadata.reason})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(ref) end)

    assert {:ok, output} =
             CallDispatcher.dispatch(
               provider,
               fn ->
                 {:ok, stream} = EventStream.start_link()
                 Process.unlink(stream)
                 send(parent, {:primary, stream})
                 {:ok, stream}
               end,
               options()
             )

    assert_receive {:primary, primary}
    assert_receive {:skipped, :max_concurrency}, 1_000
    assert CallDispatcher.get_state().queued[provider] == 0
    EventStream.complete(primary, %AssistantMessage{})
    assert {:ok, _} = EventStream.result(output)
    assert CallDispatcher.hedging_state(provider, "fake-model").hedges == 0
  end
end
