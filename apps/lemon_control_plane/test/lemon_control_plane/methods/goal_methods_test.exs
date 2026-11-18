defmodule LemonControlPlane.Methods.GoalMethodsTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{
    GoalClear,
    GoalPause,
    GoalResume,
    GoalSet,
    GoalStatus
  }

  alias LemonAgent.Workspace.GoalStore

  @ctx %{conn_id: "goal-test", auth: %{role: :operator}}

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_automation)
    session_key = "goal-methods-test-#{System.unique_integer([:positive])}"
    on_exit(fn -> GoalStore.clear(session_key) end)
    {:ok, session_key: session_key}
  end

  test "sets, reads, and clears a goal", %{session_key: session_key} do
    assert {:ok, set} =
             GoalSet.handle(
               %{
                 "sessionKey" => session_key,
                 "objective" => "Finish parity",
                 "agentId" => "default",
                 "cwd" => System.tmp_dir!(),
                 "maxContinuations" => 2
               },
               @ctx
             )

    assert set["sessionKey"] == session_key
    assert set["objectiveBytes"] == byte_size("Finish parity")
    refute Map.has_key?(set, "objective")
    assert set["status"] == "active"
    assert set["budget"]["maxContinuations"] == 2
    assert GoalStore.get(session_key).cwd == Path.expand(System.tmp_dir!())
    assert set["summary"]["objectiveReturned"] == false
    assert set["summary"]["cleanup"]["includesObjectiveText"] == false

    assert {:ok, %{"goal" => status, "summary" => status_summary}} =
             GoalStatus.handle(%{"sessionKey" => session_key}, @ctx)

    assert status["id"] == set["id"]
    assert status["objectiveBytes"] == byte_size("Finish parity")
    refute Map.has_key?(status, "objective")
    assert status["budget"]["maxContinuations"] == 2
    assert status_summary["goalCount"] == 1
    assert status_summary["filteredBySessionKey"] == true
    assert status_summary["objectiveReturned"] == false
    assert status_summary["cleanup"]["includesObjectiveText"] == false

    assert {:ok, paused} = GoalPause.handle(%{"sessionKey" => session_key}, @ctx)
    assert paused["status"] == "paused"
    assert is_integer(paused["pausedAtMs"])
    assert paused["objectiveBytes"] == byte_size("Finish parity")
    refute Map.has_key?(paused, "objective")
    assert paused["summary"]["cleanup"]["includesObjectiveText"] == false

    assert {:ok, resumed} = GoalResume.handle(%{"sessionKey" => session_key}, @ctx)
    assert resumed["status"] == "active"
    assert is_nil(resumed["pausedAtMs"])
    assert resumed["objectiveBytes"] == byte_size("Finish parity")
    refute Map.has_key?(resumed, "objective")
    assert resumed["summary"]["cleanup"]["includesObjectiveText"] == false

    assert {:ok, %{"goals" => goals, "total" => total, "summary" => list_summary}} =
             GoalStatus.handle(%{"agentId" => "default"}, @ctx)

    assert total >= 1
    assert Enum.any?(goals, &(&1["id"] == set["id"]))
    assert Enum.all?(goals, &(not Map.has_key?(&1, "objective")))
    assert list_summary["goalCount"] == total
    assert list_summary["filteredByAgentId"] == true
    assert list_summary["objectiveReturned"] == false

    assert {:ok, %{"cleared" => true, "summary" => clear_summary}} =
             GoalClear.handle(%{"sessionKey" => session_key}, @ctx)

    assert clear_summary["sessionKey"] == session_key
    assert clear_summary["objectiveReturned"] == false
    assert clear_summary["cleanup"]["includesObjectiveText"] == false

    assert {:ok, %{"goal" => nil, "summary" => empty_summary}} =
             GoalStatus.handle(%{"sessionKey" => session_key}, @ctx)

    assert empty_summary["goalCount"] == 0
    assert empty_summary["objectiveReturned"] == false
  end

  test "validates required fields", %{session_key: session_key} do
    assert {:error, {:invalid_request, "sessionKey is required", nil}} =
             GoalSet.handle(%{"objective" => "x"}, @ctx)

    assert {:error, {:invalid_request, "objective is required", nil}} =
             GoalSet.handle(%{"sessionKey" => session_key}, @ctx)

    assert {:error, {:invalid_request, "sessionKey is required", nil}} =
             GoalClear.handle(%{}, @ctx)

    assert {:error, {:invalid_request, "sessionKey is required", nil}} =
             GoalPause.handle(%{}, @ctx)

    assert {:error, {:invalid_request, "sessionKey is required", nil}} =
             GoalResume.handle(%{}, @ctx)
  end

  test "cannot replace a goal while its run outcome is unresolved", %{session_key: key} do
    {:ok, _} = GoalSet.handle(%{"sessionKey" => key, "objective" => "Original"}, @ctx)
    run_id = "run_goal_rpc_#{System.unique_integer([:positive])}"

    {:ok, _} =
      GoalStore.record_loop_status(key, :reconciling, run_id: run_id, run_kind: :continuation)

    on_exit(fn ->
      LemonCore.RunStore.finalize(run_id, %{completed: %{ok: false, error: :aborted}})
      LemonAutomation.GoalLoopManager.status(key)
    end)

    assert {:error, {:conflict, _, nil}} =
             GoalSet.handle(%{"sessionKey" => key, "objective" => "Replacement"}, @ctx)

    assert GoalStore.get(key).objective == "Original"
  end

  test "method names and scopes" do
    assert GoalSet.name() == "goal.set"
    assert GoalSet.scopes() == [:write]
    assert GoalStatus.name() == "goal.status"
    assert GoalStatus.scopes() == [:read]
    assert GoalPause.name() == "goal.pause"
    assert GoalPause.scopes() == [:write]
    assert GoalResume.name() == "goal.resume"
    assert GoalResume.scopes() == [:write]
    assert GoalClear.name() == "goal.clear"
    assert GoalClear.scopes() == [:write]
  end

  test "goal.status reports only known verdict sources", %{session_key: session_key} do
    secret = "PROMPT_SECRET_7Q2X9 merger closes Friday"
    read = %{auth: %{role: :operator, scopes: [:read]}}
    assert {:ok, _} = GoalStore.set(session_key, "Finish parity")

    # A stored verdict whose source is not a known provenance value (e.g. one a
    # judge model wrote before provenance was server-side) is omitted.
    assert {:ok, _} =
             GoalStore.record_loop_verdict(session_key, %{
               action: "continue",
               reason: "r",
               source: secret
             })

    assert {:ok, %{"goal" => %{"goalLoop" => loop}} = result} =
             LemonControlPlane.Methods.Registry.dispatch(
               "goal.status",
               %{"sessionKey" => session_key},
               read
             )

    assert loop["lastAction"] == "continue"
    assert loop["lastSource"] == nil
    refute inspect(result) =~ "PROMPT_SECRET_7Q2X9"

    for {stored, shown} <- [
          {"judge:judge-model", "judge"},
          {"judge_failure_policy", "judge_failure_policy"},
          {"manual", "manual"}
        ] do
      assert {:ok, _} =
               GoalStore.record_loop_verdict(session_key, %{
                 action: "continue",
                 reason: "r",
                 source: stored
               })

      assert {:ok, %{"goal" => %{"goalLoop" => %{"lastSource" => ^shown}}}} =
               GoalStatus.handle(%{"sessionKey" => session_key}, @ctx)
    end
  end
end
