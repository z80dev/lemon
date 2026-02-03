defmodule CodingAgent.ProcessManagerTest do
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

    # Ensure ProcessManager is running
    unless Process.whereis(CodingAgent.ProcessManager) do
      start_supervised!({CodingAgent.ProcessManager, name: CodingAgent.ProcessManager})
    end

    :ok
  end

  describe "exec/1" do
    test "starts a background process and returns process_id" do
      assert {:ok, process_id} = ProcessManager.exec(command: "sleep 60")
      assert is_binary(process_id)

      # Wait for process to be created
      Process.sleep(100)

      # Process should be in store
      assert {:ok, record, _} = ProcessStore.get(process_id)
      assert record.command == "sleep 60"

      # Clean up
      ProcessManager.kill(process_id, :sigkill)
    end

    test "supports custom cwd" do
      assert {:ok, process_id} = ProcessManager.exec(command: "sleep 60", cwd: "/tmp")

      # Wait for process to be created
      Process.sleep(100)

      assert {:ok, record, _} = ProcessStore.get(process_id)
      assert record.cwd == "/tmp"

      # Clean up
      ProcessManager.kill(process_id, :sigkill)
    end

    test "supports environment variables" do
      assert {:ok, process_id} =
               ProcessManager.exec(
                 command: "sleep 60",
                 env: %{"TEST_VAR" => "test_value"}
               )

      # Wait for process to be created
      Process.sleep(100)

      assert {:ok, record, _} = ProcessStore.get(process_id)
      assert record.env == %{"TEST_VAR" => "test_value"}

      # Clean up
      ProcessManager.kill(process_id, :sigkill)
    end
  end

  describe "exec_sync/1" do
    test "runs command synchronously and returns result" do
      assert {:ok, result} = ProcessManager.exec_sync(command: "echo hello world")

      assert result.status in [:completed, :error]
      assert is_list(result.logs)

      # Should contain our output
      output = Enum.join(result.logs, "\n")
      assert output =~ "hello world"
    end

    test "captures exit code" do
      assert {:ok, result} = ProcessManager.exec_sync(command: "exit 42")
      assert result.exit_code == 42
      assert result.status == :error
    end

    test "supports timeout" do
      assert {:error, :timeout} =
               ProcessManager.exec_sync(
                 command: "sleep 10",
                 timeout_ms: 100
               )
    end

    test "background mode returns immediately" do
      assert {:ok, process_id} =
               ProcessManager.exec_sync(
                 command: "sleep 5",
                 yield_ms: 100
               )

      assert is_binary(process_id)

      # Wait for process to be created
      Process.sleep(100)

      # Should be running
      assert {:ok, record, _} = ProcessStore.get(process_id)
      assert record.status == :running

      # Clean up
      ProcessManager.kill(process_id, :sigkill)
    end
  end

  describe "poll/2" do
    test "returns process status and logs" do
      {:ok, process_id} = ProcessManager.exec(command: "echo test")

      # Wait for completion
      Process.sleep(300)

      assert {:ok, result} = ProcessManager.poll(process_id)
      assert result.process_id == process_id
      assert result.status in [:running, :completed, :error]
      assert is_list(result.logs)
      assert result.command == "echo test"
    end

    test "returns not_found for unknown process" do
      assert {:error, :not_found} = ProcessManager.poll("unknown_process_id")
    end

    test "supports line count limit" do
      {:ok, process_id} = ProcessManager.exec(command: "seq 1 20")

      # Wait for completion
      Process.sleep(300)

      assert {:ok, result} = ProcessManager.poll(process_id, lines: 5)
      assert length(result.logs) <= 5
    end
  end

  describe "list/1" do
    test "returns all processes" do
      {:ok, id1} = ProcessManager.exec(command: "sleep 60")
      {:ok, id2} = ProcessManager.exec(command: "sleep 60")

      # Wait for processes to be created
      Process.sleep(100)

      processes = ProcessManager.list()
      ids = Enum.map(processes, fn {id, _} -> id end)

      assert id1 in ids
      assert id2 in ids

      # Clean up
      ProcessManager.kill(id1, :sigkill)
      ProcessManager.kill(id2, :sigkill)
    end

    test "filters by status" do
      {:ok, id} = ProcessManager.exec(command: "sleep 60")

      # Wait for process to be created
      Process.sleep(100)

      running = ProcessManager.list(status: :running)
      assert {id, _} = List.keyfind(running, id, 0)

      # Clean up
      ProcessManager.kill(id, :sigkill)
    end
  end

  describe "logs/2" do
    test "returns log lines for a process" do
      {:ok, process_id} = ProcessManager.exec(command: "echo line1 && echo line2")

      # Wait for completion
      Process.sleep(300)

      assert {:ok, logs} = ProcessManager.logs(process_id)
      assert is_list(logs)

      output = Enum.join(logs, "\n")
      assert output =~ "line1"
      assert output =~ "line2"
    end

    test "returns not_found for unknown process" do
      assert {:error, :not_found} = ProcessManager.logs("unknown_process_id")
    end
  end

  describe "write/2" do
    test "writes data to process stdin" do
      # Start a process that reads from stdin
      {:ok, process_id} = ProcessManager.exec(command: "cat")

      # Give it time to start
      Process.sleep(100)

      assert :ok = ProcessManager.write(process_id, "hello\n")

      # Clean up
      ProcessManager.kill(process_id, :sigkill)
    end

    test "returns error for non-running process" do
      # Create a fake process ID
      fake_id = "nonexistent_process"
      assert {:error, :process_not_running} = ProcessManager.write(fake_id, "data")
    end
  end

  describe "kill/2" do
    test "kills a running process with sigterm" do
      {:ok, process_id} = ProcessManager.exec(command: "sleep 60")

      # Give it time to start
      Process.sleep(100)

      assert :ok = ProcessManager.kill(process_id, :sigterm)

      # Wait for kill to take effect
      Process.sleep(300)

      assert {:ok, record, _} = ProcessStore.get(process_id)
      assert record.status == :killed
    end

    test "kills a running process with sigkill" do
      {:ok, process_id} = ProcessManager.exec(command: "sleep 60")

      # Give it time to start
      Process.sleep(100)

      assert :ok = ProcessManager.kill(process_id, :sigkill)

      # Wait for kill to take effect
      Process.sleep(300)

      assert {:ok, record, _} = ProcessStore.get(process_id)
      assert record.status in [:killed, :error]
    end

    test "returns error for unknown process" do
      assert {:error, :not_found} = ProcessManager.kill("unknown_process_id")
    end
  end

  describe "clear/1" do
    test "removes a process from the store" do
      {:ok, process_id} = ProcessManager.exec(command: "echo test")

      # Wait for completion
      Process.sleep(300)

      assert :ok = ProcessManager.clear(process_id)
      assert {:error, :not_found} = ProcessStore.get(process_id)
    end
  end

  describe "clear_old/1" do
    test "removes old completed processes" do
      {:ok, process_id} = ProcessManager.exec(command: "echo test")

      # Wait for completion
      Process.sleep(300)

      # Manually age the process
      {:ok, record, logs} = ProcessStore.get(process_id)
      old_record = %{record | completed_at: System.system_time(:second) - 100}
      ProcessStore.insert_record(process_id, old_record, logs)

      assert :ok = ProcessManager.clear_old(50)
      assert {:error, :not_found} = ProcessStore.get(process_id)
    end
  end

  describe "active_count/0" do
    test "returns count of active processes" do
      # Get count before
      count_before = ProcessManager.active_count()

      {:ok, id1} = ProcessManager.exec(command: "sleep 60")
      {:ok, id2} = ProcessManager.exec(command: "sleep 60")

      # Wait for processes to be created (may take longer due to LaneQueue)
      Process.sleep(500)

      # Count should have increased by 2
      count_after = ProcessManager.active_count()
      assert count_after >= count_before + 2

      # Clean up
      ProcessManager.kill(id1, :sigkill)
      ProcessManager.kill(id2, :sigkill)
    end
  end

  describe "integration" do
    test "full lifecycle: exec, poll, kill" do
      # Start a long-running process
      {:ok, process_id} = ProcessManager.exec(command: "sleep 60")

      # Wait for process to start
      Process.sleep(100)

      # Poll to check it's running
      assert {:ok, result} = ProcessManager.poll(process_id)
      assert result.status == :running
      assert is_integer(result.os_pid)

      # Get logs (should be empty)
      assert {:ok, logs} = ProcessManager.logs(process_id)
      assert logs == []

      # Kill the process
      assert :ok = ProcessManager.kill(process_id, :sigterm)

      # Wait and verify it's killed
      Process.sleep(300)
      assert {:ok, result} = ProcessManager.poll(process_id)
      assert result.status == :killed
    end

    test "process completes naturally" do
      {:ok, process_id} = ProcessManager.exec(command: "echo 'hello world'")

      # Poll until completed
      result =
        Enum.reduce_while(1..50, nil, fn _, _ ->
          case ProcessManager.poll(process_id) do
            {:ok, %{status: :completed} = result} ->
              {:halt, result}

            {:ok, %{status: :error} = result} ->
              {:halt, result}

            _ ->
              Process.sleep(100)
              {:cont, nil}
          end
        end)

      assert result != nil
      assert result.status == :completed
      output = Enum.join(result.logs, "\n")
      assert output =~ "hello world"
    end
  end
end
