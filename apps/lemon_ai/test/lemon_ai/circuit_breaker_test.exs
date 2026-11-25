defmodule LemonAi.CircuitBreakerTest do
  use ExUnit.Case, async: false

  alias LemonAi.CircuitBreaker

  setup do
    %{provider: "breaker-#{System.unique_integer([:positive])}"}
  end

  test "opens on exactly the configured number of failures", %{provider: provider} do
    for {name, opts, threshold} <- [
          {:default, [], 5},
          {:one, [failure_threshold: 1], 1},
          {:custom, [failure_threshold: 3], 3},
          {:high, [failure_threshold: 10], 10}
        ] do
      key = "#{provider}-#{name}"
      start_breaker(key, opts)

      for count <- 1..threshold do
        state = if count == threshold, do: :open, else: :closed
        assert :ok = CircuitBreaker.record_failure(key, :timeout)

        assert {:ok,
                %{
                  circuit_state: ^state,
                  failure_count: ^count,
                  failure_threshold: ^threshold,
                  last_failure_reason: :timeout
                }} = CircuitBreaker.get_state(key)

        assert CircuitBreaker.open?(key) == (state == :open)
      end
    end
  end

  test "tracks independent thresholds and failure counts per provider", %{provider: provider} do
    other = provider <> "-other"
    start_breaker(provider, failure_threshold: 2)
    start_breaker(other, failure_threshold: 5)

    for _ <- 1..2, key <- [provider, other], do: CircuitBreaker.record_failure(key)

    assert_state(provider, :open, 2)
    assert_state(other, :closed, 2)
  end

  test "closed successes reset consecutive failures before they can open the circuit",
       %{provider: provider} do
    start_breaker(provider, failure_threshold: 3)

    for _ <- 1..3 do
      Enum.each(1..2, fn _ -> CircuitBreaker.record_failure(provider) end)
      assert_state(provider, :closed, 2)
      assert :ok = CircuitBreaker.record_success(provider)
      assert_state(provider, :closed, 0)
    end
  end

  test "allows recovery exactly at the default or configured deadline", %{provider: provider} do
    for {name, opts, timeout} <- [
          {:default, [], 30_000},
          {:short, [recovery_timeout: 1], 1},
          {:long, [recovery_timeout: 10_000], 10_000}
        ] do
      key = "#{provider}-#{name}"
      {_pid, advance} = start_with_clock(key, [failure_threshold: 1] ++ opts)

      refute CircuitBreaker.open?(key)
      assert CircuitBreaker.time_until_recovery(key) == 0
      CircuitBreaker.record_failure(key)
      assert CircuitBreaker.time_until_recovery(key) == timeout

      advance.(timeout - 1)
      assert CircuitBreaker.open?(key)
      assert CircuitBreaker.time_until_recovery(key) == 1
      assert_state(key, :open, 1)

      advance.(1)
      assert_state(key, :half_open, 1)
      refute CircuitBreaker.open?(key)
      assert CircuitBreaker.time_until_recovery(key) == 0
    end
  end

  test "additional failures extend the open deadline; successes do not affect it",
       %{provider: provider} do
    {_pid, advance} = start_with_clock(provider, failure_threshold: 1, recovery_timeout: 100)
    CircuitBreaker.record_failure(provider)
    advance.(80)
    CircuitBreaker.record_success(provider)
    assert CircuitBreaker.time_until_recovery(provider) == 20
    assert_state(provider, :open, 1)

    reason = {:http_error, 503, "overloaded"}
    CircuitBreaker.record_failure(provider, reason)
    assert {:ok, %{last_failure_reason: ^reason}} = CircuitBreaker.get_state(provider)
    advance.(50)
    assert CircuitBreaker.time_until_recovery(provider) == 50
    assert_state(provider, :open, 1)

    advance.(50)
    assert_state(provider, :half_open, 1)
  end

  test "half-open failures restart recovery and two consecutive successes close it",
       %{provider: provider} do
    {_pid, advance} = start_with_clock(provider, failure_threshold: 2, recovery_timeout: 20)

    for _ <- 1..2 do
      CircuitBreaker.record_failure(provider)
      assert_state(provider, :closed, 1)
      CircuitBreaker.record_failure(provider)
      assert_state(provider, :open, 2)

      for successes_before_failure <- [0, 1] do
        advance.(20)
        assert_state(provider, :half_open, 2)

        if successes_before_failure == 1 do
          CircuitBreaker.record_success(provider)
          assert_state(provider, :half_open, 2)
        end

        CircuitBreaker.record_failure(provider)
        assert_state(provider, :open, 2)
        assert CircuitBreaker.open?(provider)
      end

      advance.(20)
      CircuitBreaker.record_success(provider)
      assert_state(provider, :half_open, 2)
      refute CircuitBreaker.open?(provider)

      CircuitBreaker.record_success(provider)
      assert_state(provider, :closed, 0)
      CircuitBreaker.record_success(provider)
      assert_state(provider, :closed, 0)
    end
  end

  test "reset clears history in every state and subsequent results count from scratch",
       %{provider: provider} do
    for initial_state <- [:closed, :open, :half_open] do
      key = "#{provider}-#{initial_state}"
      {_pid, advance} = start_with_clock(key, failure_threshold: 2, recovery_timeout: 20)

      CircuitBreaker.record_failure(key)

      if initial_state != :closed, do: CircuitBreaker.record_failure(key)

      if initial_state == :half_open do
        advance.(20)
        CircuitBreaker.record_success(key)
      end

      assert_state(key, initial_state, if(initial_state == :closed, do: 1, else: 2))

      for _ <- 1..2 do
        assert :ok = CircuitBreaker.reset(key)
        refute CircuitBreaker.open?(key)

        assert {:ok, %{circuit_state: :closed, failure_count: 0, last_failure_reason: nil}} =
                 CircuitBreaker.get_state(key)
      end

      CircuitBreaker.record_failure(key)
      assert_state(key, :closed, 1)
      CircuitBreaker.record_failure(key)
      assert_state(key, :open, 2)
      advance.(20)
      CircuitBreaker.record_success(key)
      assert_state(key, :half_open, 2)
      CircuitBreaker.record_success(key)
      assert_state(key, :closed, 0)
    end
  end

  test "ensure_started starts one breaker with the caller's options", %{provider: provider} do
    assert :not_started = CircuitBreaker.peek(provider)

    assert {:ok, pid} =
             CircuitBreaker.ensure_started(provider, failure_threshold: 7, recovery_timeout: 2500)

    on_exit(fn -> DynamicSupervisor.terminate_child(LemonAi.ProviderSupervisor, pid) end)
    assert {:ok, ^pid} = CircuitBreaker.ensure_started(provider)

    assert {:ok,
            %{
              provider: ^provider,
              circuit_state: :closed,
              failure_count: 0,
              failure_threshold: 7,
              recovery_timeout: 2500,
              last_failure_reason: nil
            }} = CircuitBreaker.get_state(provider)
  end

  test "open? and get_state auto-start missing breakers", %{provider: provider} do
    refute CircuitBreaker.open?(provider)
    assert {:ok, %{state: :closed}} = CircuitBreaker.peek(provider)
    assert_state(provider <> "-state", :closed, 0)

    for key <- [provider, provider <> "-state"] do
      assert {:ok, pid} = CircuitBreaker.ensure_started(key)
      on_exit(fn -> DynamicSupervisor.terminate_child(LemonAi.ProviderSupervisor, pid) end)
    end
  end

  describe "ETS snapshots" do
    test "peek neither starts a breaker nor refreshes expired state", %{provider: provider} do
      assert :not_started = CircuitBreaker.peek(provider)
      assert :not_started = CircuitBreaker.peek(provider)
      {_pid, advance} = start_with_clock(provider, failure_threshold: 1, recovery_timeout: 10)

      assert {:ok, %{state: :closed, failure_count: 0, time_until_recovery_ms: 0}} =
               CircuitBreaker.peek(provider)

      CircuitBreaker.record_failure(provider, :private_reason)
      advance.(10)
      assert {:ok, snapshot} = CircuitBreaker.peek(provider)
      assert snapshot == %{state: :open, failure_count: 1, time_until_recovery_ms: 0}
      assert {:ok, ^snapshot} = CircuitBreaker.peek(provider)

      assert_state(provider, :half_open, 1)
      assert {:ok, %{state: :half_open, failure_count: 1}} = CircuitBreaker.peek(provider)
    end

    test "string status identifiers find existing atom-keyed breakers" do
      start_breaker(:circuit_peek_atom_test)
      assert {:ok, %{state: :closed}} = CircuitBreaker.peek("circuit_peek_atom_test")
    end

    test "admission and status reads do not call a suspended breaker", %{provider: provider} do
      {pid, advance} = start_with_clock(provider, failure_threshold: 1, recovery_timeout: 100)
      CircuitBreaker.record_failure(provider)
      :ok = :sys.suspend(pid)

      try do
        assert CircuitBreaker.open?(provider)
        assert CircuitBreaker.time_until_recovery(provider) == 100
        assert {:ok, %{state: :open, failure_count: 1}} = CircuitBreaker.peek(provider)
        advance.(100)
        refute CircuitBreaker.open?(provider)
        assert CircuitBreaker.time_until_recovery(provider) == 0
      after
        :sys.resume(pid)
      end

      assert :ok = CircuitBreaker.reset(provider)
      refute CircuitBreaker.open?(provider)
      assert {:ok, %{state: :closed, failure_count: 0}} = CircuitBreaker.peek(provider)
    end
  end

  test "concurrent failures are counted up to the threshold and publish coherent snapshots",
       %{provider: provider} do
    for {threshold, final_state, final_count} <- [{20, :open, 20}, {50, :closed, 30}] do
      key = "#{provider}-#{threshold}"
      start_breaker(key, failure_threshold: threshold)

      tasks =
        for _ <- 1..30 do
          Task.async(fn ->
            assert :ok = CircuitBreaker.record_failure(key)

            assert {:ok, %{circuit_state: state, failure_count: count}} =
                     CircuitBreaker.get_state(key)

            case state do
              :closed -> assert count in 1..(threshold - 1)
              :open -> assert count == threshold
            end
          end)
        end

      Task.await_many(tasks)
      assert CircuitBreaker.open?(key) == (final_state == :open)
      assert_state(key, final_state, final_count)
    end
  end

  test "concurrent successes cannot open the circuit with fewer failures than the threshold",
       %{provider: provider} do
    start_breaker(provider, failure_threshold: 11)

    for operation <- [:success, :failure], _ <- 1..10 do
      Task.async(fn ->
        case operation do
          :success -> CircuitBreaker.record_success(provider)
          :failure -> CircuitBreaker.record_failure(provider)
        end
      end)
    end
    |> Task.await_many()

    assert {:ok, %{circuit_state: :closed, failure_count: count}} =
             CircuitBreaker.get_state(provider)

    assert count in 0..10
  end

  test "emits the actual lifecycle event sequence", %{provider: provider} do
    {_pid, advance} = start_with_clock(provider, failure_threshold: 1, recovery_timeout: 20)
    handler_id = {__MODULE__, self()}

    events =
      Enum.map([:opened, :half_opened, :reopened, :closed], &[:lemon_ai, :circuit_breaker, &1])

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        &__MODULE__.handle_telemetry/4,
        {self(), provider}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    CircuitBreaker.record_failure(provider)
    advance.(20)
    assert_state(provider, :half_open, 1)
    CircuitBreaker.record_failure(provider, :econnreset)
    advance.(20)
    assert_state(provider, :half_open, 1)
    CircuitBreaker.record_success(provider)
    CircuitBreaker.record_success(provider)

    for {event, expected} <- [
          {:opened, %{failure_count: 1, failure_threshold: 1, reason: :unknown}},
          {:half_opened, %{recovery_timeout: 20}},
          {:reopened, %{reason: :econnreset}},
          {:half_opened, %{recovery_timeout: 20}},
          {:closed, %{}}
        ] do
      assert_receive {:breaker_event, actual, %{system_time: system_time}, metadata}
      assert actual == event
      assert is_integer(system_time)
      assert Map.take(metadata, Map.keys(expected)) == expected
    end

    refute_received {:breaker_event, _, _, _}
  end

  @doc false
  def handle_telemetry(
        [:lemon_ai, :circuit_breaker, event],
        measurements,
        %{provider: provider} = metadata,
        {pid, provider}
      ) do
    send(pid, {:breaker_event, event, measurements, metadata})
  end

  def handle_telemetry(_event, _measurements, _metadata, _config), do: :ok

  defp start_breaker(provider, opts \\ []) do
    start_supervised!({CircuitBreaker, Keyword.put(opts, :provider, provider)},
      id: {CircuitBreaker, provider}
    )
  end

  defp start_with_clock(provider, opts) do
    clock = :atomics.new(1, signed: true)

    pid =
      start_breaker(
        provider,
        Keyword.put(opts, :monotonic_time, fn -> :atomics.get(clock, 1) end)
      )

    {pid, fn milliseconds -> :atomics.add_get(clock, 1, milliseconds) end}
  end

  defp assert_state(provider, state, count) do
    assert {:ok, %{circuit_state: ^state, failure_count: ^count}} =
             CircuitBreaker.get_state(provider)
  end
end
