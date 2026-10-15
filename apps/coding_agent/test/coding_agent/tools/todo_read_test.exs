defmodule CodingAgent.Tools.TodoReadTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{Session, SessionManager}
  alias CodingAgent.Tools.{TodoRead, TodoStore, TodoWrite}
  alias LemonAgent.Test.Mocks
  alias LemonAgent.Types.AgentToolResult
  alias LemonAgent.AbortSignal
  alias LemonAi.Types.TextContent

  setup do
    {:ok, session_pid: start_session()}
  end

  defp start_session do
    cwd = Path.join(System.tmp_dir!(), "todo-read-#{System.unique_integer([:positive])}")
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
         stream_fn: Mocks.mock_stream_fn_single(Mocks.assistant_message("ok"))},
        id: session_file
      )

    session_id = Session.get_state(session_pid).session_manager.header.id

    on_exit(fn ->
      TodoStore.delete(session_id)
      File.rm_rf!(cwd)
    end)

    session_pid
  end

  # ============================================================================
  # Tool Definition Tests
  # ============================================================================

  describe "tool/2" do
    test "refuses to execute without a session binding" do
      tool = TodoRead.tool("/tmp")
      assert {:error, _reason} = tool.execute.("read", %{}, nil, nil)
    end

    test "reads the bound session regardless of cwd", %{session_pid: session_pid} do
      todos = [%{"id" => "1", "content" => "Task", "status" => "pending", "priority" => "high"}]

      assert %AgentToolResult{} =
               TodoWrite.execute("seed", %{"todos" => todos}, nil, nil, session_pid)

      for cwd <- ["/tmp", "/var/log"] do
        tool = TodoRead.tool(cwd, session_pid: session_pid)
        assert %AgentToolResult{details: %{todos: ^todos}} = tool.execute.("read", %{}, nil, nil)
      end
    end
  end

  # ============================================================================
  # Reading Todo Lists from Session Storage
  # ============================================================================

  describe "execute/5 - reading todos from session storage" do
    test "returns stored todos", %{session_pid: session_pid} do
      todos = [
        %{"id" => "1", "content" => "Task 1", "status" => "pending", "priority" => "high"},
        %{"id" => "2", "content" => "Task 2", "status" => "completed", "priority" => "low"}
      ]

      assert %AgentToolResult{} =
               TodoWrite.execute("seed", %{"todos" => todos}, nil, nil, session_pid)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_pid)

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "Task 1"
      assert text =~ "Task 2"
      assert details.todos == todos
    end

    test "returns todos with all statuses", %{session_pid: session_pid} do
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

      assert %AgentToolResult{} =
               TodoWrite.execute("seed", %{"todos" => todos}, nil, nil, session_pid)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_pid)

      assert %AgentToolResult{details: details} = result
      assert details.todos == todos
      # 2 non-completed
      assert details.title == "2 todos"
    end

    test "returns todos with all priorities", %{session_pid: session_pid} do
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

      assert %AgentToolResult{} =
               TodoWrite.execute("seed", %{"todos" => todos}, nil, nil, session_pid)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_pid)

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "high"
      assert text =~ "medium"
      assert text =~ "low"
      assert details.title == "3 todos"
    end

    test "isolates todos between sessions" do
      session1 = start_session()
      session2 = start_session()

      todos1 = [
        %{"id" => "1", "content" => "Session 1 task", "status" => "pending", "priority" => "high"}
      ]

      todos2 = [
        %{"id" => "2", "content" => "Session 2 task", "status" => "pending", "priority" => "low"}
      ]

      assert %AgentToolResult{} =
               TodoWrite.execute("seed", %{"todos" => todos1}, nil, nil, session1)

      assert %AgentToolResult{} =
               TodoWrite.execute("seed", %{"todos" => todos2}, nil, nil, session2)

      result1 = TodoRead.execute("call_1", %{}, nil, nil, session1)
      result2 = TodoRead.execute("call_2", %{}, nil, nil, session2)

      assert %AgentToolResult{details: %{todos: read_todos1}} = result1
      assert %AgentToolResult{details: %{todos: read_todos2}} = result2

      assert read_todos1 == todos1
      assert read_todos2 == todos2
    end

    test "returns most recent todos after updates", %{session_pid: session_pid} do
      original_todos = [
        %{"id" => "1", "content" => "Original", "status" => "pending", "priority" => "high"}
      ]

      updated_todos = [
        %{"id" => "2", "content" => "Updated", "status" => "completed", "priority" => "low"}
      ]

      assert %AgentToolResult{} =
               TodoWrite.execute("seed", %{"todos" => original_todos}, nil, nil, session_pid)

      assert %AgentToolResult{} =
               TodoWrite.execute("seed", %{"todos" => updated_todos}, nil, nil, session_pid)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_pid)

      assert %AgentToolResult{details: %{todos: read_todos}} = result
      assert read_todos == updated_todos
    end

    test "returns todos with extra fields", %{session_pid: session_pid} do
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

      assert %AgentToolResult{} =
               TodoWrite.execute("seed", %{"todos" => todos}, nil, nil, session_pid)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_pid)

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
    test "returns empty list when no todos exist", %{session_pid: session_pid} do
      result = TodoRead.execute("call_1", %{}, nil, nil, session_pid)

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text == "[]"
      assert details.todos == []
    end

    test "returns 0 todos count for empty list", %{session_pid: session_pid} do
      result = TodoRead.execute("call_1", %{}, nil, nil, session_pid)

      assert %AgentToolResult{details: details} = result
      assert details.title == "0 todos"
    end

    test "returns empty list after an explicit empty write", %{session_pid: session_pid} do
      todos = [%{"id" => "1", "content" => "Task", "status" => "pending", "priority" => "high"}]

      assert %AgentToolResult{} =
               TodoWrite.execute("seed", %{"todos" => todos}, nil, nil, session_pid)

      assert %AgentToolResult{} =
               TodoWrite.execute("seed", %{"todos" => []}, nil, nil, session_pid)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_pid)

      assert %AgentToolResult{details: details} = result
      assert details.todos == []
      assert details.title == "0 todos"
    end
  end

  describe "execute/5 - session validation" do
    test "refuses a missing session" do
      assert {:error, _reason} = TodoRead.execute("read", %{}, nil, nil, nil)
    end
  end

  # ============================================================================
  # JSON Encoding Edge Cases
  # ============================================================================

  describe "execute/5 - JSON encoding edge cases" do
    test "encodes empty array as []", %{session_pid: session_pid} do
      result = TodoRead.execute("call_1", %{}, nil, nil, session_pid)

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text == "[]"
    end

    test "encodes unicode and special JSON content", %{session_pid: session_pid} do
      todos = [
        %{
          "id" => "1",
          "content" => "café 中文 العربية \"quotes\" \\backslash\nnext line",
          "status" => "pending",
          "priority" => "high"
        }
      ]

      assert %AgentToolResult{} =
               TodoWrite.execute("seed", %{"todos" => todos}, nil, nil, session_pid)

      result = TodoRead.execute("read", %{}, nil, nil, session_pid)
      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert Jason.decode!(text) == todos
    end

    test "encodes todos with special JSON characters", %{session_pid: session_pid} do
      todos = [
        %{
          "id" => "1",
          "content" => "Task with \"quotes\" and \\backslash",
          "status" => "pending",
          "priority" => "high"
        }
      ]

      assert %AgentToolResult{} =
               TodoWrite.execute("seed", %{"todos" => todos}, nil, nil, session_pid)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_pid)

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      # Should be properly escaped
      assert String.contains?(text, "quotes")
      assert String.contains?(text, "backslash")
      # Verify it's valid JSON
      assert {:ok, _} = Jason.decode(text)
    end

    test "encodes todos with newlines in content", %{session_pid: session_pid} do
      todos = [
        %{
          "id" => "1",
          "content" => "Line 1\nLine 2\nLine 3",
          "status" => "pending",
          "priority" => "high"
        }
      ]

      assert %AgentToolResult{} =
               TodoWrite.execute("seed", %{"todos" => todos}, nil, nil, session_pid)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_pid)

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      # Verify it's valid JSON and contains the content
      assert {:ok, decoded} = Jason.decode(text)
      assert hd(decoded)["content"] =~ "Line 1"
    end

    test "encodes todos with nested structures", %{session_pid: session_pid} do
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

      assert %AgentToolResult{} =
               TodoWrite.execute("seed", %{"todos" => todos}, nil, nil, session_pid)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_pid)

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert {:ok, decoded} = Jason.decode(text)
      assert hd(decoded)["metadata"]["tags"] == ["urgent", "review"]
    end

    test "pretty prints JSON output", %{session_pid: session_pid} do
      todos = [
        %{"id" => "1", "content" => "Task", "status" => "pending", "priority" => "high"}
      ]

      assert %AgentToolResult{} =
               TodoWrite.execute("seed", %{"todos" => todos}, nil, nil, session_pid)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_pid)

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      # Pretty printed JSON should have newlines
      assert text =~ "\n"
    end

    test "handles todos with null values", %{session_pid: session_pid} do
      todos = [
        %{
          "id" => "1",
          "content" => "Task",
          "status" => "pending",
          "priority" => "high",
          "optional_field" => nil
        }
      ]

      assert %AgentToolResult{} =
               TodoWrite.execute("seed", %{"todos" => todos}, nil, nil, session_pid)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_pid)

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "null"
    end

    test "handles todos with numeric values", %{session_pid: session_pid} do
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

      assert %AgentToolResult{} =
               TodoWrite.execute("seed", %{"todos" => todos}, nil, nil, session_pid)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_pid)

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "42"
      assert text =~ "3.14"
    end

    test "handles todos with boolean values", %{session_pid: session_pid} do
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

      assert %AgentToolResult{} =
               TodoWrite.execute("seed", %{"todos" => todos}, nil, nil, session_pid)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_pid)

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "true"
      assert text =~ "false"
    end
  end

  # ============================================================================
  # Concurrent Reads
  # ============================================================================

  describe "execute/5 - concurrent reads" do
    test "supports concurrent reads", %{session_pid: session_pid} do
      session = session_pid
      todos = [%{"id" => "1", "content" => "Task", "status" => "pending", "priority" => "high"}]

      assert %AgentToolResult{} =
               TodoWrite.execute("seed", %{"todos" => todos}, nil, nil, session)

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
    test "ignores extra parameters in params map", %{session_pid: session_pid} do
      todos = [%{"id" => "1", "content" => "Task", "status" => "pending", "priority" => "high"}]

      assert %AgentToolResult{} =
               TodoWrite.execute("seed", %{"todos" => todos}, nil, nil, session_pid)

      # Extra params should be ignored
      result =
        TodoRead.execute("call_1", %{"extra" => "param", "another" => 123}, nil, nil, session_pid)

      assert %AgentToolResult{details: %{todos: ^todos}} = result
    end

    test "result has correct content structure", %{session_pid: session_pid} do
      todos = [%{"id" => "1", "content" => "Task", "status" => "pending", "priority" => "high"}]

      assert %AgentToolResult{} =
               TodoWrite.execute("seed", %{"todos" => todos}, nil, nil, session_pid)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_pid)

      assert %AgentToolResult{content: content} = result
      assert is_list(content)
      assert length(content) == 1
      assert %TextContent{text: text} = hd(content)
      assert is_binary(text)
    end

    test "result details include title and todos", %{session_pid: session_pid} do
      todos = [
        %{"id" => "1", "content" => "Task 1", "status" => "pending", "priority" => "high"},
        %{"id" => "2", "content" => "Task 2", "status" => "completed", "priority" => "low"}
      ]

      assert %AgentToolResult{} =
               TodoWrite.execute("seed", %{"todos" => todos}, nil, nil, session_pid)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_pid)

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
    test "returns error when signal is already aborted", %{session_pid: session_pid} do
      signal = AbortSignal.new()
      AbortSignal.abort(signal)

      result = TodoRead.execute("call_1", %{}, signal, nil, session_pid)

      AbortSignal.clear(signal)

      assert {:error, "Operation aborted"} = result
    end

    test "proceeds normally when signal is not aborted", %{session_pid: session_pid} do
      signal = AbortSignal.new()

      result = TodoRead.execute("call_1", %{}, signal, nil, session_pid)

      AbortSignal.clear(signal)

      assert %AgentToolResult{} = result
    end

    test "abort check happens before session validation" do
      signal = AbortSignal.new()
      AbortSignal.abort(signal)

      result = TodoRead.execute("call_1", %{}, signal, nil, nil)

      AbortSignal.clear(signal)

      assert {:error, "Operation aborted"} = result
    end
  end

  # ============================================================================
  # Open Todo Count
  # ============================================================================

  describe "execute/5 - open todo count" do
    test "counts pending todos as open", %{session_pid: session_pid} do
      todos = [
        %{"id" => "1", "content" => "Pending 1", "status" => "pending", "priority" => "high"},
        %{"id" => "2", "content" => "Pending 2", "status" => "pending", "priority" => "low"}
      ]

      assert %AgentToolResult{} =
               TodoWrite.execute("seed", %{"todos" => todos}, nil, nil, session_pid)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_pid)

      assert %AgentToolResult{details: %{title: "2 todos"}} = result
    end

    test "counts in_progress todos as open", %{session_pid: session_pid} do
      todos = [
        %{
          "id" => "1",
          "content" => "In progress",
          "status" => "in_progress",
          "priority" => "high"
        }
      ]

      assert %AgentToolResult{} =
               TodoWrite.execute("seed", %{"todos" => todos}, nil, nil, session_pid)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_pid)

      assert %AgentToolResult{details: %{title: "1 todos"}} = result
    end

    test "excludes completed todos from count", %{session_pid: session_pid} do
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

      assert %AgentToolResult{} =
               TodoWrite.execute("seed", %{"todos" => todos}, nil, nil, session_pid)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_pid)

      assert %AgentToolResult{details: %{title: "1 todos"}} = result
    end

    test "all completed shows 0 todos", %{session_pid: session_pid} do
      todos = [
        %{"id" => "1", "content" => "Done 1", "status" => "completed", "priority" => "high"},
        %{"id" => "2", "content" => "Done 2", "status" => "completed", "priority" => "low"}
      ]

      assert %AgentToolResult{} =
               TodoWrite.execute("seed", %{"todos" => todos}, nil, nil, session_pid)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_pid)

      assert %AgentToolResult{details: %{title: "0 todos"}} = result
    end

    test "mixed statuses are counted correctly", %{session_pid: session_pid} do
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

      assert %AgentToolResult{} =
               TodoWrite.execute("seed", %{"todos" => todos}, nil, nil, session_pid)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_pid)

      # pending + in_progress = 2 open
      assert %AgentToolResult{details: %{title: "2 todos"}} = result
    end
  end

  # ============================================================================
  # Edge Cases
  # ============================================================================

  describe "execute/5 - edge cases" do
    test "handles large number of todos", %{session_pid: session_pid} do
      todos =
        Enum.map(1..1000, fn i ->
          %{
            "id" => "#{i}",
            "content" => "Task #{i}",
            "status" => if(rem(i, 2) == 0, do: "completed", else: "pending"),
            "priority" => Enum.at(["high", "medium", "low"], rem(i, 3))
          }
        end)

      assert %AgentToolResult{} =
               TodoWrite.execute("seed", %{"todos" => todos}, nil, nil, session_pid)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_pid)

      assert %AgentToolResult{details: details} = result
      assert length(details.todos) == 1000
      # 500 pending (odd numbers)
      assert details.title == "500 todos"
    end

    test "handles todos with very long content", %{session_pid: session_pid} do
      long_content = String.duplicate("x", 10_000)

      todos = [
        %{"id" => "1", "content" => long_content, "status" => "pending", "priority" => "high"}
      ]

      assert %AgentToolResult{} =
               TodoWrite.execute("seed", %{"todos" => todos}, nil, nil, session_pid)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_pid)

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ String.slice(long_content, 0, 100)
    end

    test "handles todos without optional fields", %{session_pid: session_pid} do
      todos = [
        %{"id" => "1", "content" => "Minimal todo", "status" => "pending", "priority" => "high"}
      ]

      assert %AgentToolResult{} =
               TodoWrite.execute("seed", %{"todos" => todos}, nil, nil, session_pid)

      result = TodoRead.execute("call_1", %{}, nil, nil, session_pid)

      assert %AgentToolResult{details: %{todos: ^todos}} = result
    end

    test "handles unique tool_call_id values", %{session_pid: session_pid} do
      todos = [%{"id" => "1", "content" => "Task", "status" => "pending", "priority" => "high"}]

      assert %AgentToolResult{} =
               TodoWrite.execute("seed", %{"todos" => todos}, nil, nil, session_pid)

      result1 = TodoRead.execute("unique-call-id-123", %{}, nil, nil, session_pid)
      result2 = TodoRead.execute("another-unique-id", %{}, nil, nil, session_pid)

      # Both should succeed regardless of tool_call_id
      assert %AgentToolResult{} = result1
      assert %AgentToolResult{} = result2
    end
  end
end
