defmodule LemonAutomation.GoalLoopTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.{GoalLoop, GoalLoopManager}
  alias LemonAgent.Workspace.GoalStore

  defmodule LoopRouterOk do
    @moduledoc false

    def submit(params) do
      send(params.meta.test_pid, {:router_submit, params})
      {:ok, params.run_id}
    end
  end

  defmodule AbortableLoopRouter do
    @moduledoc false

    def submit(params) do
      send(:persistent_term.get({__MODULE__, :test_pid}), {:abortable_submit, params, self()})
      {:ok, params.run_id}
    end

    def abort_run(run_id, reason) do
      send(:persistent_term.get({__MODULE__, :test_pid}), {:abortable_abort, run_id, reason})

      case Application.get_env(:lemon_automation, :goal_loop_test_abort_result, :ok) do
        {:raise, message} -> raise message
        result -> result
      end
    end
  end

  defmodule AcceptedWindowLoopRouter do
    @moduledoc false

    def submit(params) do
      test_pid = :persistent_term.get({__MODULE__, :test_pid})
      result = LemonRouter.submit(params)
      send(test_pid, {:accepted_before_submit_return, params, self(), result})

      receive do
        {:return_submit, run_id} when run_id == params.run_id -> result
      after
        5_000 -> {:error, :test_submit_release_timeout}
      end
    end

    def abort_run(run_id, reason) do
      send(
        :persistent_term.get({__MODULE__, :test_pid}),
        {:accepted_window_abort, run_id, reason}
      )

      LemonRouter.abort_run(run_id, reason)
    end
  end

  defmodule AmbiguousLoopRouter do
    @moduledoc false

    def submit(params) do
      send(:persistent_term.get({__MODULE__, :test_pid}), {:ambiguous_loop_submit, params})
      {:error, :outcome_unknown}
    end

    def abort_run(run_id, reason) do
      send(:persistent_term.get({__MODULE__, :test_pid}), {:ambiguous_loop_abort, run_id, reason})
      :persistent_term.get({__MODULE__, :abort_result}, :ok)
    end
  end

  defmodule BlockingGoalRuntime do
    @moduledoc false

    def available?, do: true
    def run_pid(_run_id), do: nil

    def submit_execution(%LemonCore.ExecutionCommand{} = command) do
      send(:persistent_term.get({__MODULE__, :test_pid}), {:blocking_goal_execution, command})
      :ok
    end

    def cancel_by_run_id(run_id, reason) do
      send(:persistent_term.get({__MODULE__, :test_pid}), {:blocking_goal_cancel, run_id, reason})
      :ok
    end
  end

  defmodule BlockingLoopWaiter do
    @moduledoc false

    def wait_already_subscribed(run_id, timeout_ms, _opts) do
      send(
        :persistent_term.get({AbortableLoopRouter, :test_pid}),
        {:blocking_waiter, run_id, timeout_ms, self()}
      )

      receive do
        {:finish_wait, result} -> result
      after
        5_000 -> :timeout
      end
    end
  end

  defmodule SynchronousLoopRouter do
    @moduledoc false

    def submit(params) do
      send(params.meta.test_pid, {:router_submit, params})

      send(
        self(),
        LemonCore.Event.new(:run_completed, %{completed: %{ok: true, answer: "done now"}})
      )

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

    def wait_already_subscribed(run_id, timeout_ms, opts) do
      send(opts[:test_pid], {:wait_for_run, run_id, timeout_ms})
      {:ok, "done"}
    end
  end

  defmodule WaiterTimeout do
    @moduledoc false

    def wait_already_subscribed(_run_id, _timeout_ms, _opts), do: :timeout
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

    def wait_already_subscribed(run_id, timeout_ms, _opts) do
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
            %{run_id: run_id, engine: "lemon"},
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
    :persistent_term.put({AbortableLoopRouter, :test_pid}, self())
    :persistent_term.put({AcceptedWindowLoopRouter, :test_pid}, self())
    :persistent_term.put({AmbiguousLoopRouter, :test_pid}, self())
    :persistent_term.put({AmbiguousLoopRouter, :abort_result}, :ok)
    :persistent_term.put({BlockingGoalRuntime, :test_pid}, self())

    on_exit(fn ->
      GoalStore.clear(session_key)
      :persistent_term.erase({AbortableLoopRouter, :test_pid})
      :persistent_term.erase({AcceptedWindowLoopRouter, :test_pid})
      :persistent_term.erase({AmbiguousLoopRouter, :test_pid})
      :persistent_term.erase({AmbiguousLoopRouter, :abort_result})
      :persistent_term.erase({BlockingGoalRuntime, :test_pid})
    end)

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

  test "autonomous loop observes a continuation completed synchronously during submit", %{
    session_key: session_key
  } do
    assert {:ok, _goal} =
             GoalStore.set(session_key, "Finish synchronously",
               agent_id: "agent_1",
               meta: %{"testPid" => self()}
             )

    assert {:ok, %{status: :limit_reached, tick_count: 1}} =
             GoalLoop.run_autonomous(session_key,
               judge_mod: ContinueJudge,
               router_mod: SynchronousLoopRouter,
               run_id: "run_sync_goal",
               max_ticks: 1,
               wait_timeout_ms: 10,
               meta: %{test_pid: self()}
             )

    assert_receive {:router_submit, %{run_id: "run_sync_goal"}}
    refute_received %LemonCore.Event{type: :run_completed}
  end

  test "autonomous loop pauses the goal when a continuation times out", %{
    session_key: session_key
  } do
    assert {:ok, _goal} =
             GoalStore.set(session_key, "Timeout",
               agent_id: "agent_1",
               meta: %{"testPid" => self()}
             )

    assert {:error, {:completion_outcome_unknown, "run_timeout"}} =
             GoalLoop.run_autonomous(session_key,
               judge_mod: ContinueJudge,
               router_mod: LoopRouterOk,
               waiter_mod: WaiterTimeout,
               run_id: "run_timeout",
               max_ticks: 2,
               meta: %{test_pid: self()}
             )

    assert GoalStore.get(session_key).status == "active"
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

  test "manager hard stop aborts the authoritative run once and prevents another tick", %{
    session_key: session_key
  } do
    assert {:ok, _goal} =
             GoalStore.set(session_key, "Stop after this run",
               agent_id: "agent_1",
               meta: %{"testPid" => self()}
             )

    manager =
      start_supervised!(
        {GoalLoopManager,
         name: :"goal_loop_manager_test_#{System.unique_integer([:positive])}",
         scheduler_interval_ms: 0}
      )

    run_id = "goal_hard_stop_#{System.unique_integer([:positive])}"

    assert {:ok, _loop} =
             GenServer.call(
               manager,
               {:start_loop, session_key,
                [
                  judge_mod: ContinueJudge,
                  router_mod: AbortableLoopRouter,
                  waiter_mod: BlockingLoopWaiter,
                  run_id: run_id,
                  max_ticks: 3,
                  wait_timeout_ms: 60_000,
                  meta: %{test_pid: self()}
                ]}
             )

    assert_receive {:abortable_submit, %{run_id: ^run_id}, loop_pid}, 1_000
    assert_receive {:blocking_waiter, ^run_id, 60_000, ^loop_pid}, 1_000

    assert eventually(fn ->
             state = :sys.get_state(manager)
             get_in(state, [:loops, session_key, :active_run, :id]) == run_id
           end)

    assert {:ok,
            %{
              mode: :hard,
              router_abort: :accepted,
              loop: %{status: "stopped", active_run_id: ^run_id}
            }} =
             GenServer.call(manager, {:stop_loop, session_key, :hard})

    assert_receive {:abortable_abort, ^run_id, :goal_loop_hard_stop}, 1_000
    eventually(fn -> refute Process.alive?(loop_pid) end)

    assert {:error, :not_running} = GenServer.call(manager, {:stop_loop, session_key, :hard})
    refute_receive {:abortable_abort, ^run_id, _reason}, 200
    refute_receive {:abortable_submit, _params, _pid}, 200

    goal = GoalStore.get(session_key)
    assert get_in(goal.meta, ["goalLoop", "status"]) == "stopped"
    assert get_in(goal.meta, ["goalLoop", "lastRunId"]) == run_id
  end

  test "manager reports a mutate-then-raise abort without retrying or exposing callback terms", %{
    session_key: session_key
  } do
    secret = "goal-loop-abort-secret-#{System.unique_integer([:positive])}"
    previous_abort_result = Application.get_env(:lemon_automation, :goal_loop_test_abort_result)

    Application.put_env(
      :lemon_automation,
      :goal_loop_test_abort_result,
      {:raise, secret}
    )

    on_exit(fn ->
      restore_env(:goal_loop_test_abort_result, previous_abort_result)
    end)

    assert {:ok, _goal} =
             GoalStore.set(session_key, "Stop with ambiguous abort",
               agent_id: "agent_1",
               meta: %{"testPid" => self()}
             )

    manager =
      start_supervised!(
        {GoalLoopManager,
         name: :"goal_loop_manager_unknown_abort_#{System.unique_integer([:positive])}",
         scheduler_interval_ms: 0}
      )

    run_id = "goal_unknown_abort_#{System.unique_integer([:positive])}"

    assert {:ok, _loop} =
             GenServer.call(
               manager,
               {:start_loop, session_key,
                [
                  judge_mod: ContinueJudge,
                  router_mod: AbortableLoopRouter,
                  waiter_mod: BlockingLoopWaiter,
                  run_id: run_id,
                  max_ticks: 2,
                  wait_timeout_ms: 60_000,
                  meta: %{test_pid: self()}
                ]}
             )

    assert_receive {:abortable_submit, %{run_id: ^run_id}, _loop_pid}, 1_000
    assert_receive {:blocking_waiter, ^run_id, 60_000, _loop_pid}, 1_000

    assert eventually(fn ->
             get_in(:sys.get_state(manager), [:loops, session_key, :active_run, :id]) == run_id
           end)

    assert {:ok, result} = GenServer.call(manager, {:stop_loop, session_key, :hard})
    assert result.router_abort == :outcome_unknown
    assert result.loop.status == "reconciling"
    refute inspect(result) =~ secret
    assert_receive {:abortable_abort, ^run_id, :goal_loop_hard_stop}, 1_000

    assert {:ok, repeated_stop} = GenServer.call(manager, {:stop_loop, session_key, :hard})
    assert repeated_stop.router_abort == :outcome_unknown
    assert repeated_stop.loop.status == "reconciling"
    refute_receive {:abortable_abort, ^run_id, _reason}, 200
  end

  test "hard stop owns and aborts a run accepted before submit returns", %{
    session_key: session_key
  } do
    original_runtime = Application.get_env(:lemon_router, :engine_runtime)
    Application.put_env(:lemon_router, :engine_runtime, BlockingGoalRuntime)
    {:ok, _apps} = Application.ensure_all_started(:lemon_router)
    on_exit(fn -> restore_router_env(:engine_runtime, original_runtime) end)

    assert {:ok, _goal} =
             GoalStore.set(session_key, "Stop inside the acceptance window",
               agent_id: "default",
               meta: %{"testPid" => self()}
             )

    manager =
      start_supervised!(
        {GoalLoopManager,
         name: :"goal_loop_manager_test_#{System.unique_integer([:positive])}",
         scheduler_interval_ms: 0}
      )

    run_id = "goal_acceptance_window_#{System.unique_integer([:positive])}"
    run_topic = LemonCore.Bus.run_topic(run_id)
    LemonCore.Bus.subscribe(run_topic)
    on_exit(fn -> LemonCore.Bus.unsubscribe(run_topic) end)

    assert {:ok, _loop} =
             GenServer.call(
               manager,
               {:start_loop, session_key,
                [
                  judge_mod: ContinueJudge,
                  router_mod: AcceptedWindowLoopRouter,
                  waiter_mod: BlockingLoopWaiter,
                  run_id: run_id,
                  max_ticks: 3,
                  wait_timeout_ms: 60_000,
                  meta: %{test_pid: self()}
                ]}
             )

    assert_receive {:accepted_before_submit_return, %{run_id: ^run_id}, loop_pid, {:ok, ^run_id}},
                   1_000

    assert_receive {:blocking_goal_execution, %LemonCore.ExecutionCommand{run_id: ^run_id}}, 1_000

    assert get_in(:sys.get_state(manager), [:loops, session_key, :active_run]) == %{
             id: run_id,
             kind: :continuation,
             router_mod: AcceptedWindowLoopRouter,
             phase: :submitting,
             aborted: false
           }

    assert {:ok, %{mode: :hard, loop: %{active_run_id: ^run_id, status: "stopped"}}} =
             GenServer.call(manager, {:stop_loop, session_key, :hard})

    assert_receive {:accepted_window_abort, ^run_id, :goal_loop_hard_stop}, 1_000
    assert_receive {:blocking_goal_cancel, ^run_id, :goal_loop_hard_stop}, 1_000
    eventually(fn -> refute Process.alive?(loop_pid) end)

    assert_receive %LemonCore.Event{
                     type: :run_completed,
                     meta: %{run_id: ^run_id},
                     payload: completion_payload
                   },
                   1_000

    completion = LemonCore.Events.coerce(:run_completed, completion_payload).completed
    assert completion.ok == false
    refute_receive %LemonCore.Event{type: :run_completed, meta: %{run_id: ^run_id}}, 250
    refute LemonRouter.run_active?(run_id)

    refute_receive {:blocking_waiter, ^run_id, _timeout, _pid}, 100
    refute_receive {:accepted_window_abort, ^run_id, _reason}, 100
    assert {:error, :not_running} = GenServer.call(manager, {:stop_loop, session_key, :hard})

    goal = GoalStore.get(session_key)
    assert get_in(goal.meta, ["goalLoop", "status"]) == "stopped"
    assert get_in(goal.meta, ["goalLoop", "lastRunId"]) == run_id
  end

  test "ambiguous submission retains ownership until a hard stop aborts the fixed run", %{
    session_key: session_key
  } do
    assert {:ok, _goal} =
             GoalStore.set(session_key, "Retain uncertain work",
               agent_id: "agent_1",
               meta: %{"testPid" => self()}
             )

    manager =
      start_supervised!(
        {GoalLoopManager,
         name: :"goal_loop_manager_test_#{System.unique_integer([:positive])}",
         scheduler_interval_ms: 0}
      )

    run_id = "goal_ambiguous_#{System.unique_integer([:positive])}"

    assert {:ok, %{status: "running"}} =
             GenServer.call(
               manager,
               {:start_loop, session_key,
                [
                  judge_mod: ContinueJudge,
                  router_mod: AmbiguousLoopRouter,
                  waiter_mod: WaiterTimeout,
                  run_id: run_id,
                  max_ticks: 2,
                  wait_timeout_ms: 10,
                  meta: %{test_pid: self()}
                ]}
             )

    assert_receive {:ambiguous_loop_submit, %{run_id: ^run_id}}, 1_000

    assert eventually(fn ->
             match?(
               {:ok, %{running: true, loop: %{status: "reconciling", active_run_id: ^run_id}}},
               GenServer.call(manager, {:status, session_key})
             )
           end)

    assert {:error, :already_running} =
             GenServer.call(manager, {:start_loop, session_key, [max_ticks: 1]})

    assert {:ok, %{router_abort: :accepted, loop: %{status: "stopped"}}} =
             GenServer.call(manager, {:stop_loop, session_key, :hard})

    assert_receive {:ambiguous_loop_abort, ^run_id, :goal_loop_hard_stop}, 1_000
    refute_receive {:ambiguous_loop_abort, ^run_id, _reason}, 100
    assert get_in(GoalStore.get(session_key).meta, ["goalLoop", "status"]) == "stopped"
  end

  test "an ambiguous hard-stop abort keeps ownership and blocks restart", %{
    session_key: session_key
  } do
    :persistent_term.put({AmbiguousLoopRouter, :abort_result}, {:error, :outcome_unknown})

    assert {:ok, _goal} =
             GoalStore.set(session_key, "Keep uncertain abort ownership",
               meta: %{"testPid" => self()}
             )

    manager =
      start_supervised!(
        {GoalLoopManager,
         name: :"goal_loop_manager_test_#{System.unique_integer([:positive])}",
         scheduler_interval_ms: 0}
      )

    run_id = "goal_abort_ambiguous_#{System.unique_integer([:positive])}"

    assert {:ok, %{status: "running"}} =
             GenServer.call(
               manager,
               {:start_loop, session_key,
                [
                  judge_mod: ContinueJudge,
                  router_mod: AmbiguousLoopRouter,
                  waiter_mod: WaiterTimeout,
                  run_id: run_id,
                  wait_timeout_ms: 10
                ]}
             )

    assert_receive {:ambiguous_loop_submit, %{run_id: ^run_id}}, 1_000

    assert eventually(fn ->
             match?(
               {:ok, %{loop: %{status: "reconciling"}}},
               GenServer.call(manager, {:status, session_key})
             )
           end)

    assert {:ok, %{router_abort: :outcome_unknown, loop: %{status: "reconciling"}}} =
             GenServer.call(manager, {:stop_loop, session_key, :hard})

    assert_receive {:ambiguous_loop_abort, ^run_id, :goal_loop_hard_stop}, 1_000

    assert {:error, :already_running} =
             GenServer.call(manager, {:start_loop, session_key, [max_ticks: 1]})

    assert get_in(GoalStore.get(session_key).meta, ["goalLoop", "status"]) == "reconciling"

    restored_manager =
      start_supervised!(
        {GoalLoopManager,
         name: :"goal_loop_manager_restored_#{System.unique_integer([:positive])}",
         scheduler_interval_ms: 0},
        id: {:restored_goal_loop_manager, session_key}
      )

    assert {:ok, %{running: true, loop: %{status: "reconciling"}}} =
             GenServer.call(restored_manager, {:status, session_key})

    assert {:error, :already_running} =
             GenServer.call(restored_manager, {:start_loop, session_key, [max_ticks: 1]})

    assert {:ok, %{router_abort: :outcome_unknown}} =
             GenServer.call(restored_manager, {:stop_loop, session_key, :hard})

    refute_receive {:ambiguous_loop_abort, ^run_id, _reason}, 100

    :ok =
      LemonCore.RunStore.finalize(run_id, %{
        completed: %{ok: false, error: :aborted},
        session_key: session_key
      })

    assert eventually(fn ->
             match?(
               {:ok, %{running: false}},
               GenServer.call(manager, {:status, session_key})
             )
           end)

    assert get_in(GoalStore.get(session_key).meta, ["goalLoop", "status"]) == "error"
  end

  test "manager restart restores a persisted running claim as reconciliation ownership", %{
    session_key: session_key
  } do
    run_id = "goal_claim_before_crash_#{System.unique_integer([:positive])}"

    assert {:ok, _goal} = GoalStore.set(session_key, "Do not overlap restored work")
    assert {:ok, _goal} = GoalStore.record_loop_status(session_key, :running, run_id: run_id)

    manager =
      start_supervised!(
        {GoalLoopManager,
         name: :"goal_loop_manager_claim_restore_#{System.unique_integer([:positive])}",
         scheduler_interval_ms: 0},
        id: {:goal_claim_restore, session_key}
      )

    assert {:ok,
            %{running: true, loop: %{status: "reconciling", active_run_id: ^run_id}}} =
             GenServer.call(manager, {:status, session_key})

    assert {:error, :already_running} =
             GenServer.call(manager, {:start_loop, session_key, [max_ticks: 1]})
  end

  test "run_once call timeout encloses judge and continuation wait deadlines" do
    assert GoalLoopManager.call_timeout(judge_wait_timeout_ms: 75_000) == 80_000

    assert GoalLoopManager.call_timeout(
             judge_wait_timeout_ms: 75_000,
             wait_timeout_ms: 90_000,
             await_completion: true
           ) == 95_000

    assert GoalLoopManager.call_timeout(call_timeout_ms: 123_000) == 123_000
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
