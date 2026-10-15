defmodule CodingAgent.Tools.TodoTest do
  use ExUnit.Case, async: false
  alias CodingAgent.{Session, SessionManager}
  alias CodingAgent.Session.Todos
  alias CodingAgent.Tools.{Todo, TodoStore}
  alias LemonAgent.Test.Mocks
  alias LemonAgent.Types.AgentToolResult
  @moduletag :tmp_dir

  setup %{tmp_dir: cwd} do
    path = Path.join(cwd, "session.jsonl")
    :ok = SessionManager.save_to_file(path, SessionManager.new(cwd))

    session =
      start_supervised!(
        {Session,
         cwd: cwd,
         workspace_dir: Path.join(cwd, "workspace"),
         session_file: path,
         model: Mocks.mock_model(),
         stream_fn: Mocks.mock_stream_fn_single(Mocks.assistant_message("ok"))}
      )

    id = Session.get_state(session).session_manager.header.id
    on_exit(fn -> TodoStore.delete(id) end)
    {:ok, session: session, path: path}
  end

  test "all views and journal retain status truth, notes, phases and identity", %{
    session: session,
    path: path
  } do
    todos = [
      %{
        "id" => "b",
        "content" => "Wait for credentials",
        "status" => "blocked",
        "blocker" => "Need access",
        "phase" => "Deploy",
        "priority" => "high"
      },
      %{"id" => "a", "content" => "Old approach", "status" => "abandoned", "priority" => "low"},
      %{"id" => "c", "content" => "Inspect", "status" => "completed", "priority" => "medium"},
      %{"id" => "i1", "content" => "Implement", "status" => "in_progress", "priority" => "high"},
      %{"id" => "i2", "content" => "Review", "status" => "in_progress", "priority" => "medium"},
      %{"id" => "p", "content" => "Document", "status" => "pending", "priority" => "low"}
    ]

    assert %AgentToolResult{details: details} = call(session, "write", todos)
    normalized = List.update_at(todos, 4, &Map.put(&1, "status", "pending"))
    assert details.todos == normalized

    assert hd(details.plan.entries) == %{
             content: "Wait for credentials",
             status: "blocked",
             blocker: "Need access",
             phase: "Deploy",
             priority: "high"
           }

    assert Enum.at(details.plan.entries, 1).status == "abandoned"
    assert call(session, "read").details.todos == normalized
    progress = call(session, "progress").details

    assert %{
             total: 6,
             completed: 1,
             in_progress: 1,
             blocked: 1,
             abandoned: 1,
             pending: 2,
             percentage: 16
           } = progress

    actionable = call(session, "actionable").details
    assert Enum.map(actionable.actionable, & &1["id"]) == ["i1", "i2", "p"]
    assert actionable.blocked == 1
    assert actionable.abandoned == 1
    assert actionable.todos == normalized
    assert {:ok, saved} = SessionManager.load_from_file(path)
    assert {{:ok, ^normalized}, _} = Todos.materialize(saved)
  end

  test "generated IDs and priorities remain stable when a task becomes blocked", %{
    session: session
  } do
    first = call(session, "write", [%{"content" => "Ship", "priority" => "high"}]).details.todos
    id = hd(first)["id"]

    next =
      call(session, "write", [
        %{"content" => "Ship", "priority" => "high", "status" => "blocked", "phase" => "Release"}
      ]).details.todos

    assert hd(next)["id"] == id
    assert hd(next)["priority"] == "high"
    assert hd(next)["status"] == "blocked"
  end

  test "optional fields are strings and invalid writes leave state unchanged", %{session: session} do
    original = call(session, "write", [%{"content" => "Keep"}]).details.todos

    for field <- ["phase", "blocker"] do
      assert {:error, message} = call(session, "write", [%{"content" => "Invalid", field => 42}])
      assert message =~ "#{field} must be a string"
      assert call(session, "read").details.todos == original
    end
  end

  defp call(session, action, todos \\ nil) do
    Todo.execute("todo", %{"action" => action, "todos" => todos}, nil, nil, session)
  end
end
