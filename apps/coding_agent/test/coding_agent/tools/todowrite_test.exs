defmodule CodingAgent.Tools.TodoWriteToolTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{Session, SessionManager}
  alias LemonAgent.Test.Mocks
  alias CodingAgent.Tools.TodoWrite
  alias CodingAgent.Tools.TodoRead
  alias CodingAgent.Tools.TodoStore
  alias LemonAgent.Types.AgentToolResult
  alias LemonAgent.AbortSignal
  alias LemonAi.Types.TextContent

  setup do
    cwd = Path.join(System.tmp_dir!(), "todowrite-#{System.unique_integer([:positive])}")
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
         stream_fn: Mocks.mock_stream_fn_single(Mocks.assistant_message("ok"))}
      )

    session_id = Session.get_state(session_pid).session_manager.header.id

    on_exit(fn ->
      TodoStore.delete(session_id)
      File.rm_rf!(cwd)
    end)

    {:ok, session_pid: session_pid, session_id: session_id}
  end

  defp valid_todo(overrides \\ %{}) do
    Map.merge(
      %{"id" => "1", "content" => "Test task", "status" => "pending", "priority" => "high"},
      overrides
    )
  end

  describe "tool/2" do
    test "session-bound closure journals todos with defaults", %{session_pid: session_pid} do
      tool = TodoWrite.tool("/tmp", session_pid: session_pid)

      assert %AgentToolResult{details: %{todos: [todo]}} =
               tool.execute.("write", %{"todos" => [%{"content" => "Inspect"}]}, nil, nil)

      assert todo["content"] == "Inspect"
      assert todo["status"] == "pending"
      assert todo["priority"] == "medium"
      assert is_binary(todo["id"]) and todo["id"] != ""
      assert {:ok, [^todo], _revision} = Session.todos(session_pid)
    end
  end

  describe "execute/5 - valid todos" do
    test "stores a single valid todo", %{session_pid: session_pid} do
      todos = [valid_todo()]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_pid)

      assert %AgentToolResult{} = result
      assert [%TextContent{text: text}] = result.content
      parsed = Jason.decode!(text)
      assert length(parsed) == 1
      assert hd(parsed)["content"] == "Test task"
    end

    test "stores multiple valid todos with mixed statuses and priorities", %{
      session_pid: session_pid
    } do
      todos = [
        valid_todo(%{
          "id" => "1",
          "content" => "First",
          "status" => "pending",
          "priority" => "high"
        }),
        valid_todo(%{
          "id" => "2",
          "content" => "Second",
          "status" => "in_progress",
          "priority" => "medium"
        }),
        valid_todo(%{
          "id" => "3",
          "content" => "Third",
          "status" => "completed",
          "priority" => "low"
        })
      ]

      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_pid)
      assert %AgentToolResult{} = result
      assert length(result.details.todos) == 3
    end

    test "returns correct open count excluding completed", %{session_pid: session_pid} do
      todos = [
        valid_todo(%{"id" => "1", "status" => "pending"}),
        valid_todo(%{"id" => "2", "status" => "in_progress"}),
        valid_todo(%{"id" => "3", "status" => "completed"})
      ]

      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_pid)
      assert result.details.title == "2 todos"
    end

    test "projects journaled todos into the native session cache", %{
      session_pid: session_pid,
      session_id: session_id
    } do
      todos = [valid_todo()]
      TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_pid)
      stored = TodoStore.get(session_id)
      assert length(stored) == 1
      assert hd(stored)["content"] == "Test task"
      assert {:ok, ^stored, _revision} = Session.todos(session_pid)
    end

    test "overwrites previous todos", %{session_pid: session_pid} do
      first = [valid_todo(%{"id" => "1", "content" => "First"})]
      TodoWrite.execute("call_1", %{"todos" => first}, nil, nil, session_pid)

      second = [valid_todo(%{"id" => "2", "content" => "Second"})]
      TodoWrite.execute("call_2", %{"todos" => second}, nil, nil, session_pid)

      assert {:ok, stored, _revision} = Session.todos(session_pid)
      assert length(stored) == 1
      assert hd(stored)["content"] == "Second"
    end

    test "accepts empty todo list", %{session_pid: session_pid} do
      result = TodoWrite.execute("call_1", %{"todos" => []}, nil, nil, session_pid)
      assert %AgentToolResult{} = result
      assert result.details.title == "0 todos"
      assert {:ok, [], _revision} = Session.todos(session_pid)
    end

    test "handles special characters in content", %{session_pid: session_pid} do
      todos = [valid_todo(%{"content" => "Task with \"quotes\" & <angles>"})]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_pid)
      parsed = Jason.decode!(hd(result.content).text)
      assert hd(parsed)["content"] == "Task with \"quotes\" & <angles>"
    end
  end

  describe "execute/5 - invalid status" do
    test "rejects unknown status value", %{session_pid: session_pid} do
      todos = [valid_todo(%{"status" => "done"})]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_pid)
      assert {:error, _reason} = result
      assert {:ok, [], _revision} = Session.todos(session_pid)
    end

    test "rejects empty string status", %{session_pid: session_pid} do
      todos = [valid_todo(%{"status" => ""})]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_pid)
      assert {:error, _reason} = result
      assert {:ok, [], _revision} = Session.todos(session_pid)
    end

    test "rejects non-string status", %{session_pid: session_pid} do
      todos = [valid_todo() |> Map.put("status", 42)]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_pid)
      assert {:error, _reason} = result
      assert {:ok, [], _revision} = Session.todos(session_pid)
    end
  end

  describe "execute/5 - invalid priority" do
    test "rejects unknown priority value", %{session_pid: session_pid} do
      todos = [valid_todo(%{"priority" => "urgent"})]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_pid)
      assert {:error, _reason} = result
      assert {:ok, [], _revision} = Session.todos(session_pid)
    end

    test "rejects empty string priority", %{session_pid: session_pid} do
      todos = [valid_todo(%{"priority" => ""})]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_pid)
      assert {:error, _reason} = result
      assert {:ok, [], _revision} = Session.todos(session_pid)
    end

    test "rejects non-string priority", %{session_pid: session_pid} do
      todos = [valid_todo() |> Map.put("priority", true)]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_pid)
      assert {:error, _reason} = result
      assert {:ok, [], _revision} = Session.todos(session_pid)
    end
  end

  describe "execute/5 - missing fields" do
    test "generates an id when omitted", %{session_pid: session_pid} do
      todos = [%{"content" => "No id", "status" => "pending", "priority" => "high"}]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_pid)
      assert %AgentToolResult{details: %{todos: [todo]}} = result
      assert is_binary(todo["id"])
      assert todo["id"] != ""
      assert {:ok, [^todo], _revision} = Session.todos(session_pid)
    end

    test "rejects todo missing content", %{session_pid: session_pid} do
      todos = [%{"id" => "1", "status" => "pending", "priority" => "high"}]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_pid)
      assert {:error, _reason} = result
      assert {:ok, [], _revision} = Session.todos(session_pid)
    end

    test "defaults omitted status to pending", %{session_pid: session_pid} do
      todos = [%{"id" => "1", "content" => "No status", "priority" => "high"}]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_pid)
      assert %AgentToolResult{details: %{todos: [todo]}} = result
      assert todo["status"] == "pending"
    end

    test "defaults omitted priority to medium", %{session_pid: session_pid} do
      todos = [%{"id" => "1", "content" => "No priority", "status" => "pending"}]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_pid)
      assert %AgentToolResult{details: %{todos: [todo]}} = result
      assert todo["priority"] == "medium"
    end
  end

  describe "execute/5 - duplicate IDs" do
    test "rejects todos with duplicate ids", %{session_pid: session_pid} do
      todos = [
        valid_todo(%{"id" => "dup", "content" => "First"}),
        valid_todo(%{"id" => "dup", "content" => "Second"})
      ]

      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_pid)
      assert {:error, _reason} = result
    end
  end

  describe "execute/5 - empty and whitespace content" do
    test "rejects todo with empty content string", %{session_pid: session_pid} do
      todos = [valid_todo(%{"content" => ""})]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_pid)
      assert {:error, _reason} = result
      assert {:ok, [], _revision} = Session.todos(session_pid)
    end

    test "rejects todo with whitespace-only content", %{session_pid: session_pid} do
      todos = [valid_todo(%{"content" => "   "})]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_pid)
      assert {:error, _reason} = result
      assert {:ok, [], _revision} = Session.todos(session_pid)
    end

    test "rejects todo with empty id", %{session_pid: session_pid} do
      todos = [valid_todo(%{"id" => ""})]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_pid)
      assert {:error, _reason} = result
      assert {:ok, [], _revision} = Session.todos(session_pid)
    end

    test "rejects todo with whitespace-only id", %{session_pid: session_pid} do
      todos = [valid_todo(%{"id" => "  \t  "})]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_pid)
      assert {:error, _reason} = result
      assert {:ok, [], _revision} = Session.todos(session_pid)
    end
  end

  describe "execute/5 - non-string and invalid types" do
    test "rejects integer content", %{session_pid: session_pid} do
      todos = [valid_todo() |> Map.put("content", 123)]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_pid)
      assert {:error, _reason} = result
      assert {:ok, [], _revision} = Session.todos(session_pid)
    end

    test "rejects integer id", %{session_pid: session_pid} do
      todos = [valid_todo() |> Map.put("id", 999)]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_pid)
      assert {:error, _reason} = result
      assert {:ok, [], _revision} = Session.todos(session_pid)
    end

    test "rejects non-list todos param", %{session_pid: session_pid} do
      result = TodoWrite.execute("call_1", %{"todos" => "not a list"}, nil, nil, session_pid)
      assert {:error, _reason} = result
    end

    test "rejects non-map entry in todos array", %{session_pid: session_pid} do
      todos = ["not a map"]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_pid)
      assert {:error, _reason} = result
      assert {:ok, [], _revision} = Session.todos(session_pid)
    end
  end

  describe "execute/5 - abort signal" do
    test "returns error when signal is aborted", %{session_pid: session_pid} do
      signal = AbortSignal.new()
      AbortSignal.abort(signal)
      todos = [valid_todo()]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, signal, nil, session_pid)
      AbortSignal.clear(signal)
      assert {:error, "Operation aborted"} = result
    end

    test "does not store when aborted", %{session_pid: session_pid} do
      signal = AbortSignal.new()
      AbortSignal.abort(signal)
      todos = [valid_todo(%{"content" => "Should not be stored"})]
      TodoWrite.execute("call_1", %{"todos" => todos}, signal, nil, session_pid)
      AbortSignal.clear(signal)
      assert {:ok, [], _revision} = Session.todos(session_pid)
    end

    test "proceeds when signal is not aborted", %{session_pid: session_pid} do
      signal = AbortSignal.new()
      todos = [valid_todo()]
      result = TodoWrite.execute("call_1", %{"todos" => todos}, signal, nil, session_pid)
      AbortSignal.clear(signal)
      assert %AgentToolResult{} = result
    end
  end

  describe "execute/5 - missing session" do
    test "returns an error without a session binding" do
      assert {:error, _reason} =
               TodoWrite.execute("write", %{"todos" => [valid_todo()]}, nil, nil, nil)
    end
  end

  describe "execute/5 - whole-list validation" do
    test "rejects an invalid second todo without saving a partial list", %{
      session_pid: session_pid
    } do
      todos = [
        valid_todo(%{"id" => "1"}),
        valid_todo(%{"id" => "2", "status" => "invalid"})
      ]

      result = TodoWrite.execute("call_1", %{"todos" => todos}, nil, nil, session_pid)
      assert {:error, _reason} = result
      assert {:ok, [], _revision} = Session.todos(session_pid)
    end
  end

  describe "integration - write then read" do
    test "todos written can be read back", %{session_pid: session_pid} do
      todos = [
        valid_todo(%{
          "id" => "1",
          "content" => "Alpha",
          "status" => "pending",
          "priority" => "high"
        }),
        valid_todo(%{
          "id" => "2",
          "content" => "Beta",
          "status" => "in_progress",
          "priority" => "medium"
        }),
        valid_todo(%{
          "id" => "3",
          "content" => "Gamma",
          "status" => "completed",
          "priority" => "low"
        })
      ]

      write_result = TodoWrite.execute("call_w", %{"todos" => todos}, nil, nil, session_pid)
      assert %AgentToolResult{} = write_result

      read_result = TodoRead.execute("call_r", %{}, nil, nil, session_pid)
      assert %AgentToolResult{} = read_result

      written = Jason.decode!(hd(write_result.content).text)
      read_back = Jason.decode!(hd(read_result.content).text)
      assert written == read_back
    end

    test "overwritten todos reflect latest state on read", %{session_pid: session_pid} do
      first = [valid_todo(%{"id" => "1", "content" => "Original"})]
      TodoWrite.execute("call_w1", %{"todos" => first}, nil, nil, session_pid)

      second = [valid_todo(%{"id" => "2", "content" => "Replacement"})]
      TodoWrite.execute("call_w2", %{"todos" => second}, nil, nil, session_pid)

      read_result = TodoRead.execute("call_r", %{}, nil, nil, session_pid)
      read_back = Jason.decode!(hd(read_result.content).text)
      assert length(read_back) == 1
      assert hd(read_back)["content"] == "Replacement"
    end
  end
end
