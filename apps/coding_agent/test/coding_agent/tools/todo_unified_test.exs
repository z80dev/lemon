defmodule CodingAgent.Tools.TodoUnifiedTest do
  # Uses a global ETS table via TodoStore.
  use ExUnit.Case, async: false

  alias AgentCore.AbortSignal
  alias AgentCore.Types.AgentToolResult
  alias Ai.Types.TextContent
  alias CodingAgent.Tools.{Todo, TodoStore}

  setup do
    TodoStore.clear()
    session_id = "todo-unified-#{:erlang.unique_integer([:positive])}"
    {:ok, session_id: session_id}
  end

  describe "tool/2" do
    test "returns unified todo tool definition", %{session_id: session_id} do
      tool = Todo.tool("/tmp", session_id: session_id)

      assert tool.name == "todo"
      assert tool.label == "Manage Todos"
      assert tool.parameters["required"] == ["action"]
      assert Map.has_key?(tool.parameters["properties"], "action")
      assert Map.has_key?(tool.parameters["properties"], "todos")

      assert tool.parameters["properties"]["action"]["enum"] == [
               "read",
               "write",
               "progress",
               "actionable"
             ]

      assert is_function(tool.execute, 4)
    end
  end

  describe "execute/5" do
    test "reads todos when action=read", %{session_id: session_id} do
      result = Todo.execute("call_1", %{"action" => "read"}, nil, nil, session_id)

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text == "[]"
      assert details.todos == []
      assert details.title == "0 todos"
    end

    test "writes then reads todos", %{session_id: session_id} do
      todos = [
        %{"id" => "1", "content" => "Task 1", "status" => "pending", "priority" => "high"},
        %{"id" => "2", "content" => "Task 2", "status" => "completed", "priority" => "low"}
      ]

      write_result =
        Todo.execute("call_1", %{"action" => "write", "todos" => todos}, nil, nil, session_id)

      assert %AgentToolResult{} = write_result

      read_result = Todo.execute("call_2", %{"action" => "read"}, nil, nil, session_id)
      assert %AgentToolResult{details: %{todos: read_todos, title: title}} = read_result
      assert read_todos == todos
      assert title == "1 todos"
    end

    test "returns error for invalid action", %{session_id: session_id} do
      assert {:error, msg} = Todo.execute("call_1", %{"action" => "delete"}, nil, nil, session_id)
      assert msg =~ "action must be one of: read, write, progress, actionable"
    end

    test "returns error when action is missing", %{session_id: session_id} do
      assert {:error, msg} = Todo.execute("call_1", %{}, nil, nil, session_id)
      assert msg =~ "action is required"
    end

    test "returns progress when action=progress", %{session_id: session_id} do
      todos = [
        %{"id" => "1", "content" => "Task 1", "status" => "pending", "priority" => "high"},
        %{"id" => "2", "content" => "Task 2", "status" => "completed", "priority" => "low"}
      ]

      :ok = TodoStore.put(session_id, todos)

      result = Todo.execute("call_1", %{"action" => "progress"}, nil, nil, session_id)

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "\"completed\": 1"
      assert text =~ "\"pending\": 1"
      assert details[:title] == "todo progress"
      assert details[:percentage] == 50
    end

    test "returns actionable todos when action=actionable", %{session_id: session_id} do
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

      :ok = TodoStore.put(session_id, todos)

      result = Todo.execute("call_1", %{"action" => "actionable"}, nil, nil, session_id)

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "Task 2"
      refute text =~ "Task 3"
      assert details.title == "1 actionable todos"
      assert length(details.todos) == 1
    end

    test "returns error when write is aborted", %{session_id: session_id} do
      signal = AbortSignal.new()
      AbortSignal.abort(signal)

      todos = [%{"id" => "1", "content" => "Task", "status" => "pending", "priority" => "high"}]

      result =
        Todo.execute("call_1", %{"action" => "write", "todos" => todos}, signal, nil, session_id)

      AbortSignal.clear(signal)
      assert {:error, "Operation aborted"} = result
    end
  end
end
