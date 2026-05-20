defmodule CodingAgent.Tools.KanbanTest do
  use ExUnit.Case, async: false

  alias AgentCore.Types.AgentToolResult
  alias CodingAgent.Tools.Kanban
  alias LemonCore.KanbanStore

  setup do
    on_exit(fn ->
      KanbanStore.list_boards(limit: 100)
      |> Enum.each(fn board -> KanbanStore.clear_board(board.id) end)
    end)

    :ok
  end

  test "returns the kanban tool definition" do
    tool = Kanban.tool("/tmp/lemon-kanban-tool")

    assert tool.name == "kanban"
    assert "board_create" in tool.parameters["properties"]["action"]["enum"]
    assert "task_comment" in tool.parameters["properties"]["action"]["enum"]
  end

  test "creates and lists boards with current cwd as default workspace" do
    assert %AgentToolResult{details: %{board: board}} =
             Kanban.execute(
               "call",
               %{"action" => "board_create", "name" => "Launch board"},
               nil,
               nil,
               "/tmp/lemon-kanban-tool",
               agent_id: "agent_1"
             )

    assert board.name == "Launch board"
    assert board.workspace == "/tmp/lemon-kanban-tool"
    assert board.owner == "agent_1"

    assert %AgentToolResult{details: %{boards: boards}} =
             Kanban.execute("call", %{"action" => "board_list"}, nil, nil, "/tmp", [])

    assert Enum.any?(boards, &(&1.id == board.id))
  end

  test "creates, updates, gets, and comments on tasks" do
    assert %AgentToolResult{details: %{board: board}} =
             Kanban.execute(
               "call",
               %{
                 "action" => "board_create",
                 "name" => "Task board",
                 "columns" => ["todo", "done"]
               },
               nil,
               nil,
               "/tmp",
               []
             )

    assert %AgentToolResult{details: %{task: task}} =
             Kanban.execute(
               "call",
               %{
                 "action" => "task_create",
                 "board_id" => board.id,
                 "title" => "Implement tool",
                 "description" => "Expose kanban to agents",
                 "assignee" => "agent_1"
               },
               nil,
               nil,
               "/tmp",
               []
             )

    assert task.status == "todo"
    assert task.assignee == "agent_1"

    assert %AgentToolResult{details: %{task: updated}} =
             Kanban.execute(
               "call",
               %{"action" => "task_update", "task_id" => task.id, "status" => "done"},
               nil,
               nil,
               "/tmp",
               []
             )

    assert updated.status == "done"

    assert %AgentToolResult{details: %{task: commented}} =
             Kanban.execute(
               "call",
               %{
                 "action" => "task_comment",
                 "task_id" => task.id,
                 "body" => "Ready",
                 "author" => "me"
               },
               nil,
               nil,
               "/tmp",
               []
             )

    assert [%{"body" => "Ready", "author" => "me"}] = commented.comments

    assert %AgentToolResult{details: %{task: fetched}} =
             Kanban.execute(
               "call",
               %{"action" => "task_get", "task_id" => task.id},
               nil,
               nil,
               "/tmp",
               []
             )

    assert fetched.id == task.id
  end

  test "returns clear errors for missing identifiers" do
    assert {:error, "board_id is required"} =
             Kanban.execute(
               "call",
               %{"action" => "task_list"},
               nil,
               nil,
               "/tmp",
               []
             )

    assert {:error, "unsupported kanban action: \"wat\""} =
             Kanban.execute("call", %{"action" => "wat"}, nil, nil, "/tmp", [])
  end
end
