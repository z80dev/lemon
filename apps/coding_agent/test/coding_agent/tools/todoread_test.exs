defmodule CodingAgent.Tools.TodoReadTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Tools.TodoRead
  alias CodingAgent.Tools.TodoStore
  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias AgentCore.AbortSignal
  alias Ai.Types.TextContent

  setup do
    session_id = "todoread_test_#{System.unique_integer([:positive])}"
    # Ensure table exists
    _ = TodoStore.get("__init__")
    TodoStore.put(session_id, [])

    on_exit(fn ->
      TodoStore.delete(session_id)
    end)

    {:ok, session_id: session_id}
  end

  # ── tool/2 ──────────────────────────────────────────────────────────

  describe "tool/2" do
    test "returns an AgentTool struct" do
      tool = TodoRead.tool("/tmp")
      assert %AgentTool{} = tool
    end

    test "has correct name, label, and description" do
      tool = TodoRead.tool("/tmp")
      assert tool.name == "todoread"
      assert tool.label == "Read Todos"
      assert tool.description == "Read the session todo list."
    end

    test "defines empty parameters schema" do
      tool = TodoRead.tool("/tmp")
      assert tool.parameters["type"] == "object"
      assert tool.parameters["properties"] == %{}
      assert tool.parameters["required"] == []
    end

    test "execute function has arity 4" do
      tool = TodoRead.tool("/tmp")
      assert is_function(tool.execute, 4)
    end

    test "captures session_id from opts" do
      tool = TodoRead.tool("/tmp", session_id: "my-session")
      # The execute function should have the session_id baked in;
      # we verify by calling it with an empty store and checking no error
      TodoStore.put("my-session", [])
      result = tool.execute.("call_1", %{}, nil, nil)
      assert %AgentToolResult{} = result
      TodoStore.delete("my-session")
    end

    test "defaults session_id to empty string when not provided" do
      tool = TodoRead.tool("/tmp")
      result = tool.execute.("call_1", %{}, nil, nil)
      assert {:error, "Session id not available"} = result
    end

    test "ignores cwd parameter" do
      tool_a = TodoRead.tool("/tmp/a", session_id: "s1")
      tool_b = TodoRead.tool("/tmp/b", session_id: "s1")
      assert tool_a.name == tool_b.name
      assert tool_a.description == tool_b.description
      assert tool_a.parameters == tool_b.parameters
    end
  end

  # ── execute/5 – empty todo list ─────────────────────────────────────

  describe "execute/5 with empty todo list" do
    test "returns AgentToolResult with empty JSON array", %{session_id: session_id} do
      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert Jason.decode!(text) == []
    end

    test "reports 0 open todos in details", %{session_id: session_id} do
      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)

      assert %AgentToolResult{details: details} = result
      assert details.title == "0 todos"
      assert details.todos == []
    end
  end

  # ── execute/5 – with todos ─────────────────────────────────────────

  describe "execute/5 with todos in various statuses" do
    test "returns all stored todos as JSON", %{session_id: session_id} do
      todos = [
        %{"id" => "1", "content" => "First", "status" => "pending"},
        %{"id" => "2", "content" => "Second", "status" => "in_progress"},
        %{"id" => "3", "content" => "Third", "status" => "completed"}
      ]

      TodoStore.put(session_id, todos)
      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      parsed = Jason.decode!(text)
      assert length(parsed) == 3
      assert Enum.map(parsed, & &1["id"]) == ["1", "2", "3"]
    end

    test "counts only non-completed todos as open", %{session_id: session_id} do
      todos = [
        %{"id" => "1", "content" => "Pending", "status" => "pending"},
        %{"id" => "2", "content" => "In progress", "status" => "in_progress"},
        %{"id" => "3", "content" => "Done", "status" => "completed"},
        %{"id" => "4", "content" => "Also done", "status" => "completed"}
      ]

      TodoStore.put(session_id, todos)
      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)

      assert result.details.title == "2 todos"
    end

    test "counts all as open when none are completed", %{session_id: session_id} do
      todos = [
        %{"id" => "1", "content" => "Task A", "status" => "pending"},
        %{"id" => "2", "content" => "Task B", "status" => "in_progress"}
      ]

      TodoStore.put(session_id, todos)
      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)

      assert result.details.title == "2 todos"
    end

    test "counts 0 open when all are completed", %{session_id: session_id} do
      todos = [
        %{"id" => "1", "content" => "Done A", "status" => "completed"},
        %{"id" => "2", "content" => "Done B", "status" => "completed"}
      ]

      TodoStore.put(session_id, todos)
      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)

      assert result.details.title == "0 todos"
    end

    test "includes todos list in details", %{session_id: session_id} do
      todos = [%{"id" => "1", "content" => "Check me", "status" => "pending"}]
      TodoStore.put(session_id, todos)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)

      assert result.details.todos == todos
    end

    test "returns pretty-printed JSON", %{session_id: session_id} do
      todos = [%{"id" => "1", "content" => "Pretty", "status" => "pending"}]
      TodoStore.put(session_id, todos)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_id)
      assert %AgentToolResult{content: [%TextContent{text: text}]} = result

      # Pretty JSON has newlines
      assert text =~ "\n"
      # And should decode to the same data
      assert Jason.decode!(text) == todos
    end
  end

  # ── execute/5 – non-existent session ────────────────────────────────

  describe "execute/5 with non-existent session" do
    test "returns empty list for session that was never written to" do
      fresh_id = "never_written_#{System.unique_integer([:positive])}"
      result = TodoRead.execute("call_1", %{}, nil, nil, fresh_id)

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert Jason.decode!(text) == []
      assert result.details.title == "0 todos"
    end
  end

  # ── execute/5 – error cases ─────────────────────────────────────────

  describe "execute/5 with missing session_id" do
    test "returns error when session_id is empty string" do
      result = TodoRead.execute("call_1", %{}, nil, nil, "")
      assert {:error, "Session id not available"} = result
    end
  end

  describe "execute/5 with abort signal" do
    test "returns error when signal is aborted", %{session_id: session_id} do
      signal = AbortSignal.new()
      AbortSignal.abort(signal)

      result = TodoRead.execute("call_1", %{}, signal, nil, session_id)
      assert {:error, "Operation aborted"} = result
    end

    test "does not read store when aborted", %{session_id: session_id} do
      todos = [%{"id" => "1", "content" => "Should not appear", "status" => "pending"}]
      TodoStore.put(session_id, todos)

      signal = AbortSignal.new()
      AbortSignal.abort(signal)

      result = TodoRead.execute("call_1", %{}, signal, nil, session_id)
      assert {:error, "Operation aborted"} = result
    end

    test "succeeds with non-aborted signal", %{session_id: session_id} do
      signal = AbortSignal.new()
      result = TodoRead.execute("call_1", %{}, signal, nil, session_id)
      assert %AgentToolResult{} = result
    end
  end

  # ── execute/5 – ignores params ──────────────────────────────────────

  describe "execute/5 ignores arbitrary params" do
    test "extra params do not affect output", %{session_id: session_id} do
      todos = [%{"id" => "1", "content" => "Task", "status" => "pending"}]
      TodoStore.put(session_id, todos)

      result_empty = TodoRead.execute("call_1", %{}, nil, nil, session_id)
      result_extra = TodoRead.execute("call_2", %{"foo" => "bar", "baz" => 42}, nil, nil, session_id)

      text_empty = hd(result_empty.content).text
      text_extra = hd(result_extra.content).text

      assert Jason.decode!(text_empty) == Jason.decode!(text_extra)
      assert result_empty.details.title == result_extra.details.title
    end
  end
end
