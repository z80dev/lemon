defmodule LemonAutomation.TaskAdmissionTest do
  use ExUnit.Case, async: false

  alias LemonAgent.Workspace.{GoalStore, KanbanStore}

  alias LemonAutomation.{
    GoalContinuationManager,
    GoalLoopManager,
    IntervalRunner,
    KanbanDispatcher,
    KanbanGitWorkflow
  }

  @supervisor LemonAutomation.TaskSupervisor

  defmodule Runner do
    def should_run_now?(_opts), do: true
    def run_once(opts), do: send(Keyword.fetch!(opts, :test_pid), :unexpected_runner)
    def run(_task, opts), do: send(Keyword.fetch!(opts, :test_pid), :unexpected_runner)
  end

  test "full supervisor rejects interval, continuation, goal, kanban and command work" do
    assert_rejected_work(:full, :task_capacity_reached)
  end

  test "missing supervisor rejects interval, continuation, goal, kanban and command work" do
    assert_rejected_work(:missing, :task_supervisor_unavailable)
  end

  defp assert_rejected_work(mode, reason) do
    tasks = start_supervised!(LemonCore.TaskSupervisor.child_spec(max_children: 1))

    assert {:ok, blocker} =
             LemonCore.TaskSupervisor.start_child(tasks, fn ->
               receive do
                 :release -> :ok
               end
             end)

    session_key = "task-admission-#{System.unique_integer([:positive])}"
    assert {:ok, _goal} = GoalStore.set(session_key, "Do not start rejected work")
    on_exit(fn -> GoalStore.clear(session_key) end)

    manager = start_supervised!({GoalLoopManager, name: nil, scheduler_interval_ms: 0})
    assert {:ok, board} = KanbanStore.create_board("Rejected task admission")
    assert {:ok, card} = KanbanStore.create_task(board.id, "Do not lease rejected work")
    on_exit(fn -> KanbanStore.clear_board(board.id) end)

    dispatcher =
      start_supervised!(
        {KanbanDispatcher, name: nil, worker_mod: Runner, task_supervisor: @supervisor}
      )

    original = Process.whereis(@supervisor)
    if original, do: Process.unregister(@supervisor)
    if mode == :full, do: Process.register(tasks, @supervisor)

    try do
      interval_state = %{
        runner: Runner,
        opts: [test_pid: self(), active_sessions_fun: fn -> [] end],
        track_idle: false,
        last_busy_at_ms: 0,
        in_flight_ref: nil
      }

      assert {:noreply, ^interval_state} = IntervalRunner.handle_cast(:tick, interval_state)
      continuation_state = %{calls: %{}}

      assert {:reply, {:error, ^reason}, ^continuation_state} =
               GoalContinuationManager.handle_call(
                 {:continue_once, session_key, []},
                 {self(), make_ref()},
                 continuation_state
               )

      assert {:error, :goal_loop_unavailable} =
               GoalLoopManager.start_loop(session_key, name: manager, auto: true)

      goal_state = :sys.get_state(manager)
      assert goal_state.calls == %{}
      assert goal_state.loops == %{}
      assert goal_state.loop_refs == %{}
      assert GoalStore.get(session_key).meta["goalLoop"]["auto"]["enabled"] == false

      assert {:ok, _dispatcher} =
               KanbanDispatcher.start_board(board.id,
                 name: dispatcher,
                 interval_ms: 60_000,
                 worker_opts: [test_pid: self()]
               )

      send(dispatcher, {:dispatch_tick, board.id})
      dispatcher_state = :sys.get_state(dispatcher)
      assert dispatcher_state.refs == %{}
      assert dispatcher_state.boards[board.id].running == %{}
      refute Map.has_key?(KanbanStore.get_task(card.id).meta, "kanbanLease")
      refute_receive :unexpected_runner, 0

      assert {:error, ^reason} =
               KanbanGitWorkflow.command("unused-program", [], task_supervisor: @supervisor)

      assert Task.Supervisor.children(tasks) == [blocker]
      refute_receive :unexpected_runner, 0
    after
      stop_supervised(KanbanDispatcher)
      if mode == :full, do: Process.unregister(@supervisor)
      if original, do: Process.register(original, @supervisor)
    end
  end
end
