defmodule LemonAi.CallDispatcherTest do
  use ExUnit.Case, async: false

  alias LemonAi.CallDispatcher
  alias LemonAi.RateLimiter
  alias LemonAi.CircuitBreaker
  alias LemonAi.EventStream

  # Use unique provider names per test to avoid conflicts
  setup do
    test_id = System.unique_integer([:positive])
    provider = :"test_provider_#{test_id}"
    {:ok, provider: provider}
  end

  describe "LemonAi.CallDispatcher" do
    test "dispatch allows requests when conditions are met", %{provider: provider} do
      # Start rate limiter and circuit breaker for this provider
      start_supervised!({RateLimiter, provider: provider, tokens_per_second: 10, max_tokens: 5})
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 5})

      result = CallDispatcher.dispatch(provider, fn -> {:ok, "success"} end)

      assert {:ok, "success"} = result
    end

    test "dispatch rejects when circuit is open", %{provider: provider} do
      # Start rate limiter and circuit breaker
      start_supervised!({RateLimiter, provider: provider, tokens_per_second: 10, max_tokens: 5})
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 2})

      # Record enough failures to open the circuit
      CircuitBreaker.record_failure(provider)
      CircuitBreaker.record_failure(provider)

      # record_failure/1 is a cast; the dispatch below is ordered after both casts
      # because they come from the same process.

      result = CallDispatcher.dispatch(provider, fn -> {:ok, "should not run"} end)

      assert {:error, :circuit_open} = result
    end

    test "dispatch rejects when rate limited", %{provider: provider} do
      # Start rate limiter with only 1 token and no refill
      start_supervised!({RateLimiter, provider: provider, tokens_per_second: 0, max_tokens: 1})
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 5})

      # First request should succeed
      assert {:ok, _} = CallDispatcher.dispatch(provider, fn -> {:ok, "first"} end)

      # Second request should be rate limited (no tokens left)
      result = CallDispatcher.dispatch(provider, fn -> {:ok, "second"} end)

      assert {:error, :rate_limited} = result
    end

    test "dispatch enforces concurrency cap", %{provider: provider} do
      # Start rate limiter and circuit breaker
      start_supervised!(
        {RateLimiter, provider: provider, tokens_per_second: 100, max_tokens: 100}
      )

      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 5})

      # Set concurrency cap to 1
      CallDispatcher.set_concurrency_cap(provider, 1)

      # Start a long-running request that holds the slot
      parent = self()

      task =
        Task.async(fn ->
          CallDispatcher.dispatch(provider, fn ->
            send(parent, :slot_acquired)
            # Hold the slot for a while
            receive do
              :release -> {:ok, "done"}
            end
          end)
        end)

      # Wait for the first request to acquire the slot
      assert_receive :slot_acquired, 1000

      # With queueing disabled, a second request is rejected immediately
      result =
        CallDispatcher.dispatch(provider, fn -> {:ok, "should not run"} end, queue_timeout_ms: 0)

      assert {:error, :max_concurrency} = result

      # Release the first request
      send(task.pid, :release)
      Task.await(task)
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

    test "stream terminal error is recorded as circuit breaker failure", %{provider: provider} do
      start_supervised!(
        {RateLimiter, provider: provider, tokens_per_second: 100, max_tokens: 100}
      )

      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 3})

      {:ok, stream} =
        CallDispatcher.dispatch(provider, fn ->
          EventStream.start_link(owner: self())
        end)

      wait_until(fn -> CallDispatcher.get_active_requests(provider) == 1 end)

      {:ok, cb_before} = CircuitBreaker.get_state(provider)
      assert cb_before.failure_count == 0

      EventStream.error(stream, %{
        stop_reason: :error,
        error_message: "stream failed",
        content: []
      })

      wait_until(fn -> CallDispatcher.get_active_requests(provider) == 0 end)

      wait_until(fn ->
        {:ok, state} = CircuitBreaker.get_state(provider)
        state.failure_count == 1
      end)
    end

    test "auth-shaped stream terminal error is not recorded as circuit breaker failure",
         %{provider: provider} do
      start_supervised!(
        {RateLimiter, provider: provider, tokens_per_second: 100, max_tokens: 100}
      )

      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 3})

      {:ok, stream} =
        CallDispatcher.dispatch(provider, fn ->
          EventStream.start_link(owner: self())
        end)

      wait_until(fn -> CallDispatcher.get_active_requests(provider) == 1 end)

      {:ok, cb_before} = CircuitBreaker.get_state(provider)
      assert cb_before.failure_count == 0

      EventStream.error(stream, %{
        stop_reason: :error,
        error_message: "Authentication failed (HTTP 401): invalid x-api-key",
        content: []
      })

      wait_until(fn -> CallDispatcher.get_active_requests(provider) == 0 end)

      {:ok, cb_after} = CircuitBreaker.get_state(provider)
      assert cb_after.failure_count == 0
    end

    for api <- [:anthropic_messages, :openai_completions, :openai_responses] do
      @api api
      test "#{api} missing local keys do not open the provider circuit", %{provider: provider} do
        start_supervised!(
          {RateLimiter, provider: provider, tokens_per_second: 100, max_tokens: 100}
        )

        start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 3})

        model = %LemonAi.Types.Model{id: "missing-key", provider: provider, api: @api}

        context =
          LemonAi.Types.Context.new(messages: [%LemonAi.Types.UserMessage{content: "hello"}])

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

    test "rate-limit-shaped stream terminal error is not recorded as circuit breaker failure",
         %{provider: provider} do
      start_supervised!(
        {RateLimiter, provider: provider, tokens_per_second: 100, max_tokens: 100}
      )

      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 3})

      {:ok, stream} =
        CallDispatcher.dispatch(provider, fn ->
          EventStream.start_link(owner: self())
        end)

      wait_until(fn -> CallDispatcher.get_active_requests(provider) == 1 end)

      EventStream.error(stream, %{
        stop_reason: :error,
        error_message: "Rate limit exceeded (HTTP 429): too many requests",
        content: []
      })

      wait_until(fn -> CallDispatcher.get_active_requests(provider) == 0 end)

      {:ok, cb_after} = CircuitBreaker.get_state(provider)
      assert cb_after.failure_count == 0
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
        Keyword.put(previous_dispatcher_config, :stream_result_timeout_ms, 500)
      )

      on_exit(fn ->
        Application.put_env(:lemon_ai, CallDispatcher, previous_dispatcher_config)
      end)

      {:ok, stream} =
        CallDispatcher.dispatch(provider, fn ->
          EventStream.start_link(owner: self())
        end)

      wait_until(fn -> CallDispatcher.get_active_requests(provider) == 1 end)

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

  describe "LemonAi.RateLimiter" do
    test "acquire allows requests when tokens available", %{provider: provider} do
      start_supervised!({RateLimiter, provider: provider, tokens_per_second: 10, max_tokens: 5})

      # Should allow multiple requests up to max_tokens
      assert :ok = RateLimiter.acquire(provider)
      assert :ok = RateLimiter.acquire(provider)
      assert :ok = RateLimiter.acquire(provider)
    end

    test "acquire rejects when bucket is empty", %{provider: provider} do
      # Start with only 2 tokens and no refill
      start_supervised!({RateLimiter, provider: provider, tokens_per_second: 0, max_tokens: 2})

      # Use up all tokens
      assert :ok = RateLimiter.acquire(provider)
      assert :ok = RateLimiter.acquire(provider)

      # Should be rate limited now
      assert {:error, :rate_limited} = RateLimiter.acquire(provider)
    end

    test "tokens refill over time", %{provider: provider} do
      # 2 tokens per second (one every 500ms) leaves the empty-bucket assertion
      # plenty of slack on a slow scheduler.
      start_supervised!({RateLimiter, provider: provider, tokens_per_second: 2, max_tokens: 5})

      # Use the initial tokens
      for _ <- 1..5 do
        assert :ok = RateLimiter.acquire(provider)
      end

      # Should be empty
      assert {:error, :rate_limited} = RateLimiter.acquire(provider)

      # Should have tokens again once the bucket refills
      wait_until(fn -> RateLimiter.acquire(provider) == :ok end, 5_000)
    end
  end

  describe "LemonAi.CircuitBreaker" do
    test "starts in closed state", %{provider: provider} do
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 5})

      # Circuit should be closed (not open)
      refute CircuitBreaker.open?(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :closed
    end

    test "opens after threshold failures", %{provider: provider} do
      start_supervised!({CircuitBreaker, provider: provider, failure_threshold: 3})

      # Circuit should start closed
      refute CircuitBreaker.open?(provider)

      # Record failures
      CircuitBreaker.record_failure(provider)
      CircuitBreaker.record_failure(provider)

      # Still closed (only 2 failures)
      refute CircuitBreaker.open?(provider)

      # Third failure should open the circuit
      CircuitBreaker.record_failure(provider)

      assert CircuitBreaker.open?(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :open
    end

    test "transitions to half_open after timeout", %{provider: provider} do
      advance_clock =
        start_breaker_with_clock(provider, failure_threshold: 2, recovery_timeout: 200)

      # Open the circuit
      CircuitBreaker.record_failure(provider)
      CircuitBreaker.record_failure(provider)

      assert CircuitBreaker.open?(provider)

      # Move time past the recovery timeout
      advance_clock.(200)

      # Should transition to half_open (not open)
      refute CircuitBreaker.open?(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open
    end

    test "closes after successful requests in half_open", %{provider: provider} do
      advance_clock =
        start_breaker_with_clock(provider, failure_threshold: 2, recovery_timeout: 200)

      # Open the circuit
      CircuitBreaker.record_failure(provider)
      CircuitBreaker.record_failure(provider)

      assert CircuitBreaker.open?(provider)

      # Move time past the recovery timeout
      advance_clock.(200)

      refute CircuitBreaker.open?(provider)
      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open

      # Record successful requests (need 2 for half_open_success_threshold)
      CircuitBreaker.record_success(provider)

      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :half_open

      CircuitBreaker.record_success(provider)

      # Should be closed now
      {:ok, state} = CircuitBreaker.get_state(provider)
      assert state.circuit_state == :closed
    end
  end

  # Starts a circuit breaker on a manually advanced clock; returns a function
  # that moves the clock forward by the given milliseconds.
  defp start_breaker_with_clock(provider, opts) do
    clock = :atomics.new(1, signed: true)

    start_supervised!(
      {CircuitBreaker,
       opts
       |> Keyword.put(:provider, provider)
       |> Keyword.put(:monotonic_time, fn -> :atomics.get(clock, 1) end)}
    )

    fn milliseconds ->
      # A call from the same process observes all earlier casts before time moves.
      {:ok, _state} = CircuitBreaker.get_state(provider)
      :atomics.add_get(clock, 1, milliseconds)
    end
  end

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

  defp wait_until(fun, timeout_ms \\ 5_000, step_ms \\ 10) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(step_ms)
        wait_until(fun, timeout_ms, step_ms)
      else
        flunk("condition not met within #{timeout_ms}ms")
      end
    end
  end
end
