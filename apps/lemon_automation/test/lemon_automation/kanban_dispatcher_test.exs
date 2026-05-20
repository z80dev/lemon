defmodule LemonAutomation.KanbanDispatcherTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.{KanbanDispatcher, KanbanRunWorker}
  alias LemonCore.KanbanStore

  defmodule KanbanDispatcherPassingWorker do
    @moduledoc false

    def run(task, _opts) do
      send(:persistent_term.get({__MODULE__, :test_pid}), {:worker_run, task.id})
      {:ok, %{run_id: "run_#{task.id}"}}
    end
  end

  defmodule KanbanDispatcherFailingWorker do
    @moduledoc false

    def run(task, _opts) do
      send(:persistent_term.get({__MODULE__, :test_pid}), {:worker_run, task.id})
      {:error, :failed}
    end
  end

  defmodule KanbanDispatcherBlockingWorker do
    @moduledoc false

    def run(task, _opts) do
      send(:persistent_term.get({__MODULE__, :test_pid}), {:worker_ready, task.id, self()})

      receive do
        {:finish, result} -> result
      after
        5_000 -> {:error, :worker_timeout}
      end
    end
  end

  defmodule KanbanDispatcherCrashingWorker do
    @moduledoc false

    def run(task, _opts) do
      send(:persistent_term.get({__MODULE__, :test_pid}), {:worker_run, task.id})
      exit(:boom)
    end
  end

  defmodule KanbanDispatcherRouterOk do
    @moduledoc false

    def submit(params) do
      send(:persistent_term.get({__MODULE__, :test_pid}), {:router_submit, params})
      {:ok, params.run_id}
    end
  end

  defmodule KanbanDispatcherBlockingWaiter do
    @moduledoc false

    def wait_already_subscribed(run_id, timeout_ms, opts) do
      send(
        :persistent_term.get({__MODULE__, :test_pid}),
        {:waiter_started, self(), run_id, timeout_ms}
      )

      receive do
        {:finish, ^run_id, result} -> result
      after
        Keyword.get(opts, :test_timeout_ms, 5_000) -> :timeout
      end
    end

    def wait(run_id, timeout_ms, opts) do
      wait_already_subscribed(run_id, timeout_ms, opts)
    end
  end

  setup do
    :persistent_term.put({KanbanDispatcherPassingWorker, :test_pid}, self())
    :persistent_term.put({KanbanDispatcherFailingWorker, :test_pid}, self())
    :persistent_term.put({KanbanDispatcherBlockingWorker, :test_pid}, self())
    :persistent_term.put({KanbanDispatcherCrashingWorker, :test_pid}, self())
    :persistent_term.put({KanbanDispatcherRouterOk, :test_pid}, self())
    :persistent_term.put({KanbanDispatcherBlockingWaiter, :test_pid}, self())

    on_exit(fn ->
      :persistent_term.erase({KanbanDispatcherPassingWorker, :test_pid})
      :persistent_term.erase({KanbanDispatcherFailingWorker, :test_pid})
      :persistent_term.erase({KanbanDispatcherBlockingWorker, :test_pid})
      :persistent_term.erase({KanbanDispatcherCrashingWorker, :test_pid})
      :persistent_term.erase({KanbanDispatcherRouterOk, :test_pid})
      :persistent_term.erase({KanbanDispatcherBlockingWaiter, :test_pid})

      KanbanStore.list_boards(limit: 100)
      |> Enum.each(fn board -> KanbanStore.clear_board(board.id) end)
    end)

    :ok
  end

  test "leases and completes available board tasks" do
    assert {:ok, board} = KanbanStore.create_board("Dispatch")
    assert {:ok, task} = KanbanStore.create_task(board.id, "Task")

    name = :"kanban-dispatcher-#{System.unique_integer([:positive])}"
    start_supervised!({KanbanDispatcher, name: name, worker_mod: KanbanDispatcherPassingWorker})

    assert {:ok, dispatcher} =
             KanbanDispatcher.start_board(board.id,
               name: name,
               interval_ms: 10,
               max_concurrency: 1,
               lease_ms: 1_000,
               worker_id: "worker-a"
             )

    assert dispatcher.status == "running"
    assert_receive {:worker_run, task_id}, 250
    assert task_id == task.id

    eventually(fn ->
      completed = KanbanStore.get_task(task.id)
      assert completed.status == "done"
      assert completed.run_id == "run_#{task.id}"
      refute Map.has_key?(completed.meta, "kanbanLease")
    end)

    assert {:ok, %{running: true, dispatcher: status}} =
             KanbanDispatcher.status(board.id, name: name)

    assert status.running_count == 0
  end

  test "marks failed worker results as blocked" do
    assert {:ok, board} =
             KanbanStore.create_board("Failures", columns: ["todo", "doing", "blocked", "done"])

    assert {:ok, task} = KanbanStore.create_task(board.id, "Task")

    name = :"kanban-dispatcher-#{System.unique_integer([:positive])}"
    start_supervised!({KanbanDispatcher, name: name, worker_mod: KanbanDispatcherFailingWorker})

    assert {:ok, _dispatcher} =
             KanbanDispatcher.start_board(board.id,
               name: name,
               interval_ms: 10,
               max_concurrency: 1,
               lease_ms: 1_000
             )

    task_id = task.id
    assert_receive {:worker_run, ^task_id}, 250

    eventually(fn ->
      failed = KanbanStore.get_task(task.id)
      assert failed.status == "blocked"
      assert failed.meta["lastFailure"]["reason"] =~ "failed"
      refute Map.has_key?(failed.meta, "kanbanLease")
    end)
  end

  test "reclaims expired leases during dispatch ticks" do
    assert {:ok, board} = KanbanStore.create_board("Reclaim")
    assert {:ok, task} = KanbanStore.create_task(board.id, "Task")
    assert {:ok, leased} = KanbanStore.lease_task(board.id, "old-worker", lease_ms: 1)
    assert leased.id == task.id

    Process.sleep(2)

    name = :"kanban-dispatcher-#{System.unique_integer([:positive])}"
    start_supervised!({KanbanDispatcher, name: name, worker_mod: KanbanDispatcherPassingWorker})

    assert {:ok, _dispatcher} =
             KanbanDispatcher.start_board(board.id,
               name: name,
               interval_ms: 10,
               max_concurrency: 1,
               lease_ms: 1_000
             )

    task_id = task.id
    assert_receive {:worker_run, ^task_id}, 250

    eventually(fn ->
      assert KanbanStore.get_task(task.id).status == "done"
    end)
  end

  test "runs board tasks up to the configured concurrency and starts more after workers finish" do
    assert {:ok, board} = KanbanStore.create_board("Concurrency")
    assert {:ok, task_a} = KanbanStore.create_task(board.id, "Task A")
    assert {:ok, task_b} = KanbanStore.create_task(board.id, "Task B")
    assert {:ok, task_c} = KanbanStore.create_task(board.id, "Task C")

    task_supervisor = :"kanban-task-supervisor-#{System.unique_integer([:positive])}"
    start_supervised!({Task.Supervisor, name: task_supervisor})

    name = :"kanban-dispatcher-#{System.unique_integer([:positive])}"

    start_supervised!(
      {KanbanDispatcher,
       name: name, worker_mod: KanbanDispatcherBlockingWorker, task_supervisor: task_supervisor}
    )

    assert {:ok, _dispatcher} =
             KanbanDispatcher.start_board(board.id,
               name: name,
               interval_ms: 10,
               max_concurrency: 2,
               lease_ms: 1_000
             )

    started = receive_worker_ready(2)
    started_ids = Enum.map(started, fn {task_id, _pid} -> task_id end)
    all_task_ids = [task_a.id, task_b.id, task_c.id]
    unstarted_ids = all_task_ids -- started_ids

    assert length(Enum.uniq(started_ids)) == 2
    assert Enum.all?(started_ids, &(&1 in all_task_ids))
    assert [unstarted_task_id] = unstarted_ids
    refute_receive {:worker_ready, ^unstarted_task_id, _pid}, 50

    assert {:ok, %{dispatcher: %{running_count: 2}}} =
             KanbanDispatcher.status(board.id, name: name)

    {released_task_id, released_pid} = hd(started)
    send(released_pid, {:finish, {:ok, %{run_id: "run_#{released_task_id}"}}})

    assert_receive {:worker_ready, ^unstarted_task_id, unstarted_pid}, 500

    remaining =
      Enum.reject(started, fn {_task_id, pid} -> pid == released_pid end) ++
        [{unstarted_task_id, unstarted_pid}]

    Enum.each(remaining, fn {task_id, pid} ->
      send(pid, {:finish, {:ok, %{run_id: "run_#{task_id}"}}})
    end)

    eventually(fn ->
      assert KanbanStore.get_task(task_a.id).status == "done"
      assert KanbanStore.get_task(task_b.id).status == "done"
      assert KanbanStore.get_task(task_c.id).status == "done"
    end)
  end

  test "dispatches real kanban run workers with bounded production-shaped concurrency" do
    assert {:ok, board} =
             KanbanStore.create_board("Real workers",
               workspace: "/tmp/lemon-kanban",
               columns: ["todo", "doing", "done"]
             )

    assert {:ok, task_a} = KanbanStore.create_task(board.id, "Task A", assignee: "agent_a")
    assert {:ok, task_b} = KanbanStore.create_task(board.id, "Task B", assignee: "agent_b")
    assert {:ok, task_c} = KanbanStore.create_task(board.id, "Task C", assignee: "agent_c")

    task_supervisor = :"kanban-task-supervisor-#{System.unique_integer([:positive])}"
    start_supervised!({Task.Supervisor, name: task_supervisor})

    name = :"kanban-dispatcher-#{System.unique_integer([:positive])}"

    start_supervised!(
      {KanbanDispatcher,
       name: name, worker_mod: KanbanRunWorker, task_supervisor: task_supervisor}
    )

    assert {:ok, _dispatcher} =
             KanbanDispatcher.start_board(board.id,
               name: name,
               interval_ms: 10,
               max_concurrency: 2,
               lease_ms: 1_000,
               worker_opts: [
                 router_mod: KanbanDispatcherRouterOk,
                 waiter_mod: KanbanDispatcherBlockingWaiter,
                 timeout_ms: 1_000,
                 wait_opts: [test_timeout_ms: 5_000],
                 worktree_mode: :off
               ]
             )

    submitted = receive_router_submits(2)
    submitted_task_ids = Enum.map(submitted, fn params -> params.meta.kanban_task_id end)
    all_task_ids = [task_a.id, task_b.id, task_c.id]
    unstarted_ids = all_task_ids -- submitted_task_ids

    assert length(Enum.uniq(submitted_task_ids)) == 2
    assert Enum.all?(submitted_task_ids, &(&1 in all_task_ids))
    assert [unstarted_task_id] = unstarted_ids
    refute_receive {:router_submit, %{meta: %{kanban_task_id: ^unstarted_task_id}}}, 50

    waiters = receive_waiters_for(submitted)

    Enum.each(submitted, fn params ->
      assert params.origin == :kanban
      assert params.cwd == "/tmp/lemon-kanban"
      assert params.tool_policy == %{blocked_tools: ["kanban"]}
      assert params.meta.kanban_board_id == board.id
      assert params.meta.kanban_dispatcher
    end)

    assert {:ok, %{dispatcher: %{running_count: 2}}} =
             KanbanDispatcher.status(board.id, name: name)

    released = hd(submitted)
    {released_pid, 1_000} = Map.fetch!(waiters, released.run_id)
    send(released_pid, {:finish, released.run_id, {:ok, "done"}})

    assert_receive {:router_submit, %{meta: %{kanban_task_id: ^unstarted_task_id}} = next_params},
                   500

    assert next_params.tool_policy == %{blocked_tools: ["kanban"]}
    assert_receive {:waiter_started, next_pid, next_run_id, 1_000}, 500
    assert next_run_id == next_params.run_id

    remaining =
      submitted
      |> Enum.reject(&(&1.run_id == released.run_id))
      |> Enum.map(fn params ->
        {pid, _timeout_ms} = Map.fetch!(waiters, params.run_id)
        {pid, params.run_id}
      end)
      |> Kernel.++([{next_pid, next_run_id}])

    Enum.each(remaining, fn {pid, run_id} ->
      send(pid, {:finish, run_id, {:ok, "done"}})
    end)

    eventually(fn ->
      assert KanbanStore.get_task(task_a.id).status == "done"
      assert KanbanStore.get_task(task_b.id).status == "done"
      assert KanbanStore.get_task(task_c.id).status == "done"
    end)

    for task <- [task_a, task_b, task_c] do
      completed = KanbanStore.get_task(task.id)
      assert String.starts_with?(completed.run_id, "run_")
      refute Map.has_key?(completed.meta, "kanbanLease")
    end
  end

  test "marks crashed workers as blocked without crashing the dispatcher" do
    assert {:ok, board} =
             KanbanStore.create_board("Crash", columns: ["todo", "doing", "blocked", "done"])

    assert {:ok, task} = KanbanStore.create_task(board.id, "Task")

    task_supervisor = :"kanban-task-supervisor-#{System.unique_integer([:positive])}"
    start_supervised!({Task.Supervisor, name: task_supervisor})

    name = :"kanban-dispatcher-#{System.unique_integer([:positive])}"

    dispatcher_pid =
      start_supervised!(
        {KanbanDispatcher,
         name: name, worker_mod: KanbanDispatcherCrashingWorker, task_supervisor: task_supervisor}
      )

    assert {:ok, _dispatcher} =
             KanbanDispatcher.start_board(board.id,
               name: name,
               interval_ms: 10,
               max_concurrency: 1,
               lease_ms: 1_000
             )

    task_id = task.id
    assert_receive {:worker_run, ^task_id}, 250

    eventually(fn ->
      failed = KanbanStore.get_task(task.id)
      assert failed.status == "blocked"
      assert failed.meta["lastFailure"]["reason"] =~ "boom"
      refute Map.has_key?(failed.meta, "kanbanLease")
    end)

    assert Process.alive?(dispatcher_pid)

    assert {:ok, %{running: true, dispatcher: %{running_count: 0}}} =
             KanbanDispatcher.status(board.id, name: name)
  end

  defp receive_worker_ready(count) do
    Enum.map(1..count, fn _ ->
      receive do
        {:worker_ready, task_id, pid} -> {task_id, pid}
      after
        500 -> flunk("expected #{count} worker starts")
      end
    end)
  end

  defp receive_router_submits(count) do
    Enum.map(1..count, fn _ ->
      receive do
        {:router_submit, params} -> params
      after
        500 -> flunk("expected #{count} router submissions")
      end
    end)
  end

  defp receive_waiters_for(params_list) do
    expected = MapSet.new(Enum.map(params_list, & &1.run_id))

    Enum.reduce(1..MapSet.size(expected), %{}, fn _, acc ->
      receive do
        {:waiter_started, pid, run_id, timeout_ms} ->
          assert MapSet.member?(expected, run_id)
          Map.put(acc, run_id, {pid, timeout_ms})
      after
        500 -> flunk("expected #{MapSet.size(expected)} waiter starts")
      end
    end)
  end

  defp eventually(fun) do
    eventually(fun, 20)
  end

  defp eventually(fun, attempts) when attempts > 0 do
    fun.()
  rescue
    error ->
      Process.sleep(25)
      if attempts == 1, do: reraise(error, __STACKTRACE__), else: eventually(fun, attempts - 1)
  end
end
