defmodule LemonRouter.RunCountTrackerTest do
  use ExUnit.Case, async: false

  alias LemonCore.Events.{Completion, RunCompleted}
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
    reset_counters()
    :ok
  end

  # Synchronize a deterministic volatile baseline without altering durable history.
  defp reset_counters do
    :sys.replace_state(RunCountTracker, fn _ -> %{runs: %{}, available?: true} end)
    :ok
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
    test "midnight_reset removes old volatile entries and rebuilds today's durable totals" do
      run_id = "midnight-durable-#{System.unique_integer([:positive])}"
      assert :ok = LemonCore.Introspection.record(:run_completed, %{ok: true}, run_id: run_id)
      RunCountTracker.record_terminal("volatile-previous-day", true)
      assert RunCountTracker.failed_today() == 1

      send(RunCountTracker, :midnight_reset)
      state = :sys.get_state(RunCountTracker)
      refute Map.has_key?(state.runs, "volatile-previous-day")
      assert state.runs[run_id] == false
      assert is_integer(RunCountTracker.queued())
      assert RunCountTracker.completed_today() == map_size(state.runs)
    end
  end

  test "failed terminals count once across telemetry and explicit failure events" do
    :telemetry.execute([:lemon, :run, :stop], %{ok: false}, %{run_id: "failed-terminal"})
    RunCountTracker.record_terminal("failed-terminal", true)
    RunCountTracker.record_terminal("crashed-terminal", true)
    assert RunCountTracker.completed_today() == 2
    assert RunCountTracker.failed_today() == 2
  end

  test "pre-executor failures leave durable seed evidence without a RunProcess" do
    run_id = "queued-terminal-#{System.unique_integer([:positive])}"
    command = %LemonCore.ExecutionCommand{run_id: run_id, session_key: "count-test", prompt: ""}
    completion = Completion.new(%{ok: false, error: :cancelled})

    event =
      LemonCore.Event.new(
        :run_completed,
        RunCompleted.new(%{completed: completion, duration_ms: 0}),
        %{run_id: run_id}
      )

    assert :ok = LemonRouter.RunCompletion.publish(command, event)
    assert RunCountTracker.failed_today() == 1
    send(RunCountTracker, :midnight_reset)
    assert :sys.get_state(RunCountTracker).runs[run_id] == true
  end

  test "restart seeds today's durable terminals, deduplicating run IDs and excluding yesterday" do
    prefix = "count-seed-#{System.unique_integer([:positive])}"
    midnight = DateTime.new!(Date.utc_today(), ~T[00:00:00], "Etc/UTC")
    ts = DateTime.to_unix(midnight, :millisecond)

    for {suffix, type, payload, timestamp} <- [
          {"ok", :run_completed, %{ok: true}, ts},
          {"bad", :run_completed, %{ok: false}, ts},
          {"bad", :run_failed, %{}, ts},
          {"crash", :run_failed, %{}, ts},
          {"old", :run_completed, %{ok: true}, ts - 1}
        ] do
      assert :ok =
               LemonCore.Introspection.record(type, payload,
                 run_id: prefix <> suffix,
                 ts_ms: timestamp
               )
    end

    assert :ok = Supervisor.terminate_child(LemonRouter.Supervisor, RunCountTracker)
    assert {:ok, _} = Supervisor.restart_child(LemonRouter.Supervisor, RunCountTracker)
    state = :sys.get_state(RunCountTracker)
    assert state.runs[prefix <> "ok"] == false
    assert state.runs[prefix <> "bad"] == true
    assert state.runs[prefix <> "crash"] == true
    refute Map.has_key?(state.runs, prefix <> "old")
    before = RunCountTracker.completed_today()
    RunCountTracker.record_terminal(prefix <> "bad", true)
    assert RunCountTracker.completed_today() == before
  end

  test "exiting tracker preserves other fields and reports unavailable daily counts" do
    assert :ok = Supervisor.terminate_child(LemonRouter.Supervisor, RunCountTracker)
    on_exit(fn -> Supervisor.restart_child(LemonRouter.Supervisor, RunCountTracker) end)
    counts = LemonRouter.RunOrchestrator.counts()
    assert is_integer(counts.active)
    assert is_integer(counts.queued)
    assert counts.completed_today == nil
    assert counts.failed_today == nil
  end

  test "an unresponsive coordinator returns an unknown backlog within 500 ms" do
    supervisor = LemonRouter.SessionCoordinatorSupervisor

    {:ok, pid} =
      DynamicSupervisor.start_child(
        supervisor,
        {Task, fn -> receive do: (:stop -> :ok) end}
      )

    try do
      started = System.monotonic_time(:millisecond)
      counts = LemonRouter.RunOrchestrator.counts()
      assert counts.queued == nil
      assert is_integer(counts.active)
      assert System.monotonic_time(:millisecond) - started < 500
    after
      DynamicSupervisor.terminate_child(supervisor, pid)
    end
  end

  test "unavailable run supervision does not invent zero active runs" do
    supervisor = LemonRouter.RunSupervisor
    assert :ok = Supervisor.terminate_child(LemonRouter.Supervisor, supervisor)

    try do
      assert LemonRouter.RunOrchestrator.counts().active == nil
    after
      Supervisor.restart_child(LemonRouter.Supervisor, supervisor)
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
