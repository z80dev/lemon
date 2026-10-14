defmodule CodingAgent.ProcessStoreServerTest do
  @moduledoc """
  Tests for the ProcessStoreServer GenServer.

  Custom server names still share the production ETS and DETS names. These
  non-async fixtures temporarily stop only the canonical supervised store,
  use a fresh DETS file, then close the fixture before restoring that child.
  """
  use ExUnit.Case, async: false

  alias CodingAgent.{ProcessStore, ProcessStoreServer}

  setup do
    name = :"process_store_server_test_#{System.unique_integer([:positive])}"

    tmp_dir =
      Path.join(System.tmp_dir!(), "process_store_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    dets_path = Path.join(tmp_dir, "test.dets")
    canonical_running? = is_pid(Process.whereis(ProcessStoreServer))

    on_exit(fn ->
      try do
        File.rm_rf!(tmp_dir)
      after
        if canonical_running? do
          assert {:ok, _pid} =
                   Supervisor.restart_child(CodingAgent.Supervisor, ProcessStoreServer)
        end
      end
    end)

    if canonical_running? do
      assert :ok = Supervisor.terminate_child(CodingAgent.Supervisor, ProcessStoreServer)
    end

    assert :ets.whereis(:coding_agent_processes) == :undefined
    assert :dets.info(:coding_agent_processes_dets) == :undefined

    {:ok, name: name, tmp_dir: tmp_dir, dets_path: dets_path}
  end

  describe "start_link/1" do
    test "starts the server with a custom name", %{name: name, dets_path: dets_path} do
      pid = start_server!(name, dets_path)
      assert is_pid(pid)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "returns existing pid when already started", %{name: name, dets_path: dets_path} do
      pid1 = start_server!(name, dets_path)
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
      pid = start_server!(name, dets_path)
      assert :ok = ProcessStoreServer.ensure_table(pid)
      assert :ets.info(:coding_agent_processes, :owner) == pid
      GenServer.stop(pid)
    end
  end

  describe "cleanup/2" do
    test "removes expired processes", %{name: name, dets_path: dets_path} do
      pid = start_server!(name, dets_path)

      # Insert a test process with old completed_at
      old_time = System.system_time(:second) - 1000
      record = %{status: :completed, completed_at: old_time, updated_at: old_time}
      insert_record(pid, "test_proc_1", record)

      assert {:ok, _deleted} = ProcessStoreServer.cleanup(pid, 60)
      assert :ets.lookup(:coding_agent_processes, "test_proc_1") == []
      assert :dets.lookup(:coding_agent_processes_dets, "test_proc_1") == []

      GenServer.stop(pid)
    end

    test "does not remove recent processes", %{name: name, dets_path: dets_path} do
      pid = start_server!(name, dets_path)

      # Insert a test process with recent completed_at
      recent_time = System.system_time(:second) - 10
      record = %{status: :completed, completed_at: recent_time, updated_at: recent_time}
      insert_record(pid, "test_proc_2", record)

      # Cleanup with TTL of 60 seconds should NOT remove the recent record
      assert {:ok, _deleted} = ProcessStoreServer.cleanup(pid, 60)
      assert :ets.lookup(:coding_agent_processes, "test_proc_2") == [{"test_proc_2", record, []}]

      assert :dets.lookup(:coding_agent_processes_dets, "test_proc_2") == [
               {"test_proc_2", record, []}
             ]

      GenServer.stop(pid)
    end

    test "does not remove running processes", %{name: name, dets_path: dets_path} do
      pid = start_server!(name, dets_path)

      # Insert a running process (old but still running)
      old_time = System.system_time(:second) - 1000
      record = %{status: :running, inserted_at: old_time}
      insert_record(pid, "test_proc_3", record)

      # Cleanup should NOT remove running processes
      assert {:ok, _deleted} = ProcessStoreServer.cleanup(pid, 60)
      assert :ets.lookup(:coding_agent_processes, "test_proc_3") == [{"test_proc_3", record, []}]

      assert :dets.lookup(:coding_agent_processes_dets, "test_proc_3") == [
               {"test_proc_3", record, []}
             ]

      GenServer.stop(pid)
    end
  end

  describe "clear/1" do
    test "removes all processes from ETS", %{name: name, dets_path: dets_path} do
      pid = start_server!(name, dets_path)

      # Insert test processes
      insert_record(pid, "proc_1", %{status: :running})
      insert_record(pid, "proc_2", %{status: :completed})

      assert :ok = ProcessStoreServer.clear(pid)

      for id <- ["proc_1", "proc_2"] do
        assert :ets.lookup(:coding_agent_processes, id) == []
        assert :dets.lookup(:coding_agent_processes_dets, id) == []
      end

      GenServer.stop(pid)
    end
  end

  describe "dets_status/1" do
    test "returns status info for initialized DETS", %{name: name, dets_path: dets_path} do
      pid = start_server!(name, dets_path)

      status = ProcessStoreServer.dets_status(pid)
      assert status.state.dets_initialized
      assert status.state.ets_initialized
      assert status.state.loaded_from_dets
      assert status.state.dets_path == dets_path
      assert List.to_string(status.info.filename) == dets_path
      assert status.info.type == :set

      GenServer.stop(pid)
    end
  end

  describe "server lifecycle" do
    test "ETS table survives client process exits", %{name: name, dets_path: dets_path} do
      pid = start_server!(name, dets_path)
      record = %{status: :completed, completed_at: System.system_time(:second)}

      {client, ref} =
        spawn_monitor(fn ->
          insert_record(pid, "lifecycle_proc", record)
        end)

      assert_receive {:DOWN, ^ref, :process, ^client, :normal}, 5_000
      assert Process.alive?(pid)
      assert :ets.info(:coding_agent_processes, :owner) == pid

      assert {:ok, ^record, []} =
               ProcessStoreServer.transaction(pid, fn -> ProcessStore.get("lifecycle_proc") end)

      assert :dets.lookup(:coding_agent_processes_dets, "lifecycle_proc") == [
               {"lifecycle_proc", record, []}
             ]

      GenServer.stop(pid)
      assert :ets.whereis(:coding_agent_processes) == :undefined
      assert :dets.info(:coding_agent_processes_dets) == :undefined

      # The client never owned either table; a new store recovers its durable row.
      restarted = start_server!(name, dets_path)

      assert {:ok, ^record, []} =
               ProcessStoreServer.transaction(restarted, fn ->
                 ProcessStore.get("lifecycle_proc")
               end)
    end
  end

  defp start_server!(name, dets_path) do
    assert {:ok, pid} = ProcessStoreServer.start_link(name: name, dets_path: dets_path)
    Process.unlink(pid)

    # Registered after fixture restoration so this runs first, even on failure.
    on_exit({:store_server, pid}, fn ->
      ref = Process.monitor(pid)

      try do
        GenServer.stop(pid)
      catch
        :exit, {:noproc, _} -> :ok
      end

      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    end)

    assert :ok = ProcessStoreServer.ensure_table(pid)
    assert :ets.info(:coding_agent_processes, :owner) == pid
    assert List.to_string(:dets.info(:coding_agent_processes_dets, :filename)) == dets_path
    assert is_pid(:dets.info(:coding_agent_processes_dets, :owner))
    assert :dets.info(:coding_agent_processes_dets, :access) == :read_write
    pid
  end

  defp insert_record(pid, id, record) do
    assert :ok =
             ProcessStoreServer.transaction(pid, fn ->
               :ok = ProcessStore.insert_record(id, record, [])
               :dets.sync(:coding_agent_processes_dets)
             end)

    assert :ets.lookup(:coding_agent_processes, id) == [{id, record, []}]
    assert :dets.lookup(:coding_agent_processes_dets, id) == [{id, record, []}]
  end
end
