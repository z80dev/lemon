defmodule LemonAutomation.KanbanDispatcherLiveTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias LemonAutomation.KanbanDispatcher
  alias LemonCore.KanbanStore

  test "provider-backed dispatcher completes concurrent kanban work through real workers" do
    case live_config() do
      {:skip, reason} ->
        IO.puts("[KanbanDispatcherLiveTest] Skipping: #{reason}")
        assert true

      {:ok, model} ->
        workspace = Path.join(System.tmp_dir!(), "lemon-kanban-live-#{unique_id()}")
        File.mkdir_p!(workspace)

        on_exit(fn ->
          File.rm_rf!(workspace)

          KanbanStore.list_boards(limit: 100)
          |> Enum.each(fn board -> KanbanStore.clear_board(board.id) end)
        end)

        {:ok, _apps} = Application.ensure_all_started(:lemon_router)
        {:ok, _apps} = Application.ensure_all_started(:lemon_gateway)

        assert {:ok, board} =
                 KanbanStore.create_board("Live dispatcher #{unique_id()}",
                   workspace: workspace,
                   columns: ["todo", "doing", "done"]
                 )

        tasks =
          for label <- ["A", "B", "C"] do
            assert {:ok, task} =
                     KanbanStore.create_task(board.id, "Live proof task #{label}",
                       description:
                         "Reply with exactly KANBAN_LIVE_#{label}_DONE. Do not edit files or run tools unless required.",
                       assignee: "default"
                     )

            task
          end

        task_supervisor = :"kanban-live-task-supervisor-#{unique_id()}"
        start_supervised!({Task.Supervisor, name: task_supervisor})

        name = :"kanban-live-dispatcher-#{unique_id()}"
        start_supervised!({KanbanDispatcher, name: name, task_supervisor: task_supervisor})

        assert {:ok, _dispatcher} =
                 KanbanDispatcher.start_board(board.id,
                   name: name,
                   interval_ms: 100,
                   max_concurrency: 2,
                   lease_ms: 180_000,
                   worker_id: "live-kanban-dispatcher",
                   worker_opts: [
                     model: model,
                     timeout_ms: 180_000,
                     worktree_mode: :off
                   ]
                 )

        eventually(fn ->
          assert {:ok, %{dispatcher: %{running_count: 2}}} =
                   KanbanDispatcher.status(board.id, name: name)
        end)

        eventually(
          fn ->
            completed = Enum.map(tasks, &KanbanStore.get_task(&1.id))
            assert Enum.all?(completed, &(&1.status == "done"))
            assert Enum.all?(completed, &(is_binary(&1.run_id) and &1.run_id != ""))
            assert Enum.uniq(Enum.map(completed, & &1.run_id)) |> length() == length(completed)
            assert Enum.all?(completed, &(not Map.has_key?(&1.meta, "kanbanLease")))
          end,
          90,
          2_000
        )
    end
  end

  defp live_config do
    cond do
      System.get_env("LEMON_TEST_ALLOW_LIVE_CREDENTIALS") not in [
        "1",
        "true",
        "TRUE",
        "yes",
        "YES"
      ] ->
        {:skip, "set LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1 to run provider-backed kanban proof"}

      blank?(System.get_env("LEMON_KANBAN_LIVE_MODEL")) ->
        {:skip, "set LEMON_KANBAN_LIVE_MODEL to the provider/model for worker runs"}

      true ->
        {:ok, String.trim(System.fetch_env!("LEMON_KANBAN_LIVE_MODEL"))}
    end
  end

  defp eventually(fun, attempts \\ 100, sleep_ms \\ 50)

  defp eventually(fun, attempts, sleep_ms) when attempts > 0 do
    fun.()
  rescue
    error ->
      Process.sleep(sleep_ms)

      if attempts == 1,
        do: reraise(error, __STACKTRACE__),
        else: eventually(fun, attempts - 1, sleep_ms)
  end

  defp unique_id, do: System.unique_integer([:positive])
  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""
end
