defmodule CodingAgent.Tools.TodoReadTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Tools.TodoRead
  alias CodingAgent.Tools.TodoStore
  alias AgentCore.Types.AgentToolResult
  alias AgentCore.AbortSignal
  alias Ai.Types.TextContent

  setup do
    session_id = "todoread_test_#{System.unique_integer([:positive])}"
    TodoStore.put(session_id, [])

    on_exit(fn ->
      TodoStore.delete(session_id)
    end)

    {:ok, session_id: session_id}
  end

  describe "tool/2" do
    test "returns an AgentTool struct" do
      tool = TodoRead.tool("/tmp")
      assert tool.name == "todoread"
      assert tool.label == "Read Todos"
      assert tool.description == "Read the session todo list."
      assert is_function(tool.execute, 4)
    end

    test "parameters define an object with no required properties" do
      tool = TodoRead.tool("/tmp")
      assert tool.parameters["type"] == "object"
      assert tool.parameters["properties"] == %{}
      assert tool.parameters["required"] == []
    end

    test "captures session_id from opts" do
      tool = TodoRead.tool("/tmp", session_id: "my-session")
      assert is_function(tool.execute, 4)
    end

    test "defaults session_id to empty string when not provided" do
      tool = TodoRead.tool("/tmp")
      result = tool.execute.("call_1", %{}, nil, nil)
      assert {:error, "Session id not available"} = result
    end
  end

  describe "execute/5 - empty list" do
    test "returns empty array for new session", %{session_id: session_id} do
      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)

      assert %AgentToolResult{} = result
      assert [%TextContent{text: text}] = result.content
      assert Jason.decode!(text) == []
      assert result.details.title == "0 todos"
      assert result.details.todos == []
    end

    test "returns zero open count for empty list", %{session_id: session_id} do
      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)
      assert result.details.title == "0 todos"
    end
  end

  describe "execute/5 - with todos" do
    test "returns stored todos", %{session_id: session_id} do
      todos = [
        %{"id" => "1", "content" => "Task one", "status" => "pending", "priority" => "high"},
        %{"id" => "2", "content" => "Task two", "status" => "completed", "priority" => "low"}
      ]

      TodoStore.put(session_id, todos)
      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)

      assert %AgentToolResult{} = result
      parsed = Jason.decode!(hd(result.content).text)
      assert length(parsed) == 2
      assert Enum.at(parsed, 0)["content"] == "Task one"
      assert Enum.at(parsed, 1)["content"] == "Task two"
    end

    test "counts only non-completed todos as open", %{session_id: session_id} do
      todos = [
        %{"id" => "1", "content" => "Done", "status" => "completed", "priority" => "low"},
        %{"id" => "2", "content" => "Active", "status" => "in_progress", "priority" => "medium"},
        %{"id" => "3", "content" => "Waiting", "status" => "pending", "priority" => "high"}
      ]

      TodoStore.put(session_id, todos)
      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)
      assert result.details.title == "2 todos"
    end

    test "counts all as open when none completed", %{session_id: session_id} do
      todos = [
        %{"id" => "1", "content" => "A", "status" => "pending", "priority" => "high"},
        %{"id" => "2", "content" => "B", "status" => "in_progress", "priority" => "medium"}
      ]

      TodoStore.put(session_id, todos)
      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)
      assert result.details.title == "2 todos"
    end

    test "counts zero open when all completed", %{session_id: session_id} do
      todos = [
        %{"id" => "1", "content" => "A", "status" => "completed", "priority" => "high"},
        %{"id" => "2", "content" => "B", "status" => "completed", "priority" => "low"}
      ]

      TodoStore.put(session_id, todos)
      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)
      assert result.details.title == "0 todos"
    end

    test "returns todos in details", %{session_id: session_id} do
      todos = [
        %{"id" => "1", "content" => "Task", "status" => "pending", "priority" => "high"}
      ]

      TodoStore.put(session_id, todos)
      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)
      assert result.details.todos == todos
    end

    test "returns valid JSON in content text", %{session_id: session_id} do
      todos = [
        %{"id" => "abc", "content" => "Special chars: <>&\"'", "status" => "pending", "priority" => "low"}
      ]

      TodoStore.put(session_id, todos)
      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)
      parsed = Jason.decode!(hd(result.content).text)
      assert hd(parsed)["content"] == "Special chars: <>&\"'"
    end

    test "handles single todo", %{session_id: session_id} do
      todos = [%{"id" => "only", "content" => "Solo task", "status" => "pending", "priority" => "medium"}]
      TodoStore.put(session_id, todos)
      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)
      assert result.details.title == "1 todos"
      assert length(result.details.todos) == 1
    end
  end

  describe "execute/5 - session isolation" do
    test "different sessions have independent todo lists" do
      session_a = "todoread_iso_a_#{System.unique_integer([:positive])}"
      session_b = "todoread_iso_b_#{System.unique_integer([:positive])}"

      on_exit(fn ->
        TodoStore.delete(session_a)
        TodoStore.delete(session_b)
      end)

      TodoStore.put(session_a, [%{"id" => "1", "content" => "A", "status" => "pending", "priority" => "high"}])
      TodoStore.put(session_b, [%{"id" => "2", "content" => "B", "status" => "completed", "priority" => "low"}])

      result_a = TodoRead.execute("call_1", %{}, nil, nil, session_a)
      result_b = TodoRead.execute("call_2", %{}, nil, nil, session_b)

      assert hd(result_a.details.todos)["content"] == "A"
      assert hd(result_b.details.todos)["content"] == "B"
      assert result_a.details.title == "1 todos"
      assert result_b.details.title == "0 todos"
    end
  end

  describe "execute/5 - missing session_id" do
    test "returns error when session_id is empty string" do
      result = TodoRead.execute("call_1", %{}, nil, nil, "")
      assert {:error, "Session id not available"} = result
    end
  end

  describe "execute/5 - abort signal" do
    test "returns error when signal is aborted" do
      signal = AbortSignal.new()
      AbortSignal.abort(signal)
      result = TodoRead.execute("call_1", %{}, signal, nil, "any-session")
      assert {:error, "Operation aborted"} = result
    end

    test "proceeds when signal is not aborted", %{session_id: session_id} do
      signal = AbortSignal.new()
      result = TodoRead.execute("call_1", %{}, signal, nil, session_id)
      assert %AgentToolResult{} = result
    end

    test "proceeds when signal is nil", %{session_id: session_id} do
      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)
      assert %AgentToolResult{} = result
    end
  end

  describe "execute/5 - ignores params" do
    test "ignores arbitrary params passed to it", %{session_id: session_id} do
      result = TodoRead.execute("call_1", %{"foo" => "bar", "extra" => 123}, nil, nil, session_id)
      assert %AgentToolResult{} = result
    end
  end
end
