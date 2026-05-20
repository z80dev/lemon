defmodule LemonControlPlane.Methods.GoalMethodsTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{
    GoalClear,
    GoalContinue,
    GoalLoopOnce,
    GoalLoopStart,
    GoalLoopStatus,
    GoalLoopStop,
    GoalPause,
    GoalResume,
    GoalSet,
    GoalStatus
  }

  alias LemonCore.GoalStore

  @ctx %{conn_id: "goal-test", auth: %{role: :operator}}

  defmodule ContinuationOk do
    @moduledoc false

    def continue_once(session_key, opts) do
      send(self(), {:goal_continue, session_key, opts})

      {:ok, goal} =
        GoalStore.set(session_key, "private objective", agent_id: "default", run_id: "run_before")

      {:ok,
       %{
         run_id: "run_continue",
         goal: %{goal | last_run_id: "run_continue", continuation_count: 1}
       }}
    end
  end

  defmodule LoopOnceOk do
    @moduledoc false

    def run_once(session_key, opts) do
      send(self(), {:goal_loop_once, session_key, opts})

      {:ok, goal} =
        GoalStore.set(session_key, "private objective", agent_id: "default", run_id: "run_before")

      {:ok,
       %{
         run_id: "run_loop",
         verdict: %{action: :continue, reason: "still open", source: "test"},
         goal: %{goal | last_run_id: "run_loop", continuation_count: 1}
       }}
    end

    def start_loop(session_key, opts) do
      send(self(), {:goal_loop_start, session_key, opts})

      {:ok,
       %{
         session_key: session_key,
         status: "running",
         started_at_ms: 123,
         max_ticks: opts[:max_ticks]
       }}
    end

    def stop_loop(session_key) do
      send(self(), {:goal_loop_stop, session_key})

      {:ok, goal} =
        GoalStore.set(session_key, "private objective", agent_id: "default", run_id: "run_before")

      {:ok,
       %{
         loop: %{session_key: session_key, status: "stopped", started_at_ms: 123, max_ticks: 2},
         goal: goal
       }}
    end

    def status(session_key) do
      send(self(), {:goal_loop_status, session_key})

      {:ok, goal} =
        GoalStore.set(session_key, "private objective", agent_id: "default", run_id: "run_before")

      {:ok,
       %{
         running: true,
         loop: %{session_key: session_key, status: "running", started_at_ms: 123, max_ticks: 2},
         goal: goal
       }}
    end
  end

  setup do
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
                 "maxContinuations" => 2
               },
               @ctx
             )

    assert set["sessionKey"] == session_key
    assert set["objectiveBytes"] == byte_size("Finish parity")
    refute Map.has_key?(set, "objective")
    assert set["status"] == "active"
    assert set["budget"]["maxContinuations"] == 2
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

    previous_mod = Application.get_env(:lemon_control_plane, :goal_continuation_module)
    previous_loop_mod = Application.get_env(:lemon_control_plane, :goal_loop_module)
    Application.put_env(:lemon_control_plane, :goal_continuation_module, ContinuationOk)
    Application.put_env(:lemon_control_plane, :goal_loop_module, LoopOnceOk)

    on_exit(fn ->
      if previous_mod do
        Application.put_env(:lemon_control_plane, :goal_continuation_module, previous_mod)
      else
        Application.delete_env(:lemon_control_plane, :goal_continuation_module)
      end

      if previous_loop_mod do
        Application.put_env(:lemon_control_plane, :goal_loop_module, previous_loop_mod)
      else
        Application.delete_env(:lemon_control_plane, :goal_loop_module)
      end
    end)

    assert {:ok, continued} =
             GoalContinue.handle(
               %{"sessionKey" => session_key, "runId" => "run_continue"},
               @ctx
             )

    assert_receive {:goal_continue, ^session_key, opts}
    assert opts[:run_id] == "run_continue"
    assert continued["runId"] == "run_continue"
    assert continued["goal"]["continuationCount"] == 1
    assert continued["goal"]["objectiveBytes"] == byte_size("private objective")
    refute Map.has_key?(continued["goal"], "objective")
    assert continued["summary"]["objectiveReturned"] == false
    assert continued["summary"]["cleanup"]["includesObjectiveText"] == false

    assert {:ok, looped} =
             GoalLoopOnce.handle(
               %{
                 "sessionKey" => session_key,
                 "runId" => "run_loop",
                 "judgeModel" => "judge-model",
                 "judgeFailurePolicy" => "continueOnce"
               },
               @ctx
             )

    assert_receive {:goal_loop_once, ^session_key, loop_opts}
    assert loop_opts[:run_id] == "run_loop"
    assert loop_opts[:judge_model] == "judge-model"
    assert loop_opts[:judge_failure_policy] == :continue_once
    assert looped["runId"] == "run_loop"
    assert looped["verdict"]["action"] == "continue"
    assert looped["verdict"]["reason"] == "still open"
    assert looped["goal"]["continuationCount"] == 1
    assert looped["goal"]["objectiveBytes"] == byte_size("private objective")
    refute Map.has_key?(looped["goal"], "objective")
    assert looped["summary"]["verdictReasonBytes"] == byte_size("still open")
    assert looped["summary"]["objectiveReturned"] == false
    assert looped["summary"]["cleanup"]["includesObjectiveText"] == false

    assert {:ok, started} =
             GoalLoopStart.handle(
               %{
                 "sessionKey" => session_key,
                 "maxTicks" => 2,
                 "intervalMs" => 5,
                 "judgeModel" => "judge-model",
                 "judgeFailurePolicy" => "needsInput",
                 "auto" => true
               },
               @ctx
             )

    assert_receive {:goal_loop_start, ^session_key, start_opts}
    assert start_opts[:max_ticks] == 2
    assert start_opts[:interval_ms] == 5
    assert start_opts[:judge_model] == "judge-model"
    assert start_opts[:judge_failure_policy] == :needs_input
    assert start_opts[:auto] == true
    assert started["loop"]["status"] == "running"
    assert started["loop"]["maxTicks"] == 2
    assert started["summary"]["objectiveReturned"] == false
    assert started["summary"]["cleanup"]["includesObjectiveText"] == false

    assert {:ok, loop_status} = GoalLoopStatus.handle(%{"sessionKey" => session_key}, @ctx)
    assert_receive {:goal_loop_status, ^session_key}
    assert loop_status["running"] == true
    assert loop_status["loop"]["status"] == "running"
    assert loop_status["auto"]["enabled"] == false
    assert loop_status["goal"]["objectiveBytes"] == byte_size("private objective")
    refute Map.has_key?(loop_status["goal"], "objective")
    assert loop_status["summary"]["running"] == true
    assert loop_status["summary"]["objectiveReturned"] == false
    assert loop_status["summary"]["cleanup"]["includesObjectiveText"] == false

    assert {:ok, stopped} = GoalLoopStop.handle(%{"sessionKey" => session_key}, @ctx)
    assert_receive {:goal_loop_stop, ^session_key}
    assert stopped["loop"]["status"] == "stopped"
    assert stopped["goal"]["objectiveBytes"] == byte_size("private objective")
    refute Map.has_key?(stopped["goal"], "objective")
    assert stopped["summary"]["objectiveReturned"] == false
    assert stopped["summary"]["cleanup"]["includesObjectiveText"] == false

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

    assert {:error, {:invalid_request, "sessionKey is required", nil}} =
             GoalContinue.handle(%{}, @ctx)

    assert {:error, {:invalid_request, "sessionKey is required", nil}} =
             GoalLoopOnce.handle(%{}, @ctx)

    assert {:error, {:invalid_request, "sessionKey is required", nil}} =
             GoalLoopStart.handle(%{}, @ctx)

    assert {:error, {:invalid_request, "sessionKey is required", nil}} =
             GoalLoopStatus.handle(%{}, @ctx)

    assert {:error, {:invalid_request, "sessionKey is required", nil}} =
             GoalLoopStop.handle(%{}, @ctx)
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
    assert GoalContinue.name() == "goal.continue"
    assert GoalContinue.scopes() == [:write]
    assert GoalLoopOnce.name() == "goal.loop.once"
    assert GoalLoopOnce.scopes() == [:write]
    assert GoalLoopStart.name() == "goal.loop.start"
    assert GoalLoopStart.scopes() == [:write]
    assert GoalLoopStatus.name() == "goal.loop.status"
    assert GoalLoopStatus.scopes() == [:read]
    assert GoalLoopStop.name() == "goal.loop.stop"
    assert GoalLoopStop.scopes() == [:write]
    assert GoalClear.name() == "goal.clear"
    assert GoalClear.scopes() == [:write]
  end
end
