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

    test "filters by status" do
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
  end

  describe "execute/4 with abort signal" do
    test "returns cancelled when aborted" do
      tool = CodingAgent.Tools.Process.tool([])
      signal = AgentCore.AbortSignal.new()
      AgentCore.AbortSignal.abort(signal)

      result = tool.execute.("call_1", %{"action" => "list"}, signal, nil)

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
  end
end
