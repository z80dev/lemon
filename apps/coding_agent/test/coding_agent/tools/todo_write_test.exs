defmodule CodingAgent.Tools.TodoWriteTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{Session, SessionManager}
  alias CodingAgent.Tools.Todo
  alias LemonAgent.AbortSignal
  alias LemonAgent.Test.Mocks
  alias LemonAgent.Types.AgentToolResult

  setup do
    cwd = Path.join(System.tmp_dir!(), "todo-write-#{System.unique_integer([:positive])}")
    File.mkdir_p!(cwd)
    session_file = Path.join(cwd, "session.jsonl")
    :ok = SessionManager.save_to_file(session_file, SessionManager.new(cwd))

    session_pid =
      start_supervised!(
        {Session,
         cwd: cwd,
         workspace_dir: Path.join(cwd, "workspace"),
         session_file: session_file,
         model: Mocks.mock_model(),
         stream_fn: Mocks.mock_stream_fn_single(Mocks.assistant_message("ok"))}
      )

    on_exit(fn -> File.rm_rf!(cwd) end)
    {:ok, session_pid: session_pid}
  end

  defp write(todos, session, signal \\ nil),
    do: Todo.execute("write", %{"action" => "write", "todos" => todos}, signal, nil, session)

  defp valid_todo(overrides \\ %{}) do
    Map.merge(
      %{"id" => "1", "content" => "Test task", "status" => "pending", "priority" => "high"},
      overrides
    )
  end

  test "omitted id, status and priority get a generated id, pending and medium", %{
    session_pid: session
  } do
    assert %AgentToolResult{details: %{todos: [todo], title: "1 todos"}} =
             write([%{"content" => "Inspect"}], session)

    assert todo["status"] == "pending"
    assert todo["priority"] == "medium"
    assert is_binary(todo["id"]) and todo["id"] != ""
    assert {:ok, [^todo], _revision} = Session.todos(session)
  end

  test "writes replace the whole list and the open count excludes terminal tasks", %{
    session_pid: session
  } do
    write([valid_todo(%{"content" => "Original"})], session)

    todos = [
      valid_todo(%{"id" => "a", "content" => "Done", "status" => "completed"}),
      valid_todo(%{"id" => "b", "content" => "Dropped", "status" => "abandoned"}),
      valid_todo(%{"id" => "c", "content" => "Next"})
    ]

    assert %AgentToolResult{details: %{title: "1 todos"}} = write(todos, session)
    assert {:ok, written, _revision} = Session.todos(session)
    assert Enum.map(written, & &1["id"]) == ["a", "b", "c"]

    assert %AgentToolResult{details: %{todos: []}} = write([], session)
    assert {:ok, [], _revision} = Session.todos(session)
  end

  test "invalid entries reject the whole write without saving a partial list", %{
    session_pid: session
  } do
    invalid = [
      valid_todo(%{"status" => "done"}),
      valid_todo(%{"status" => ""}),
      valid_todo(%{"status" => 42}),
      valid_todo(%{"priority" => "urgent"}),
      valid_todo(%{"priority" => ""}),
      valid_todo(%{"priority" => true}),
      Map.delete(valid_todo(), "content"),
      valid_todo(%{"content" => ""}),
      valid_todo(%{"content" => "   "}),
      valid_todo(%{"content" => 123}),
      valid_todo(%{"id" => ""}),
      valid_todo(%{"id" => "  \t  "}),
      valid_todo(%{"id" => 999}),
      valid_todo(%{"phase" => 1}),
      "not a map"
    ]

    for entry <- invalid do
      assert {:error, _reason} = write([valid_todo(%{"id" => "ok"}), entry], session)
      assert {:ok, [], _revision} = Session.todos(session)
    end

    duplicate = [valid_todo(%{"id" => "dup"}), valid_todo(%{"id" => "dup", "content" => "Two"})]
    assert {:error, "todo ids must be unique"} = write(duplicate, session)
    assert {:error, "Todos must be an array"} = write("not a list", session)
    assert {:ok, [], _revision} = Session.todos(session)
  end

  test "an aborted write stores nothing", %{session_pid: session} do
    signal = AbortSignal.new()
    AbortSignal.abort(signal)

    assert {:error, "Operation aborted"} = write([valid_todo()], session, signal)
    assert {:ok, [], _revision} = Session.todos(session)
    assert %AgentToolResult{} = write([valid_todo()], session, AbortSignal.new())
  end

  test "reads and writes refuse without a session binding" do
    assert {:error, "Session not available"} = write([valid_todo()], nil)

    assert {:error, "Session not available"} =
             Todo.execute("read", %{"action" => "read"}, nil, nil, nil)

    tool = Todo.tool("/tmp")
    assert {:error, _} = tool.execute.("read", %{"action" => "read"}, nil, nil)
  end
end
