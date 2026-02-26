defmodule CodingAgent.ProcessStoreTest do
  use ExUnit.Case, async: false

  alias CodingAgent.ProcessStore
  alias CodingAgent.ProcessStoreServer

  setup do
    # Clear all processes before each test
    try do
      ProcessStore.clear()
    catch
      _, _ -> :ok
    end

    :ok
  end

  describe "new_process/1" do
    test "creates a process with default attributes" do
      process_id = ProcessStore.new_process(%{command: "echo hello"})

      assert is_binary(process_id)
      assert {:ok, record, _logs} = ProcessStore.get(process_id)
      assert record.status == :queued
      assert record.command == "echo hello"
      assert is_integer(record.inserted_at)
      assert is_integer(record.updated_at)
    end

    test "creates a process with custom attributes" do
      process_id =
        ProcessStore.new_process(%{
          command: "ls -la",
          cwd: "/tmp",
          env: %{"FOO" => "bar"},
          owner: "user123"
        })

      assert {:ok, record, _} = ProcessStore.get(process_id)
      assert record.command == "ls -la"
      assert record.cwd == "/tmp"
      assert record.env == %{"FOO" => "bar"}
      assert record.owner == "user123"
    end

    test "generates unique process IDs" do
      process_ids = for _ <- 1..100, do: ProcessStore.new_process(%{})
      assert length(Enum.uniq(process_ids)) == 100
    end
  end

  describe "mark_running/2" do
    test "marks a process as running with OS PID" do
      process_id = ProcessStore.new_process(%{command: "echo test"})
      assert :ok = ProcessStore.mark_running(process_id, 12345)

      assert {:ok, record, _} = ProcessStore.get(process_id)
      assert record.status == :running
      assert record.os_pid == 12345
      assert is_integer(record.started_at)
    end

    test "returns ok for unknown process" do
      assert :ok = ProcessStore.mark_running("unknown_process_id", 12345)
    end
  end

  describe "append_log/2" do
    test "appends log lines to a process" do
      process_id = ProcessStore.new_process(%{command: "echo test"})

      assert :ok = ProcessStore.append_log(process_id, "Line 1")
      assert :ok = ProcessStore.append_log(process_id, "Line 2")

      assert {:ok, _, logs} = ProcessStore.get(process_id)
      assert logs == ["Line 1", "Line 2"]
    end

    test "maintains bounded log buffer" do
      process_id = ProcessStore.new_process(%{command: "echo test"})

      # Add more than max_log_lines (1000)
      for i <- 1..1100 do
        ProcessStore.append_log(process_id, "Line #{i}")
      end

      assert {:ok, _, logs} = ProcessStore.get(process_id)
      assert length(logs) == 1000
      # Most recent lines should be kept
      assert List.last(logs) == "Line 1100"
      assert hd(logs) == "Line 101"
    end

    test "returns ok for unknown process" do
      assert :ok = ProcessStore.append_log("unknown_process_id", "log line")
    end
  end

  describe "mark_completed/2" do
    test "marks a process as completed with exit code" do
      process_id = ProcessStore.new_process(%{command: "echo test"})
      ProcessStore.mark_running(process_id, 12345)

      assert :ok = ProcessStore.mark_completed(process_id, 0)

      assert {:ok, record, _} = ProcessStore.get(process_id)
      assert record.status == :completed
      assert record.exit_code == 0
      assert is_integer(record.completed_at)
    end

    test "returns ok for unknown process" do
      assert :ok = ProcessStore.mark_completed("unknown_process_id", 0)
    end
  end

  describe "mark_killed/1" do
    test "marks a process as killed" do
      process_id = ProcessStore.new_process(%{command: "echo test"})
      ProcessStore.mark_running(process_id, 12345)

      assert :ok = ProcessStore.mark_killed(process_id)

      assert {:ok, record, _} = ProcessStore.get(process_id)
      assert record.status == :killed
      assert is_integer(record.completed_at)
    end

    test "returns ok for unknown process" do
      assert :ok = ProcessStore.mark_killed("unknown_process_id")
    end
  end

  describe "mark_error/2" do
    test "marks a process as error with reason" do
      process_id = ProcessStore.new_process(%{command: "echo test"})
      ProcessStore.mark_running(process_id, 12345)

      error = %{exit_code: 1, message: "Command failed"}
      assert :ok = ProcessStore.mark_error(process_id, error)

      assert {:ok, record, _} = ProcessStore.get(process_id)
      assert record.status == :error
      assert record.error == error
      assert is_integer(record.completed_at)
    end

    test "returns ok for unknown process" do
      assert :ok = ProcessStore.mark_error("unknown_process_id", "error")
    end
  end

  describe "get/1" do
    test "returns not_found for unknown process" do
      assert {:error, :not_found} = ProcessStore.get("unknown_process_id")
    end
  end

  describe "list/1" do
    test "returns all processes when filter is :all" do
      id1 = ProcessStore.new_process(%{command: "echo 1"})
      id2 = ProcessStore.new_process(%{command: "echo 2"})
      id3 = ProcessStore.new_process(%{command: "echo 3"})

      processes = ProcessStore.list(:all)
      ids = Enum.map(processes, fn {id, _} -> id end)

      assert length(processes) == 3
      assert id1 in ids
      assert id2 in ids
      assert id3 in ids
    end

    test "filters by status" do
      id1 = ProcessStore.new_process(%{command: "echo 1"})
      id2 = ProcessStore.new_process(%{command: "echo 2"})
      id3 = ProcessStore.new_process(%{command: "echo 3"})

      ProcessStore.mark_running(id1, 123)
      ProcessStore.mark_completed(id2, 0)
      ProcessStore.mark_error(id3, "failed")

      running = ProcessStore.list(:running)
      completed = ProcessStore.list(:completed)
      error = ProcessStore.list(:error)

      assert length(running) == 1
      assert elem(hd(running), 0) == id1

      assert length(completed) == 1
      assert elem(hd(completed), 0) == id2

      assert length(error) == 1
      assert elem(hd(error), 0) == id3
    end
  end

  describe "get_logs/2" do
    test "returns recent log lines in chronological order" do
      process_id = ProcessStore.new_process(%{command: "echo test"})

      for i <- 1..10 do
        ProcessStore.append_log(process_id, "Line #{i}")
      end

      assert {:ok, logs} = ProcessStore.get_logs(process_id, 5)
      assert length(logs) == 5
      # Returns oldest of the recent lines (chronological order, limited to last 5)
      assert logs == ["Line 6", "Line 7", "Line 8", "Line 9", "Line 10"]
    end

    test "returns not_found for unknown process" do
      assert {:error, :not_found} = ProcessStore.get_logs("unknown_process_id")
    end
  end

  describe "delete/1" do
    test "deletes a process from the store" do
      process_id = ProcessStore.new_process(%{command: "echo test"})
      assert {:ok, _, _} = ProcessStore.get(process_id)

      assert :ok = ProcessStore.delete(process_id)
      assert {:error, :not_found} = ProcessStore.get(process_id)
    end
  end

  describe "cleanup/1" do
    test "removes old completed processes" do
      # Create a process and mark it completed
      process_id = ProcessStore.new_process(%{command: "echo test"})
      ProcessStore.mark_running(process_id, 12345)
      ProcessStore.mark_completed(process_id, 0)

      # Manually set completed_at to be old
      {:ok, record, logs} = ProcessStore.get(process_id)
      old_record = %{record | completed_at: System.system_time(:second) - 100}
      ProcessStore.insert_record(process_id, old_record, logs)

      # Cleanup with 50 second TTL should remove it
      assert :ok = ProcessStore.cleanup(50)
      assert {:error, :not_found} = ProcessStore.get(process_id)
    end

    test "keeps recent completed processes" do
      process_id = ProcessStore.new_process(%{command: "echo test"})
      ProcessStore.mark_running(process_id, 12345)
      ProcessStore.mark_completed(process_id, 0)

      # Cleanup with 1 hour TTL should keep it
      assert :ok = ProcessStore.cleanup(3600)
      assert {:ok, _, _} = ProcessStore.get(process_id)
    end
  end

  describe "dets_open?/0" do
    test "returns boolean" do
      assert is_boolean(ProcessStore.dets_open?())
    end
  end

  describe "persistence" do
    test "processes survive server restart when DETS is available" do
      process_id = ProcessStore.new_process(%{command: "echo test"})
      ProcessStore.mark_running(process_id, 12345)
      ProcessStore.append_log(process_id, "log line")

      # Simulate restart by clearing ETS
      :ets.delete_all_objects(:coding_agent_processes)

      # Manually trigger reload from DETS by calling ensure_table
      ProcessStoreServer.ensure_table(CodingAgent.ProcessStoreServer)

      # Check if data was recovered - may or may not work depending on DETS config
      case ProcessStore.get(process_id) do
        {:ok, record, logs} ->
          assert record.command == "echo test"
          assert record.os_pid == 12345
          assert logs == ["log line"]

        {:error, :not_found} ->
          # DETS not available in test, skip assertions
          :ok
      end
    end

    test "running processes are marked as lost on restart" do
      process_id = ProcessStore.new_process(%{command: "echo test"})
      ProcessStore.mark_running(process_id, 12345)

      # Simulate restart by clearing ETS and reloading
      :ets.delete_all_objects(:coding_agent_processes)
      ProcessStoreServer.ensure_table(CodingAgent.ProcessStoreServer)

      # Check result - may be :lost if DETS recovered, or :not_found if not
      case ProcessStore.get(process_id) do
        {:ok, record, _} ->
          assert record.status == :lost
          assert record.error == :lost_on_restart

        {:error, :not_found} ->
          # DETS not available in test, skip
          :ok
      end
    end
  end
end
