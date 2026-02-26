defmodule CodingAgent.Tools.ProcessTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Tools.Process, as: ProcessTool
  alias CodingAgent.ProcessManager
  alias CodingAgent.ProcessStore
  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias AgentCore.AbortSignal

  setup do
    try do
      ProcessStore.clear()
    catch
      _, _ -> :ok
    end

    :ok
  end

  # ============================================================================
  # Tool Definition / Schema Validation
  # ============================================================================

  describe "tool/1 definition" do
    test "returns an AgentTool struct" do
      assert %AgentTool{} = ProcessTool.tool()
    end

    test "has name 'process'" do
      assert ProcessTool.tool().name == "process"
    end

    test "has label 'Manage Background Process'" do
      assert ProcessTool.tool().label == "Manage Background Process"
    end

    test "execute is a 4-arity function" do
      assert is_function(ProcessTool.tool().execute, 4)
    end

    test "description mentions all actions" do
      desc = ProcessTool.tool().description
      assert desc =~ "list"
      assert desc =~ "poll"
      assert desc =~ "log"
      assert desc =~ "write"
      assert desc =~ "kill"
      assert desc =~ "clear"
    end

    test "parameters require only action" do
      params = ProcessTool.tool().parameters
      assert params["required"] == ["action"]
    end

    test "action enum lists all valid actions" do
      action_prop = ProcessTool.tool().parameters["properties"]["action"]
      assert action_prop["type"] == "string"
      assert Enum.sort(action_prop["enum"]) == Enum.sort(["list", "poll", "log", "write", "kill", "clear"])
    end

    test "signal enum lists sigterm and sigkill" do
      signal_prop = ProcessTool.tool().parameters["properties"]["signal"]
      assert signal_prop["enum"] == ["sigterm", "sigkill"]
    end

    test "status enum lists all valid statuses" do
      status_prop = ProcessTool.tool().parameters["properties"]["status"]
      expected = ["all", "running", "completed", "error", "killed", "lost"]
      assert Enum.sort(status_prop["enum"]) == Enum.sort(expected)
    end

    test "lines property is integer type" do
      lines_prop = ProcessTool.tool().parameters["properties"]["lines"]
      assert lines_prop["type"] == "integer"
    end

    test "data property is string type" do
      data_prop = ProcessTool.tool().parameters["properties"]["data"]
      assert data_prop["type"] == "string"
    end

    test "tool/1 accepts opts keyword list" do
      assert %AgentTool{} = ProcessTool.tool(some_opt: true)
    end
  end

  # ============================================================================
  # Exec (list action) Tests
  # ============================================================================

  describe "list action" do
    test "returns AgentToolResult with empty list" do
      result = execute(%{"action" => "list"})
      assert %AgentToolResult{} = result
      assert result.details.action == "list"
      assert result.details.count == 0
      assert result.details.processes == []
    end

    test "formats 'No processes found.' when empty" do
      result = execute(%{"action" => "list"})
      assert get_text(result) == "No processes found."
    end

    test "lists multiple processes" do
      {:ok, id1} = ProcessManager.exec(command: "sleep 60")
      {:ok, id2} = ProcessManager.exec(command: "sleep 60")
      Process.sleep(150)

      result = execute(%{"action" => "list"})
      ids = Enum.map(result.details.processes, & &1.process_id)
      assert id1 in ids
      assert id2 in ids
      assert result.details.count >= 2

      ProcessManager.kill(id1, :sigkill)
      ProcessManager.kill(id2, :sigkill)
    end

    test "each process entry has expected fields" do
      {:ok, id} = ProcessManager.exec(command: "sleep 60")
      Process.sleep(150)

      result = execute(%{"action" => "list"})
      entry = Enum.find(result.details.processes, &(&1.process_id == id))
      assert entry != nil
      assert Map.has_key?(entry, :status)
      assert Map.has_key?(entry, :command)
      assert Map.has_key?(entry, :cwd)
      assert Map.has_key?(entry, :exit_code)
      assert Map.has_key?(entry, :os_pid)
      assert Map.has_key?(entry, :started_at)
      assert Map.has_key?(entry, :completed_at)

      ProcessManager.kill(id, :sigkill)
    end

    test "filters by running status" do
      {:ok, running_id} = ProcessManager.exec(command: "sleep 60")
      {:ok, _done_id} = ProcessManager.exec(command: "echo done")
      Process.sleep(300)

      result = execute(%{"action" => "list", "status" => "running"})
      ids = Enum.map(result.details.processes, & &1.process_id)
      assert running_id in ids
      assert Enum.all?(result.details.processes, &(&1.status == :running))

      ProcessManager.kill(running_id, :sigkill)
    end

    test "filters by completed status" do
      {:ok, _id} = ProcessManager.exec(command: "echo done")
      Process.sleep(300)

      result = execute(%{"action" => "list", "status" => "completed"})
      assert Enum.all?(result.details.processes, &(&1.status == :completed))
    end

    test "filters by error status" do
      {:ok, _id} = ProcessManager.exec(command: "exit 1")
      Process.sleep(300)

      result = execute(%{"action" => "list", "status" => "error"})
      assert Enum.all?(result.details.processes, &(&1.status == :error))
    end

    test "filters by killed status" do
      {:ok, id} = ProcessManager.exec(command: "sleep 60")
      Process.sleep(150)
      ProcessManager.kill(id, :sigterm)
      Process.sleep(300)

      result = execute(%{"action" => "list", "status" => "killed"})
      ids = Enum.map(result.details.processes, & &1.process_id)
      assert id in ids
    end

    test "default status filter returns all statuses" do
      {:ok, running_id} = ProcessManager.exec(command: "sleep 60")
      {:ok, _done_id} = ProcessManager.exec(command: "echo ok")
      Process.sleep(300)

      result = execute(%{"action" => "list"})
      ids = Enum.map(result.details.processes, & &1.process_id)
      assert running_id in ids

      ProcessManager.kill(running_id, :sigkill)
    end

    test "invalid status filter defaults to all" do
      {:ok, id} = ProcessManager.exec(command: "echo test")
      Process.sleep(200)

      result = execute(%{"action" => "list", "status" => "bogus"})
      ids = Enum.map(result.details.processes, & &1.process_id)
      assert id in ids
    end

    test "list text includes UPPERCASE status" do
      {:ok, _id} = ProcessManager.exec(command: "echo hi")
      Process.sleep(200)

      text = get_text(execute(%{"action" => "list"}))
      assert text =~ "COMPLETED" or text =~ "RUNNING" or text =~ "ERROR"
    end

    test "list text truncates long commands" do
      long_cmd = String.duplicate("a", 100)
      {:ok, _id} = ProcessManager.exec(command: "echo #{long_cmd}")
      Process.sleep(200)

      text = get_text(execute(%{"action" => "list"}))
      assert text =~ "..."
    end
  end

  # ============================================================================
  # Poll Action Tests
  # ============================================================================

  describe "poll action" do
    test "polls a completed process" do
      {:ok, id} = ProcessManager.exec(command: "echo hello")
      Process.sleep(300)

      result = execute(%{"action" => "poll", "process_id" => id})
      assert %AgentToolResult{} = result
      assert result.details.action == "poll"
      assert result.details.process_id == id
      assert result.details.status == :completed
      assert result.details.exit_code == 0
      assert result.details.command =~ "echo"
    end

    test "poll text includes process info header" do
      {:ok, id} = ProcessManager.exec(command: "echo test")
      Process.sleep(300)

      text = get_text(execute(%{"action" => "poll", "process_id" => id}))
      assert text =~ "Process:"
      assert text =~ "Status: COMPLETED"
      assert text =~ "Command:"
      assert text =~ "Output:"
    end

    test "poll includes exit code in text for completed process" do
      {:ok, id} = ProcessManager.exec(command: "echo test")
      Process.sleep(300)

      text = get_text(execute(%{"action" => "poll", "process_id" => id}))
      assert text =~ "Exit Code: 0"
    end

    test "poll includes OS PID for running process" do
      {:ok, id} = ProcessManager.exec(command: "sleep 60")
      Process.sleep(150)

      result = execute(%{"action" => "poll", "process_id" => id})
      assert is_integer(result.details.os_pid)
      assert get_text(result) =~ "OS PID:"

      ProcessManager.kill(id, :sigkill)
    end

    test "poll shows '[No output yet]' for process with no output" do
      {:ok, id} = ProcessManager.exec(command: "sleep 60")
      Process.sleep(150)

      text = get_text(execute(%{"action" => "poll", "process_id" => id}))
      assert text =~ "[No output yet]"

      ProcessManager.kill(id, :sigkill)
    end

    test "poll supports custom line count" do
      {:ok, id} = ProcessManager.exec(command: "seq 1 50")
      Process.sleep(300)

      result = execute(%{"action" => "poll", "process_id" => id, "lines" => 5})
      assert length(result.details.logs) <= 5
    end

    test "poll defaults to 100 lines" do
      {:ok, id} = ProcessManager.exec(command: "echo test")
      Process.sleep(300)

      # Should work without specifying lines
      result = execute(%{"action" => "poll", "process_id" => id})
      assert is_list(result.details.logs)
    end

    test "poll returns error for nonexistent process" do
      assert {:error, msg} = execute(%{"action" => "poll", "process_id" => "no_such_id"})
      assert msg =~ "not found"
      assert msg =~ "no_such_id"
    end

    test "poll requires process_id" do
      assert {:error, msg} = execute(%{"action" => "poll"})
      assert msg =~ "process_id is required"
    end

    test "poll rejects empty process_id" do
      assert {:error, msg} = execute(%{"action" => "poll", "process_id" => ""})
      assert msg =~ "cannot be empty"
    end

    test "poll rejects non-string process_id" do
      assert {:error, msg} = execute(%{"action" => "poll", "process_id" => 123})
      assert msg =~ "must be a string"
    end
  end

  # ============================================================================
  # Log Action Tests
  # ============================================================================

  describe "log action" do
    test "returns logs for a process with output" do
      {:ok, id} = ProcessManager.exec(command: "echo line1 && echo line2")
      Process.sleep(300)

      result = execute(%{"action" => "log", "process_id" => id})
      assert %AgentToolResult{} = result
      assert result.details.action == "log"
      assert result.details.process_id == id
      text = get_text(result)
      assert text =~ "line1"
      assert text =~ "line2"
    end

    test "returns '[No logs]' when no output" do
      {:ok, id} = ProcessManager.exec(command: "true")
      Process.sleep(300)

      text = get_text(execute(%{"action" => "log", "process_id" => id}))
      assert text == "[No logs]"
    end

    test "log supports custom line count" do
      {:ok, id} = ProcessManager.exec(command: "seq 1 30")
      Process.sleep(300)

      result = execute(%{"action" => "log", "process_id" => id, "lines" => 5})
      assert result.details.line_count <= 5
    end

    test "log returns error for nonexistent process" do
      assert {:error, msg} = execute(%{"action" => "log", "process_id" => "nope"})
      assert msg =~ "not found"
    end

    test "log requires process_id" do
      assert {:error, msg} = execute(%{"action" => "log"})
      assert msg =~ "process_id is required"
    end
  end

  # ============================================================================
  # Write Action Tests
  # ============================================================================

  describe "write action" do
    test "writes data to a running process" do
      {:ok, id} = ProcessManager.exec(command: "cat")
      Process.sleep(150)

      result = execute(%{"action" => "write", "process_id" => id, "data" => "hello\n"})
      assert %AgentToolResult{} = result
      assert result.details.action == "write"
      assert result.details.process_id == id
      assert result.details.bytes_written == 6
      assert get_text(result) =~ "written"

      ProcessManager.kill(id, :sigkill)
    end

    test "write requires process_id" do
      assert {:error, msg} = execute(%{"action" => "write", "data" => "test"})
      assert msg =~ "process_id is required"
    end

    test "write requires data" do
      assert {:error, msg} = execute(%{"action" => "write", "process_id" => "some_id"})
      assert msg =~ "data is required"
    end

    test "write rejects non-string data" do
      assert {:error, msg} =
               execute(%{"action" => "write", "process_id" => "some_id", "data" => 123})

      assert msg =~ "data must be a string"
    end

    test "write returns error for non-running process" do
      assert {:error, msg} =
               execute(%{"action" => "write", "process_id" => "nonexistent", "data" => "test"})

      assert msg =~ "not running"
    end

    test "write returns error for completed process" do
      {:ok, id} = ProcessManager.exec(command: "echo done")
      Process.sleep(300)

      assert {:error, msg} = execute(%{"action" => "write", "process_id" => id, "data" => "test"})
      assert msg =~ "not running"
    end
  end

  # ============================================================================
  # Kill Action Tests
  # ============================================================================

  describe "kill action" do
    test "kills running process with default sigterm" do
      {:ok, id} = ProcessManager.exec(command: "sleep 60")
      Process.sleep(150)

      result = execute(%{"action" => "kill", "process_id" => id})
      assert %AgentToolResult{} = result
      assert result.details.action == "kill"
      assert result.details.signal == "SIGTERM"
      assert get_text(result) =~ "killed"
      assert get_text(result) =~ "SIGTERM"

      Process.sleep(300)
      assert {:ok, record, _} = ProcessStore.get(id)
      assert record.status == :killed
    end

    test "kills running process with sigkill" do
      {:ok, id} = ProcessManager.exec(command: "sleep 60")
      Process.sleep(150)

      result = execute(%{"action" => "kill", "process_id" => id, "signal" => "sigkill"})
      assert result.details.signal == "SIGKILL"
      assert get_text(result) =~ "SIGKILL"
    end

    test "invalid signal defaults to sigterm" do
      {:ok, id} = ProcessManager.exec(command: "sleep 60")
      Process.sleep(150)

      result = execute(%{"action" => "kill", "process_id" => id, "signal" => "invalid"})
      assert result.details.signal == "SIGTERM"
    end

    test "kill requires process_id" do
      assert {:error, msg} = execute(%{"action" => "kill"})
      assert msg =~ "process_id is required"
    end

    test "kill returns error for unknown process" do
      assert {:error, msg} = execute(%{"action" => "kill", "process_id" => "ghost"})
      assert msg =~ "not found"
    end

    test "kill result text includes process_id" do
      {:ok, id} = ProcessManager.exec(command: "sleep 60")
      Process.sleep(150)

      text = get_text(execute(%{"action" => "kill", "process_id" => id}))
      assert text =~ id
    end
  end

  # ============================================================================
  # Clear Action Tests
  # ============================================================================

  describe "clear action" do
    test "clears a completed process" do
      {:ok, id} = ProcessManager.exec(command: "echo done")
      Process.sleep(300)

      result = execute(%{"action" => "clear", "process_id" => id})
      assert %AgentToolResult{} = result
      assert result.details.action == "clear"
      assert result.details.process_id == id
      assert get_text(result) =~ "cleared"

      assert {:error, :not_found} = ProcessStore.get(id)
    end

    test "clear requires process_id" do
      assert {:error, msg} = execute(%{"action" => "clear"})
      assert msg =~ "process_id is required"
    end

    test "clear returns error for unknown process" do
      assert {:error, msg} = execute(%{"action" => "clear", "process_id" => "ghost"})
      assert msg =~ "not found"
    end

    test "clear result text includes process_id" do
      {:ok, id} = ProcessManager.exec(command: "echo x")
      Process.sleep(300)

      text = get_text(execute(%{"action" => "clear", "process_id" => id}))
      assert text =~ id
    end
  end

  # ============================================================================
  # Abort Signal Tests
  # ============================================================================

  describe "abort signal handling" do
    test "returns cancelled for list when aborted" do
      result = execute_with_abort(%{"action" => "list"})
      assert %AgentToolResult{} = result
      assert get_text(result) =~ "cancelled"
    end

    test "returns cancelled for poll when aborted" do
      result = execute_with_abort(%{"action" => "poll", "process_id" => "any"})
      assert get_text(result) =~ "cancelled"
    end

    test "returns cancelled for log when aborted" do
      result = execute_with_abort(%{"action" => "log", "process_id" => "any"})
      assert get_text(result) =~ "cancelled"
    end

    test "returns cancelled for write when aborted" do
      result = execute_with_abort(%{"action" => "write", "process_id" => "any", "data" => "x"})
      assert get_text(result) =~ "cancelled"
    end

    test "returns cancelled for kill when aborted" do
      result = execute_with_abort(%{"action" => "kill", "process_id" => "any"})
      assert get_text(result) =~ "cancelled"
    end

    test "returns cancelled for clear when aborted" do
      result = execute_with_abort(%{"action" => "clear", "process_id" => "any"})
      assert get_text(result) =~ "cancelled"
    end

    test "non-aborted signal proceeds normally" do
      signal = AbortSignal.new()
      result = ProcessTool.execute("call", %{"action" => "list"}, signal, nil)
      assert %AgentToolResult{} = result
      assert result.details.action == "list"
      AbortSignal.clear(signal)
    end

    test "nil signal proceeds normally" do
      result = ProcessTool.execute("call", %{"action" => "list"}, nil, nil)
      assert %AgentToolResult{} = result
      assert result.details.action == "list"
    end
  end

  # ============================================================================
  # Validation / Error Cases
  # ============================================================================

  describe "validation and error cases" do
    test "missing action defaults to list" do
      result = execute(%{})
      assert result.details.action == "list"
    end

    test "unknown action returns error" do
      assert {:error, msg} = execute(%{"action" => "restart"})
      assert msg =~ "Unknown action"
    end

    test "nil action returns error" do
      assert {:error, msg} = execute(%{"action" => nil})
      assert msg =~ "Unknown action"
    end

    test "error message for not_found includes process_id" do
      assert {:error, msg} = execute(%{"action" => "poll", "process_id" => "my_proc_42"})
      assert msg =~ "my_proc_42"
    end

    test "empty process_id rejected across all actions that need it" do
      for action <- ["poll", "log", "write", "kill", "clear"] do
        params =
          case action do
            "write" -> %{"action" => action, "process_id" => "", "data" => "x"}
            _ -> %{"action" => action, "process_id" => ""}
          end

        assert {:error, msg} = execute(params), "Expected error for action #{action}"
        assert msg =~ "cannot be empty", "Expected 'cannot be empty' for action #{action}"
      end
    end
  end

  # ============================================================================
  # Integration / Lifecycle Tests
  # ============================================================================

  describe "full lifecycle through tool" do
    test "exec -> poll -> kill -> clear" do
      {:ok, id} = ProcessManager.exec(command: "sleep 60")
      Process.sleep(150)

      # Poll shows running
      poll_result = execute(%{"action" => "poll", "process_id" => id})
      assert poll_result.details.status == :running

      # Kill
      kill_result = execute(%{"action" => "kill", "process_id" => id})
      assert get_text(kill_result) =~ "killed"
      Process.sleep(300)

      # Poll shows killed
      poll_result2 = execute(%{"action" => "poll", "process_id" => id})
      assert poll_result2.details.status == :killed

      # Clear removes it
      clear_result = execute(%{"action" => "clear", "process_id" => id})
      assert get_text(clear_result) =~ "cleared"

      # Now poll returns not found
      assert {:error, _} = execute(%{"action" => "poll", "process_id" => id})
    end

    test "exec -> log -> process completes naturally" do
      {:ok, id} = ProcessManager.exec(command: "echo hello_world")
      Process.sleep(300)

      log_result = execute(%{"action" => "log", "process_id" => id})
      assert get_text(log_result) =~ "hello_world"

      poll_result = execute(%{"action" => "poll", "process_id" => id})
      assert poll_result.details.status == :completed
      assert poll_result.details.exit_code == 0
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp execute(params) do
    ProcessTool.execute("test_call", params, nil, nil)
  end

  defp execute_with_abort(params) do
    signal = AbortSignal.new()
    AbortSignal.abort(signal)
    result = ProcessTool.execute("test_call", params, signal, nil)
    AbortSignal.clear(signal)
    result
  end

  defp get_text(%AgentToolResult{content: [%{text: text} | _]}), do: text
end
