defmodule CodingAgent.Tools.TodoUnifiedTest do
  use ExUnit.Case, async: false

  alias LemonAgent.AbortSignal
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent
  alias CodingAgent.{Session, SessionManager}
  alias LemonAgent.Test.Mocks
  alias CodingAgent.Tools.{Todo, TodoStore}

  setup do
    cwd = Path.join(System.tmp_dir!(), "todo-unified-#{System.unique_integer([:positive])}")
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

    session_id = Session.get_state(session_pid).session_manager.header.id

    on_exit(fn ->
      TodoStore.delete(session_id)
      File.rm_rf!(cwd)
    end)

    {:ok, session_pid: session_pid, session_id: session_id}
  end

  describe "tool/2" do
    test "session-bound closure writes and reads a content-only plan", %{session_pid: session_pid} do
      tool = Todo.tool("/tmp", session_pid: session_pid)

      assert %AgentToolResult{details: details} =
               tool.execute.(
                 "write",
                 %{"action" => "write", "todos" => [%{"content" => "Inspect"}]},
                 nil,
                 nil
               )

      assert details.plan.entries == [
               %{content: "Inspect", status: "pending", priority: "medium"}
             ]

      assert %AgentToolResult{details: ^details} =
               tool.execute.("read", %{"action" => "read"}, nil, nil)
    end
  end

  describe "execute/5" do
    test "reads todos when action=read", %{session_pid: session_pid} do
      result = Todo.execute("call_1", %{"action" => "read"}, nil, nil, session_pid)

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text == "[]"
      assert details.todos == []
      assert details.title == "0 todos"
      assert details.plan == %{entries: []}
    end

    test "writes then reads todos", %{session_pid: session_pid} do
      todos = [
        %{"id" => "1", "content" => "Task 1", "status" => "pending", "priority" => "high"},
        %{"id" => "2", "content" => "Task 2", "status" => "completed", "priority" => "low"}
      ]

      write_result =
        Todo.execute("call_1", %{"action" => "write", "todos" => todos}, nil, nil, session_pid)

      assert %AgentToolResult{} = write_result

      read_result = Todo.execute("call_2", %{"action" => "read"}, nil, nil, session_pid)
      assert %AgentToolResult{details: %{todos: read_todos, title: title}} = read_result
      assert read_todos == todos
      assert title == "1 todos"
    end

    test "returns error for invalid action", %{session_pid: session_pid} do
      assert {:error, _reason} =
               Todo.execute("call_1", %{"action" => "delete"}, nil, nil, session_pid)

      assert {:ok, [], _revision} = Session.todos(session_pid)
    end

    test "returns error when action is missing", %{session_pid: session_pid} do
      assert {:error, _reason} = Todo.execute("call_1", %{}, nil, nil, session_pid)
      assert {:ok, [], _revision} = Session.todos(session_pid)
    end

    test "returns progress when action=progress", %{session_pid: session_pid} do
      todos = [
        %{"id" => "1", "content" => "Task 1", "status" => "pending", "priority" => "high"},
        %{"id" => "2", "content" => "Task 2", "status" => "completed", "priority" => "low"}
      ]

      assert %AgentToolResult{} =
               Todo.execute(
                 "seed",
                 %{"action" => "write", "todos" => todos},
                 nil,
                 nil,
                 session_pid
               )

      result = Todo.execute("call_1", %{"action" => "progress"}, nil, nil, session_pid)

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "\"completed\": 1"
      assert text =~ "\"pending\": 1"
      assert details[:title] == "todo progress"
      assert details[:percentage] == 50
      assert details.todos == todos

      assert details.plan.entries == [
               %{content: "Task 1", status: "pending", priority: "high"},
               %{content: "Task 2", status: "completed", priority: "low"}
             ]
    end

    test "returns actionable todos when action=actionable", %{session_pid: session_pid} do
      todos = [
        %{"id" => "1", "content" => "Task 1", "status" => "completed", "priority" => "high"},
        %{
          "id" => "2",
          "content" => "Task 2",
          "status" => "pending",
          "priority" => "high",
          "dependencies" => ["1"]
        },
        %{
          "id" => "3",
          "content" => "Task 3",
          "status" => "pending",
          "priority" => "low",
          "dependencies" => ["missing"]
        }
      ]

      assert %AgentToolResult{} =
               Todo.execute(
                 "seed",
                 %{"action" => "write", "todos" => todos},
                 nil,
                 nil,
                 session_pid
               )

      result = Todo.execute("call_1", %{"action" => "actionable"}, nil, nil, session_pid)

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "Task 2"
      refute text =~ "Task 3"
      assert details.title == "1 actionable todos"
      assert details.todos == todos
      assert Enum.map(details.actionable, & &1["id"]) == ["2"]

      assert details.plan.entries == [
               %{content: "Task 1", status: "completed", priority: "high"},
               %{content: "Task 2", status: "pending", priority: "high"},
               %{content: "Task 3", status: "pending", priority: "low"}
             ]
    end

    test "returns error when write is aborted", %{session_pid: session_pid} do
      signal = AbortSignal.new()
      AbortSignal.abort(signal)

      todos = [%{"id" => "1", "content" => "Task", "status" => "pending", "priority" => "high"}]

      result =
        Todo.execute("call_1", %{"action" => "write", "todos" => todos}, signal, nil, session_pid)

      AbortSignal.clear(signal)
      assert {:error, "Operation aborted"} = result
    end

    test "writes a content-only plan with canonical state and projection", %{
      session_pid: session_pid,
      session_id: session_id
    } do
      tool = Todo.tool("/tmp", session_pid: session_pid)

      params = %{
        "action" => "write",
        "todos" => [%{"content" => "Inspect"}, %{"content" => "Fix"}]
      }

      result = tool.execute.("call_1", params, nil, nil)

      assert %AgentToolResult{details: details} = result
      assert details.todos == TodoStore.get(session_id)
      assert {:ok, todos, _revision} = Session.todos(session_pid)
      assert todos == details.todos
      assert Jason.decode!(hd(result.content).text) == details.todos
      assert Enum.all?(details.todos, &(is_binary(&1["id"]) and &1["id"] != ""))

      assert details.plan == %{
               entries: [
                 %{content: "Inspect", status: "pending", priority: "medium"},
                 %{content: "Fix", status: "pending", priority: "medium"}
               ]
             }

      read = Todo.execute("call_2", %{"action" => "read"}, nil, nil, session_pid)
      assert read.details == details
    end

    test "clearing a plan returns a complete empty snapshot on all views", %{
      session_pid: session_pid
    } do
      Todo.execute(
        "call_1",
        %{"action" => "write", "todos" => [%{"content" => "Task"}]},
        nil,
        nil,
        session_pid
      )

      cleared =
        Todo.execute("call_2", %{"action" => "write", "todos" => []}, nil, nil, session_pid)

      assert cleared.details.todos == []
      assert cleared.details.plan == %{entries: []}

      for action <- ["read", "progress", "actionable"] do
        result = Todo.execute("call_3", %{"action" => action}, nil, nil, session_pid)
        assert result.details.todos == []
        assert result.details.plan == %{entries: []}
      end
    end
  end
end
