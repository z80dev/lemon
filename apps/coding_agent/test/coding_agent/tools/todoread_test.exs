defmodule CodingAgent.Tools.TodoReadTest do
  @moduledoc """
  Tests for CodingAgent.Tools.TodoRead.

  Tests tool definition and execute behavior.
  Uses async: false because TodoStore uses a global ETS table.
  """
  use ExUnit.Case, async: false

  alias CodingAgent.Tools.TodoRead
  alias CodingAgent.Tools.TodoStore

  # ============================================================================
  # Setup
  # ============================================================================

  setup do
    # Ensure table exists
    _ = TodoStore.get("__init__")
    TodoStore.clear()

    session_id = "todoread-test-#{:erlang.unique_integer([:positive])}"
    {:ok, session_id: session_id}
  end

  # ============================================================================
  # Tool Definition
  # ============================================================================

  describe "tool/2" do
    test "returns a valid tool definition" do
      tool = TodoRead.tool("/tmp")
      assert tool.name == "todoread"
      assert is_binary(tool.description)
      assert tool.parameters["required"] == []
    end

    test "accepts session_id option" do
      tool = TodoRead.tool("/tmp", session_id: "my-session")
      assert tool.name == "todoread"
    end
  end

  # ============================================================================
  # Execute
  # ============================================================================

  describe "execute/5" do
    test "returns empty todo list for new session", %{session_id: session_id} do
      result = TodoRead.execute("tc1", %{}, nil, nil, session_id)

      assert %{content: [%{text: text}], details: details} = result
      assert text == "[]"
      assert details.title == "0 todos"
      assert details.todos == []
    end

    test "returns stored todos", %{session_id: session_id} do
      todos = [
        %{"id" => "1", "content" => "Do thing", "status" => "pending"},
        %{"id" => "2", "content" => "Done thing", "status" => "completed"}
      ]

      TodoStore.put(session_id, todos)

      result = TodoRead.execute("tc1", %{}, nil, nil, session_id)

      assert %{content: [%{text: text}], details: details} = result
      assert details.title == "1 todos"
      assert length(details.todos) == 2

      # Verify it's valid JSON
      decoded = Jason.decode!(text)
      assert length(decoded) == 2
    end

    test "counts only non-completed todos for title", %{session_id: session_id} do
      todos = [
        %{"id" => "1", "content" => "Pending", "status" => "pending"},
        %{"id" => "2", "content" => "In progress", "status" => "in_progress"},
        %{"id" => "3", "content" => "Done", "status" => "completed"}
      ]

      TodoStore.put(session_id, todos)

      result = TodoRead.execute("tc1", %{}, nil, nil, session_id)
      assert result.details.title == "2 todos"
    end

    test "returns error for empty session_id" do
      result = TodoRead.execute("tc1", %{}, nil, nil, "")
      assert {:error, msg} = result
      assert msg =~ "Session id"
    end
  end
end
