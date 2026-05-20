defmodule LemonAutomation.GoalLoopTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.{GoalLoop, GoalLoopManager}
  alias LemonCore.GoalStore

  defmodule LoopRouterOk do
    @moduledoc false

    def submit(params) do
      send(params.meta.test_pid, {:router_submit, params})
      {:ok, params.run_id}
    end
  end

  defmodule ContinueJudge do
    @moduledoc false

    def judge(goal, _opts) do
      send(goal.meta["testPid"], {:judge_goal, goal.id})
      {:ok, %{action: :continue, reason: "still open", source: "test"}}
    end
  end

  defmodule DoneJudge do
    @moduledoc false

    def judge(_goal, _opts), do: {:ok, %{action: :done, reason: "complete", source: "test"}}
  end

  defmodule BlockedJudge do
    @moduledoc false

    def judge(_goal, _opts), do: {:ok, %{action: :blocked, reason: "blocked", source: "test"}}
  end

  defmodule WaiterOk do
    @moduledoc false

    def wait(run_id, timeout_ms, opts) do
      send(opts[:test_pid], {:wait_for_run, run_id, timeout_ms})
      {:ok, "done"}
    end
  end

  defmodule WaiterTimeout do
    @moduledoc false

    def wait(_run_id, _timeout_ms, _opts), do: :timeout
  end

  defmodule JudgeRouterOk do
    @moduledoc false

    def submit(params) do
      send(Process.get(:goal_loop_test_pid), {:judge_router_submit, params})
      {:ok, params.run_id}
    end
  end

  defmodule JudgeWaiterDone do
    @moduledoc false

    def wait(run_id, timeout_ms, _opts) do
      send(Process.get(:goal_loop_test_pid), {:judge_wait, run_id, timeout_ms})
      {:ok, ~s({"action":"done","reason":"finished by judge"})}
    end
  end

  defmodule RunnerJudge do
    @moduledoc false

    def judge(goal, context) do
      send(goal.meta["testPid"], {:runner_judge, context.model})
      %{action: :done, reason: "runner says done"}
    end
  end

  defmodule LiveJudgeRuntime do
    @moduledoc false

    def available?, do: true
    def run_pid(_run_id), do: nil
    def cancel_by_run_id(_run_id, _reason), do: :ok

    def submit_execution(%LemonCore.ExecutionCommand{} = command) do
      test_pid = :persistent_term.get({__MODULE__, :test_pid}, nil)
      if is_pid(test_pid), do: send(test_pid, {:live_judge_execution, command})

      spawn(fn ->
        Process.sleep(25)

        run_id = command.run_id
        session_key = command.session_key

        LemonCore.Bus.broadcast(
          LemonCore.Bus.run_topic(run_id),
          LemonCore.Event.new(
            :run_started,
            %{run_id: run_id, engine: command.engine_id},
            %{run_id: run_id, session_key: session_key}
          )
        )

        LemonCore.Bus.broadcast(
          LemonCore.Bus.run_topic(run_id),
          LemonCore.Event.new(
            :run_completed,
            %{completed: %{ok: true, answer: ~s({"action":"done","reason":"live router proof"})}},
            %{run_id: run_id, session_key: session_key}
          )
        )
      end)

      :ok
    end
  end

  defmodule FailingJudge do
    @moduledoc false

    def judge(_goal, _opts), do: {:error, :judge_unavailable}
  end

  defmodule ManagerLoop do
    @moduledoc false

    def run_once(_session_key, _opts), do: {:error, :unused}

    def run_autonomous(session_key, opts) do
      send(Process.whereis(:goal_loop_manager_test), {:manager_run, session_key, opts})
      {:ok, %{status: :finished, tick_count: 1, goal: GoalStore.get(session_key)}}
    end
  end

  setup do
    session_key = "goal-loop-test-#{System.unique_integer([:positive])}"
    Process.put(:goal_loop_test_pid, self())
    on_exit(fn -> GoalStore.clear(session_key) end)
    {:ok, session_key: session_key}
  end

  test "records a continue verdict and submits the next continuation", %{session_key: session_key} do
    assert {:ok, _goal} =
             GoalStore.set(session_key, "Keep going",
               agent_id: "agent_1",
               meta: %{"testPid" => self()}
             )

    assert {:ok, %{run_id: "run_loop", goal: updated, verdict: verdict}} =
             GoalLoop.run_once(session_key,
               judge_mod: ContinueJudge,
               router_mod: LoopRouterOk,
               run_id: "run_loop",
               meta: %{test_pid: self()}
             )

    assert_receive {:judge_goal, _goal_id}
    assert_receive {:router_submit, submitted}
    assert submitted.meta.goal_continuation == true
    assert verdict.action == :continue
    assert updated.continuation_count == 1
    assert updated.last_run_id == "run_loop"

    stored = GoalStore.get(session_key)
    assert stored.meta["goalLoop"]["lastVerdict"]["action"] == "continue"
    assert stored.meta["goalLoop"]["lastVerdict"]["source"] == "test"
    assert stored.meta["goalLoop"]["verdictCount"] == 1
  end

  test "done verdict completes the goal without submitting", %{session_key: session_key} do
    assert {:ok, _goal} = GoalStore.set(session_key, "Finish me")

    assert {:ok, %{run_id: nil, goal: completed, verdict: verdict}} =
             GoalLoop.run_once(session_key, judge_mod: DoneJudge, router_mod: LoopRouterOk)

    assert verdict.action == :done
    assert completed.status == "completed"
    assert completed.continuation_count == 0
    assert completed.meta["goalLoop"]["lastVerdict"]["action"] == "done"
    refute_received {:router_submit, _params}
  end

  test "blocked verdict pauses the goal without submitting", %{session_key: session_key} do
    assert {:ok, _goal} = GoalStore.set(session_key, "Blocked work")

    assert {:ok, %{run_id: nil, goal: paused, verdict: verdict}} =
             GoalLoop.run_once(session_key, judge_mod: BlockedJudge, router_mod: LoopRouterOk)

    assert verdict.action == :blocked
    assert paused.status == "paused"
    assert is_integer(paused.paused_at_ms)
    assert paused.meta["goalLoop"]["lastVerdict"]["action"] == "blocked"
    refute_received {:router_submit, _params}
  end

  test "routes through a configured judge runner with model metadata", %{session_key: session_key} do
    assert {:ok, _goal} =
             GoalStore.set(session_key, "Judge me",
               agent_id: "agent_1",
               meta: %{"testPid" => self()}
             )

    assert {:ok, %{run_id: nil, goal: completed, verdict: verdict}} =
             GoalLoop.run_once(session_key, judge_runner: RunnerJudge, judge_model: "judge-model")

    assert_receive {:runner_judge, "judge-model"}
    assert completed.status == "completed"
    assert verdict.action == :done
    assert verdict.source == "judge:judge-model"
  end

  test "routes through application-configured judge runner and model", %{
    session_key: session_key
  } do
    previous_runner = Application.get_env(:lemon_automation, :goal_judge_runner)
    previous_model = Application.get_env(:lemon_automation, :goal_judge_model)

    on_exit(fn ->
      restore_env(:goal_judge_runner, previous_runner)
      restore_env(:goal_judge_model, previous_model)
    end)

    Application.put_env(:lemon_automation, :goal_judge_runner, RunnerJudge)
    Application.put_env(:lemon_automation, :goal_judge_model, "configured-judge")

    assert {:ok, _goal} =
             GoalStore.set(session_key, "Judge me",
               agent_id: "agent_1",
               meta: %{"testPid" => self()}
             )

    assert {:ok, %{run_id: nil, goal: completed, verdict: verdict}} =
             GoalLoop.run_once(session_key)

    assert_receive {:runner_judge, "configured-judge"}
    assert completed.status == "completed"
    assert verdict.action == :done
    assert verdict.source == "judge:configured-judge"
  end

  test "router judge runner submits a judge run and parses the JSON verdict", %{
    session_key: session_key
  } do
    assert {:ok, _goal} = GoalStore.set(session_key, "Judge via router", agent_id: "agent_1")

    assert {:ok, %{run_id: nil, goal: completed, verdict: verdict}} =
             GoalLoop.run_once(session_key,
               judge_runner: LemonAutomation.GoalJudge.RouterRunner,
               judge_router_mod: JudgeRouterOk,
               judge_waiter_mod: JudgeWaiterDone,
               judge_wait_timeout_ms: 123,
               judge_run_id: "run_judge",
               judge_model: "judge-model"
             )

    assert_receive {:judge_router_submit, submitted}
    assert submitted.origin == :goal_judge
    assert submitted.session_key == "#{session_key}:goal_judge"
    assert submitted.model == "judge-model"
    assert submitted.meta.goal_judge == true
    assert_receive {:judge_wait, "run_judge", 123}
    assert completed.status == "completed"
    assert verdict.action == :done
    assert verdict.reason == "finished by judge"
    assert verdict.source == "judge:judge-model"
  end

  test "router judge runner completes through LemonRouter and RunCompletionWaiter", %{
    session_key: session_key
  } do
    original_runtime = Application.get_env(:lemon_router, :engine_runtime)
    Application.put_env(:lemon_router, :engine_runtime, LiveJudgeRuntime)
    :persistent_term.put({LiveJudgeRuntime, :test_pid}, self())

    on_exit(fn ->
      restore_router_env(:engine_runtime, original_runtime)
      :persistent_term.erase({LiveJudgeRuntime, :test_pid})
    end)

    {:ok, _apps} = Application.ensure_all_started(:lemon_router)

    assert {:ok, _goal} =
             GoalStore.set(session_key, "Judge through the live router path", agent_id: "default")

    assert {:ok, %{run_id: nil, goal: completed, verdict: verdict}} =
             GoalLoop.run_once(session_key,
               judge_runner: LemonAutomation.GoalJudge.RouterRunner,
               judge_run_id: "run_live_judge_#{System.unique_integer([:positive])}",
               judge_wait_timeout_ms: 1_000,
               judge_model: "live-proof-model"
             )

    assert_receive {:live_judge_execution, command}, 1_000
    assert command.meta.goal_judge == true
    assert command.meta.model == "live-proof-model"
    assert command.session_key == "#{session_key}:goal_judge"
    assert completed.status == "completed"
    assert verdict.action == :done
    assert verdict.reason == "live router proof"
    assert verdict.source == "judge:live-proof-model"
  end

  test "judge failure pauses by default and can fail open for one continuation", %{
    session_key: session_key
  } do
    assert {:ok, _goal} = GoalStore.set(session_key, "Fail closed")

    assert {:error, {:judge_failed, :judge_unavailable}} =
             GoalLoop.run_once(session_key, judge_mod: FailingJudge)

    paused = GoalStore.get(session_key)
    assert paused.status == "paused"
    assert paused.meta["goalLoop"]["status"] == "error"

    assert {:ok, _goal} =
             GoalStore.set(session_key, "Fail open",
               agent_id: "agent_1",
               meta: %{"testPid" => self()}
             )

    assert {:ok, %{run_id: "run_fail_open", verdict: verdict}} =
             GoalLoop.run_once(session_key,
               judge_mod: FailingJudge,
               judge_failure_policy: :continue_once,
               router_mod: LoopRouterOk,
               run_id: "run_fail_open",
               meta: %{test_pid: self()}
             )

    assert verdict.action == :continue
    assert verdict.source == "judge_failure_policy"
    assert_receive {:router_submit, _submitted}
  end

  test "continue verdict pauses when the persisted continuation budget is exhausted", %{
    session_key: session_key
  } do
    assert {:ok, _goal} =
             GoalStore.set(session_key, "Budgeted",
               agent_id: "agent_1",
               budget: %{"max_continuations" => 0},
               meta: %{"testPid" => self()}
             )

    assert {:error, :budget_exhausted} =
             GoalLoop.run_once(session_key, judge_mod: ContinueJudge, router_mod: LoopRouterOk)

    goal = GoalStore.get(session_key)
    assert goal.status == "paused"
    assert goal.meta["goalLoop"]["status"] == "limit_reached"
  end

  test "lifecycle blockers are returned before judging", %{session_key: session_key} do
    assert {:error, :not_found} = GoalLoop.run_once(session_key, judge_mod: ContinueJudge)

    assert {:ok, _goal} = GoalStore.set(session_key, "Pause me")
    assert {:ok, _paused} = GoalStore.pause(session_key)
    assert {:error, :paused} = GoalLoop.run_once(session_key, judge_mod: ContinueJudge)

    assert {:ok, _resumed} = GoalStore.resume(session_key)
    assert {:ok, _completed} = GoalStore.complete(session_key)
    assert {:error, :completed} = GoalLoop.run_once(session_key, judge_mod: ContinueJudge)
  end

  test "autonomous loop waits for continuations and stops at the tick limit", %{
    session_key: session_key
  } do
    assert {:ok, _goal} =
             GoalStore.set(session_key, "Keep going autonomously",
               agent_id: "agent_1",
               meta: %{"testPid" => self()}
             )

    assert {:ok, result} =
             GoalLoop.run_autonomous(session_key,
               judge_mod: ContinueJudge,
               router_mod: LoopRouterOk,
               waiter_mod: WaiterOk,
               wait_opts: [test_pid: self()],
               wait_timeout_ms: 42,
               run_id: "run_auto",
               max_ticks: 2,
               meta: %{test_pid: self()}
             )

    assert result.status == :limit_reached
    assert result.tick_count == 2
    assert_receive {:wait_for_run, "run_auto", 42}
    assert_receive {:wait_for_run, "run_auto", 42}
    assert GoalStore.get(session_key).continuation_count == 2
  end

  test "autonomous loop pauses the goal when a continuation times out", %{
    session_key: session_key
  } do
    assert {:ok, _goal} =
             GoalStore.set(session_key, "Timeout",
               agent_id: "agent_1",
               meta: %{"testPid" => self()}
             )

    assert {:error, {:run_timeout, "run_timeout"}} =
             GoalLoop.run_autonomous(session_key,
               judge_mod: ContinueJudge,
               router_mod: LoopRouterOk,
               waiter_mod: WaiterTimeout,
               run_id: "run_timeout",
               max_ticks: 2,
               meta: %{test_pid: self()}
             )

    assert GoalStore.get(session_key).status == "paused"
  end

  test "manager persists opt-in auto loop options when starting a loop", %{
    session_key: session_key
  } do
    register_manager_test_pid()
    assert {:ok, _goal} = GoalStore.set(session_key, "Auto start me")

    manager =
      start_supervised!(
        {GoalLoopManager,
         name: :"goal_loop_manager_test_#{System.unique_integer([:positive])}",
         loop_mod: ManagerLoop,
         scheduler_interval_ms: 0}
      )

    assert {:ok, loop} =
             GenServer.call(manager, {:start_loop, session_key, [auto: true, max_ticks: 2]})

    assert loop.status == "running"
    assert_receive {:manager_run, ^session_key, opts}
    assert opts[:max_ticks] == 2

    auto = GoalStore.get(session_key).meta["goalLoop"]["auto"]
    assert auto["enabled"] == true
    assert auto["options"]["maxTicks"] == 2
  end

  test "manager scheduler starts persisted auto loops and stop disables auto", %{
    session_key: session_key
  } do
    register_manager_test_pid()
    assert {:ok, _goal} = GoalStore.set(session_key, "Scheduled")

    assert {:ok, _goal} =
             GoalStore.configure_loop_auto(session_key, true,
               max_ticks: 1,
               judge_failure_policy: :pause
             )

    manager =
      start_supervised!(
        {GoalLoopManager,
         name: :"goal_loop_manager_test_#{System.unique_integer([:positive])}",
         loop_mod: ManagerLoop,
         scheduler_interval_ms: 10,
         auto_scan_limit: 5}
      )

    assert_receive {:manager_run, ^session_key, opts}, 200
    assert opts[:max_ticks] == 1
    assert opts[:judge_failure_policy] == :pause

    assert {:ok, %{goal: stopped}} = GenServer.call(manager, {:stop_loop, session_key})
    assert stopped.meta["goalLoop"]["auto"]["enabled"] == false
  end

  test "manager scheduler runs persisted auto goal through the router judge path", %{
    session_key: session_key
  } do
    original_runtime = Application.get_env(:lemon_router, :engine_runtime)
    original_runner = Application.get_env(:lemon_automation, :goal_judge_runner)

    Application.put_env(:lemon_router, :engine_runtime, LiveJudgeRuntime)

    Application.put_env(
      :lemon_automation,
      :goal_judge_runner,
      LemonAutomation.GoalJudge.RouterRunner
    )

    :persistent_term.put({LiveJudgeRuntime, :test_pid}, self())

    on_exit(fn ->
      restore_router_env(:engine_runtime, original_runtime)
      restore_env(:goal_judge_runner, original_runner)
      :persistent_term.erase({LiveJudgeRuntime, :test_pid})
    end)

    {:ok, _apps} = Application.ensure_all_started(:lemon_router)

    assert {:ok, _goal} =
             GoalStore.set(session_key, "Auto judge through router", agent_id: "default")

    assert {:ok, _goal} =
             GoalStore.configure_loop_auto(session_key, true,
               max_ticks: 1,
               judge_model: "auto-proof-model"
             )

    _manager =
      start_supervised!(
        {GoalLoopManager,
         name: :"goal_loop_manager_test_#{System.unique_integer([:positive])}",
         scheduler_interval_ms: 10,
         auto_scan_limit: 5}
      )

    assert_receive {:live_judge_execution, command}, 1_000
    assert command.meta.goal_judge == true
    assert command.meta.model == "auto-proof-model"
    assert command.session_key == "#{session_key}:goal_judge"

    assert eventually(fn ->
             goal = GoalStore.get(session_key)

             goal.status == "completed" and
               get_in(goal.meta, ["goalLoop", "status"]) == "finished" and
               get_in(goal.meta, ["goalLoop", "lastVerdict", "action"]) == "done"
           end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:lemon_automation, key)
  defp restore_env(key, value), do: Application.put_env(:lemon_automation, key, value)
  defp restore_router_env(key, nil), do: Application.delete_env(:lemon_router, key)
  defp restore_router_env(key, value), do: Application.put_env(:lemon_router, key, value)

  defp eventually(fun, timeout_ms \\ 1_000) when is_function(fun, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(10)
        do_eventually(fun, deadline)
      end
    end
  end

  defp register_manager_test_pid do
    case Process.whereis(:goal_loop_manager_test) do
      nil -> :ok
      _pid -> Process.unregister(:goal_loop_manager_test)
    end

    Process.register(self(), :goal_loop_manager_test)
  end
end
