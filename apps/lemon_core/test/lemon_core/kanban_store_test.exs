defmodule LemonCore.KanbanStoreTest do
  use ExUnit.Case, async: false

  alias LemonCore.KanbanStore

  setup do
    on_exit(fn ->
      KanbanStore.list_boards(limit: 100)
      |> Enum.each(fn board -> KanbanStore.clear_board(board.id) end)
    end)

    :ok
  end

  test "creates boards, moves tasks, comments, lists, archives, and clears" do
    assert {:ok, board} =
             KanbanStore.create_board("Hermes parity",
               workspace: "/tmp/lemon",
               owner: "codex",
               columns: ["todo", "doing", "blocked", "done"]
             )

    assert board.name == "Hermes parity"
    assert board.status == "active"
    assert board.columns == ["todo", "doing", "blocked", "done"]

    assert KanbanStore.get_board(board.id).id == board.id
    assert Enum.any?(KanbanStore.list_boards(owner: "codex"), &(&1.id == board.id))

    assert {:ok, task} =
             KanbanStore.create_task(board.id, "Build board store",
               description: "private details",
               assignee: "sonnet",
               worker_profile: "junior",
               session_key: "session-private",
               depends_on: ["task-a", "task-a", ""]
             )

    assert task.status == "todo"
    assert task.depends_on == ["task-a"]
    assert KanbanStore.get_task(task.id).id == task.id

    assert {:ok, doing} =
             KanbanStore.update_task(task.id,
               status: "doing",
               priority: "high",
               runId: "run_1"
             )

    assert doing.status == "doing"
    assert doing.priority == "high"
    assert doing.run_id == "run_1"

    assert {:ok, commented} =
             KanbanStore.add_comment(task.id, "Needs live proof", author: "codex")

    assert length(commented.comments) == 1
    assert hd(commented.comments)["body"] == "Needs live proof"

    assert {:ok, done} = KanbanStore.update_task(task.id, %{status: "done"})
    assert done.status == "done"
    assert is_integer(done.completed_at_ms)

    assert [%{id: task_id}] = KanbanStore.list_tasks(board.id, status: "done")
    assert task_id == task.id

    assert {:ok, archived} = KanbanStore.archive_board(board.id)
    assert archived.status == "archived"
    assert is_integer(archived.archived_at_ms)

    assert :ok = KanbanStore.clear_board(board.id)
    assert KanbanStore.get_board(board.id) == %{}
    assert KanbanStore.get_task(task.id) == %{}
  end

  test "diagnostics redacts task contents and raw session ids" do
    assert {:ok, board} = KanbanStore.create_board("Secret board", workspace: "/private/repo")

    assert {:ok, task} =
             KanbanStore.create_task(board.id, "Secret task",
               description: "private description",
               session_key: "session-secret"
             )

    assert {:ok, _task} = KanbanStore.add_comment(task.id, "private comment")

    diagnostics = KanbanStore.diagnostics(limit: 10)

    assert diagnostics.board_count >= 1
    assert diagnostics.task_count >= 1
    assert diagnostics.cleanup.includes_titles == false
    assert diagnostics.cleanup.includes_descriptions == false
    assert diagnostics.cleanup.includes_comments == false
    assert diagnostics.cleanup.includes_raw_session_ids == false

    refute inspect(diagnostics) =~ "Secret task"
    refute inspect(diagnostics) =~ "private description"
    refute inspect(diagnostics) =~ "private comment"
    refute inspect(diagnostics) =~ "session-secret"
  end

  test "validates board and task input" do
    assert {:error, :empty_name} = KanbanStore.create_board("  ")
    assert {:error, :board_not_found} = KanbanStore.create_task("missing", "Task")

    assert {:ok, board} = KanbanStore.create_board("Validation", columns: ["todo", "done"])
    assert {:error, :empty_title} = KanbanStore.create_task(board.id, " ")
    assert {:error, :invalid_status} = KanbanStore.create_task(board.id, "Task", status: "review")
  end

  test "leases dependency-unblocked tasks and reclaims expired leases" do
    assert {:ok, board} =
             KanbanStore.create_board("Leases", columns: ["todo", "doing", "blocked", "done"])

    assert {:ok, dependency} = KanbanStore.create_task(board.id, "Dependency")

    assert {:ok, dependent} =
             KanbanStore.create_task(board.id, "Dependent", depends_on: [dependency.id])

    assert {:ok, leased} = KanbanStore.lease_task(board.id, "worker-a", lease_ms: 1)
    assert leased.id == dependency.id
    assert leased.status == "doing"
    assert leased.meta["kanbanLease"]["workerId"] == "worker-a"

    assert {:error, :no_available_task} = KanbanStore.lease_task(board.id, "worker-b")

    Process.sleep(2)

    assert {:ok, [reclaimed]} = KanbanStore.reclaim_expired_leases(board.id)
    assert reclaimed.id == dependency.id
    assert reclaimed.status == "todo"
    refute Map.has_key?(reclaimed.meta, "kanbanLease")

    assert {:ok, leased_again} = KanbanStore.lease_task(board.id, "worker-b")
    assert leased_again.id == dependency.id

    assert {:ok, completed} = KanbanStore.complete_task(dependency.id, run_id: "run_done")
    assert completed.status == "done"
    assert completed.run_id == "run_done"
    refute Map.has_key?(completed.meta, "kanbanLease")

    assert {:ok, next} = KanbanStore.lease_task(board.id, "worker-c")
    assert next.id == dependent.id

    assert {:ok, failed} =
             KanbanStore.fail_task(dependent.id, "needs human", worker_id: "worker-c")

    assert failed.status == "blocked"
    assert failed.meta["lastFailure"]["reason"] == "needs human"
    refute Map.has_key?(failed.meta, "kanbanLease")
  end
end
