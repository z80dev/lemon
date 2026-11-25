defmodule LemonAi.CallDispatcherTest do
  use ExUnit.Case, async: false

  alias LemonAi.CallDispatcher
  alias LemonAi.CircuitBreaker
  alias LemonAi.EventStream
  alias LemonAi.RateLimiter
  alias LemonAi.Types.{Context, Model, UserMessage}

  # Use unique provider names per test to avoid conflicts
  setup do
    test_id = System.unique_integer([:positive])
    provider = :"test_provider_#{test_id}"
    {:ok, provider: provider}
  end

  describe "LemonAi.CallDispatcher" do
    test "retains only safe bounded last failure summaries across successful calls", %{
      provider: provider
    } do
      assert CallDispatcher.last_error(provider) == nil
      before = System.system_time(:millisecond)
      secret = String.duplicate("token=sk-secret /private/account https://secret.example ", 1000)
      reason = {:http_error, 401, secret}
      assert {:error, ^reason} = CallDispatcher.dispatch(provider, fn -> {:error, reason} end)
      error = CallDispatcher.last_error(to_string(provider))
      assert %{"message" => message, "atMs" => at_ms} = error
      assert message == "Provider authentication failed. Check the key with lemon setup."
      assert String.length(message) <= 256
      assert at_ms >= before
      refute Jason.encode!(error) =~ "sk-secret"
      refute Jason.encode!(error) =~ "/private"
      refute Jason.encode!(error) =~ "secret.example"
      assert {:ok, :done} = CallDispatcher.dispatch(provider, fn -> {:ok, :done} end)
      assert CallDispatcher.last_error(provider) == error
      assert {:error, :timeout} = CallDispatcher.dispatch(provider, fn -> {:error, :timeout} end)
      assert CallDispatcher.last_error(provider)["message"] =~ "temporarily unavailable"
    end

    test "dispatch lets an admitted callback run and emits a timestamp", %{provider: provider} do
      attach_dispatcher_events(provider, [:dispatch])
      before = System.system_time()

      assert {:ok, "success"} = CallDispatcher.dispatch(provider, fn -> {:ok, "success"} end)

      assert_receive {:dispatcher_event, :dispatch, %{system_time: started},
                      %{provider: ^provider}}

      assert started >= before
      assert started <= System.system_time()
    end

    test "open circuits reject before consuming rate limit tokens", %{provider: provider} do
      start_supervised!({RateLimiter, provider: provider, tokens_per_second: 0, max_tokens: 1})
      advance = start_breaker_with_clock(provider, failure_threshold: 1, recovery_timeout: 100)
      assert :ok = CircuitBreaker.record_failure(provider)

      attach_dispatcher_events(provider, [:rejected])

      assert {:error, :circuit_open} =
               CallDispatcher.dispatch(provider, fn -> flunk("open circuit admitted callback") end)

      assert_receive {:dispatcher_event, :rejected, %{duration: duration, system_time: time},
                      %{provider: ^provider, reason: :circuit_open, retry_after_ms: 100}}

      assert is_integer(time)
      assert duration >= 0
      assert {:ok, %{available_tokens: 1}} = RateLimiter.get_state(provider)
      advance.(100)
      assert {:ok, :probe} = CallDispatcher.dispatch(provider, fn -> {:ok, :probe} end)
    end

    test "rate limiting rejects without affecting the circuit or leaking a slot",
         %{provider: provider} do
      start_supervised!({RateLimiter, provider: provider, tokens_per_second: 0, max_tokens: 1})
      attach_dispatcher_events(provider, [:rejected])
      assert {:ok, :first} = CallDispatcher.dispatch(provider, fn -> {:ok, :first} end)

      for _ <- 1..3 do
        assert {:error, :rate_limited} =
                 CallDispatcher.dispatch(provider, fn ->
                   flunk("empty bucket admitted callback")
                 end)

        assert_receive {:dispatcher_event, :rejected, %{duration: duration},
                        %{provider: ^provider, reason: :rate_limited}}

        assert is_integer(duration) and duration >= 0
      end

      assert {:ok, %{circuit_state: :closed, failure_count: 0}} =
               CircuitBreaker.get_state(provider)

      assert CallDispatcher.get_active_requests(provider) == 0
    end

    test "dispatch enforces the concurrency cap when queueing is disabled", %{provider: provider} do
      assert :ok = CallDispatcher.set_concurrency_cap(provider, 1)
      holder = hold_slot(provider, :holder)
      attach_dispatcher_events(provider, [:rejected])

      assert {:error, :max_concurrency} =
               CallDispatcher.dispatch(provider, fn -> flunk("full cap admitted callback") end,
                 queue_timeout_ms: 0
               )

      assert_receive {:dispatcher_event, :rejected, %{duration: duration},
                      %{provider: ^provider, reason: :max_concurrency}}

      assert is_integer(duration) and duration >= 0
      send(holder.pid, :release)
      assert {:ok, :holder} = Task.await(holder)
      assert CallDispatcher.get_active_requests(provider) == 0
    end

    test "successful callback results pass through and clear circuit failures", %{
      provider: provider
    } do
      for value <- [{:ok, :success}, "raw_string", nil] do
        assert {:error, :timeout} =
                 CallDispatcher.dispatch(provider, fn -> {:error, :timeout} end)

        assert {:ok, %{failure_count: 1}} = CircuitBreaker.get_state(provider)

        assert CallDispatcher.dispatch(provider, fn -> value end) == value
        assert {:ok, %{failure_count: 0}} = CircuitBreaker.get_state(provider)
      end
    end

    test "re-raises callback exceptions, releases slots and records circuit failures",
         %{provider: provider} do
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 2})
      assert :ok = CallDispatcher.set_concurrency_cap(provider, 1)

      for count <- 1..2 do
        assert_raise RuntimeError, "simulated error", fn ->
          CallDispatcher.dispatch(provider, fn -> raise "simulated error" end,
            queue_timeout_ms: 0
          )
        end

        assert {:ok, %{failure_count: ^count}} = CircuitBreaker.get_state(provider)
        assert CallDispatcher.get_active_requests(provider) == 0
      end

      assert CircuitBreaker.open?(provider)
    end

    test "concurrent dispatch failures are counted below and at the threshold",
         %{provider: provider} do
      for {threshold, state} <- [{3, :open}, {6, :closed}] do
        key = "#{provider}-#{threshold}"

        start_supervised!({CircuitBreaker, provider: key, failure_threshold: threshold},
          id: {CircuitBreaker, key}
        )

        tasks =
          for _ <- 1..5 do
            Task.async(fn ->
              CallDispatcher.dispatch(key, fn -> {:error, :timeout} end)
            end)
          end

        results = Task.await_many(tasks)
        expected_count = min(threshold, 5)
        assert Enum.count(results, &(&1 == {:error, :timeout})) >= expected_count
        assert Enum.all?(results, &(&1 in [{:error, :timeout}, {:error, :circuit_open}]))

        assert {:ok, %{circuit_state: ^state, failure_count: ^expected_count}} =
                 CircuitBreaker.get_state(key)

        assert CallDispatcher.get_active_requests(key) == 0
      end
    end

    test "opening the circuit rejects concurrent newcomers, not work already admitted",
         %{provider: provider} do
      advance = start_breaker_with_clock(provider, failure_threshold: 1, recovery_timeout: 100)
      holder = hold_slot(provider, :in_flight)
      assert {:error, :timeout} = CallDispatcher.dispatch(provider, fn -> {:error, :timeout} end)

      tasks =
        for _ <- 1..5 do
          Task.async(fn ->
            CallDispatcher.dispatch(provider, fn -> flunk("open circuit admitted callback") end)
          end)
        end

      assert Task.await_many(tasks) == List.duplicate({:error, :circuit_open}, 5)
      send(holder.pid, :release)
      assert {:ok, :in_flight} = Task.await(holder)
      assert CircuitBreaker.open?(provider)

      advance.(100)

      tasks =
        for probe <- [:first, :second] do
          hold_slot(provider, probe)
        end

      assert {:ok, %{circuit_state: :half_open}} = CircuitBreaker.get_state(provider)
      Enum.each(tasks, &send(&1.pid, :release))
      assert Task.await_many(tasks) == [{:ok, :first}, {:ok, :second}]

      assert {:ok, %{circuit_state: :closed, failure_count: 0}} =
               CircuitBreaker.get_state(provider)
    end

    test "nested dispatch to another provider does not consume the outer provider's cap",
         %{provider: provider} do
      inner = :"#{provider}_inner"
      assert :ok = CallDispatcher.set_concurrency_cap(provider, 1)
      assert :ok = CallDispatcher.set_concurrency_cap(inner, 1)

      assert {:ok, {:ok, :inner}} =
               CallDispatcher.dispatch(provider, fn ->
                 {:ok,
                  CallDispatcher.dispatch(inner, fn -> {:ok, :inner} end, queue_timeout_ms: 0)}
               end)

      assert CallDispatcher.get_active_requests(provider) == 0
      assert CallDispatcher.get_active_requests(inner) == 0
    end

    test "dispatcher releases slot if caller is killed", %{provider: provider} do
      start_supervised!(
        {RateLimiter, provider: provider, tokens_per_second: 100, max_tokens: 100}
      )

      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 5})

      CallDispatcher.set_concurrency_cap(provider, 1)

      pid =
        spawn(fn ->
          CallDispatcher.dispatch(provider, fn ->
            Process.sleep(:infinity)
          end)
        end)

      wait_until(fn -> CallDispatcher.get_active_requests(provider) == 1 end)

      # :kill ensures the caller's `after` cleanup does not run.
      Process.exit(pid, :kill)

      wait_until(fn -> CallDispatcher.get_active_requests(provider) == 0 end)

      assert {:ok, "ok"} = CallDispatcher.dispatch(provider, fn -> {:ok, "ok"} end)
    end

    test "stream dispatch keeps slot occupied until stream terminal result", %{provider: provider} do
      start_supervised!(
        {RateLimiter, provider: provider, tokens_per_second: 100, max_tokens: 100}
      )

      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 5})

      CallDispatcher.set_concurrency_cap(provider, 1)

      {:ok, stream} =
        CallDispatcher.dispatch(provider, fn ->
          EventStream.start_link(owner: self())
        end)

      wait_until(fn -> CallDispatcher.get_active_requests(provider) == 1 end)

      assert {:error, :max_concurrency} =
               CallDispatcher.dispatch(provider, fn -> {:ok, "blocked"} end, queue_timeout_ms: 0)

      EventStream.complete(stream, %{stop_reason: :end_turn, content: []})

      wait_until(fn -> CallDispatcher.get_active_requests(provider) == 0 end)

      assert {:ok, "after_stream"} =
               CallDispatcher.dispatch(provider, fn -> {:ok, "after_stream"} end)
    end

    for {description, error, count, summary} <- [
          {"provider failure", "stream failed", 1, "request failed"},
          {"authentication failure", "Authentication failed (HTTP 401): invalid x-api-key", 0,
           "authentication failed"},
          {"rate limit", "Rate limit exceeded (HTTP 429): too many requests", 0,
           "rate limit exceeded"}
        ] do
      @terminal_error error
      @failure_count count
      @summary summary
      test "accounts for stream terminal #{description}", %{provider: provider} do
        start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 3})

        {:ok, stream} =
          CallDispatcher.dispatch(provider, fn -> EventStream.start_link(owner: self()) end)

        wait_until(fn -> CallDispatcher.get_active_requests(provider) == 1 end)
        assert {:ok, %{failure_count: 0}} = CircuitBreaker.get_state(provider)

        EventStream.error(stream, %{
          stop_reason: :error,
          error_message: @terminal_error,
          content: []
        })

        wait_until(fn -> CallDispatcher.get_active_requests(provider) == 0 end)

        assert {:ok, %{failure_count: @failure_count}} = CircuitBreaker.get_state(provider)

        assert CallDispatcher.last_error(provider)["message"] =~ @summary
      end
    end

    for api <- [:anthropic_messages, :openai_completions, :openai_responses] do
      @api api
      test "#{api} missing local keys do not open the provider circuit", %{provider: provider} do
        start_supervised!(
          {RateLimiter, provider: provider, tokens_per_second: 100, max_tokens: 100}
        )

        start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 3})

        model = %Model{id: "missing-key", provider: provider, api: @api}

        context =
          Context.new(messages: [%UserMessage{content: "hello"}])

        # Exercise the real provider's local credential refusal and asynchronous
        # dispatcher accounting beyond the breaker threshold, without resets.
        for _ <- 1..5 do
          assert {:ok, stream} = LemonAi.stream(model, context, %{})
          assert {:error, message} = EventStream.result(stream)
          assert message.error_message =~ "No API key provided"
          wait_until(fn -> CallDispatcher.get_active_requests(provider) == 0 end)
          EventStream.cancel(stream, :test_cleanup)
        end

        assert {:ok, %{failure_count: 0, circuit_state: :closed}} =
                 CircuitBreaker.get_state(provider)

        assert {:ok, :still_available} =
                 CallDispatcher.dispatch(provider, fn -> {:ok, :still_available} end)
      end
    end

    test "user-driven stream cancel is not recorded as circuit breaker failure",
         %{provider: provider} do
      start_supervised!(
        {RateLimiter, provider: provider, tokens_per_second: 100, max_tokens: 100}
      )

      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 3})

      for reason <- [:aborted, :redirected] do
        {:ok, stream} =
          CallDispatcher.dispatch(provider, fn ->
            EventStream.start_link(owner: self())
          end)

        wait_until(fn -> CallDispatcher.get_active_requests(provider) == 1 end)

        EventStream.cancel(stream, reason)

        wait_until(fn -> CallDispatcher.get_active_requests(provider) == 0 end)
      end

      {:ok, cb_after} = CircuitBreaker.get_state(provider)
      assert cb_after.failure_count == 0
    end

    test "shutdown link-cascade of the stream is not recorded as circuit breaker failure",
         %{provider: provider} do
      start_supervised!(
        {RateLimiter, provider: provider, tokens_per_second: 100, max_tokens: 100}
      )

      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 3})

      parent = self()

      # The stream's parent/owner is a task that gets shut down mid-stream —
      # the fallback wrapper's relay-task teardown path.
      {:ok, owner_task} =
        Task.Supervisor.start_child(LemonAi.StreamTaskSupervisor, fn ->
          {:ok, stream} =
            CallDispatcher.dispatch(provider, fn ->
              EventStream.start_link(owner: self())
            end)

          send(parent, {:stream, stream})
          Process.sleep(:infinity)
        end)

      assert_receive {:stream, _stream}, 1_000
      wait_until(fn -> CallDispatcher.get_active_requests(provider) == 1 end)

      Process.exit(owner_task, :shutdown)

      wait_until(fn -> CallDispatcher.get_active_requests(provider) == 0 end)

      {:ok, cb_after} = CircuitBreaker.get_state(provider)
      assert cb_after.failure_count == 0
    end

    test "stream tracking timeout cancels stalled stream and releases slot", %{provider: provider} do
      start_supervised!(
        {RateLimiter, provider: provider, tokens_per_second: 100, max_tokens: 100}
      )

      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 5})

      CallDispatcher.set_concurrency_cap(provider, 1)

      previous_dispatcher_config = Application.get_env(:lemon_ai, CallDispatcher, [])

      Application.put_env(
        :lemon_ai,
        CallDispatcher,
        Keyword.put(previous_dispatcher_config, :stream_timeout, 100)
      )

      on_exit(fn ->
        Application.put_env(:lemon_ai, CallDispatcher, previous_dispatcher_config)
      end)

      {:ok, stream} =
        CallDispatcher.dispatch(provider, fn ->
          EventStream.start_link(owner: self())
        end)

      wait_until(fn -> CallDispatcher.get_active_requests(provider) == 1 end)

      assert EventStream.result(stream, 1_000) ==
               {:error, {:canceled, :dispatcher_stream_timeout}}

      wait_until(fn -> CallDispatcher.get_active_requests(provider) == 0 end, 5_000)

      assert {:ok, "after_timeout"} =
               CallDispatcher.dispatch(provider, fn -> {:ok, "after_timeout"} end)

      :ok = EventStream.cancel(stream, :test_cleanup)
    end

    test "set_concurrency_cap works correctly", %{provider: provider} do
      # Default cap is 10
      assert 10 = CallDispatcher.get_concurrency_cap(provider)

      # Set a new cap
      assert :ok = CallDispatcher.set_concurrency_cap(provider, 5)
      assert 5 = CallDispatcher.get_concurrency_cap(provider)

      # Set another value
      assert :ok = CallDispatcher.set_concurrency_cap(provider, 20)
      assert 20 = CallDispatcher.get_concurrency_cap(provider)
    end
  end

  describe "concurrency queueing" do
    setup %{provider: provider} do
      start_supervised!(
        {RateLimiter, provider: provider, tokens_per_second: 100, max_tokens: 100}
      )

      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 5})
      CallDispatcher.set_concurrency_cap(provider, 1)
      :ok
    end

    test "dispatch at the cap waits for a slot and runs once it frees", %{provider: provider} do
      holder = hold_slot(provider, :holder)
      parent = self()

      waiter =
        Task.async(fn ->
          CallDispatcher.dispatch(provider, fn -> report_ran(parent, :waiter) end)
        end)

      wait_until(fn -> queued_count(provider) == 1 end)
      refute_receive {:ran, :waiter}, 100

      send(holder.pid, :release)
      assert {:ok, :holder} = Task.await(holder)

      assert_receive {:ran, :waiter}, 1_000
      assert {:ok, :waiter} = Task.await(waiter)
      assert CallDispatcher.get_active_requests(provider) == 0
    end

    test "queued dispatch returns max_concurrency when the wait times out without leaking a slot",
         %{provider: provider} do
      holder = hold_slot(provider, :holder)
      parent = self()
      handler_id = "test-queued-#{inspect(make_ref())}"

      :telemetry.attach(
        handler_id,
        [:lemon_ai, :dispatcher, :queued],
        fn event, _measurements, metadata, _config ->
          send(parent, {:telemetry, event, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:error, :max_concurrency} =
               CallDispatcher.dispatch(provider, fn -> report_ran(parent, :timed_out) end,
                 queue_timeout_ms: 50
               )

      assert_receive {:telemetry, [:lemon_ai, :dispatcher, :queued], %{provider: ^provider}}
      assert queued_count(provider) == 0

      send(holder.pid, :release)
      assert {:ok, :holder} = Task.await(holder)

      assert CallDispatcher.get_active_requests(provider) == 0
      refute_received {:ran, :timed_out}
    end

    test "queued waiters are granted slots in arrival order", %{provider: provider} do
      holder = hold_slot(provider, :holder)
      parent = self()

      first = Task.async(fn -> dispatch_holding_slot(parent, provider, :first) end)
      wait_until(fn -> queued_count(provider) == 1 end)

      second = Task.async(fn -> dispatch_holding_slot(parent, provider, :second) end)
      wait_until(fn -> queued_count(provider) == 2 end)

      send(holder.pid, :release)
      assert {:ok, :holder} = Task.await(holder)

      assert_receive {:slot_acquired, :first}, 1_000
      refute_received {:slot_acquired, :second}
      assert queued_count(provider) == 1

      send(first.pid, :release)
      assert {:ok, :first} = Task.await(first)

      assert_receive {:slot_acquired, :second}, 1_000
      send(second.pid, :release)
      assert {:ok, :second} = Task.await(second)

      assert CallDispatcher.get_active_requests(provider) == 0
    end

    test "queued waiter that dies before being granted does not leak a slot",
         %{provider: provider} do
      holder = hold_slot(provider, :holder)
      parent = self()

      waiter_pid =
        spawn(fn ->
          CallDispatcher.dispatch(provider, fn -> report_ran(parent, :dead_waiter) end)
        end)

      wait_until(fn -> queued_count(provider) == 1 end)
      Process.exit(waiter_pid, :kill)

      send(holder.pid, :release)
      assert {:ok, :holder} = Task.await(holder)

      wait_until(fn ->
        CallDispatcher.get_active_requests(provider) == 0 and queued_count(provider) == 0
      end)

      refute_received {:ran, :dead_waiter}

      assert {:ok, "free"} =
               CallDispatcher.dispatch(provider, fn -> {:ok, "free"} end, queue_timeout_ms: 0)
    end
  end

  describe "dynamic concurrency caps" do
    test "lowering the cap preserves active requests and blocks new admission",
         %{provider: provider} do
      assert :ok = CallDispatcher.set_concurrency_cap(provider, 3)
      holders = for i <- 1..3, do: hold_slot(provider, i)
      assert CallDispatcher.get_active_requests(provider) == 3

      assert :ok = CallDispatcher.set_concurrency_cap(provider, 1)
      assert CallDispatcher.get_active_requests(provider) == 3

      assert {:error, :max_concurrency} =
               CallDispatcher.dispatch(provider, fn -> flunk("lower cap admitted callback") end,
                 queue_timeout_ms: 0
               )

      Enum.each(holders, &send(&1.pid, :release))
      assert Task.await_many(holders) == [{:ok, 1}, {:ok, 2}, {:ok, 3}]
      assert CallDispatcher.get_active_requests(provider) == 0
    end

    test "raising the cap admits a queued waiter before existing work releases",
         %{provider: provider} do
      assert :ok = CallDispatcher.set_concurrency_cap(provider, 1)
      holder = hold_slot(provider, :holder)
      parent = self()
      waiter = Task.async(fn -> dispatch_holding_slot(parent, provider, :waiter) end)
      wait_until(fn -> queued_count(provider) == 1 end)

      assert :ok = CallDispatcher.set_concurrency_cap(provider, 2)
      assert_receive {:slot_acquired, :waiter}
      assert CallDispatcher.get_active_requests(provider) == 2

      send(waiter.pid, :release)
      assert {:ok, :waiter} = Task.await(waiter)

      assert {:ok, :new} =
               CallDispatcher.dispatch(provider, fn -> {:ok, :new} end, queue_timeout_ms: 0)

      send(holder.pid, :release)
      assert {:ok, :holder} = Task.await(holder)
      assert CallDispatcher.get_active_requests(provider) == 0
    end

    test "concurrent cap changes and queued dispatches do not lose results or slots",
         %{provider: provider} do
      assert :ok = CallDispatcher.set_concurrency_cap(provider, 1)
      holder = hold_slot(provider, :holder)
      parent = self()

      waiters =
        for i <- 1..10 do
          Task.async(fn -> CallDispatcher.dispatch(provider, fn -> report_ran(parent, i) end) end)
        end

      wait_until(fn -> queued_count(provider) == 10 end)

      cap_changer =
        Task.async(fn ->
          for cap <- [2, 1, 3, 2, 1],
              do: assert(:ok = CallDispatcher.set_concurrency_cap(provider, cap))
        end)

      send(holder.pid, :release)
      assert {:ok, :holder} = Task.await(holder)
      Task.await(cap_changer)
      assert Task.await_many(waiters) == Enum.map(1..10, &{:ok, &1})
      assert queued_count(provider) == 0
      assert CallDispatcher.get_active_requests(provider) == 0
    end

    test "concurrent providers have independent slots", %{provider: provider} do
      other = :"#{provider}_other"
      assert :ok = CallDispatcher.set_concurrency_cap(provider, 1)
      assert :ok = CallDispatcher.set_concurrency_cap(other, 1)

      holders = [hold_slot(provider, :first), hold_slot(other, :other)]

      for key <- [provider, other] do
        assert CallDispatcher.get_active_requests(key) == 1

        assert {:error, :max_concurrency} =
                 CallDispatcher.dispatch(key, fn -> flunk("full provider admitted callback") end,
                   queue_timeout_ms: 0
                 )
      end

      Enum.each(holders, &send(&1.pid, :release))
      assert Task.await_many(holders) == [{:ok, :first}, {:ok, :other}]
      assert CallDispatcher.get_active_requests(provider) == 0
      assert CallDispatcher.get_active_requests(other) == 0
    end
  end

  defp start_breaker_with_clock(provider, opts) do
    clock = :atomics.new(1, signed: true)

    start_supervised!(
      {CircuitBreaker,
       opts
       |> Keyword.put(:provider, provider)
       |> Keyword.put(:monotonic_time, fn -> :atomics.get(clock, 1) end)}
    )

    fn milliseconds -> :atomics.add_get(clock, 1, milliseconds) end
  end

  defp attach_dispatcher_events(provider, events) do
    handler_id = {__MODULE__, self()}
    events = Enum.map(events, &[:lemon_ai, :dispatcher, &1])

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        &__MODULE__.handle_telemetry/4,
        {self(), provider}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  @doc false
  def handle_telemetry(
        [:lemon_ai, :dispatcher, event],
        measurements,
        %{provider: provider} = metadata,
        {pid, provider}
      ) do
    send(pid, {:dispatcher_event, event, measurements, metadata})
  end

  def handle_telemetry(_event, _measurements, _metadata, _config), do: :ok

  # Starts a task whose dispatch holds a slot until it receives `:release`.
  defp hold_slot(provider, name) do
    parent = self()
    task = Task.async(fn -> dispatch_holding_slot(parent, provider, name) end)
    assert_receive {:slot_acquired, ^name}, 1_000
    task
  end

  defp dispatch_holding_slot(parent, provider, name) do
    CallDispatcher.dispatch(provider, fn ->
      send(parent, {:slot_acquired, name})

      receive do
        :release -> {:ok, name}
      end
    end)
  end

  defp report_ran(parent, name) do
    send(parent, {:ran, name})
    {:ok, name}
  end

  defp queued_count(provider) do
    Map.get(CallDispatcher.get_state().queued, provider, 0)
  end

  defp wait_until(fun, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_until(fun, deadline, timeout_ms)
  end

  defp wait_until(fun, deadline, timeout_ms) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(10)
        wait_until(fun, deadline, timeout_ms)

      true ->
        flunk("condition not met within #{timeout_ms}ms")
    end
  end
end
