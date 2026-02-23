defmodule LemonRouter.RunCountTrackerTest do
  use ExUnit.Case, async: false

  alias LemonRouter.RunCountTracker

  @moduledoc """
  Tests for RunCountTracker telemetry-based run counting.

  Verifies that queued and completed_today counters respond to
  the standard Lemon telemetry events rather than returning
  hardcoded placeholder values.
  """

  # The tracker is started by the LemonRouter application supervisor.
  # We verify it is running and test against the live instance.
  # Because other test modules may emit telemetry that bumps counters,
  # we reset to zero before each test to get deterministic assertions.

  setup do
    # Reset counters to a known state
    send(Process.whereis(RunCountTracker), :midnight_reset)
    Process.sleep(10)
    :ok
  end

  describe "queued counter" do
    test "starts at zero after reset" do
      assert RunCountTracker.queued() == 0
    end

    test "increments on [:lemon, :run, :submit] telemetry event" do
      :telemetry.execute([:lemon, :run, :submit], %{count: 1}, %{
        session_key: "test:rct:submit",
        origin: :control_plane,
        engine: "echo"
      })

      assert RunCountTracker.queued() >= 1
    end

    test "decrements on [:lemon, :run, :start] telemetry event" do
      # Emit a submit first so there's something to decrement
      :telemetry.execute([:lemon, :run, :submit], %{count: 1}, %{
        session_key: "test:rct:start",
        origin: :control_plane,
        engine: "echo"
      })

      queued_after_submit = RunCountTracker.queued()
      assert queued_after_submit >= 1

      :telemetry.execute([:lemon, :run, :start], %{ts_ms: System.system_time(:millisecond)}, %{
        run_id: "run_test_rct_start"
      })

      assert RunCountTracker.queued() < queued_after_submit
    end

    test "never returns negative values" do
      # Force multiple starts without submits to drive counter below zero
      Enum.each(1..5, fn _ ->
        :telemetry.execute([:lemon, :run, :start], %{ts_ms: 0}, %{run_id: "run_neg"})
      end)

      assert RunCountTracker.queued() >= 0
    end
  end

  describe "completed_today counter" do
    test "starts at zero after reset" do
      assert RunCountTracker.completed_today() == 0
    end

    test "increments on [:lemon, :run, :stop] telemetry event" do
      :telemetry.execute([:lemon, :run, :stop], %{duration_ms: 100, ok: true}, %{
        run_id: "run_done_1"
      })

      assert RunCountTracker.completed_today() >= 1
    end

    test "accumulates across multiple completions" do
      Enum.each(1..3, fn i ->
        :telemetry.execute([:lemon, :run, :stop], %{duration_ms: i * 10, ok: true}, %{
          run_id: "run_multi_#{i}"
        })
      end)

      assert RunCountTracker.completed_today() >= 3
    end
  end

  describe "midnight reset" do
    test "midnight_reset message clears counters" do
      # Inject some counts
      :telemetry.execute([:lemon, :run, :submit], %{count: 1}, %{
        session_key: "s",
        origin: :test,
        engine: "e"
      })

      :telemetry.execute([:lemon, :run, :stop], %{duration_ms: 1, ok: true}, %{
        run_id: "r"
      })

      send(Process.whereis(RunCountTracker), :midnight_reset)
      Process.sleep(20)

      assert RunCountTracker.queued() == 0
      assert RunCountTracker.completed_today() == 0
    end
  end

  describe "ms_until_next_utc_midnight/0" do
    test "returns a positive integer" do
      ms = RunCountTracker.ms_until_next_utc_midnight()
      assert is_integer(ms)
      assert ms > 0
      # Should be at most 24 hours
      assert ms <= 24 * 60 * 60 * 1000
    end
  end
end
