defmodule CodingAgent.Tools.TodoReadTest do
  @moduledoc """
  Comprehensive tests for the TodoRead tool.

  This module tests the TodoRead tool which reads the stored todo list
  for the current session from ETS-based storage.
  """

  use ExUnit.Case, async: true

  alias CodingAgent.Tools.{TodoRead, TodoStore}
  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias AgentCore.AbortSignal
  alias Ai.Types.TextContent

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
    test "returns an AgentTool struct with correct properties", %{session_id: session_id} do
      tool = TodoRead.tool("/tmp", session_id: session_id)

      assert %AgentTool{} = tool
      assert tool.name == "todoread"
      assert tool.label == "Read Todos"
      assert tool.description =~ "todo"
    end

    test "has correct parameter schema", %{session_id: session_id} do
      tool = TodoRead.tool("/tmp", session_id: session_id)

      assert tool.parameters["type"] == "object"
      assert tool.parameters["properties"] == %{}
      assert tool.parameters["required"] == []
    end

    test "execute function is a 4-arity function", %{session_id: session_id} do
      tool = TodoRead.tool("/tmp", session_id: session_id)

      assert is_function(tool.execute, 4)
    end

    test "works without session_id option" do
      tool = TodoRead.tool("/tmp")

      assert tool.name == "todoread"
      assert is_function(tool.execute, 4)
    end

    test "works with empty options list" do
      tool = TodoRead.tool("/tmp", [])

      assert tool.name == "todoread"
    end

    test "ignores cwd parameter (first argument)", %{session_id: session_id} do
      tool1 = TodoRead.tool("/tmp", session_id: session_id)
      tool2 = TodoRead.tool("/var/log", session_id: session_id)

      # Both should work identically - cwd is not used
      assert tool1.name == tool2.name
      assert tool1.description == tool2.description
    end

    test "tool execute function can be invoked via closure", %{session_id: session_id} do
      tool = TodoRead.tool("/tmp", session_id: session_id)
      result = tool.execute.("call_1", %{}, nil, nil)

      assert %AgentToolResult{} = result
    end
  end

  # ============================================================================
  # Reading Todo Lists from Session Storage
  # ============================================================================

  describe "execute/5 - reading todos from session storage" do
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
    end

    test "returns todos with all statuses", %{session_id: session_id} do
      todos = [
        %{"id" => "1", "content" => "Pending task", "status" => "pending", "priority" => "high"},
        %{
          "id" => "2",
          "content" => "In progress task",
          "status" => "in_progress",
          "priority" => "medium"
        },
        %{
          "id" => "3",
          "content" => "Completed task",
          "status" => "completed",
          "priority" => "low"
        }
      ]

      TodoStore.put(session_id, todos)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)

      assert %AgentToolResult{details: details} = result
      assert details.todos == todos
      # 2 non-completed
      assert details.title == "2 todos"
    end

    test "returns todos with all priorities", %{session_id: session_id} do
      todos = [
        %{"id" => "1", "content" => "High priority", "status" => "pending", "priority" => "high"},
        %{
          "id" => "2",
          "content" => "Medium priority",
          "status" => "pending",
          "priority" => "medium"
        },
        %{"id" => "3", "content" => "Low priority", "status" => "pending", "priority" => "low"}
      ]

      TodoStore.put(session_id, todos)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "high"
      assert text =~ "medium"
      assert text =~ "low"
      assert details.title == "3 todos"
    end

    test "isolates todos between sessions" do
      session1 = "session-1-#{:erlang.unique_integer([:positive])}"
      session2 = "session-2-#{:erlang.unique_integer([:positive])}"

      todos1 = [
        %{"id" => "1", "content" => "Session 1 task", "status" => "pending", "priority" => "high"}
      ]

      todos2 = [
        %{"id" => "2", "content" => "Session 2 task", "status" => "pending", "priority" => "low"}
      ]

      TodoStore.put(session1, todos1)
      TodoStore.put(session2, todos2)

      result1 = TodoRead.execute("call_1", %{}, nil, nil, session1)
      result2 = TodoRead.execute("call_2", %{}, nil, nil, session2)

      assert %AgentToolResult{details: %{todos: read_todos1}} = result1
      assert %AgentToolResult{details: %{todos: read_todos2}} = result2

      assert read_todos1 == todos1
      assert read_todos2 == todos2
    end

    test "returns most recent todos after updates", %{session_id: session_id} do
      original_todos = [
        %{"id" => "1", "content" => "Original", "status" => "pending", "priority" => "high"}
      ]

      updated_todos = [
        %{"id" => "2", "content" => "Updated", "status" => "completed", "priority" => "low"}
      ]

      TodoStore.put(session_id, original_todos)
      TodoStore.put(session_id, updated_todos)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)

      assert %AgentToolResult{details: %{todos: read_todos}} = result
      assert read_todos == updated_todos
    end

    test "returns todos with extra fields", %{session_id: session_id} do
      todos = [
        %{
          "id" => "1",
          "content" => "Task with notes",
          "status" => "pending",
          "priority" => "high",
          "notes" => "Additional notes",
          "due_date" => "2024-12-31"
        }
      ]

      TodoStore.put(session_id, todos)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "Additional notes"
      assert text =~ "2024-12-31"
      assert details.todos == todos
    end
  end

  # ============================================================================
  # Empty Todo List Handling
  # ============================================================================

  describe "execute/5 - empty todo list handling" do
    test "returns empty list when no todos exist", %{session_id: session_id} do
      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text == "[]"
      assert details.todos == []
    end

    test "returns 0 todos count for empty list", %{session_id: session_id} do
      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)

      assert %AgentToolResult{details: details} = result
      assert details.title == "0 todos"
    end

    test "returns empty list after todos are deleted", %{session_id: session_id} do
      todos = [%{"id" => "1", "content" => "Task", "status" => "pending", "priority" => "high"}]
      TodoStore.put(session_id, todos)
      TodoStore.delete(session_id)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)

      assert %AgentToolResult{details: details} = result
      assert details.todos == []
      assert details.title == "0 todos"
    end

    test "returns empty list after clear operation", %{session_id: session_id} do
      todos = [%{"id" => "1", "content" => "Task", "status" => "pending", "priority" => "high"}]
      TodoStore.put(session_id, todos)
      TodoStore.clear()

      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)

      assert %AgentToolResult{details: details} = result
      assert details.todos == []
    end

    test "returns empty list for new session after other sessions are cleared" do
      old_session = "old-session-#{:erlang.unique_integer([:positive])}"
      new_session = "new-session-#{:erlang.unique_integer([:positive])}"

      TodoStore.put(old_session, [
        %{"id" => "1", "content" => "Old task", "status" => "pending", "priority" => "high"}
      ])

      TodoStore.clear()

      result = TodoRead.execute("call_1", %{}, nil, nil, new_session)

      assert %AgentToolResult{details: %{todos: []}} = result
    end
  end

  # ============================================================================
  # Session ID Validation
  # ============================================================================

  describe "execute/5 - session id validation" do
    test "returns error when session_id is empty string" do
      result = TodoRead.execute("call_1", %{}, nil, nil, "")

      assert {:error, msg} = result
      assert msg =~ "Session id not available"
    end

    test "works with various session id formats" do
      # UUID-style
      uuid_session = "550e8400-e29b-41d4-a716-446655440000"
      result1 = TodoRead.execute("call_1", %{}, nil, nil, uuid_session)
      assert %AgentToolResult{} = result1

      # Hyphenated
      hyphen_session = "my-session-id"
      result2 = TodoRead.execute("call_2", %{}, nil, nil, hyphen_session)
      assert %AgentToolResult{} = result2

      # Underscored
      underscore_session = "my_session_id"
      result3 = TodoRead.execute("call_3", %{}, nil, nil, underscore_session)
      assert %AgentToolResult{} = result3

      # Numeric
      numeric_session = "12345"
      result4 = TodoRead.execute("call_4", %{}, nil, nil, numeric_session)
      assert %AgentToolResult{} = result4
    end

    test "handles special characters in session id", %{session_id: _session_id} do
      special_session = "session:with:colons"
      todos = [%{"id" => "1", "content" => "Task", "status" => "pending", "priority" => "high"}]
      TodoStore.put(special_session, todos)

      result = TodoRead.execute("call_1", %{}, nil, nil, special_session)

      assert %AgentToolResult{details: %{todos: read_todos}} = result
      assert read_todos == todos
    end

    test "handles long session ids" do
      long_session = String.duplicate("a", 500)
      todos = [%{"id" => "1", "content" => "Task", "status" => "pending", "priority" => "high"}]
      TodoStore.put(long_session, todos)

      result = TodoRead.execute("call_1", %{}, nil, nil, long_session)

      assert %AgentToolResult{details: %{todos: read_todos}} = result
      assert read_todos == todos
    end

    test "session ids are case-sensitive" do
      lower_session = "mysession"
      upper_session = "MYSESSION"

      lower_todos = [
        %{"id" => "1", "content" => "Lower task", "status" => "pending", "priority" => "high"}
      ]

      upper_todos = [
        %{"id" => "2", "content" => "Upper task", "status" => "pending", "priority" => "low"}
      ]

      TodoStore.put(lower_session, lower_todos)
      TodoStore.put(upper_session, upper_todos)

      result_lower = TodoRead.execute("call_1", %{}, nil, nil, lower_session)
      result_upper = TodoRead.execute("call_2", %{}, nil, nil, upper_session)

      assert %AgentToolResult{details: %{todos: ^lower_todos}} = result_lower
      assert %AgentToolResult{details: %{todos: ^upper_todos}} = result_upper
    end
  end

  # ============================================================================
  # JSON Encoding Edge Cases
  # ============================================================================

  describe "execute/5 - JSON encoding edge cases" do
    test "encodes empty array as []", %{session_id: session_id} do
      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text == "[]"
    end

    test "encodes todos with unicode content", %{session_id: session_id} do
      todos = [
        %{
          "id" => "1",
          "content" => "Task with unicode: ",
          "status" => "pending",
          "priority" => "high"
        },
        %{"id" => "2", "content" => "Chinese: ", "status" => "pending", "priority" => "medium"},
        %{"id" => "3", "content" => "Arabic: ", "status" => "pending", "priority" => "low"}
      ]

      TodoStore.put(session_id, todos)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ ""
      assert text =~ ""
      assert text =~ ""
    end

    test "encodes todos with special JSON characters", %{session_id: session_id} do
      todos = [
        %{
          "id" => "1",
          "content" => "Task with \"quotes\" and \\backslash",
          "status" => "pending",
          "priority" => "high"
        }
      ]

      TodoStore.put(session_id, todos)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      # Should be properly escaped
      assert String.contains?(text, "quotes")
      assert String.contains?(text, "backslash")
      # Verify it's valid JSON
      assert {:ok, _} = Jason.decode(text)
    end

    test "encodes todos with newlines in content", %{session_id: session_id} do
      todos = [
        %{
          "id" => "1",
          "content" => "Line 1\nLine 2\nLine 3",
          "status" => "pending",
          "priority" => "high"
        }
      ]

      TodoStore.put(session_id, todos)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      # Verify it's valid JSON and contains the content
      assert {:ok, decoded} = Jason.decode(text)
      assert hd(decoded)["content"] =~ "Line 1"
    end

    test "encodes todos with nested structures", %{session_id: session_id} do
      todos = [
        %{
          "id" => "1",
          "content" => "Task with metadata",
          "status" => "pending",
          "priority" => "high",
          "metadata" => %{
            "tags" => ["urgent", "review"],
            "assignee" => %{"name" => "John", "email" => "john@example.com"}
          }
        }
      ]

      TodoStore.put(session_id, todos)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert {:ok, decoded} = Jason.decode(text)
      assert hd(decoded)["metadata"]["tags"] == ["urgent", "review"]
    end

    test "pretty prints JSON output", %{session_id: session_id} do
      todos = [
        %{"id" => "1", "content" => "Task", "status" => "pending", "priority" => "high"}
      ]

      TodoStore.put(session_id, todos)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      # Pretty printed JSON should have newlines
      assert text =~ "\n"
    end

    test "handles todos with null values", %{session_id: session_id} do
      todos = [
        %{
          "id" => "1",
          "content" => "Task",
          "status" => "pending",
          "priority" => "high",
          "optional_field" => nil
        }
      ]

      TodoStore.put(session_id, todos)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "null"
    end

    test "handles todos with numeric values", %{session_id: session_id} do
      todos = [
        %{
          "id" => "1",
          "content" => "Task",
          "status" => "pending",
          "priority" => "high",
          "order" => 42,
          "score" => 3.14
        }
      ]

      TodoStore.put(session_id, todos)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "42"
      assert text =~ "3.14"
    end

    test "handles todos with boolean values", %{session_id: session_id} do
      todos = [
        %{
          "id" => "1",
          "content" => "Task",
          "status" => "pending",
          "priority" => "high",
          "is_urgent" => true,
          "is_archived" => false
        }
      ]

      TodoStore.put(session_id, todos)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "true"
      assert text =~ "false"
    end
  end

  # ============================================================================
  # Error Handling for Missing Sessions
  # ============================================================================

  describe "execute/5 - missing session handling" do
    test "returns empty list for never-used session id" do
      random_session = "random-session-#{:rand.uniform(1_000_000)}"

      result = TodoRead.execute("call_1", %{}, nil, nil, random_session)

      assert %AgentToolResult{details: %{todos: []}} = result
    end

    test "returns empty list after session data is deleted" do
      session = "deletable-session-#{:erlang.unique_integer([:positive])}"
      todos = [%{"id" => "1", "content" => "Task", "status" => "pending", "priority" => "high"}]

      TodoStore.put(session, todos)
      TodoStore.delete(session)

      result = TodoRead.execute("call_1", %{}, nil, nil, session)

      assert %AgentToolResult{details: %{todos: []}} = result
    end

    test "gracefully handles concurrent access" do
      session = "concurrent-session-#{:erlang.unique_integer([:positive])}"
      todos = [%{"id" => "1", "content" => "Task", "status" => "pending", "priority" => "high"}]
      TodoStore.put(session, todos)

      # Simulate concurrent reads
      results =
        1..10
        |> Enum.map(fn i ->
          Task.async(fn ->
            TodoRead.execute("call_#{i}", %{}, nil, nil, session)
          end)
        end)
        |> Enum.map(&Task.await/1)

      # All reads should succeed
      Enum.each(results, fn result ->
        assert %AgentToolResult{details: %{todos: ^todos}} = result
      end)
    end
  end

  # ============================================================================
  # Integration with Tool System
  # ============================================================================

  describe "tool system integration" do
    test "execute function matches tool closure signature", %{session_id: session_id} do
      tool = TodoRead.tool("/tmp", session_id: session_id)

      # Tool execute expects (tool_call_id, params, signal, on_update)
      result = tool.execute.("call_1", %{}, nil, nil)

      assert %AgentToolResult{} = result
    end

    test "ignores extra parameters in params map", %{session_id: session_id} do
      todos = [%{"id" => "1", "content" => "Task", "status" => "pending", "priority" => "high"}]
      TodoStore.put(session_id, todos)

      # Extra params should be ignored
      result =
        TodoRead.execute("call_1", %{"extra" => "param", "another" => 123}, nil, nil, session_id)

      assert %AgentToolResult{details: %{todos: ^todos}} = result
    end

    test "works with nil on_update callback", %{session_id: session_id} do
      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)

      assert %AgentToolResult{} = result
    end

    test "result has correct content structure", %{session_id: session_id} do
      todos = [%{"id" => "1", "content" => "Task", "status" => "pending", "priority" => "high"}]
      TodoStore.put(session_id, todos)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)

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

      TodoStore.put(session_id, todos)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)

      assert %AgentToolResult{details: details} = result
      assert Map.has_key?(details, :title)
      assert Map.has_key?(details, :todos)
      assert details.title == "1 todos"
      assert details.todos == todos
    end
  end

  # ============================================================================
  # Abort Signal Handling
  # ============================================================================

  describe "execute/5 - abort signal handling" do
    test "returns error when signal is already aborted", %{session_id: session_id} do
      signal = AbortSignal.new()
      AbortSignal.abort(signal)

      result = TodoRead.execute("call_1", %{}, signal, nil, session_id)

      AbortSignal.clear(signal)

      assert {:error, "Operation aborted"} = result
    end

    test "proceeds normally when signal is not aborted", %{session_id: session_id} do
      signal = AbortSignal.new()

      result = TodoRead.execute("call_1", %{}, signal, nil, session_id)

      AbortSignal.clear(signal)

      assert %AgentToolResult{} = result
    end

    test "proceeds normally when signal is nil", %{session_id: session_id} do
      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)

      assert %AgentToolResult{} = result
    end

    test "abort check happens before session validation" do
      signal = AbortSignal.new()
      AbortSignal.abort(signal)

      # Even with empty session (which would normally error), abort takes priority
      result = TodoRead.execute("call_1", %{}, signal, nil, "")

      AbortSignal.clear(signal)

      assert {:error, "Operation aborted"} = result
    end
  end

  # ============================================================================
  # Open Todo Count
  # ============================================================================

  describe "execute/5 - open todo count" do
    test "counts pending todos as open", %{session_id: session_id} do
      todos = [
        %{"id" => "1", "content" => "Pending 1", "status" => "pending", "priority" => "high"},
        %{"id" => "2", "content" => "Pending 2", "status" => "pending", "priority" => "low"}
      ]

      TodoStore.put(session_id, todos)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)

      assert %AgentToolResult{details: %{title: "2 todos"}} = result
    end

    test "counts in_progress todos as open", %{session_id: session_id} do
      todos = [
        %{
          "id" => "1",
          "content" => "In progress",
          "status" => "in_progress",
          "priority" => "high"
        }
      ]

      TodoStore.put(session_id, todos)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)

      assert %AgentToolResult{details: %{title: "1 todos"}} = result
    end

    test "excludes completed todos from count", %{session_id: session_id} do
      todos = [
        %{"id" => "1", "content" => "Pending", "status" => "pending", "priority" => "high"},
        %{"id" => "2", "content" => "Completed 1", "status" => "completed", "priority" => "low"},
        %{
          "id" => "3",
          "content" => "Completed 2",
          "status" => "completed",
          "priority" => "medium"
        }
      ]

      TodoStore.put(session_id, todos)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)

      assert %AgentToolResult{details: %{title: "1 todos"}} = result
    end

    test "all completed shows 0 todos", %{session_id: session_id} do
      todos = [
        %{"id" => "1", "content" => "Done 1", "status" => "completed", "priority" => "high"},
        %{"id" => "2", "content" => "Done 2", "status" => "completed", "priority" => "low"}
      ]

      TodoStore.put(session_id, todos)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)

      assert %AgentToolResult{details: %{title: "0 todos"}} = result
    end

    test "mixed statuses are counted correctly", %{session_id: session_id} do
      todos = [
        %{"id" => "1", "content" => "Pending", "status" => "pending", "priority" => "high"},
        %{
          "id" => "2",
          "content" => "In progress",
          "status" => "in_progress",
          "priority" => "medium"
        },
        %{"id" => "3", "content" => "Completed", "status" => "completed", "priority" => "low"}
      ]

      TodoStore.put(session_id, todos)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)

      # pending + in_progress = 2 open
      assert %AgentToolResult{details: %{title: "2 todos"}} = result
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

      TodoStore.put(session_id, todos)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)

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

      TodoStore.put(session_id, todos)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ String.slice(long_content, 0, 100)
    end

    test "handles empty content string", %{session_id: session_id} do
      # Note: While TodoWrite validates non-empty content, TodoRead should handle
      # any data that might be in storage
      todos = [%{"id" => "1", "content" => "", "status" => "pending", "priority" => "high"}]
      TodoStore.put(session_id, todos)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)

      assert %AgentToolResult{details: %{todos: ^todos}} = result
    end

    test "handles todos without optional fields", %{session_id: session_id} do
      todos = [
        %{"id" => "1", "content" => "Minimal todo", "status" => "pending", "priority" => "high"}
      ]

      TodoStore.put(session_id, todos)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)

      assert %AgentToolResult{details: %{todos: ^todos}} = result
    end

    test "handles unique tool_call_id values", %{session_id: session_id} do
      todos = [%{"id" => "1", "content" => "Task", "status" => "pending", "priority" => "high"}]
      TodoStore.put(session_id, todos)

      result1 = TodoRead.execute("unique-call-id-123", %{}, nil, nil, session_id)
      result2 = TodoRead.execute("another-unique-id", %{}, nil, nil, session_id)

      # Both should succeed regardless of tool_call_id
      assert %AgentToolResult{} = result1
      assert %AgentToolResult{} = result2
    end

    test "handles whitespace-only session id" do
      result = TodoRead.execute("call_1", %{}, nil, nil, "   ")

      # Non-empty string (even whitespace) should work since it's not ""
      assert %AgentToolResult{} = result
    end
  end

  # ============================================================================
  # Details Structure Validation
  # ============================================================================

  describe "execute/5 - details structure" do
    test "details is a map with required keys", %{session_id: session_id} do
      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)

      assert %AgentToolResult{details: details} = result
      assert is_map(details)
      assert Map.has_key?(details, :title)
      assert Map.has_key?(details, :todos)
    end

    test "title is a string", %{session_id: session_id} do
      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)

      assert %AgentToolResult{details: %{title: title}} = result
      assert is_binary(title)
    end

    test "todos is a list", %{session_id: session_id} do
      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)

      assert %AgentToolResult{details: %{todos: todos}} = result
      assert is_list(todos)
    end

    test "title format is 'N todos'", %{session_id: session_id} do
      todos = [
        %{"id" => "1", "content" => "Task 1", "status" => "pending", "priority" => "high"},
        %{"id" => "2", "content" => "Task 2", "status" => "pending", "priority" => "low"},
        %{"id" => "3", "content" => "Task 3", "status" => "pending", "priority" => "medium"}
      ]

      TodoStore.put(session_id, todos)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)

      assert %AgentToolResult{details: %{title: title}} = result
      assert title =~ ~r/^\d+ todos$/
      assert title == "3 todos"
    end
  end
end
