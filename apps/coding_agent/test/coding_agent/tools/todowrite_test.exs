defmodule CodingAgent.Tools.TodoWriteTest do
  @moduledoc """
  Comprehensive tests for the TodoWrite tool.

  This module tests the TodoWrite tool which validates and stores todo lists
  for the current session in ETS-based storage.
  """

  # Uses a global ETS table; tests call TodoStore.clear/0, so cannot be async.
  use ExUnit.Case, async: false

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias AgentCore.AbortSignal
  alias Ai.Types.TextContent
  alias CodingAgent.Tools.{TodoWrite, TodoStore}

  setup do
    # Clear the store before each test to ensure isolation
    TodoStore.clear()
    session_id = "test-session-#{:erlang.unique_integer([:positive])}"
    {:ok, session_id: session_id}
  end

  # ============================================================================
  # Tool Definition Tests
  # ============================================================================

  describe "tool/2" do
    test "returns a proper AgentTool struct" do
      tool = TodoWrite.tool("/tmp")

      assert %AgentTool{} = tool
      assert tool.name == "todowrite"
      assert tool.label == "Write Todos"
      assert tool.description =~ "Write"
      assert tool.description =~ "todo"
    end

    test "has correct parameter schema" do
      tool = TodoWrite.tool("/tmp")

      assert tool.parameters["type"] == "object"
      assert tool.parameters["required"] == ["todos"]

      # Verify todos property schema
      todos_schema = tool.parameters["properties"]["todos"]
      assert todos_schema["type"] == "array"
      assert todos_schema["description"] =~ "todo list"

      # Verify todo item schema
      item_schema = todos_schema["items"]
      assert item_schema["type"] == "object"
      assert item_schema["required"] == ["content", "status", "priority", "id"]

      # Verify all required fields are defined
      properties = item_schema["properties"]
      assert Map.has_key?(properties, "id")
      assert Map.has_key?(properties, "content")
      assert Map.has_key?(properties, "status")
      assert Map.has_key?(properties, "priority")
    end

    test "execute function is a 4-arity function" do
      tool = TodoWrite.tool("/tmp")
      assert is_function(tool.execute, 4)
    end

    test "accepts session_id option" do
      tool = TodoWrite.tool("/tmp", session_id: "my-session")
      assert tool.name == "todowrite"
    end

    test "works with empty options list" do
      tool = TodoWrite.tool("/tmp", [])
      assert tool.name == "todowrite"
    end

    test "ignores cwd parameter (first argument)" do
      tool1 = TodoWrite.tool("/tmp")
      tool2 = TodoWrite.tool("/var/log")

      # Both should work identically - cwd is not used
      assert tool1.name == tool2.name
      assert tool1.description == tool2.description
      assert tool1.parameters == tool2.parameters
    end

    test "tool execute function can be invoked via closure" do
      tool = TodoWrite.tool("/tmp", session_id: "test-session")

      todos = [
        %{"id" => "1", "content" => "Test", "status" => "pending", "priority" => "high"}
      ]

      result = tool.execute.("call_1", %{"todos" => todos}, nil, nil)
      assert %AgentToolResult{} = result
    end
  end

  # ============================================================================
  # Valid Todo Validation Tests
  # ============================================================================

  describe "execute/5 - valid todos" do
    test "stores a single valid todo", %{session_id: session_id} do
      todos = [
        %{"id" => "1", "content" => "Test todo", "status" => "pending", "priority" => "high"}
      ]

      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)

      assert %AgentToolResult{} = result
      assert [%TextContent{text: text}] = result.content
      assert text =~ "Test todo"
      assert result.details.title == "1 todos"
      assert result.details.todos == todos
    end

    test "stores multiple valid todos", %{session_id: session_id} do
      todos = [
        %{"id" => "1", "content" => "First task", "status" => "pending", "priority" => "high"},
        %{"id" => "2", "content" => "Second task", "status" => "in_progress", "priority" => "medium"},
        %{"id" => "3", "content" => "Third task", "status" => "completed", "priority" => "low"}
      ]

      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)

      assert %AgentToolResult{} = result
      assert result.details.title == "2 todos"
      assert length(result.details.todos) == 3
    end

    test "stores todos with all valid status values", %{session_id: session_id} do
      valid_statuses = ["pending", "in_progress", "completed"]

      for status <- valid_statuses do
        todos = [
          %{"id" => "1", "content" => "Task with #{status}", "status" => status, "priority" => "high"}
        ]

        result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)

        assert %AgentToolResult{} = result,
               "Expected success for status: #{status}, got: #{inspect(result)}"

        # Clean up for next iteration
        TodoStore.delete(session_id)
      end
    end

    test "stores todos with all valid priority values", %{session_id: session_id} do
      valid_priorities = ["high", "medium", "low"]

      for priority <- valid_priorities do
        todos = [
          %{"id" => "1", "content" => "Task with #{priority}", "status" => "pending", "priority" => priority}
        ]

        result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)

        assert %AgentToolResult{} = result,
               "Expected success for priority: #{priority}, got: #{inspect(result)}"

        # Clean up for next iteration
        TodoStore.delete(session_id)
      end
    end

    test "stores todos with extra fields", %{session_id: session_id} do
      todos = [
        %{
          "id" => "1",
          "content" => "Task with metadata",
          "status" => "pending",
          "priority" => "high",
          "notes" => "Additional notes",
          "due_date" => "2024-12-31",
          "tags" => ["urgent", "review"]
        }
      ]

      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)

      assert %AgentToolResult{} = result
      stored = TodoStore.get(session_id)
      assert hd(stored)["notes"] == "Additional notes"
      assert hd(stored)["tags"] == ["urgent", "review"]
    end

    test "stores empty todo list", %{session_id: session_id} do
      result = TodoWrite.execute("call_1", %{"todos" => []}, nil, nil, session_id)

      assert %AgentToolResult{} = result
      assert result.details.title == "0 todos"
      assert result.details.todos == []
    end
  end

  # ============================================================================
  # Invalid Todo Validation Tests
  # ============================================================================

  describe "execute/5 - invalid todos" do
    test "returns error when todos is not an array", %{session_id: session_id} do
      result = TodoWrite.execute("call_1", %{"todos" => "not an array"}, nil, nil, session_id)
      assert {:error, "Todos must be an array"} = result

      result = TodoWrite.execute("call_1", %{"todos" => 123}, nil, nil, session_id)
      assert {:error, "Todos must be an array"} = result

      result = TodoWrite.execute("call_1", %{"todos" => %{"key" => "value"}}, nil, nil, session_id)
      assert {:error, "Todos must be an array"} = result
    end

    test "returns error when todo entry is not an object", %{session_id: session_id} do
      todos = ["not a map"]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert {:error, "Todo 1 must be an object"} = result

      todos = [123]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert {:error, "Todo 1 must be an object"} = result

      todos = [nil]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert {:error, "Todo 1 must be an object"} = result
    end

    test "returns error when todo is missing id field", %{session_id: session_id} do
      todos = [%{"content" => "Test", "status" => "pending", "priority" => "high"}]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert {:error, "Todo 1 id must be a non-empty string"} = result
    end

    test "returns error when todo id is empty", %{session_id: session_id} do
      todos = [%{"id" => "", "content" => "Test", "status" => "pending", "priority" => "high"}]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert {:error, "Todo 1 id must be a non-empty string"} = result
    end

    test "returns error when todo id is whitespace only", %{session_id: session_id} do
      todos = [%{"id" => "   ", "content" => "Test", "status" => "pending", "priority" => "high"}]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert {:error, "Todo 1 id must be a non-empty string"} = result
    end

    test "returns error when todo id is not a string", %{session_id: session_id} do
      todos = [%{"id" => 123, "content" => "Test", "status" => "pending", "priority" => "high"}]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert {:error, "Todo 1 id must be a non-empty string"} = result
    end

    test "returns error when todo is missing content field", %{session_id: session_id} do
      todos = [%{"id" => "1", "status" => "pending", "priority" => "high"}]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert {:error, "Todo 1 content must be a non-empty string"} = result
    end

    test "returns error when todo content is empty", %{session_id: session_id} do
      todos = [%{"id" => "1", "content" => "", "status" => "pending", "priority" => "high"}]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert {:error, "Todo 1 content must be a non-empty string"} = result
    end

    test "returns error when todo content is whitespace only", %{session_id: session_id} do
      todos = [%{"id" => "1", "content" => "   ", "status" => "pending", "priority" => "high"}]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert {:error, "Todo 1 content must be a non-empty string"} = result
    end

    test "returns error when todo content is not a string", %{session_id: session_id} do
      todos = [%{"id" => "1", "content" => 123, "status" => "pending", "priority" => "high"}]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert {:error, "Todo 1 content must be a non-empty string"} = result
    end

    test "returns error when todo is missing status field", %{session_id: session_id} do
      todos = [%{"id" => "1", "content" => "Test", "priority" => "high"}]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert {:error, "Todo 1 status must be pending, in_progress, or completed"} = result
    end

    test "returns error when todo status is not a string", %{session_id: session_id} do
      todos = [%{"id" => "1", "content" => "Test", "status" => 123, "priority" => "high"}]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert {:error, "Todo 1 status must be pending, in_progress, or completed"} = result
    end

    test "returns error when todo is missing priority field", %{session_id: session_id} do
      todos = [%{"id" => "1", "content" => "Test", "status" => "pending"}]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert {:error, "Todo 1 priority must be high, medium, or low"} = result
    end

    test "returns error when todo priority is not a string", %{session_id: session_id} do
      todos = [%{"id" => "1", "content" => "Test", "status" => "pending", "priority" => 123}]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert {:error, "Todo 1 priority must be high, medium, or low"} = result
    end

    test "reports first invalid todo when multiple are invalid", %{session_id: session_id} do
      todos = [
        %{"id" => "1", "content" => "Valid", "status" => "pending", "priority" => "high"},
        %{"id" => "", "content" => "Invalid - empty id", "status" => "pending", "priority" => "high"},
        %{"id" => "3", "content" => "", "status" => "pending", "priority" => "high"}
      ]

      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert {:error, "Todo 2 id must be a non-empty string"} = result
    end
  end

  # ============================================================================
  # Status Value Validation Tests
  # ============================================================================

  describe "execute/5 - status validation" do
    test "accepts 'pending' as valid status", %{session_id: session_id} do
      todos = [%{"id" => "1", "content" => "Test", "status" => "pending", "priority" => "high"}]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert %AgentToolResult{} = result
    end

    test "accepts 'in_progress' as valid status", %{session_id: session_id} do
      todos = [%{"id" => "1", "content" => "Test", "status" => "in_progress", "priority" => "high"}]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert %AgentToolResult{} = result
    end

    test "accepts 'completed' as valid status", %{session_id: session_id} do
      todos = [%{"id" => "1", "content" => "Test", "status" => "completed", "priority" => "high"}]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert %AgentToolResult{} = result
    end

    test "rejects invalid status values", %{session_id: session_id} do
      invalid_statuses = ["done", "blocked", "waiting", "started", "", "PENDING", "Pending"]

      for status <- invalid_statuses do
        todos = [%{"id" => "1", "content" => "Test", "status" => status, "priority" => "high"}]
        result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)

        assert {:error, "Todo 1 status must be pending, in_progress, or completed"} = result,
               "Expected error for status: #{inspect(status)}, got: #{inspect(result)}"
      end
    end
  end

  # ============================================================================
  # Priority Value Validation Tests
  # ============================================================================

  describe "execute/5 - priority validation" do
    test "accepts 'high' as valid priority", %{session_id: session_id} do
      todos = [%{"id" => "1", "content" => "Test", "status" => "pending", "priority" => "high"}]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert %AgentToolResult{} = result
    end

    test "accepts 'medium' as valid priority", %{session_id: session_id} do
      todos = [%{"id" => "1", "content" => "Test", "status" => "pending", "priority" => "medium"}]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert %AgentToolResult{} = result
    end

    test "accepts 'low' as valid priority", %{session_id: session_id} do
      todos = [%{"id" => "1", "content" => "Test", "status" => "pending", "priority" => "low"}]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert %AgentToolResult{} = result
    end

    test "rejects invalid priority values", %{session_id: session_id} do
      invalid_priorities = ["urgent", "critical", "normal", "", "HIGH", "High", "1", "0"]

      for priority <- invalid_priorities do
        todos = [%{"id" => "1", "content" => "Test", "status" => "pending", "priority" => priority}]
        result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)

        assert {:error, "Todo 1 priority must be high, medium, or low"} = result,
               "Expected error for priority: #{inspect(priority)}, got: #{inspect(result)}"
      end
    end
  end

  # ============================================================================
  # Unique ID Validation Tests
  # ============================================================================

  describe "execute/5 - unique id validation" do
    test "accepts todos with unique ids", %{session_id: session_id} do
      todos = [
        %{"id" => "1", "content" => "First", "status" => "pending", "priority" => "high"},
        %{"id" => "2", "content" => "Second", "status" => "pending", "priority" => "medium"},
        %{"id" => "3", "content" => "Third", "status" => "pending", "priority" => "low"}
      ]

      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert %AgentToolResult{} = result
    end

    test "rejects todos with duplicate ids", %{session_id: session_id} do
      todos = [
        %{"id" => "1", "content" => "First", "status" => "pending", "priority" => "high"},
        %{"id" => "1", "content" => "Duplicate", "status" => "pending", "priority" => "medium"}
      ]

      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert {:error, "todo ids must be unique"} = result
    end

    test "rejects todos with multiple duplicate ids", %{session_id: session_id} do
      todos = [
        %{"id" => "1", "content" => "First", "status" => "pending", "priority" => "high"},
        %{"id" => "2", "content" => "Second", "status" => "pending", "priority" => "medium"},
        %{"id" => "1", "content" => "Duplicate of first", "status" => "pending", "priority" => "low"},
        %{"id" => "2", "content" => "Duplicate of second", "status" => "pending", "priority" => "high"}
      ]

      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert {:error, "todo ids must be unique"} = result
    end

    test "rejects todos with all same ids", %{session_id: session_id} do
      todos = [
        %{"id" => "same", "content" => "First", "status" => "pending", "priority" => "high"},
        %{"id" => "same", "content" => "Second", "status" => "in_progress", "priority" => "medium"},
        %{"id" => "same", "content" => "Third", "status" => "completed", "priority" => "low"}
      ]

      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert {:error, "todo ids must be unique"} = result
    end
  end

  # ============================================================================
  # Abort Signal Handling Tests
  # ============================================================================

  describe "execute/5 - abort signal handling" do
    test "returns error when signal is already aborted", %{session_id: session_id} do
      signal = AbortSignal.new()
      AbortSignal.abort(signal)

      todos = [%{"id" => "1", "content" => "Test", "status" => "pending", "priority" => "high"}]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, signal, nil, session_id)

      AbortSignal.clear(signal)

      assert {:error, "Operation aborted"} = result
    end

    test "proceeds normally when signal is not aborted", %{session_id: session_id} do
      signal = AbortSignal.new()

      todos = [%{"id" => "1", "content" => "Test", "status" => "pending", "priority" => "high"}]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, signal, nil, session_id)

      AbortSignal.clear(signal)

      assert %AgentToolResult{} = result
    end

    test "proceeds normally when signal is nil", %{session_id: session_id} do
      todos = [%{"id" => "1", "content" => "Test", "status" => "pending", "priority" => "high"}]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)

      assert %AgentToolResult{} = result
    end

    test "abort check happens before validation", %{session_id: session_id} do
      signal = AbortSignal.new()
      AbortSignal.abort(signal)

      # Even with invalid todos, abort takes priority
      todos = [%{"id" => "", "content" => "", "status" => "invalid", "priority" => "invalid"}]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, signal, nil, session_id)

      AbortSignal.clear(signal)

      assert {:error, "Operation aborted"} = result
    end

    test "abort check happens before session validation" do
      signal = AbortSignal.new()
      AbortSignal.abort(signal)

      # Even with empty session (which would normally error), abort takes priority
      todos = [%{"id" => "1", "content" => "Test", "status" => "pending", "priority" => "high"}]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, signal, nil, "")

      AbortSignal.clear(signal)

      assert {:error, "Operation aborted"} = result
    end
  end

  # ============================================================================
  # Session ID Validation Tests
  # ============================================================================

  describe "execute/5 - session id validation" do
    test "returns error when session_id is empty string" do
      todos = [%{"id" => "1", "content" => "Test", "status" => "pending", "priority" => "high"}]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, "")
      assert {:error, "Session id not available"} = result
    end

    test "works with various session id formats", %{session_id: _session_id} do
      todos = [%{"id" => "1", "content" => "Test", "status" => "pending", "priority" => "high"}]

      # UUID-style
      result1 = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, "550e8400-e29b-41d4-a716-446655440000")
      assert %AgentToolResult{} = result1

      # Hyphenated
      result2 = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, "my-session-id")
      assert %AgentToolResult{} = result2

      # Underscored
      result3 = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, "my_session_id")
      assert %AgentToolResult{} = result3

      # Numeric
      result4 = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, "12345")
      assert %AgentToolResult{} = result4
    end
  end

  # ============================================================================
  # Open Todo Count Tests
  # ============================================================================

  describe "execute/5 - open todo count" do
    test "counts pending todos as open", %{session_id: session_id} do
      todos = [
        %{"id" => "1", "content" => "Pending 1", "status" => "pending", "priority" => "high"},
        %{"id" => "2", "content" => "Pending 2", "status" => "pending", "priority" => "low"}
      ]

      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert %AgentToolResult{details: %{title: "2 todos"}} = result
    end

    test "counts in_progress todos as open", %{session_id: session_id} do
      todos = [
        %{"id" => "1", "content" => "In progress", "status" => "in_progress", "priority" => "high"}
      ]

      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert %AgentToolResult{details: %{title: "1 todos"}} = result
    end

    test "excludes completed todos from count", %{session_id: session_id} do
      todos = [
        %{"id" => "1", "content" => "Pending", "status" => "pending", "priority" => "high"},
        %{"id" => "2", "content" => "Completed 1", "status" => "completed", "priority" => "low"},
        %{"id" => "3", "content" => "Completed 2", "status" => "completed", "priority" => "medium"}
      ]

      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert %AgentToolResult{details: %{title: "1 todos"}} = result
    end

    test "all completed shows 0 todos", %{session_id: session_id} do
      todos = [
        %{"id" => "1", "content" => "Done 1", "status" => "completed", "priority" => "high"},
        %{"id" => "2", "content" => "Done 2", "status" => "completed", "priority" => "low"}
      ]

      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert %AgentToolResult{details: %{title: "0 todos"}} = result
    end

    test "mixed statuses are counted correctly", %{session_id: session_id} do
      todos = [
        %{"id" => "1", "content" => "Pending", "status" => "pending", "priority" => "high"},
        %{"id" => "2", "content" => "In progress", "status" => "in_progress", "priority" => "medium"},
        %{"id" => "3", "content" => "Completed", "status" => "completed", "priority" => "low"}
      ]

      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      # pending + in_progress = 2 open
      assert %AgentToolResult{details: %{title: "2 todos"}} = result
    end
  end

  # ============================================================================
  # Storage Verification Tests
  # ============================================================================

  describe "execute/5 - storage verification" do
    test "todos are stored in TodoStore", %{session_id: session_id} do
      todos = [
        %{"id" => "1", "content" => "Test todo", "status" => "pending", "priority" => "high"}
      ]

      TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)

      stored = TodoStore.get(session_id)
      assert stored == todos
    end

    test "storing new todos replaces old ones", %{session_id: session_id} do
      old_todos = [%{"id" => "1", "content" => "Old", "status" => "pending", "priority" => "high"}]
      new_todos = [%{"id" => "2", "content" => "New", "status" => "completed", "priority" => "low"}]

      TodoWrite.execute("call_1", %{"todos" => old_todos}, nil, nil, session_id)
      TodoWrite.execute("call_2", %{"todos" => new_todos}, nil, nil, session_id)

      stored = TodoStore.get(session_id)
      assert stored == new_todos
    end

    test "todos are isolated between sessions", %{session_id: _session_id} do
      session1 = "session-1-#{:erlang.unique_integer([:positive])}"
      session2 = "session-2-#{:erlang.unique_integer([:positive])}"

      todos1 = [%{"id" => "1", "content" => "Session 1 task", "status" => "pending", "priority" => "high"}]
      todos2 = [%{"id" => "2", "content" => "Session 2 task", "status" => "pending", "priority" => "low"}]

      TodoWrite.execute("call_1", %{"todos" => todos1}, nil, nil, session1)
      TodoWrite.execute("call_2", %{"todos" => todos2}, nil, nil, session2)

      assert TodoStore.get(session1) == todos1
      assert TodoStore.get(session2) == todos2
    end
  end

  # ============================================================================
  # JSON Output Tests
  # ============================================================================

  describe "execute/5 - JSON output" do
    test "returns pretty-printed JSON", %{session_id: session_id} do
      todos = [%{"id" => "1", "content" => "Test", "status" => "pending", "priority" => "high"}]

      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      # Pretty printed JSON should have newlines
      assert text =~ "\n"
      # Verify it's valid JSON
      assert {:ok, decoded} = Jason.decode(text)
      assert decoded == todos
    end

    test "encodes todos with unicode content", %{session_id: session_id} do
      todos = [
        %{"id" => "1", "content" => "Task with unicode: 🎉", "status" => "pending", "priority" => "high"},
        %{"id" => "2", "content" => "Chinese: 你好", "status" => "pending", "priority" => "medium"}
      ]

      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert {:ok, decoded} = Jason.decode(text)
      assert hd(decoded)["content"] =~ "🎉"
    end

    test "encodes todos with special JSON characters", %{session_id: session_id} do
      todos = [
        %{"id" => "1", "content" => "Task with \"quotes\" and \\backslash", "status" => "pending", "priority" => "high"}
      ]

      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert {:ok, decoded} = Jason.decode(text)
      assert hd(decoded)["content"] =~ "quotes"
    end
  end

  # ============================================================================
  # Edge Cases
  # ============================================================================

  describe "execute/5 - edge cases" do
    test "handles large number of todos", %{session_id: session_id} do
      todos =
        Enum.map(1..1000, fn i ->
          %{
            "id" => "#{i}",
            "content" => "Task #{i}",
            "status" => if(rem(i, 2) == 0, do: "completed", else: "pending"),
            "priority" => Enum.at(["high", "medium", "low"], rem(i, 3))
          }
        end)

      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)

      assert %AgentToolResult{details: details} = result
      assert length(details.todos) == 1000
      # 500 pending (odd numbers)
      assert details.title == "500 todos"
    end

    test "handles todos with very long content", %{session_id: session_id} do
      long_content = String.duplicate("x", 10_000)

      todos = [
        %{"id" => "1", "content" => long_content, "status" => "pending", "priority" => "high"}
      ]

      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)

      assert %AgentToolResult{} = result
      stored = TodoStore.get(session_id)
      assert hd(stored)["content"] == long_content
    end

    test "handles todos with long ids", %{session_id: session_id} do
      long_id = String.duplicate("a", 1000)

      todos = [
        %{"id" => long_id, "content" => "Task with long id", "status" => "pending", "priority" => "high"}
      ]

      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)

      assert %AgentToolResult{} = result
      stored = TodoStore.get(session_id)
      assert hd(stored)["id"] == long_id
    end

    test "handles todos with numeric-looking ids", %{session_id: session_id} do
      todos = [
        %{"id" => "123", "content" => "Numeric id", "status" => "pending", "priority" => "high"},
        %{"id" => "001", "content" => "Leading zeros", "status" => "pending", "priority" => "medium"}
      ]

      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)

      assert %AgentToolResult{} = result
      stored = TodoStore.get(session_id)
      assert length(stored) == 2
    end

    test "handles todos with special characters in content", %{session_id: session_id} do
      todos = [
        %{"id" => "1", "content" => "Task with <html> & \"special\" chars", "status" => "pending", "priority" => "high"},
        %{"id" => "2", "content" => "Task with new\nline", "status" => "pending", "priority" => "medium"}
      ]

      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)

      assert %AgentToolResult{} = result
      stored = TodoStore.get(session_id)
      assert length(stored) == 2
    end
  end

  # ============================================================================
  # Result Structure Tests
  # ============================================================================

  describe "execute/5 - result structure" do
    test "result has correct content structure", %{session_id: session_id} do
      todos = [%{"id" => "1", "content" => "Test", "status" => "pending", "priority" => "high"}]

      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)

      assert %AgentToolResult{content: content} = result
      assert is_list(content)
      assert length(content) == 1
      assert %TextContent{text: text} = hd(content)
      assert is_binary(text)
    end

    test "result details include title and todos", %{session_id: session_id} do
      todos = [
        %{"id" => "1", "content" => "Task 1", "status" => "pending", "priority" => "high"},
        %{"id" => "2", "content" => "Task 2", "status" => "completed", "priority" => "low"}
      ]

      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)

      assert %AgentToolResult{details: details} = result
      assert Map.has_key?(details, :title)
      assert Map.has_key?(details, :todos)
      assert details.title == "1 todos"
      assert details.todos == todos
    end

    test "title format is 'N todos'", %{session_id: session_id} do
      todos = [
        %{"id" => "1", "content" => "Task 1", "status" => "pending", "priority" => "high"},
        %{"id" => "2", "content" => "Task 2", "status" => "pending", "priority" => "low"},
        %{"id" => "3", "content" => "Task 3", "status" => "pending", "priority" => "medium"}
      ]

      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)

      assert %AgentToolResult{details: %{title: title}} = result
      assert title =~ ~r/^\d+ todos$/
      assert title == "3 todos"
    end
  end
end
