defmodule LemonAutomation.GoalContinuationTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.GoalContinuation
  alias LemonAutomation.GoalStore

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

  defmodule GoalRouterWrongId do
    def submit(_params), do: {:ok, "unexpected"}
  end

  defmodule GoalWaiterOk do
    def wait_already_subscribed(_run_id, _timeout, _opts), do: {:ok, "implemented"}
  end

  setup do
    session_key = "goal-continuation-test-#{System.unique_integer([:positive])}"
    on_exit(fn -> GoalStore.clear(session_key) end)
    {:ok, session_key: session_key}
  end

  test "submits a goal continuation and records the run", %{session_key: session_key} do
    assert {:ok, goal} =
             GoalStore.set(session_key, "Ship Hermes parity",
               agent_id: "agent_1",
               cwd: ".",
               authority: LemonAutomation.GoalAuthority.operator()
             )

    assert {:ok, params} = GoalContinuation.build_params(goal, "run_preview")
    params = put_in(params, [:meta, :test_pid], self())

    assert params.origin == :goal
    assert params.session_key == session_key
    assert params.agent_id == "agent_1"
    assert params.queue_mode == :followup
    assert params.cwd == Path.expand(".")
    # Goal runs never get goal, cron or any other delegation tool.
    assert Enum.sort(params.tool_policy.blocked_tools) ==
             Enum.sort(LemonAutomation.GoalAuthority.delegation_tools())

    assert {:ok, params.meta.cwd_identity} ==
             LemonAutomation.KanbanAuthority.directory_identity(params.cwd)

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

    assert {:ok, _goal} =
             GoalStore.set(session_key, "Pause me",
               authority: LemonAutomation.GoalAuthority.operator()
             )

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
    assert {:ok, _goal} =
             GoalStore.set(session_key, "Fail safely",
               authority: LemonAutomation.GoalAuthority.operator()
             )

    assert {:error, :busy} =
             GoalContinuation.continue_once(session_key,
               run_id: "run_failed",
               router_mod: GoalRouterError
             )

    goal = GoalStore.get(session_key)
    assert goal.continuation_count == 0
    refute goal.last_run_id == "run_failed"
  end

  test "waited completion persists result and counts acceptance once", %{session_key: key} do
    assert {:ok, _} =
             GoalStore.set(key, "Implement", authority: LemonAutomation.GoalAuthority.operator())

    assert {:ok, %{goal: goal, completion: {:ok, "implemented"}}} =
             GoalContinuation.continue_once(key,
               await_completion: true,
               run_id: "run_completed",
               router_mod: GoalRouterOk,
               waiter_mod: GoalWaiterOk,
               meta: %{test_pid: self()}
             )

    assert goal.continuation_count == 1
    assert goal.meta["lastResult"]["output"] == "implemented"
    assert GoalStore.get(key).meta["lastResult"]["status"] == "completed"
  end

  test "one-shot submission never adopts a different run id", %{session_key: key} do
    assert {:ok, _} =
             GoalStore.set(key, "Fixed identity",
               authority: LemonAutomation.GoalAuthority.operator()
             )

    assert {:error, {:submission_outcome_unknown, "fixed"}} =
             GoalContinuation.continue_once(key, run_id: "fixed", router_mod: GoalRouterWrongId)

    assert GoalStore.get(key).continuation_count == 0
  end
end
