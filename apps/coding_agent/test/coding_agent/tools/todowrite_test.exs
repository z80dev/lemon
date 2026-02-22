defmodule CodingAgent.Tools.TodoWriteTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Tools.TodoWrite
  alias CodingAgent.Tools.TodoRead
  alias CodingAgent.Tools.TodoStore
  alias AgentCore.Types.AgentToolResult
  alias AgentCore.AbortSignal
  alias Ai.Types.TextContent

  setup do
    session_id = "todowrite_test_#{System.unique_integer([:positive])}"
    TodoStore.put(session_id, [])

    on_exit(fn ->
      TodoStore.delete(session_id)
    end)

    {:ok, session_id: session_id}
  end

  defp valid_todo(overrides \\ %{}) do
    Map.merge(
      %{"id" => "1", "content" => "Test task", "status" => "pending", "priority" => "high"},
      overrides
    )
  end

  describe "tool/2" do
    test "returns an AgentTool struct with correct metadata" do
      tool = TodoWrite.tool("/tmp")
      assert tool.name == "todowrite"
      assert tool.label == "Write Todos"
      assert tool.description == "Write the session todo list."
      assert is_function(tool.execute, 4)
    end

    test "parameters require todos array with proper item schema" do
      tool = TodoWrite.tool("/tmp")
      assert tool.parameters["type"] == "object"
      assert "todos" in tool.parameters["required"]
      assert tool.parameters["properties"]["todos"]["type"] == "array"
      item_schema = tool.parameters["properties"]["todos"]["items"]
      assert item_schema["required"] == ["content", "status", "priority", "id"]
    end
  end

  describe "execute/5 - valid todos" do
    test "stores a single valid todo", %{session_id: session_id} do
      todos = [valid_todo()]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)

      assert %AgentToolResult{} = result
      assert [%TextContent{text: text}] = result.content
      parsed = Jason.decode!(text)
      assert length(parsed) == 1
      assert hd(parsed)["content"] == "Test task"
    end

    test "stores multiple valid todos with mixed statuses and priorities", %{session_id: session_id} do
      todos = [
        valid_todo(%{"id" => "1", "content" => "First", "status" => "pending", "priority" => "high"}),
        valid_todo(%{"id" => "2", "content" => "Second", "status" => "in_progress", "priority" => "medium"}),
        valid_todo(%{"id" => "3", "content" => "Third", "status" => "completed", "priority" => "low"})
      ]

      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert %AgentToolResult{} = result
      assert length(result.details.todos) == 3
    end

    test "returns correct open count excluding completed", %{session_id: session_id} do
      todos = [
        valid_todo(%{"id" => "1", "status" => "pending"}),
        valid_todo(%{"id" => "2", "status" => "in_progress"}),
        valid_todo(%{"id" => "3", "status" => "completed"})
      ]

      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert result.details.title == "2 todos"
    end

    test "persists todos to store", %{session_id: session_id} do
      todos = [valid_todo()]
      TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      stored = TodoStore.get(session_id)
      assert length(stored) == 1
      assert hd(stored)["content"] == "Test task"
    end

    test "overwrites previous todos", %{session_id: session_id} do
      first = [valid_todo(%{"id" => "1", "content" => "First"})]
      TodoWrite.execute("call_1", %{"todos" => first}, nil, nil, session_id)

      second = [valid_todo(%{"id" => "2", "content" => "Second"})]
      TodoWrite.execute("call_2", %{"todos" => second}, nil, nil, session_id)

      stored = TodoStore.get(session_id)
      assert length(stored) == 1
      assert hd(stored)["content"] == "Second"
    end

    test "accepts empty todo list", %{session_id: session_id} do
      result = TodoWrite.execute("call_1", %{"todos" => []}, nil, nil, session_id)
      assert %AgentToolResult{} = result
      assert result.details.title == "0 todos"
      assert TodoStore.get(session_id) == []
    end

    test "handles special characters in content", %{session_id: session_id} do
      todos = [valid_todo(%{"content" => "Task with \"quotes\" & <angles>"})]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      parsed = Jason.decode!(hd(result.content).text)
      assert hd(parsed)["content"] == "Task with \"quotes\" & <angles>"
    end
  end

  describe "execute/5 - invalid status" do
    test "rejects unknown status value", %{session_id: session_id} do
      todos = [valid_todo(%{"status" => "done"})]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert {:error, msg} = result
      assert msg =~ "status must be pending, in_progress, or completed"
    end

    test "rejects empty string status", %{session_id: session_id} do
      todos = [valid_todo(%{"status" => ""})]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert {:error, msg} = result
      assert msg =~ "status must be"
    end

    test "rejects non-string status", %{session_id: session_id} do
      todos = [valid_todo() |> Map.put("status", 42)]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert {:error, msg} = result
      assert msg =~ "status must be"
    end
  end

  describe "execute/5 - invalid priority" do
    test "rejects unknown priority value", %{session_id: session_id} do
      todos = [valid_todo(%{"priority" => "urgent"})]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert {:error, msg} = result
      assert msg =~ "priority must be high, medium, or low"
    end

    test "rejects empty string priority", %{session_id: session_id} do
      todos = [valid_todo(%{"priority" => ""})]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert {:error, msg} = result
      assert msg =~ "priority must be"
    end

    test "rejects non-string priority", %{session_id: session_id} do
      todos = [valid_todo() |> Map.put("priority", true)]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert {:error, msg} = result
      assert msg =~ "priority must be"
    end
  end

  describe "execute/5 - missing fields" do
    test "rejects todo missing id", %{session_id: session_id} do
      todos = [%{"content" => "No id", "status" => "pending", "priority" => "high"}]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert {:error, msg} = result
      assert msg =~ "id must be a non-empty string"
    end

    test "rejects todo missing content", %{session_id: session_id} do
      todos = [%{"id" => "1", "status" => "pending", "priority" => "high"}]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert {:error, msg} = result
      assert msg =~ "content must be a non-empty string"
    end

    test "rejects todo missing status", %{session_id: session_id} do
      todos = [%{"id" => "1", "content" => "No status", "priority" => "high"}]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert {:error, msg} = result
      assert msg =~ "status must be"
    end

    test "rejects todo missing priority", %{session_id: session_id} do
      todos = [%{"id" => "1", "content" => "No priority", "status" => "pending"}]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert {:error, msg} = result
      assert msg =~ "priority must be"
    end
  end

  describe "execute/5 - duplicate IDs" do
    test "rejects todos with duplicate ids", %{session_id: session_id} do
      todos = [
        valid_todo(%{"id" => "dup", "content" => "First"}),
        valid_todo(%{"id" => "dup", "content" => "Second"})
      ]

      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert {:error, "todo ids must be unique"} = result
    end

  end

  describe "execute/5 - empty and whitespace content" do
    test "rejects todo with empty content string", %{session_id: session_id} do
      todos = [valid_todo(%{"content" => ""})]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert {:error, msg} = result
      assert msg =~ "content must be a non-empty string"
    end

    test "rejects todo with whitespace-only content", %{session_id: session_id} do
      todos = [valid_todo(%{"content" => "   "})]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert {:error, msg} = result
      assert msg =~ "content must be a non-empty string"
    end

    test "rejects todo with empty id", %{session_id: session_id} do
      todos = [valid_todo(%{"id" => ""})]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert {:error, msg} = result
      assert msg =~ "id must be a non-empty string"
    end

    test "rejects todo with whitespace-only id", %{session_id: session_id} do
      todos = [valid_todo(%{"id" => "  \t  "})]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert {:error, msg} = result
      assert msg =~ "id must be a non-empty string"
    end
  end

  describe "execute/5 - non-string and invalid types" do
    test "rejects integer content", %{session_id: session_id} do
      todos = [valid_todo() |> Map.put("content", 123)]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert {:error, msg} = result
      assert msg =~ "content must be a non-empty string"
    end

    test "rejects integer id", %{session_id: session_id} do
      todos = [valid_todo() |> Map.put("id", 999)]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert {:error, msg} = result
      assert msg =~ "id must be a non-empty string"
    end

    test "rejects non-list todos param", %{session_id: session_id} do
      result = TodoWrite.execute("call_1", %{"todos" => "not a list"}, nil, nil, session_id)
      assert {:error, "Todos must be an array"} = result
    end

    test "rejects non-map entry in todos array", %{session_id: session_id} do
      todos = ["not a map"]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert {:error, msg} = result
      assert msg =~ "must be an object"
    end
  end

  describe "execute/5 - abort signal" do
    test "returns error when signal is aborted", %{session_id: session_id} do
      signal = AbortSignal.new()
      AbortSignal.abort(signal)
      todos = [valid_todo()]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, signal, nil, session_id)
      assert {:error, "Operation aborted"} = result
    end

    test "does not store when aborted", %{session_id: session_id} do
      signal = AbortSignal.new()
      AbortSignal.abort(signal)
      todos = [valid_todo(%{"content" => "Should not be stored"})]
      TodoWrite.execute("call_1", %{"todos" => todos}, signal, nil, session_id)
      assert TodoStore.get(session_id) == []
    end

    test "proceeds when signal is not aborted", %{session_id: session_id} do
      signal = AbortSignal.new()
      todos = [valid_todo()]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, signal, nil, session_id)
      assert %AgentToolResult{} = result
    end
  end

  describe "execute/5 - missing session_id" do
    test "returns error when session_id is empty string" do
      todos = [valid_todo()]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, "")
      assert {:error, "Session id not available"} = result
    end

  end

  describe "execute/5 - validation order and indexing" do
    test "error message includes 1-based index for second todo", %{session_id: session_id} do
      todos = [
        valid_todo(%{"id" => "1"}),
        valid_todo(%{"id" => "2", "status" => "invalid"})
      ]

      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_id)
      assert {:error, msg} = result
      assert msg =~ "Todo 2"
    end
  end

  describe "integration - write then read" do
    test "todos written can be read back", %{session_id: session_id} do
      todos = [
        valid_todo(%{"id" => "1", "content" => "Alpha", "status" => "pending", "priority" => "high"}),
        valid_todo(%{"id" => "2", "content" => "Beta", "status" => "in_progress", "priority" => "medium"}),
        valid_todo(%{"id" => "3", "content" => "Gamma", "status" => "completed", "priority" => "low"})
      ]

      write_result = TodoWrite.execute("call_w", %{"todos" => todos}, nil, nil, session_id)
      assert %AgentToolResult{} = write_result

      read_result = TodoRead.execute("call_r", %{}, nil, nil, session_id)
      assert %AgentToolResult{} = read_result

      written = Jason.decode!(hd(write_result.content).text)
      read_back = Jason.decode!(hd(read_result.content).text)
      assert written == read_back
    end

    test "overwritten todos reflect latest state on read", %{session_id: session_id} do
      first = [valid_todo(%{"id" => "1", "content" => "Original"})]
      TodoWrite.execute("call_w1", %{"todos" => first}, nil, nil, session_id)

      second = [valid_todo(%{"id" => "2", "content" => "Replacement"})]
      TodoWrite.execute("call_w2", %{"todos" => second}, nil, nil, session_id)

      read_result = TodoRead.execute("call_r", %{}, nil, nil, session_id)
      read_back = Jason.decode!(hd(read_result.content).text)
      assert length(read_back) == 1
      assert hd(read_back)["content"] == "Replacement"
    end

  end
end
