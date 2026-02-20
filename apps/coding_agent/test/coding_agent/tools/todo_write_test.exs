defmodule CodingAgent.Tools.TodoWriteTest do
  @moduledoc """
  Tests for the TodoWrite tool.
  """
  use ExUnit.Case, async: true

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias AgentCore.AbortSignal
  alias Ai.Types.TextContent
  alias CodingAgent.Tools.{TodoWrite, TodoStore}

  setup do
    session_id = "test_session_#{System.unique_integer([:positive])}"
    TodoStore.put(session_id, [])

    on_exit(fn ->
      :ets.delete(:coding_agent_todos, session_id)
    end)

    {:ok, session_id: session_id}
  end

  describe "tool/2" do
    test "returns proper AgentTool struct" do
      tool = TodoWrite.tool("/tmp", session_id: "test")

      assert %AgentTool{} = tool
      assert tool.name == "todowrite"
      assert tool.label == "Write Todos"
      assert tool.description =~ "Write"
      assert tool.parameters["type"] == "object"
      assert "todos" in tool.parameters["required"]
      assert is_function(tool.execute, 4)
    end
  end

  describe "execute/5" do
    test "stores valid todos", %{session_id: session_id} do
      todos = [
        %{"id" => "1", "content" => "Test todo", "status" => "pending", "priority" => "high"}
      ]

      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)

      assert %AgentToolResult{} = result
      assert [%TextContent{text: text}] = result.content
      assert text =~ "Test todo"
      assert result.details.title == "1 todos"

      # Verify stored
      stored = TodoStore.get(session_id)
      assert length(stored) == 1
      assert hd(stored)["content"] == "Test todo"
    end

    test "validates todos is an array", %{session_id: session_id} do
      result = TodoWrite.execute("call_1", %{"todos" => "not an array"}, nil, nil, session_id)
      assert {:error, "Todos must be an array"} = result
    end

    test "validates each todo has required fields", %{session_id: session_id} do
      # Missing id
      todos = [%{"content" => "Test", "status" => "pending", "priority" => "high"}]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert {:error, _} = result

      # Missing content
      todos = [%{"id" => "1", "status" => "pending", "priority" => "high"}]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert {:error, _} = result

      # Empty content
      todos = [%{"id" => "1", "content" => "", "status" => "pending", "priority" => "high"}]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert {:error, _} = result

      # Missing status
      todos = [%{"id" => "1", "content" => "Test", "priority" => "high"}]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert {:error, _} = result

      # Missing priority
      todos = [%{"id" => "1", "content" => "Test", "status" => "pending"}]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert {:error, _} = result
    end

    test "validates status values", %{session_id: session_id} do
      valid_statuses = ["pending", "in_progress", "completed"]

      for status <- valid_statuses do
        todos = [%{"id" => "1", "content" => "Test", "status" => status, "priority" => "high"}]
        result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
        assert %AgentToolResult{} = result
      end

      # Invalid status
      todos = [%{"id" => "1", "content" => "Test", "status" => "invalid", "priority" => "high"}]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert {:error, _} = result
    end

    test "validates priority values", %{session_id: session_id} do
      valid_priorities = ["high", "medium", "low"]

      for priority <- valid_priorities do
        todos = [
          %{"id" => "1", "content" => "Test", "status" => "pending", "priority" => priority}
        ]

        result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
        assert %AgentToolResult{} = result
      end

      # Invalid priority
      todos = [
        %{"id" => "1", "content" => "Test", "status" => "pending", "priority" => "invalid"}
      ]

      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert {:error, _} = result
    end

    test "validates unique ids", %{session_id: session_id} do
      todos = [
        %{"id" => "1", "content" => "First", "status" => "pending", "priority" => "high"},
        %{"id" => "1", "content" => "Duplicate", "status" => "pending", "priority" => "medium"}
      ]

      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert {:error, "todo ids must be unique"} = result
    end

    test "returns error when session_id is empty" do
      todos = [%{"id" => "1", "content" => "Test", "status" => "pending", "priority" => "high"}]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, "")
      assert {:error, "Session id not available"} = result
    end

    test "returns error when aborted", %{session_id: session_id} do
      signal = AbortSignal.new()
      AbortSignal.abort(signal)

      todos = [%{"id" => "1", "content" => "Test", "status" => "pending", "priority" => "high"}]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, signal, nil, session_id)

      assert {:error, "Operation aborted"} = result
    end

    test "stores multiple todos and counts open ones", %{session_id: session_id} do
      todos = [
        %{"id" => "1", "content" => "Open 1", "status" => "pending", "priority" => "high"},
        %{"id" => "2", "content" => "Open 2", "status" => "in_progress", "priority" => "medium"},
        %{"id" => "3", "content" => "Done", "status" => "completed", "priority" => "low"}
      ]

      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)

      assert %AgentToolResult{} = result
      assert result.details.title == "2 todos"
      assert length(result.details.todos) == 3
    end

    test "validates todo is an object", %{session_id: session_id} do
      todos = ["not a map"]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert {:error, _} = result
    end
  end
end
