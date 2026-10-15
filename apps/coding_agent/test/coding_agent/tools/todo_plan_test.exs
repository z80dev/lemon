defmodule CodingAgent.Tools.TodoPlanTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{Session, SessionManager}
  alias CodingAgent.Tools.{Todo, TodoRead, TodoStore, TodoWrite}
  alias LemonAgent.Types.AgentToolResult
  alias LemonAgent.Test.Mocks

  setup do
    {:ok, session_pid: start_session()}
  end

  defp start_session do
    cwd = Path.join(System.tmp_dir!(), "todo-plan-#{System.unique_integer([:positive])}")
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
         stream_fn: Mocks.mock_stream_fn_single(Mocks.assistant_message("ok"))},
        id: session_file
      )

    session_id = Session.get_state(session_pid).session_manager.header.id

    on_exit(fn ->
      TodoStore.delete(session_id)
      File.rm_rf!(cwd)
    end)

    session_pid
  end

  defp write(session_pid, todos) do
    TodoWrite.execute("write", %{"todos" => todos}, nil, nil, session_pid)
  end

  test "nullable optional fields work through constrained provider schemas", %{
    session_pid: session_pid
  } do
    first =
      write(session_pid, [
        %{"content" => "Inspect", "id" => nil},
        %{"content" => "Verify", "id" => nil}
      ])

    assert %AgentToolResult{} = first
    ids = Enum.map(first.details.todos, & &1["id"])
    assert length(Enum.uniq(ids)) == 2
    assert Enum.all?(ids, &is_binary/1)

    for action <- ["read", "progress", "actionable"] do
      assert %AgentToolResult{details: %{todos: todos}} =
               Todo.execute(
                 "getter",
                 %{"action" => action, "todos" => nil},
                 nil,
                 nil,
                 session_pid
               )

      assert Enum.map(todos, & &1["id"]) == ids
    end
  end

  test "getters reject status-update payloads instead of silently ignoring them", %{
    session_pid: session_pid
  } do
    assert %AgentToolResult{} = write(session_pid, [%{"content" => "Verify behavior"}])
    {:ok, original, revision} = Session.todos(session_pid)
    completed = Enum.map(original, &Map.put(&1, "status", "completed"))

    for action <- ["read", "progress", "actionable"] do
      assert {:error, _} =
               Todo.execute(
                 "getter",
                 %{"action" => action, "todos" => completed},
                 nil,
                 nil,
                 session_pid
               )

      assert {:ok, ^original, ^revision} = Session.todos(session_pid)
    end

    assert %AgentToolResult{} =
             Todo.execute(
               "update",
               %{"action" => "write", "todos" => completed},
               nil,
               nil,
               session_pid
             )

    assert %AgentToolResult{details: %{completed: 1}} =
             Todo.execute("counts", %{"action" => "progress"}, nil, nil, session_pid)
  end

  test "same-content updates retain generated ids across reorder and status changes", %{
    session_pid: session_pid
  } do
    first = write(session_pid, [%{"content" => "Inspect"}, %{"content" => "Fix"}])
    [inspect_todo, fix_todo] = first.details.todos

    updated =
      write(session_pid, [
        %{"content" => "Fix", "status" => "in_progress", "priority" => "high"},
        %{"content" => "Inspect", "status" => "completed"}
      ])

    assert Enum.map(updated.details.todos, & &1["id"]) == [fix_todo["id"], inspect_todo["id"]]

    assert updated.details.plan.entries == [
             %{content: "Fix", status: "in_progress", priority: "high"},
             %{content: "Inspect", status: "completed", priority: "medium"}
           ]

    assert {:ok, todos, _revision} = Session.todos(session_pid)
    assert todos == updated.details.todos
  end

  test "omitting an id reuses a previously explicit id", %{session_pid: session_pid} do
    write(session_pid, [%{"id" => "existing", "content" => "Task"}])
    updated = write(session_pid, [%{"content" => "Task", "status" => "completed"}])
    assert hd(updated.details.todos)["id"] == "existing"
  end

  test "explicit ids preserve task identity when content changes", %{session_pid: session_pid} do
    first = write(session_pid, [%{"content" => "Old description"}])
    id = hd(first.details.todos)["id"]
    updated = write(session_pid, [%{"id" => id, "content" => "New description"}])
    assert hd(updated.details.todos)["id"] == id

    assert updated.details.plan.entries == [
             %{content: "New description", status: "pending", priority: "medium"}
           ]
  end

  test "duplicate content receives distinct stable ids", %{session_pid: session_pid} do
    entries = [%{"content" => "Repeat"}, %{"content" => "Repeat"}, %{"content" => "Repeat"}]
    first = write(session_pid, entries)
    ids = Enum.map(first.details.todos, & &1["id"])
    assert length(Enum.uniq(ids)) == 3
    second = write(session_pid, entries)
    assert Enum.map(second.details.todos, & &1["id"]) == ids
  end

  test "explicit ids are reserved regardless of entry order", %{session_pid: session_pid} do
    first = write(session_pid, [%{"content" => "Repeat"}, %{"content" => "Repeat"}])
    [first_id, second_id] = Enum.map(first.details.todos, & &1["id"])

    updated =
      write(session_pid, [
        %{"content" => "Repeat"},
        %{"id" => first_id, "content" => "Renamed"}
      ])

    assert Enum.map(updated.details.todos, & &1["id"]) == [second_id, first_id]
  end

  test "generated ids cannot collide with supplied ids", %{session_pid: session_pid} do
    first = write(session_pid, [%{"content" => "Task"}])
    generated_id = hd(first.details.todos)["id"]
    assert %AgentToolResult{} = write(session_pid, [])

    updated =
      write(session_pid, [
        %{"content" => "Task"},
        %{"id" => generated_id, "content" => "Other task"}
      ])

    ids = Enum.map(updated.details.todos, & &1["id"])
    assert Enum.uniq(ids) == ids
    assert List.last(ids) == generated_id
  end

  test "invalid explicit values and duplicate ids never mutate state", %{
    session_pid: session_pid
  } do
    original = write(session_pid, [%{"content" => "Keep"}]).details.todos
    {:ok, ^original, revision} = Session.todos(session_pid)

    for {field, value} <- [
          {"status", "unknown"},
          {"status", nil},
          {"priority", nil},
          {"id", ""}
        ] do
      assert {:error, _reason} =
               write(session_pid, [Map.put(%{"content" => "Invalid"}, field, value)])

      assert {:ok, ^original, ^revision} = Session.todos(session_pid)
    end

    assert {:error, _reason} =
             write(session_pid, [
               %{"id" => "duplicate", "content" => "One"},
               %{"id" => "duplicate", "content" => "Two"}
             ])

    assert {:ok, ^original, ^revision} = Session.todos(session_pid)
  end

  test "standalone read preserves journaled metadata without adding it to the plan", %{
    session_pid: session_pid
  } do
    todos = [
      %{
        "id" => "done",
        "content" => "Done",
        "status" => "completed",
        "priority" => "high",
        "dependencies" => []
      },
      %{
        "id" => "waiting",
        "content" => "Wait",
        "status" => "pending",
        "priority" => "low",
        "dependencies" => ["missing"]
      }
    ]

    assert %AgentToolResult{} = write(session_pid, todos)
    result = TodoRead.execute("read", %{}, nil, nil, session_pid)
    assert %AgentToolResult{} = result
    assert result.details.todos == todos

    assert result.details.plan.entries == [
             %{content: "Done", status: "completed", priority: "high"},
             %{content: "Wait", status: "pending", priority: "low"}
           ]

    assert Jason.decode!(hd(result.content).text) == todos
  end

  test "plans remain session isolated", %{session_pid: session_pid} do
    other_session = start_session()
    new_session = start_session()
    first = write(session_pid, [%{"content" => "First session"}])
    second = write(other_session, [%{"content" => "Second session"}])

    assert TodoRead.execute("read", %{}, nil, nil, session_pid).details.plan == first.details.plan

    assert TodoRead.execute("read", %{}, nil, nil, other_session).details.plan ==
             second.details.plan

    assert Todo.execute("read", %{"action" => "read"}, nil, nil, new_session).details.plan ==
             %{entries: []}
  end
end
