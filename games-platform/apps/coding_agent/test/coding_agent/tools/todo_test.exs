defmodule CodingAgent.Tools.TodoTest do
  # Shares a global ETS table with other todo tool tests.
  use ExUnit.Case, async: false

  alias CodingAgent.Tools.{TodoStore, TodoRead, TodoWrite}
  alias AgentCore.Types.AgentToolResult
  alias AgentCore.AbortSignal
  alias Ai.Types.TextContent

  setup do
    # Clear the store before each test
    TodoStore.clear()
    session_id = "test-session-#{:erlang.unique_integer([:positive])}"
    {:ok, session_id: session_id}
  end

  # ============================================================================
  # TodoStore Tests
  # ============================================================================

  describe "TodoStore.get/1" do
    test "returns empty list for non-existent session", %{session_id: session_id} do
      assert TodoStore.get(session_id) == []
    end

    test "returns stored todos", %{session_id: session_id} do
      todos = [%{"id" => "1", "content" => "Task 1", "status" => "pending", "priority" => "high"}]
      TodoStore.put(session_id, todos)

      assert TodoStore.get(session_id) == todos
    end
  end

  describe "TodoStore.put/2" do
    test "stores todos for session", %{session_id: session_id} do
      todos = [%{"id" => "1", "content" => "Task 1", "status" => "pending", "priority" => "high"}]

      assert :ok = TodoStore.put(session_id, todos)
      assert TodoStore.get(session_id) == todos
    end

    test "overwrites existing todos", %{session_id: session_id} do
      old_todos = [%{"id" => "1", "content" => "Old", "status" => "pending", "priority" => "low"}]

      new_todos = [
        %{"id" => "2", "content" => "New", "status" => "completed", "priority" => "high"}
      ]

      TodoStore.put(session_id, old_todos)
      TodoStore.put(session_id, new_todos)

      assert TodoStore.get(session_id) == new_todos
    end
  end

  describe "TodoStore.delete/1" do
    test "removes todos for session", %{session_id: session_id} do
      todos = [%{"id" => "1", "content" => "Task", "status" => "pending", "priority" => "high"}]
      TodoStore.put(session_id, todos)

      assert :ok = TodoStore.delete(session_id)
      assert TodoStore.get(session_id) == []
    end

    test "returns ok for non-existent session", %{session_id: session_id} do
      assert :ok = TodoStore.delete(session_id)
    end
  end

  describe "TodoStore.clear/0" do
    test "removes all todos" do
      TodoStore.put("session1", [
        %{"id" => "1", "content" => "Task", "status" => "pending", "priority" => "high"}
      ])

      TodoStore.put("session2", [
        %{"id" => "2", "content" => "Task", "status" => "pending", "priority" => "high"}
      ])

      assert :ok = TodoStore.clear()
      assert TodoStore.get("session1") == []
      assert TodoStore.get("session2") == []
    end
  end

  # ============================================================================
  # TodoWrite Tool Tests
  # ============================================================================

  describe "TodoWrite.tool/2" do
    test "returns an AgentTool struct with correct properties", %{session_id: session_id} do
      tool = TodoWrite.tool("/tmp", session_id: session_id)

      assert tool.name == "todowrite"
      assert tool.label == "Write Todos"
      assert tool.description =~ "todo"
      assert tool.parameters["type"] == "object"
      assert tool.parameters["required"] == ["todos"]
      assert is_function(tool.execute, 4)
    end
  end

  describe "TodoWrite.execute/5" do
    test "stores todos and returns them", %{session_id: session_id} do
      todos = [
        %{"id" => "1", "content" => "Task 1", "status" => "pending", "priority" => "high"},
        %{"id" => "2", "content" => "Task 2", "status" => "completed", "priority" => "low"}
      ]

      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "Task 1"
      assert text =~ "Task 2"
      assert details.todos == todos
      # One non-completed
      assert details.title == "1 todos"
    end

    test "counts open todos correctly", %{session_id: session_id} do
      todos = [
        %{"id" => "1", "content" => "Task 1", "status" => "pending", "priority" => "high"},
        %{"id" => "2", "content" => "Task 2", "status" => "in_progress", "priority" => "medium"},
        %{"id" => "3", "content" => "Task 3", "status" => "completed", "priority" => "low"}
      ]

      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)

      assert %AgentToolResult{details: details} = result
      # Two non-completed
      assert details.title == "2 todos"
    end

    test "returns error when todos is not an array", %{session_id: session_id} do
      result = TodoWrite.execute("call_1", %{"todos" => "not an array"}, nil, nil, session_id)

      assert {:error, msg} = result
      assert msg =~ "must be an array"
    end

    test "returns error when todo entry is not an object", %{session_id: session_id} do
      todos = ["bad entry"]

      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)

      assert {:error, msg} = result
      assert msg =~ "Todo 1"
      assert msg =~ "object"
    end

    test "returns error when todo content is empty", %{session_id: session_id} do
      todos = [%{"id" => "1", "content" => "   ", "status" => "pending", "priority" => "high"}]

      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)

      assert {:error, msg} = result
      assert msg =~ "content must be a non-empty string"
    end

    test "returns error when todo status is invalid", %{session_id: session_id} do
      todos = [%{"id" => "1", "content" => "Task", "status" => "blocked", "priority" => "high"}]

      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)

      assert {:error, msg} = result
      assert msg =~ "status must be pending"
    end

    test "returns error when todo priority is invalid", %{session_id: session_id} do
      todos = [%{"id" => "1", "content" => "Task", "status" => "pending", "priority" => "urgent"}]

      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)

      assert {:error, msg} = result
      assert msg =~ "priority must be high"
    end

    test "returns error when todo ids are duplicated", %{session_id: session_id} do
      todos = [
        %{"id" => "1", "content" => "Task 1", "status" => "pending", "priority" => "high"},
        %{"id" => "1", "content" => "Task 2", "status" => "completed", "priority" => "low"}
      ]

      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)

      assert {:error, msg} = result
      assert msg =~ "todo ids must be unique"
    end

    test "returns error when session_id is empty" do
      todos = [%{"id" => "1", "content" => "Task", "status" => "pending", "priority" => "high"}]

      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, "")

      assert {:error, msg} = result
      assert msg =~ "Session id not available"
    end

    test "returns error when aborted", %{session_id: session_id} do
      signal = AbortSignal.new()
      AbortSignal.abort(signal)

      todos = [%{"id" => "1", "content" => "Task", "status" => "pending", "priority" => "high"}]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, signal, nil, session_id)

      AbortSignal.clear(signal)

      assert {:error, "Operation aborted"} = result
    end
  end

  # ============================================================================
  # TodoRead Tool Tests
  # ============================================================================

  describe "TodoRead.tool/2" do
    test "returns an AgentTool struct with correct properties", %{session_id: session_id} do
      tool = TodoRead.tool("/tmp", session_id: session_id)

      assert tool.name == "todoread"
      assert tool.label == "Read Todos"
      assert tool.description =~ "todo"
      assert tool.parameters["type"] == "object"
      assert tool.parameters["required"] == []
      assert is_function(tool.execute, 4)
    end
  end

  describe "TodoRead.execute/5" do
    test "returns empty list when no todos exist", %{session_id: session_id} do
      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text == "[]"
      assert details.todos == []
      assert details.title == "0 todos"
    end

    test "returns stored todos", %{session_id: session_id} do
      todos = [
        %{"id" => "1", "content" => "Task 1", "status" => "pending", "priority" => "high"},
        %{"id" => "2", "content" => "Task 2", "status" => "completed", "priority" => "low"}
      ]

      TodoStore.put(session_id, todos)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "Task 1"
      assert text =~ "Task 2"
      assert details.todos == todos
      assert details.title == "1 todos"
    end

    test "returns error when session_id is empty" do
      result = TodoRead.execute("call_1", %{}, nil, nil, "")

      assert {:error, msg} = result
      assert msg =~ "Session id not available"
    end

    test "returns error when aborted", %{session_id: session_id} do
      signal = AbortSignal.new()
      AbortSignal.abort(signal)

      result = TodoRead.execute("call_1", %{}, signal, nil, session_id)

      AbortSignal.clear(signal)

      assert {:error, "Operation aborted"} = result
    end
  end

  # ============================================================================
  # Integration Tests
  # ============================================================================

  describe "TodoRead/TodoWrite integration" do
    test "write then read returns same todos", %{session_id: session_id} do
      todos = [
        %{"id" => "1", "content" => "Task 1", "status" => "pending", "priority" => "high"}
      ]

      TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      read_result = TodoRead.execute("call_2", %{}, nil, nil, session_id)

      assert %AgentToolResult{details: %{todos: read_todos}} = read_result
      assert read_todos == todos
    end

    test "updates replace previous todos", %{session_id: session_id} do
      todos1 = [%{"id" => "1", "content" => "First", "status" => "pending", "priority" => "high"}]
      todos2 = [%{"id" => "2", "content" => "Second", "status" => "pending", "priority" => "low"}]

      TodoWrite.execute("call_1", %{"todos" => todos1}, nil, nil, session_id)
      TodoWrite.execute("call_2", %{"todos" => todos2}, nil, nil, session_id)

      read_result = TodoRead.execute("call_3", %{}, nil, nil, session_id)

      assert %AgentToolResult{details: %{todos: read_todos}} = read_result
      assert read_todos == todos2
    end
  end
end
