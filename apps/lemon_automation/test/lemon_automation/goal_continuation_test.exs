defmodule LemonAutomation.GoalContinuationTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.GoalContinuation
  alias LemonCore.GoalStore

  defmodule GoalRouterOk do
    @moduledoc false

    def submit(params) do
      send(params.meta.test_pid, {:router_submit, params})
      {:ok, params.run_id}
    end
  end

  defmodule GoalRouterError do
    @moduledoc false

    def submit(_params), do: {:error, :busy}
  end

  setup do
    session_key = "goal-continuation-test-#{System.unique_integer([:positive])}"
    on_exit(fn -> GoalStore.clear(session_key) end)
    {:ok, session_key: session_key}
  end

  test "submits a goal continuation and records the run", %{session_key: session_key} do
    assert {:ok, goal} = GoalStore.set(session_key, "Ship Hermes parity", agent_id: "agent_1")

    params =
      goal
      |> GoalContinuation.build_params("run_preview")
      |> put_in([:meta, :test_pid], self())

    assert params.origin == :goal
    assert params.session_key == session_key
    assert params.agent_id == "agent_1"
    assert params.queue_mode == :followup
    assert params.run_id == "run_preview"
    assert params.meta.goal_id == goal.id
    assert params.prompt =~ "Ship Hermes parity"

    assert {:ok, %{run_id: "run_goal", goal: updated}} =
             GoalContinuation.continue_once(session_key,
               run_id: "run_goal",
               router_mod: GoalRouterOk,
               meta: %{test_pid: self()}
             )

    assert_receive {:router_submit, submitted}
    assert submitted.origin == :goal
    assert submitted.meta.goal_continuation == true
    assert submitted.meta.goal_continuation_count == 1
    assert submitted.meta.goal_objective_bytes == byte_size("Ship Hermes parity")
    assert updated.continuation_count == 1
    assert updated.last_run_id == "run_goal"
  end

  test "returns lifecycle and budget blockers", %{session_key: session_key} do
    assert {:error, :not_found} =
             GoalContinuation.continue_once(session_key, router_mod: GoalRouterOk)

    assert {:ok, _goal} = GoalStore.set(session_key, "Pause me")
    assert {:ok, _paused} = GoalStore.pause(session_key)

    assert {:error, :paused} =
             GoalContinuation.continue_once(session_key, router_mod: GoalRouterOk)

    assert {:ok, _resumed} = GoalStore.resume(session_key)

    assert {:error, :budget_exhausted} =
             GoalContinuation.continue_once(session_key,
               router_mod: GoalRouterOk,
               max_continuations: 0
             )

    assert {:ok, _completed} = GoalStore.complete(session_key)

    assert {:error, :completed} =
             GoalContinuation.continue_once(session_key, router_mod: GoalRouterOk)
  end

  test "does not mutate the goal when router submit fails", %{session_key: session_key} do
    assert {:ok, _goal} = GoalStore.set(session_key, "Fail safely")

    assert {:error, :busy} =
             GoalContinuation.continue_once(session_key,
               run_id: "run_failed",
               router_mod: GoalRouterError
             )

    goal = GoalStore.get(session_key)
    assert goal.continuation_count == 0
    refute goal.last_run_id == "run_failed"
  end
end
