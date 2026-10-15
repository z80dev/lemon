defmodule LemonWeb.WorkStoreReadsTest do
  use ExUnit.Case, async: false

  alias LemonAgent.Workspace.{GoalStore, KanbanStore}
  alias LemonAutomation.{CronManager, CronStore, GoalLoopManager}
  alias LemonCore.Store

  defmodule BusyBackend do
    @behaviour LemonCore.Store.Backend
    def init(_), do: {:ok, %{}}
    def put(_, _, _, _), do: {:error, :sqlite_busy}
    def put_new(_, _, _, _), do: {:error, :sqlite_busy}
    def get(_, _, _), do: {:error, :sqlite_busy}
    def delete(_, _, _), do: {:error, :sqlite_busy}
    def list(_, _), do: {:error, :sqlite_busy}
  end

  test "workspace history failures do not select the remembered or default workspace" do
    key = "agent:workspace-failure-#{System.unique_integer([:positive])}:main"
    cwd = Path.join(System.tmp_dir!(), "remembered-workspace")
    LemonWeb.SessionCwd.remember(key, cwd)
    on_exit(fn -> Store.delete(:web_session_cwds, key) end)

    with_busy_backend(fn ->
      assert LemonWeb.SessionCwd.recorded(key) == {:error, :unavailable}
      assert LemonWeb.SessionCwd.resolve(key) == {:error, :unavailable}
    end)

    assert LemonWeb.SessionCwd.recorded(key) == {:ok, cwd}
    assert LemonWeb.SessionCwd.resolve(key) == cwd
  end

  test "strict kanban reads preserve backend failure" do
    with_busy_backend(fn ->
      assert {:error, :store_unavailable} = KanbanStore.list_boards(strict: true)
      assert {:error, :store_unavailable} = KanbanStore.list_tasks("board_test", strict: true)
    end)
  end

  test "strict goal reads preserve backend failure" do
    with_busy_backend(fn ->
      assert {:error, :store_unavailable} = GoalStore.list(strict: true)
    end)
  end

  test "strict cron run reads preserve backend failure" do
    with_busy_backend(fn ->
      assert {:error, :store_unavailable} = CronStore.list_runs("cron_test", strict: true)
    end)
  end

  test "cron manager rejects stale job controls inside its serialized callback" do
    job = %{id: "cron_test", enabled: true, prompt: "private old prompt"}
    revision = CronManager.control_revision(job)
    state = %{jobs: %{"cron_test" => %{job | prompt: "private changed prompt"}}}

    assert {:reply, {:error, :stale}, ^state} =
             CronManager.handle_call({:update, job.id, %{enabled: false}, revision}, nil, state)

    assert {:reply, {:error, :stale}, ^state} =
             CronManager.handle_call({:run_now, job.id, revision}, nil, state)

    assert {:reply, {:error, :stale}, ^state} =
             CronManager.handle_call({:remove, job.id, revision}, nil, state)

    assert {:reply, {:error, :not_found}, ^state} =
             CronManager.handle_call({:remove, "cron_missing", revision}, nil, state)
  end

  test "cron manager removes only the exact inspected job revision" do
    {:ok, job} =
      CronManager.add(%{
        name: "web remove guard",
        schedule: "0 0 1 1 *",
        agent_id: "default",
        session_key: "agent:default:main",
        prompt: "private prompt",
        enabled: false
      })

    on_exit(fn -> CronManager.remove(job.id) end)
    old = CronManager.control_revision(job)
    {:ok, updated} = CronManager.update(job.id, %{name: "web remove guard renamed"})

    assert {:error, :stale} = CronManager.remove(job.id, old)
    assert Enum.any?(CronManager.list(), &(&1.id == job.id))
    assert :ok = CronManager.remove(job.id, CronManager.control_revision(updated))
    refute Enum.any?(CronManager.list(), &(&1.id == job.id))
  end

  test "goal manager refuses an old goal revision before start, stop or pause" do
    key = "agent:workguard#{System.unique_integer([:positive])}:main"
    on_exit(fn -> GoalStore.clear(key) end)
    {:ok, _} = GoalStore.set(key, "Original private objective")
    state = %{loops: %{}}

    {:reply, {:ok, %{control_revision: revision}}, ^state} =
      GoalLoopManager.handle_call({:status, key}, nil, state)

    {:ok, _} = GoalStore.set(key, "Changed private objective")

    assert {:reply, {:error, :stale}, ^state} =
             GoalLoopManager.handle_call({:start_loop, key, [max_ticks: 3], revision}, nil, state)

    assert {:reply, {:error, :stale}, ^state} =
             GoalLoopManager.handle_call({:stop_loop, key, :hard, revision}, nil, state)

    assert {:reply, {:error, :stale}, ^state} =
             GoalLoopManager.handle_call({:transition_goal, key, :pause, revision}, nil, state)

    assert GoalStore.get(key).status == "active"
  end

  defp with_busy_backend(fun) do
    original = :sys.get_state(Store)
    :sys.replace_state(Store, &%{&1 | backend: BusyBackend, backend_state: %{}})

    try do
      fun.()
    after
      :sys.replace_state(Store, fn _ -> original end)
    end
  end
end
