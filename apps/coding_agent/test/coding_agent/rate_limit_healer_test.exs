defmodule CodingAgent.RateLimitHealerTest do
  use ExUnit.Case, async: false

  alias CodingAgent.RateLimitHealer
  alias Ai.Types.Model

  # Test model fixture
  @test_model %Model{
    id: "test-model",
    name: "Test Model",
    provider: :test_provider,
    api: :test_api,
    context_window: 128_000,
    max_tokens: 4096,
    input: [:text],
    reasoning: false,
    cost: nil
  }

  setup do
    # Registry is started by the application supervisor
    # Just ensure it's available
    _ = Process.whereis(CodingAgent.RateLimitHealerRegistry)

    # Attach telemetry handler for testing
    :telemetry.attach_many(
      "test-handler-#{System.unique_integer()}",
      [
        [:coding_agent, :rate_limit_healer, :probe_attempt],
        [:coding_agent, :rate_limit_healer, :probe_success],
        [:coding_agent, :rate_limit_healer, :probe_rate_limited],
        [:coding_agent, :rate_limit_healer, :healed],
        [:coding_agent, :rate_limit_healer, :failed]
      ],
      fn event, measurements, metadata, test_pid ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      self()
    )

    on_exit(fn ->
      :telemetry.detach("test-handler-#{System.unique_integer()}")
    end)

    :ok
  end

  describe "start_link/1" do
    test "starts a healer with required options" do
      opts = [
        session_id: "test-session-#{System.unique_integer([:positive])}",
        provider: :test_provider,
        model: @test_model
      ]

      assert {:ok, pid} = RateLimitHealer.start_link(opts)
      assert Process.alive?(pid)
    end

    test "registers healer in registry" do
      session_id = "test-session-#{System.unique_integer([:positive])}"

      opts = [
        session_id: session_id,
        provider: :test_provider,
        model: @test_model
      ]

      assert {:ok, _pid} = RateLimitHealer.start_link(opts)
      assert RateLimitHealer.exists?(session_id)
      assert {:ok, _pid} = RateLimitHealer.lookup(session_id)
    end

    test "fails without required options" do
      assert_raise KeyError, fn ->
        RateLimitHealer.start_link([])
      end
    end
  end

  describe "status/1" do
    test "returns current healing status" do
      session_id = "test-session-#{System.unique_integer([:positive])}"

      opts = [
        session_id: session_id,
        provider: :test_provider,
        model: @test_model,
        max_probe_attempts: 5
      ]

      {:ok, healer} = RateLimitHealer.start_link(opts)

      status = RateLimitHealer.status(healer)

      assert status.state == :probing
      assert status.probe_count == 0
      assert status.max_attempts == 5
      assert status.started_at != nil
      assert status.healed_at == nil
    end
  end

  describe "calculate_backoff_delay/1" do
    test "calculates exponential backoff" do
      assert RateLimitHealer.calculate_backoff_delay(0) == 1000
      assert RateLimitHealer.calculate_backoff_delay(1) == 2000
      assert RateLimitHealer.calculate_backoff_delay(2) == 4000
      assert RateLimitHealer.calculate_backoff_delay(3) == 8000
    end

    test "caps at maximum delay" do
      # 2^20 * 1000 is way over the max of 300_000
      assert RateLimitHealer.calculate_backoff_delay(20) == 300_000
    end
  end

  describe "mark_healed/1" do
    test "transitions state to recovered" do
      session_id = "test-session-#{System.unique_integer([:positive])}"

      opts = [
        session_id: session_id,
        provider: :test_provider,
        model: @test_model
      ]

      {:ok, healer} = RateLimitHealer.start_link(opts)

      assert :ok = RateLimitHealer.mark_healed(healer)

      status = RateLimitHealer.status(healer)
      assert status.state == :recovered
      assert status.healed_at != nil
    end

    test "executes on_healed callback" do
      test_pid = self()
      session_id = "test-session-#{System.unique_integer([:positive])}"

      opts = [
        session_id: session_id,
        provider: :test_provider,
        model: @test_model,
        on_healed: fn -> send(test_pid, :healed_callback_executed) end
      ]

      {:ok, healer} = RateLimitHealer.start_link(opts)

      RateLimitHealer.mark_healed(healer)

      assert_receive :healed_callback_executed, 1000
    end

    test "emits telemetry event" do
      session_id = "test-session-#{System.unique_integer([:positive])}"

      opts = [
        session_id: session_id,
        provider: :test_provider,
        model: @test_model
      ]

      {:ok, healer} = RateLimitHealer.start_link(opts)

      RateLimitHealer.mark_healed(healer)

      assert_receive {:telemetry, [:coding_agent, :rate_limit_healer, :healed], _measurements, metadata}
      assert metadata.session_id == session_id
      assert metadata.provider == :test_provider
    end
  end

  describe "mark_failed/2" do
    test "transitions state to failed" do
      session_id = "test-session-#{System.unique_integer([:positive])}"

      opts = [
        session_id: session_id,
        provider: :test_provider,
        model: @test_model
      ]

      {:ok, healer} = RateLimitHealer.start_link(opts)

      assert :ok = RateLimitHealer.mark_failed(healer, :test_reason)

      status = RateLimitHealer.status(healer)
      assert status.state == :failed
    end

    test "executes on_failed callback" do
      test_pid = self()
      session_id = "test-session-#{System.unique_integer([:positive])}"

      opts = [
        session_id: session_id,
        provider: :test_provider,
        model: @test_model,
        on_failed: fn -> send(test_pid, :failed_callback_executed) end
      ]

      {:ok, healer} = RateLimitHealer.start_link(opts)

      RateLimitHealer.mark_failed(healer, :test_reason)

      assert_receive :failed_callback_executed, 1000
    end

    test "emits telemetry event" do
      session_id = "test-session-#{System.unique_integer([:positive])}"

      opts = [
        session_id: session_id,
        provider: :test_provider,
        model: @test_model
      ]

      {:ok, healer} = RateLimitHealer.start_link(opts)

      RateLimitHealer.mark_failed(healer, :test_reason)

      assert_receive {:telemetry, [:coding_agent, :rate_limit_healer, :failed], _measurements, metadata}
      assert metadata.session_id == session_id
      assert metadata.reason == ":test_reason"
    end
  end

  describe "execute_probe/1" do
    test "increments probe count" do
      state = %RateLimitHealer{
        session_id: "test",
        provider: :test_provider,
        model: @test_model,
        probe_count: 0,
        probe_timeout_ms: 1000
      }

      {_result, new_state} = RateLimitHealer.execute_probe(state)
      assert new_state.probe_count == 1
    end

    test "emits probe_attempt telemetry" do
      state = %RateLimitHealer{
        session_id: "test",
        provider: :test_provider,
        model: @test_model,
        probe_count: 0,
        max_probe_attempts: 5,
        probe_timeout_ms: 1000
      }

      RateLimitHealer.execute_probe(state)

      assert_receive {:telemetry, [:coding_agent, :rate_limit_healer, :probe_attempt], measurements, metadata}
      assert measurements.probe_count == 1
      assert measurements.max_attempts == 5
      assert metadata.session_id == "test"
    end
  end

  describe "stop/1" do
    test "stops the healer process" do
      session_id = "test-session-#{System.unique_integer([:positive])}"

      opts = [
        session_id: session_id,
        provider: :test_provider,
        model: @test_model
      ]

      {:ok, healer} = RateLimitHealer.start_link(opts)

      assert :ok = RateLimitHealer.stop(healer)

      # Give it time to stop
      Process.sleep(100)

      refute Process.alive?(healer)
      refute RateLimitHealer.exists?(session_id)
    end

    test "emits stopped telemetry event" do
      session_id = "test-session-#{System.unique_integer([:positive])}"

      opts = [
        session_id: session_id,
        provider: :test_provider,
        model: @test_model
      ]

      {:ok, healer} = RateLimitHealer.start_link(opts)

      RateLimitHealer.stop(healer)

      assert_receive {:telemetry, [:coding_agent, :rate_limit_healer, :stopped], _measurements, metadata}
      assert metadata.session_id == session_id
    end
  end

  describe "exists?/1 and lookup/1" do
    test "returns false for non-existent healer" do
      refute RateLimitHealer.exists?("non-existent-session")
      assert {:error, :not_found} = RateLimitHealer.lookup("non-existent-session")
    end

    test "returns true for existing healer" do
      session_id = "test-session-#{System.unique_integer([:positive])}"

      opts = [
        session_id: session_id,
        provider: :test_provider,
        model: @test_model
      ]

      {:ok, pid} = RateLimitHealer.start_link(opts)

      assert RateLimitHealer.exists?(session_id)
      assert {:ok, ^pid} = RateLimitHealer.lookup(session_id)
    end
  end

  describe "schedule_probe/1" do
    test "sets next_probe_at with jitter" do
      state = %RateLimitHealer{
        session_id: "test",
        provider: :test_provider,
        model: @test_model,
        probe_count: 1,
        probe_timer_ref: nil
      }

      new_state = RateLimitHealer.schedule_probe(state)

      assert new_state.next_probe_at != nil
      assert new_state.probe_timer_ref != nil

      # Verify timer is set (cancel it to clean up)
      assert Process.cancel_timer(new_state.probe_timer_ref) != false
    end

    test "increases delay with probe count" do
      state_early = %RateLimitHealer{
        session_id: "test",
        provider: :test_provider,
        model: @test_model,
        probe_count: 0,
        probe_timer_ref: nil
      }

      state_late = %RateLimitHealer{
        session_id: "test",
        provider: :test_provider,
        model: @test_model,
        probe_count: 5,
        probe_timer_ref: nil
      }

      scheduled_early = RateLimitHealer.schedule_probe(state_early)
      scheduled_late = RateLimitHealer.schedule_probe(state_late)

      # Later probe should have later next_probe_at
      assert DateTime.compare(scheduled_late.next_probe_at, scheduled_early.next_probe_at) == :gt

      # Clean up timers
      Process.cancel_timer(scheduled_early.probe_timer_ref)
      Process.cancel_timer(scheduled_late.probe_timer_ref)
    end
  end
end
