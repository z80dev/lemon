defmodule LemonCore.GoalStoreTest do
  use ExUnit.Case, async: false

  alias LemonCore.GoalStore

  setup do
    session_key = "goal-store-test-#{System.unique_integer([:positive])}"
    on_exit(fn -> GoalStore.clear(session_key) end)
    {:ok, session_key: session_key}
  end

  test "sets, transitions, lists, and clears a goal", %{session_key: session_key} do
    assert {:ok, goal} =
             GoalStore.set(session_key, "Ship Hermes parity",
               agent_id: "default",
               run_id: "run_goal_test"
             )

    assert goal.session_key == session_key
    assert goal.objective == "Ship Hermes parity"
    assert goal.status == "active"
    assert is_binary(goal.id)

    assert GoalStore.get(session_key).id == goal.id
    assert Enum.any?(GoalStore.list(agent_id: "default"), &(&1.id == goal.id))

    assert {:ok, paused} = GoalStore.pause(session_key)
    assert paused.status == "paused"
    assert is_integer(paused.paused_at_ms)

    assert {:ok, resumed} = GoalStore.resume(session_key)
    assert resumed.status == "active"
    assert resumed.paused_at_ms == nil

    assert {:ok, continued} = GoalStore.record_continuation(session_key, "run_continue")
    assert continued.status == "active"
    assert continued.last_run_id == "run_continue"
    assert continued.continuation_count == 1

    assert {:ok, looped} =
             GoalStore.record_loop_verdict(
               session_key,
               %{action: :continue, reason: "more work remains", source: "test"},
               run_id: "run_continue"
             )

    assert looped.meta["goalLoop"]["lastVerdict"]["action"] == "continue"
    assert looped.meta["goalLoop"]["lastVerdict"]["reason"] == "more work remains"
    assert looped.meta["goalLoop"]["lastVerdict"]["runId"] == "run_continue"
    assert looped.meta["goalLoop"]["verdictCount"] == 1

    assert {:ok, running} = GoalStore.record_loop_status(session_key, :running)
    assert running.meta["goalLoop"]["status"] == "running"
    assert running.meta["goalLoop"]["lastVerdict"]["action"] == "continue"
    assert is_integer(running.meta["goalLoop"]["startedAtMs"])

    assert {:ok, stopped} = GoalStore.record_loop_status(session_key, :stopped)
    assert stopped.meta["goalLoop"]["status"] == "stopped"
    assert stopped.meta["goalLoop"]["lastVerdict"]["action"] == "continue"
    assert is_integer(stopped.meta["goalLoop"]["stoppedAtMs"])

    assert {:ok, auto_goal} =
             GoalStore.configure_loop_auto(session_key, true,
               max_ticks: 2,
               max_continuations: 3,
               interval_ms: 5,
               wait_timeout_ms: 10,
               judge_model: "judge-model",
               judge_failure_policy: :pause,
               model: "worker-model"
             )

    assert auto_goal.meta["goalLoop"]["auto"]["enabled"] == true
    assert auto_goal.meta["goalLoop"]["auto"]["options"]["maxTicks"] == 2
    assert auto_goal.meta["goalLoop"]["auto"]["options"]["maxContinuations"] == 3
    assert auto_goal.meta["goalLoop"]["auto"]["options"]["judgeFailurePolicy"] == "pause"

    assert {:ok, manual_goal} = GoalStore.configure_loop_auto(session_key, false)
    assert manual_goal.meta["goalLoop"]["auto"]["enabled"] == false
    assert manual_goal.meta["goalLoop"]["lastVerdict"]["action"] == "continue"

    assert {:error, :invalid_loop_action} =
             GoalStore.record_loop_verdict(session_key, %{action: :unknown})

    assert {:error, :invalid_loop_status} = GoalStore.record_loop_status(session_key, :unknown)

    assert {:ok, completed} = GoalStore.complete(session_key)
    assert completed.status == "completed"
    assert is_integer(completed.completed_at_ms)

    assert :ok = GoalStore.clear(session_key)
    assert GoalStore.get(session_key) == %{}
  end

  test "diagnostics redacts objectives and raw session ids", %{session_key: session_key} do
    assert {:ok, _goal} = GoalStore.set(session_key, "private objective text")

    diagnostics = GoalStore.diagnostics(limit: 10)

    assert diagnostics.count >= 1
    assert diagnostics.active_count >= 1
    assert diagnostics.cleanup.includes_objectives == false
    assert diagnostics.cleanup.includes_raw_session_ids == false

    assert Enum.any?(diagnostics.recent, fn goal ->
             goal.session_hash && goal.objective_bytes == byte_size("private objective text") &&
               goal.loop_auto_enabled == false
           end)

    refute inspect(diagnostics) =~ "private objective text"
    refute inspect(diagnostics) =~ session_key
  end

  test "rejects empty objectives", %{session_key: session_key} do
    assert {:error, :empty_objective} = GoalStore.set(session_key, "  ")
  end
end
