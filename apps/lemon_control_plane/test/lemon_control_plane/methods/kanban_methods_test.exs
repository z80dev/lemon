defmodule LemonControlPlane.Methods.KanbanMethodsTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{
    KanbanBoardArchive,
    KanbanBoardCreate,
    KanbanBoardGet,
    KanbanBoardList,
    KanbanDispatcherStart,
    KanbanDispatcherStatus,
    KanbanDispatcherStop,
    KanbanTaskComment,
    KanbanTaskCreate,
    KanbanTaskUpdate
  }

  alias LemonCore.KanbanStore

  @ctx %{conn_id: "kanban-test", auth: %{role: :operator}}

  setup do
    on_exit(fn ->
      KanbanStore.list_boards(limit: 100)
      |> Enum.each(fn board -> KanbanStore.clear_board(board.id) end)
    end)

    :ok
  end

  test "creates, reads, updates, comments, lists, and archives boards" do
    assert {:ok, board} =
             KanbanBoardCreate.handle(
               %{
                 "name" => "Hermes parity",
                 "owner" => "codex",
                 "workspace" => "/tmp/lemon",
                 "columns" => ["todo", "doing", "done"]
               },
               @ctx
             )

    assert board["name"] == "Hermes parity"
    assert board["owner"] == "codex"
    assert board["columns"] == ["todo", "doing", "done"]
    assert board["summary"]["action"] == "kanban.board.create"
    assert board["summary"]["boardIdReturned"] == true
    assert board["summary"]["columnCount"] == 3
    assert board["summary"]["cleanup"]["includesBoardName"] == true

    assert {:ok, task} =
             KanbanTaskCreate.handle(
               %{
                 "boardId" => board["id"],
                 "title" => "Build store",
                 "assignee" => "sonnet",
                 "workerProfile" => "junior",
                 "dependsOn" => ["task-a"]
               },
               @ctx
             )

    assert task["boardId"] == board["id"]
    assert task["status"] == "todo"
    assert task["assignee"] == "sonnet"
    assert task["workerProfile"] == "junior"
    assert task["summary"]["action"] == "kanban.task.create"
    assert task["summary"]["dependencyCount"] == 1
    assert task["summary"]["cleanup"]["includesTaskTitle"] == true

    assert {:ok, updated} =
             KanbanTaskUpdate.handle(
               %{"taskId" => task["id"], "status" => "doing", "runId" => "run_1"},
               @ctx
             )

    assert updated["status"] == "doing"
    assert updated["runId"] == "run_1"
    assert updated["summary"]["action"] == "kanban.task.update"
    assert updated["summary"]["runIdReturned"] == true

    assert {:ok, commented} =
             KanbanTaskComment.handle(
               %{"taskId" => task["id"], "body" => "Needs proof", "author" => "codex"},
               @ctx
             )

    assert length(commented["comments"]) == 1
    assert hd(commented["comments"])["author"] == "codex"
    assert commented["summary"]["action"] == "kanban.task.comment"
    assert commented["summary"]["commentCount"] == 1

    assert {:ok, %{"board" => fetched, "tasks" => tasks, "totalTasks" => 1} = fetched_result} =
             KanbanBoardGet.handle(%{"boardId" => board["id"]}, @ctx)

    assert fetched["id"] == board["id"]
    assert hd(tasks)["id"] == task["id"]
    assert fetched_result["summary"]["action"] == "kanban.board.get"
    assert fetched_result["summary"]["taskCount"] == 1
    assert fetched_result["summary"]["taskStatusCounts"]["doing"] == 1

    assert {:ok, %{"boards" => boards, "total" => total} = list_result} =
             KanbanBoardList.handle(%{"owner" => "codex"}, @ctx)

    assert total >= 1
    assert Enum.any?(boards, &(&1["id"] == board["id"]))
    assert list_result["summary"]["action"] == "kanban.board.list"
    assert list_result["summary"]["boardCount"] == total
    assert list_result["summary"]["filters"]["ownerReturned"] == true

    assert {:ok, archived} = KanbanBoardArchive.handle(%{"boardId" => board["id"]}, @ctx)
    assert archived["status"] == "archived"
    assert archived["summary"]["action"] == "kanban.board.archive"
    assert archived["summary"]["archived"] == true
  end

  test "starts, reads, and stops a board dispatcher" do
    assert {:ok, board} =
             KanbanBoardCreate.handle(
               %{"name" => "Dispatch board", "columns" => ["todo", "doing", "done"]},
               @ctx
             )

    assert {:ok, %{"dispatcher" => dispatcher} = start_result} =
             KanbanDispatcherStart.handle(
               %{
                 "boardId" => board["id"],
                 "intervalMs" => 1_000,
                 "maxConcurrency" => 1,
                 "leaseMs" => 1_000,
                 "workerId" => "worker-a",
                 "workerProfile" => "junior"
               },
               @ctx
             )

    assert dispatcher["boardId"] == board["id"]
    assert dispatcher["status"] == "running"
    assert dispatcher["workerId"] == "worker-a"
    assert start_result["summary"]["action"] == "kanban.dispatcher.start"
    assert start_result["summary"]["dispatcherReturned"] == true
    assert start_result["summary"]["workerIdReturned"] == true

    assert {:ok, %{"running" => true, "dispatcher" => status} = status_result} =
             KanbanDispatcherStatus.handle(%{"boardId" => board["id"]}, @ctx)

    assert status["boardId"] == board["id"]
    assert status["maxConcurrency"] == 1
    assert status_result["summary"]["action"] == "kanban.dispatcher.status"
    assert status_result["summary"]["running"] == true

    assert {:ok, %{"dispatcher" => stopped} = stop_result} =
             KanbanDispatcherStop.handle(%{"boardId" => board["id"]}, @ctx)

    assert stopped["status"] == "stopped"
    assert stop_result["summary"]["action"] == "kanban.dispatcher.stop"
    assert stop_result["summary"]["status"] == "stopped"

    assert {:ok, %{"running" => false, "dispatcher" => nil} = stopped_status} =
             KanbanDispatcherStatus.handle(%{"boardId" => board["id"]}, @ctx)

    assert stopped_status["summary"]["running"] == false
    assert stopped_status["summary"]["dispatcherReturned"] == false
  end

  test "validates required fields" do
    assert {:error, {:invalid_request, "name is required", nil}} =
             KanbanBoardCreate.handle(%{}, @ctx)

    assert {:error, {:invalid_request, "boardId is required", nil}} =
             KanbanBoardGet.handle(%{}, @ctx)

    assert {:error, {:invalid_request, "boardId is required", nil}} =
             KanbanBoardArchive.handle(%{}, @ctx)

    assert {:error, {:invalid_request, "boardId is required", nil}} =
             KanbanTaskCreate.handle(%{"title" => "Task"}, @ctx)

    assert {:error, {:invalid_request, "title is required", nil}} =
             KanbanTaskCreate.handle(%{"boardId" => "board_1"}, @ctx)

    assert {:error, {:invalid_request, "taskId is required", nil}} =
             KanbanTaskUpdate.handle(%{}, @ctx)

    assert {:error, {:invalid_request, "taskId is required", nil}} =
             KanbanTaskComment.handle(%{"body" => "x"}, @ctx)

    assert {:error, {:invalid_request, "body is required", nil}} =
             KanbanTaskComment.handle(%{"taskId" => "task_1"}, @ctx)

    assert {:error, {:invalid_request, "boardId is required", nil}} =
             KanbanDispatcherStart.handle(%{}, @ctx)

    assert {:error, {:invalid_request, "boardId is required", nil}} =
             KanbanDispatcherStatus.handle(%{}, @ctx)

    assert {:error, {:invalid_request, "boardId is required", nil}} =
             KanbanDispatcherStop.handle(%{}, @ctx)
  end

  test "method names and scopes" do
    assert KanbanBoardCreate.name() == "kanban.board.create"
    assert KanbanBoardCreate.scopes() == [:write]
    assert KanbanBoardList.name() == "kanban.board.list"
    assert KanbanBoardList.scopes() == [:read]
    assert KanbanBoardGet.name() == "kanban.board.get"
    assert KanbanBoardGet.scopes() == [:read]
    assert KanbanBoardArchive.name() == "kanban.board.archive"
    assert KanbanBoardArchive.scopes() == [:write]
    assert KanbanTaskCreate.name() == "kanban.task.create"
    assert KanbanTaskCreate.scopes() == [:write]
    assert KanbanTaskUpdate.name() == "kanban.task.update"
    assert KanbanTaskUpdate.scopes() == [:write]
    assert KanbanTaskComment.name() == "kanban.task.comment"
    assert KanbanTaskComment.scopes() == [:write]
    assert KanbanDispatcherStart.name() == "kanban.dispatcher.start"
    assert KanbanDispatcherStart.scopes() == [:write]
    assert KanbanDispatcherStatus.name() == "kanban.dispatcher.status"
    assert KanbanDispatcherStatus.scopes() == [:read]
    assert KanbanDispatcherStop.name() == "kanban.dispatcher.stop"
    assert KanbanDispatcherStop.scopes() == [:write]
  end
end
