defmodule CodingAgent.Tools.ProcessToolTest do
  use ExUnit.Case, async: false

  alias CodingAgent.ProcessManager
  alias CodingAgent.ProcessStore

  setup do
    # Clear all processes before each test
    try do
      ProcessStore.clear()
    catch
      _, _ -> :ok
    end

    :ok
  end

  describe "tool/1" do
    test "returns tool definition" do
      tool = CodingAgent.Tools.Process.tool([])

      assert tool.name == "process"
      assert tool.label == "Manage Background Process"
      assert is_map(tool.parameters)
      assert is_function(tool.execute, 4)
    end
  end

  describe "execute/4 list action" do
    test "lists all processes" do
      # Create some processes
      {:ok, id1} = ProcessManager.exec(command: "echo 1")
      {:ok, id2} = ProcessManager.exec(command: "echo 2")

      tool = CodingAgent.Tools.Process.tool([])
      result = tool.execute.("call_1", %{"action" => "list"}, nil, nil)

      assert result.content != nil
      text = result.content |> hd() |> Map.get(:text)
      assert text =~ "Processes"
      assert result.details.action == "list"
      assert result.details.count >= 2

      # Verify our processes are in the list
      process_ids = Enum.map(result.details.processes, & &1.process_id)
      assert id1 in process_ids
      assert id2 in process_ids
    end

    test "returns empty message when no processes" do
      # Clear all processes first
      ProcessStore.clear()

      tool = CodingAgent.Tools.Process.tool([])
      result = tool.execute.("call_1", %{"action" => "list"}, nil, nil)

      assert result.content != nil
      text = result.content |> hd() |> Map.get(:text)
      assert text == "No processes found."
      assert result.details.count == 0
      assert result.details.processes == []
    end

    test "filters by running status" do
      # Create a running process
      {:ok, id} = ProcessManager.exec(command: "sleep 60")

      tool = CodingAgent.Tools.Process.tool([])

      result = tool.execute.("call_1", %{"action" => "list", "status" => "running"}, nil, nil)

      assert result.details.count >= 1
      process_ids = Enum.map(result.details.processes, & &1.process_id)
      assert id in process_ids

      # Clean up
      ProcessManager.kill(id, :sigkill)
    end

    test "filters by completed status" do
      # Create a completed process
      {:ok, id} = ProcessManager.exec(command: "echo done")

      # Wait for completion
      Elixir.Process.sleep(200)

      tool = CodingAgent.Tools.Process.tool([])

      result = tool.execute.("call_1", %{"action" => "list", "status" => "completed"}, nil, nil)

      process_ids = Enum.map(result.details.processes, & &1.process_id)
      assert id in process_ids
    end

    test "filters by error status" do
      # Create a process that exits with error
      {:ok, id} = ProcessManager.exec(command: "exit 1")

      # Wait for completion
      Elixir.Process.sleep(200)

      tool = CodingAgent.Tools.Process.tool([])

      result = tool.execute.("call_1", %{"action" => "list", "status" => "error"}, nil, nil)

      process_ids = Enum.map(result.details.processes, & &1.process_id)
      assert id in process_ids
    end

    test "filters by killed status" do
      # Create and kill a process
      {:ok, id} = ProcessManager.exec(command: "sleep 60")
      Elixir.Process.sleep(100)
      ProcessManager.kill(id, :sigterm)
      Elixir.Process.sleep(200)

      tool = CodingAgent.Tools.Process.tool([])

      result = tool.execute.("call_1", %{"action" => "list", "status" => "killed"}, nil, nil)

      process_ids = Enum.map(result.details.processes, & &1.process_id)
      assert id in process_ids
    end

    test "default status filter is all" do
      # Create processes with different statuses
      {:ok, running_id} = ProcessManager.exec(command: "sleep 60")
      {:ok, completed_id} = ProcessManager.exec(command: "echo done")
      Elixir.Process.sleep(200)

      tool = CodingAgent.Tools.Process.tool([])

      # No status filter specified
      result = tool.execute.("call_1", %{"action" => "list"}, nil, nil)

      process_ids = Enum.map(result.details.processes, & &1.process_id)
      assert running_id in process_ids
      assert completed_id in process_ids

      # Clean up
      ProcessManager.kill(running_id, :sigkill)
    end
  end

  describe "execute/4 poll action" do
    test "polls a process" do
      {:ok, process_id} = ProcessManager.exec(command: "echo hello")

      # Wait for completion
      Elixir.Process.sleep(200)

      tool = CodingAgent.Tools.Process.tool([])

      result =
        tool.execute.("call_1", %{"action" => "poll", "process_id" => process_id}, nil, nil)

      assert result.content != nil
      text = result.content |> hd() |> Map.get(:text)
      assert text =~ "Process:"
      assert result.details.action == "poll"
      assert result.details.process_id == process_id
      assert result.details.status in [:running, :completed, :error]
    end

    test "returns error for unknown process" do
      tool = CodingAgent.Tools.Process.tool([])

      assert {:error, reason} =
               tool.execute.(
                 "call_1",
                 %{"action" => "poll", "process_id" => "unknown_id"},
                 nil,
                 nil
               )

      assert reason =~ "not found"
    end

    test "requires process_id" do
      tool = CodingAgent.Tools.Process.tool([])

      assert {:error, reason} = tool.execute.("call_1", %{"action" => "poll"}, nil, nil)
      assert reason =~ "process_id is required"
    end

    test "returns error for empty process_id" do
      tool = CodingAgent.Tools.Process.tool([])

      assert {:error, reason} =
               tool.execute.("call_1", %{"action" => "poll", "process_id" => ""}, nil, nil)

      assert reason =~ "process_id cannot be empty"
    end

    test "poll result includes command details" do
      {:ok, process_id} = ProcessManager.exec(command: "echo test_output")

      # Wait for completion
      Elixir.Process.sleep(200)

      tool = CodingAgent.Tools.Process.tool([])

      result =
        tool.execute.("call_1", %{"action" => "poll", "process_id" => process_id}, nil, nil)

      assert result.details.command =~ "echo"
      assert result.details.exit_code == 0
      assert result.details.status == :completed
      assert is_integer(result.details.os_pid) or is_nil(result.details.os_pid)
    end

    test "supports line count" do
      {:ok, process_id} = ProcessManager.exec(command: "seq 1 20")

      # Wait for completion
      Elixir.Process.sleep(200)

      tool = CodingAgent.Tools.Process.tool([])

      result =
        tool.execute.(
          "call_1",
          %{"action" => "poll", "process_id" => process_id, "lines" => 5},
          nil,
          nil
        )

      assert length(result.details.logs) <= 5
    end
  end

  describe "execute/4 log action" do
    test "returns logs for a process" do
      {:ok, process_id} = ProcessManager.exec(command: "echo line1 && echo line2")

      # Wait for completion
      Elixir.Process.sleep(200)

      tool = CodingAgent.Tools.Process.tool([])
      result = tool.execute.("call_1", %{"action" => "log", "process_id" => process_id}, nil, nil)

      assert result.content != nil
      text = result.content |> hd() |> Map.get(:text)
      assert text =~ "line1"
      assert text =~ "line2"
      assert result.details.action == "log"
      assert result.details.process_id == process_id
    end

    test "returns not_found for unknown process" do
      tool = CodingAgent.Tools.Process.tool([])

      assert {:error, reason} =
               tool.execute.(
                 "call_1",
                 %{"action" => "log", "process_id" => "unknown_id"},
                 nil,
                 nil
               )

      assert reason =~ "not found"
    end

    test "requires process_id" do
      tool = CodingAgent.Tools.Process.tool([])

      assert {:error, reason} = tool.execute.("call_1", %{"action" => "log"}, nil, nil)
      assert reason =~ "process_id is required"
    end

    test "returns empty logs message when no output" do
      {:ok, process_id} = ProcessManager.exec(command: "true")

      # Wait for completion
      Elixir.Process.sleep(200)

      tool = CodingAgent.Tools.Process.tool([])
      result = tool.execute.("call_1", %{"action" => "log", "process_id" => process_id}, nil, nil)

      assert result.content != nil
      text = result.content |> hd() |> Map.get(:text)
      assert text == "[No logs]"
    end

    test "supports line count parameter" do
      {:ok, process_id} = ProcessManager.exec(command: "seq 1 20")

      # Wait for completion
      Elixir.Process.sleep(200)

      tool = CodingAgent.Tools.Process.tool([])

      result =
        tool.execute.(
          "call_1",
          %{"action" => "log", "process_id" => process_id, "lines" => 5},
          nil,
          nil
        )

      # Log action returns line_count, not logs
      assert result.details.line_count <= 5
    end
  end

  describe "execute/4 write action" do
    test "writes to process stdin" do
      # Start a process that reads from stdin
      {:ok, process_id} = ProcessManager.exec(command: "cat")

      # Give it time to start
      Elixir.Process.sleep(100)

      tool = CodingAgent.Tools.Process.tool([])

      result =
        tool.execute.(
          "call_1",
          %{"action" => "write", "process_id" => process_id, "data" => "hello\n"},
          nil,
          nil
        )

      assert result.content != nil
      text = result.content |> hd() |> Map.get(:text)
      assert text =~ "written"
      assert result.details.action == "write"
      assert result.details.bytes_written == 6

      # Clean up
      ProcessManager.kill(process_id, :sigkill)
    end

    test "requires data parameter" do
      tool = CodingAgent.Tools.Process.tool([])

      assert {:error, reason} =
               tool.execute.(
                 "call_1",
                 %{"action" => "write", "process_id" => "some_id"},
                 nil,
                 nil
               )

      assert reason =~ "data is required"
    end

    test "returns error for non-running process" do
      tool = CodingAgent.Tools.Process.tool([])

      assert {:error, reason} =
               tool.execute.(
                 "call_1",
                 %{"action" => "write", "process_id" => "nonexistent", "data" => "test"},
                 nil,
                 nil
               )

      assert reason =~ "not running"
    end

    test "requires process_id" do
      tool = CodingAgent.Tools.Process.tool([])

      assert {:error, reason} =
               tool.execute.(
                 "call_1",
                 %{"action" => "write", "data" => "test"},
                 nil,
                 nil
               )

      assert reason =~ "process_id is required"
    end
  end

  describe "execute/4 kill action" do
    test "kills a running process with sigterm" do
      {:ok, process_id} = ProcessManager.exec(command: "sleep 60")

      # Give it time to start
      Elixir.Process.sleep(100)

      tool = CodingAgent.Tools.Process.tool([])

      result =
        tool.execute.(
          "call_1",
          %{"action" => "kill", "process_id" => process_id},
          nil,
          nil
        )

      assert result.content != nil
      text = result.content |> hd() |> Map.get(:text)
      assert text =~ "killed"
      assert text =~ "SIGTERM"
      assert result.details.action == "kill"
      assert result.details.signal == "SIGTERM"

      # Wait for kill to take effect
      Elixir.Process.sleep(200)

      assert {:ok, record, _} = ProcessStore.get(process_id)
      assert record.status == :killed
    end

    test "kills with sigkill when specified" do
      {:ok, process_id} = ProcessManager.exec(command: "sleep 60")

      # Give it time to start
      Elixir.Process.sleep(100)

      tool = CodingAgent.Tools.Process.tool([])

      result =
        tool.execute.(
          "call_1",
          %{"action" => "kill", "process_id" => process_id, "signal" => "sigkill"},
          nil,
          nil
        )

      assert result.content != nil
      text = result.content |> hd() |> Map.get(:text)
      assert text =~ "SIGKILL"
      assert result.details.signal == "SIGKILL"

      # Clean up
      ProcessManager.kill(process_id, :sigkill)
    end

    test "returns error for unknown process" do
      tool = CodingAgent.Tools.Process.tool([])

      assert {:error, reason} =
               tool.execute.(
                 "call_1",
                 %{"action" => "kill", "process_id" => "unknown_id"},
                 nil,
                 nil
               )

      assert reason =~ "not found"
    end

    test "requires process_id" do
      tool = CodingAgent.Tools.Process.tool([])

      assert {:error, reason} = tool.execute.("call_1", %{"action" => "kill"}, nil, nil)
      assert reason =~ "process_id is required"
    end

    test "defaults to sigterm when signal not specified" do
      {:ok, process_id} = ProcessManager.exec(command: "sleep 60")

      # Give it time to start
      Elixir.Process.sleep(100)

      tool = CodingAgent.Tools.Process.tool([])

      result =
        tool.execute.(
          "call_1",
          %{"action" => "kill", "process_id" => process_id},
          nil,
          nil
        )

      assert result.details.signal == "SIGTERM"

      # Clean up
      ProcessManager.kill(process_id, :sigkill)
    end
  end

  describe "execute/4 clear action" do
    test "clears a completed process" do
      {:ok, process_id} = ProcessManager.exec(command: "echo test")

      # Wait for completion
      Elixir.Process.sleep(200)

      tool = CodingAgent.Tools.Process.tool([])

      result =
        tool.execute.(
          "call_1",
          %{"action" => "clear", "process_id" => process_id},
          nil,
          nil
        )

      assert result.content != nil
      text = result.content |> hd() |> Map.get(:text)
      assert text =~ "cleared"
      assert result.details.action == "clear"

      assert {:error, :not_found} = ProcessStore.get(process_id)
    end

    test "returns error for unknown process" do
      tool = CodingAgent.Tools.Process.tool([])

      assert {:error, reason} =
               tool.execute.(
                 "call_1",
                 %{"action" => "clear", "process_id" => "unknown_id"},
                 nil,
                 nil
               )

      assert reason =~ "not found"
    end

    test "requires process_id" do
      tool = CodingAgent.Tools.Process.tool([])

      assert {:error, reason} = tool.execute.("call_1", %{"action" => "clear"}, nil, nil)
      assert reason =~ "process_id is required"
    end
  end

  describe "execute/4 with abort signal" do
    test "returns cancelled when aborted for list action" do
      tool = CodingAgent.Tools.Process.tool([])
      signal = AgentCore.AbortSignal.new()
      AgentCore.AbortSignal.abort(signal)

      result = tool.execute.("call_1", %{"action" => "list"}, signal, nil)

      assert result.content != nil
      text = result.content |> hd() |> Map.get(:text)
      assert text =~ "cancelled"
    end

    test "returns cancelled when aborted for poll action" do
      tool = CodingAgent.Tools.Process.tool([])
      signal = AgentCore.AbortSignal.new()
      AgentCore.AbortSignal.abort(signal)

      result = tool.execute.("call_1", %{"action" => "poll", "process_id" => "test"}, signal, nil)

      assert result.content != nil
      text = result.content |> hd() |> Map.get(:text)
      assert text =~ "cancelled"
    end

    test "returns cancelled when aborted for log action" do
      tool = CodingAgent.Tools.Process.tool([])
      signal = AgentCore.AbortSignal.new()
      AgentCore.AbortSignal.abort(signal)

      result = tool.execute.("call_1", %{"action" => "log", "process_id" => "test"}, signal, nil)

      assert result.content != nil
      text = result.content |> hd() |> Map.get(:text)
      assert text =~ "cancelled"
    end

    test "returns cancelled when aborted for write action" do
      tool = CodingAgent.Tools.Process.tool([])
      signal = AgentCore.AbortSignal.new()
      AgentCore.AbortSignal.abort(signal)

      result =
        tool.execute.(
          "call_1",
          %{"action" => "write", "process_id" => "test", "data" => "test"},
          signal,
          nil
        )

      assert result.content != nil
      text = result.content |> hd() |> Map.get(:text)
      assert text =~ "cancelled"
    end

    test "returns cancelled when aborted for kill action" do
      tool = CodingAgent.Tools.Process.tool([])
      signal = AgentCore.AbortSignal.new()
      AgentCore.AbortSignal.abort(signal)

      result =
        tool.execute.("call_1", %{"action" => "kill", "process_id" => "test"}, signal, nil)

      assert result.content != nil
      text = result.content |> hd() |> Map.get(:text)
      assert text =~ "cancelled"
    end

    test "returns cancelled when aborted for clear action" do
      tool = CodingAgent.Tools.Process.tool([])
      signal = AgentCore.AbortSignal.new()
      AgentCore.AbortSignal.abort(signal)

      result =
        tool.execute.("call_1", %{"action" => "clear", "process_id" => "test"}, signal, nil)

      assert result.content != nil
      text = result.content |> hd() |> Map.get(:text)
      assert text =~ "cancelled"
    end
  end

  describe "execute/4 validation" do
    test "requires action parameter" do
      tool = CodingAgent.Tools.Process.tool([])

      # Default action is "list"
      result = tool.execute.("call_1", %{}, nil, nil)
      assert result.details.action == "list"
    end

    test "returns error for unknown action" do
      tool = CodingAgent.Tools.Process.tool([])

      assert {:error, reason} =
               tool.execute.(
                 "call_1",
                 %{"action" => "unknown"},
                 nil,
                 nil
               )

      assert reason =~ "Unknown action"
    end

    test "returns error for nil action" do
      tool = CodingAgent.Tools.Process.tool([])

      assert {:error, reason} =
               tool.execute.(
                 "call_1",
                 %{"action" => nil},
                 nil,
                 nil
               )

      assert reason =~ "Unknown action"
    end

    test "error messages include process_id for context" do
      tool = CodingAgent.Tools.Process.tool([])

      assert {:error, reason} =
               tool.execute.(
                 "call_1",
                 %{"action" => "poll", "process_id" => "specific_id_123"},
                 nil,
                 nil
               )

      assert reason =~ "specific_id_123"
    end
  end

  describe "tool struct properties" do
    test "tool has correct name and label" do
      tool = CodingAgent.Tools.Process.tool([])

      assert tool.name == "process"
      assert tool.label == "Manage Background Process"
    end

    test "tool has description" do
      tool = CodingAgent.Tools.Process.tool([])

      assert is_binary(tool.description)
      assert tool.description =~ "process"
    end

    test "tool parameters schema is correct" do
      tool = CodingAgent.Tools.Process.tool([])

      assert tool.parameters["type"] == "object"
      assert "action" in tool.parameters["required"]
      assert is_map(tool.parameters["properties"])
      assert "action" in Map.keys(tool.parameters["properties"])
      assert "process_id" in Map.keys(tool.parameters["properties"])
      assert "status" in Map.keys(tool.parameters["properties"])
      assert "lines" in Map.keys(tool.parameters["properties"])
      assert "data" in Map.keys(tool.parameters["properties"])
      assert "signal" in Map.keys(tool.parameters["properties"])
    end

    test "action enum includes all valid actions" do
      tool = CodingAgent.Tools.Process.tool([])

      action_enum = tool.parameters["properties"]["action"]["enum"]
      assert "list" in action_enum
      assert "poll" in action_enum
      assert "log" in action_enum
      assert "write" in action_enum
      assert "kill" in action_enum
      assert "clear" in action_enum
    end

    test "signal enum includes valid signals" do
      tool = CodingAgent.Tools.Process.tool([])

      signal_enum = tool.parameters["properties"]["signal"]["enum"]
      assert "sigterm" in signal_enum
      assert "sigkill" in signal_enum
    end

    test "status enum includes valid statuses" do
      tool = CodingAgent.Tools.Process.tool([])

      status_enum = tool.parameters["properties"]["status"]["enum"]
      assert "all" in status_enum
      assert "running" in status_enum
      assert "completed" in status_enum
      assert "error" in status_enum
      assert "killed" in status_enum
      assert "lost" in status_enum
    end
  end

  describe "result structure" do
    test "list action returns proper AgentToolResult struct" do
      tool = CodingAgent.Tools.Process.tool([])
      result = tool.execute.("call_1", %{"action" => "list"}, nil, nil)

      assert %AgentCore.Types.AgentToolResult{} = result
      assert is_list(result.content)
      assert result.content != []
      assert is_map(result.details)
      assert result.details.action == "list"
    end

    test "poll action returns proper AgentToolResult struct" do
      {:ok, process_id} = ProcessManager.exec(command: "echo test")
      Elixir.Process.sleep(200)

      tool = CodingAgent.Tools.Process.tool([])
      result = tool.execute.("call_1", %{"action" => "poll", "process_id" => process_id}, nil, nil)

      assert %AgentCore.Types.AgentToolResult{} = result
      assert is_list(result.content)
      assert result.content != []
      assert is_map(result.details)
      assert result.details.action == "poll"
    end

    test "error results are properly formatted" do
      tool = CodingAgent.Tools.Process.tool([])

      assert {:error, reason} =
               tool.execute.(
                 "call_1",
                 %{"action" => "poll", "process_id" => "nonexistent"},
                 nil,
                 nil
               )

      assert is_binary(reason)
    end
  end
end
