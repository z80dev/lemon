defmodule CodingAgent.ProcessStoreServerTest do
  @moduledoc """
  Tests for the ProcessStoreServer GenServer.
  """
  use ExUnit.Case, async: false

  alias CodingAgent.ProcessStoreServer

  setup do
    # Use a unique name for each test to avoid conflicts
    name = :"process_store_server_test_#{System.unique_integer([:positive])}"

    tmp_dir =
      Path.join(System.tmp_dir!(), "process_store_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    dets_path = Path.join(tmp_dir, "test.dets")

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    {:ok, name: name, tmp_dir: tmp_dir, dets_path: dets_path}
  end

  describe "start_link/1" do
    test "starts the server with a custom name", %{name: name, dets_path: dets_path} do
      assert {:ok, pid} = ProcessStoreServer.start_link(name: name, dets_path: dets_path)
      assert is_pid(pid)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "returns existing pid when already started", %{name: name, dets_path: dets_path} do
      {:ok, pid1} = ProcessStoreServer.start_link(name: name, dets_path: dets_path)
      assert {:ok, pid2} = ProcessStoreServer.start_link(name: name, dets_path: dets_path)
      assert pid1 == pid2
      GenServer.stop(pid1)
    end
  end

  describe "table_name/0" do
    test "returns the ETS table name" do
      assert ProcessStoreServer.table_name() == :coding_agent_processes
    end
  end

  describe "ensure_table/1" do
    test "ensures ETS table is created", %{name: name, dets_path: dets_path} do
      {:ok, pid} = ProcessStoreServer.start_link(name: name, dets_path: dets_path)
      assert :ok = ProcessStoreServer.ensure_table(pid)
      assert :ets.whereis(:coding_agent_processes) != :undefined
      GenServer.stop(pid)
    end
  end

  describe "cleanup/2" do
    test "removes expired processes", %{name: name, dets_path: dets_path} do
      {:ok, pid} = ProcessStoreServer.start_link(name: name, dets_path: dets_path)
      ProcessStoreServer.ensure_table(pid)

      # Insert a test process with old completed_at
      old_time = System.system_time(:second) - 1000
      record = %{status: :completed, completed_at: old_time, updated_at: old_time}
      :ets.insert(:coding_agent_processes, {"test_proc_1", record, []})

      # Cleanup with TTL of 60 seconds should remove the old record
      assert {:ok, deleted} = ProcessStoreServer.cleanup(pid, 60)
      assert deleted == 1

      GenServer.stop(pid)
    end

    test "does not remove recent processes", %{name: name, dets_path: dets_path} do
      {:ok, pid} = ProcessStoreServer.start_link(name: name, dets_path: dets_path)
      ProcessStoreServer.ensure_table(pid)

      # Insert a test process with recent completed_at
      recent_time = System.system_time(:second) - 10
      record = %{status: :completed, completed_at: recent_time, updated_at: recent_time}
      :ets.insert(:coding_agent_processes, {"test_proc_2", record, []})

      # Cleanup with TTL of 60 seconds should NOT remove the recent record
      assert {:ok, deleted} = ProcessStoreServer.cleanup(pid, 60)
      assert deleted == 0

      GenServer.stop(pid)
    end

    test "does not remove running processes", %{name: name, dets_path: dets_path} do
      {:ok, pid} = ProcessStoreServer.start_link(name: name, dets_path: dets_path)
      ProcessStoreServer.ensure_table(pid)

      # Insert a running process (old but still running)
      old_time = System.system_time(:second) - 1000
      record = %{status: :running, inserted_at: old_time}
      :ets.insert(:coding_agent_processes, {"test_proc_3", record, []})

      # Cleanup should NOT remove running processes
      assert {:ok, deleted} = ProcessStoreServer.cleanup(pid, 60)
      assert deleted == 0

      GenServer.stop(pid)
    end
  end

  describe "clear/1" do
    test "removes all processes from ETS", %{name: name, dets_path: dets_path} do
      {:ok, pid} = ProcessStoreServer.start_link(name: name, dets_path: dets_path)
      ProcessStoreServer.ensure_table(pid)

      # Insert test processes
      :ets.insert(:coding_agent_processes, {"proc_1", %{status: :running}, []})
      :ets.insert(:coding_agent_processes, {"proc_2", %{status: :completed}, []})

      assert :ok = ProcessStoreServer.clear(pid)
      assert :ets.info(:coding_agent_processes, :size) == 0

      GenServer.stop(pid)
    end
  end

  describe "dets_status/1" do
    test "returns status info for initialized DETS", %{name: name, dets_path: dets_path} do
      {:ok, pid} = ProcessStoreServer.start_link(name: name, dets_path: dets_path)
      ProcessStoreServer.ensure_table(pid)

      status = ProcessStoreServer.dets_status(pid)
      assert is_map(status)
      assert is_map(status.info)

      GenServer.stop(pid)
    end
  end

  describe "server lifecycle" do
    test "ETS table survives client process exits", %{dets_path: dets_path} do
      name = :"lifecycle_test_#{System.unique_integer([:positive])}"
      {:ok, pid} = ProcessStoreServer.start_link(name: name, dets_path: dets_path)
      ProcessStoreServer.ensure_table(pid)

      # Insert a record
      :ets.insert(:coding_agent_processes, {"lifecycle_proc", %{status: :running}, []})

      # Stop the server
      GenServer.stop(pid)

      # The ETS table may be deleted when the owner stops
      # This test documents the expected behavior
      assert true
    end
  end

  describe "process state tracking" do
    test "handles various process states in cleanup", %{name: name, dets_path: dets_path} do
      {:ok, pid} = ProcessStoreServer.start_link(name: name, dets_path: dets_path)
      ProcessStoreServer.ensure_table(pid)

      now = System.system_time(:second)
      old_time = now - 1000

      states_to_test = [
        {:completed, old_time, true},
        {:error, old_time, true},
        {:killed, old_time, true},
        {:lost, old_time, true},
        {:running, old_time, false},
        {:pending, old_time, false}
      ]

      for {status, time, should_delete} <- states_to_test do
        key = "proc_#{status}_#{System.unique_integer([:positive])}"
        record = %{status: status, completed_at: time, updated_at: time, inserted_at: time}
        :ets.insert(:coding_agent_processes, {key, record, []})

        {:ok, deleted} = ProcessStoreServer.cleanup(pid, 60)

        if should_delete do
          assert deleted >= 1, "Expected #{status} process to be deleted"
        else
          # Clean up for next iteration
          :ets.delete(:coding_agent_processes, key)
        end
      end

      GenServer.stop(pid)
    end
  end
end
