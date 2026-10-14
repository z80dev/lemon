defmodule CodingAgent.ProcessStoreServerTest do
  @moduledoc """
  Tests for the ProcessStoreServer GenServer.

  Custom server names still share the production ETS and DETS names. These
  non-async fixtures temporarily stop only the canonical supervised store,
  use a fresh DETS file, then close the fixture before restoring that child.
  """
  use ExUnit.Case, async: false

  alias CodingAgent.ProcessStoreServer

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

      # The ETS table is global; other suites may leave expired rows, so assert
      # on this record rather than on the total deleted count.
      assert {:ok, deleted} = ProcessStoreServer.cleanup(pid, 60)
      assert deleted >= 1
      assert :ets.lookup(:coding_agent_processes, "test_proc_1") == []

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

  describe "late DETS load" do
    test "late read-only storage recovery restores capacity before admission", %{
      name: name,
      dets_path: dets_path,
      tmp_dir: tmp_dir
    } do
      File.chmod!(tmp_dir, 0o700)
      owner = "late-open-owner"
      held = "late-open-held"
      pending = "late-open-pending"
      fingerprint = :crypto.hash(:sha256, "late-open-command")
      deadline = System.system_time(:millisecond) + 60_000
      pid = start_server!(name, dets_path, background_process_limit: 1)

      assert :new =
               GenServer.call(pid, {:register_launch, held, owner, fingerprint, deadline, self()})

      assert :ok = GenServer.call(pid, {:claim_launch, held, owner, fingerprint})
      GenServer.stop(pid)

      File.chmod!(dets_path, 0o400)

      recovered =
        start_server!(name, dets_path, background_process_limit: 1, storage_unavailable: true)

      assert %{state: %{dets_initialized: false, loaded_from_dets: false}} =
               ProcessStoreServer.dets_status(recovered)

      File.chmod!(dets_path, 0o600)

      # Registration itself triggers the late load. Counting only in init lets
      # the following claim start another process on top of the retained slot.
      assert :new =
               GenServer.call(
                 recovered,
                 {:register_launch, pending, owner, fingerprint, deadline, self()}
               )

      assert {:ok, %{identity: ^held, classification: :outcome_unknown, status: :lost}} =
               GenServer.call(recovered, {:launch_receipt, held, owner})

      assert {:error, :not_found} =
               GenServer.call(recovered, {:launch_receipt, held, owner <> "-foreign"})

      assert {:error, :capacity_full} =
               GenServer.call(recovered, {:claim_launch, pending, owner, fingerprint})

      refute GenServer.call(recovered, :background_capacity_available)

      assert %{occupied: 1, unknown: 1, queued: 1, limit: 1} =
               GenServer.call(recovered, :background_counts)

      # Reopening and repeated ensures must neither reset nor double charge the
      # held slot, and must retain this server's still-live pending admission.
      :sys.replace_state(recovered, fn state ->
        :ok = :dets.close(:coding_agent_processes_dets)
        state
      end)

      assert :ok = ProcessStoreServer.ensure_table(recovered)
      assert :ok = ProcessStoreServer.ensure_table(recovered)

      assert {:error, :capacity_full} =
               GenServer.call(recovered, {:claim_launch, pending, owner, fingerprint})

      assert %{occupied: 1, unknown: 1, queued: 1} =
               GenServer.call(recovered, :background_counts)

      assert :ok = GenServer.call(recovered, {:confirm_termination, held, :external_confirmed})
      assert :ok = GenServer.call(recovered, {:confirm_termination, held, :external_confirmed})
      assert :ok = GenServer.call(recovered, {:claim_launch, pending, owner, fingerprint})
      refute GenServer.call(recovered, :background_capacity_available)

      GenServer.stop(recovered)
      restarted = start_server!(name, dets_path, background_process_limit: 1)
      assert %{occupied: 1, unknown: 2} = GenServer.call(restarted, :background_counts)
      refute GenServer.call(restarted, :background_capacity_available)
    end

    test "late load rebinds a surviving launch owner exactly once", %{
      name: name,
      dets_path: dets_path
    } do
      id = "late-live-owner"
      owner = "late-live-session"
      fingerprint = :crypto.hash(:sha256, id)
      deadline = System.system_time(:millisecond) + 60_000
      parent = self()

      live =
        spawn(fn ->
          {:ok, _} = Registry.register(CodingAgent.ProcessRegistry, id, nil)
          send(parent, :owner_registered)

          receive do
            {:claim, server} ->
              send(
                parent,
                {:owner_claimed, GenServer.call(server, {:claim_launch, id, owner, fingerprint})}
              )
          end

          receive do: (:stop -> :ok)
        end)

      on_exit(fn -> Process.exit(live, :kill) end)
      assert_receive :owner_registered
      pid = start_server!(name, dets_path, background_process_limit: 1)

      assert :new =
               GenServer.call(pid, {:register_launch, id, owner, fingerprint, deadline, self()})

      send(live, {:claim, pid})
      assert_receive {:owner_claimed, :ok}
      GenServer.stop(pid)
      File.chmod!(dets_path, 0o400)

      recovered =
        start_server!(name, dets_path, background_process_limit: 1, storage_unavailable: true)

      assert %{state: %{dets_initialized: false}} = ProcessStoreServer.dets_status(recovered)
      File.chmod!(dets_path, 0o600)

      assert :ok = ProcessStoreServer.ensure_table(recovered)

      :sys.replace_state(recovered, fn state ->
        :ok = :dets.close(:coding_agent_processes_dets)
        state
      end)

      assert :ok = ProcessStoreServer.ensure_table(recovered)
      assert :ok = ProcessStoreServer.ensure_table(recovered)

      assert :ok = GenServer.call(recovered, {:subscribe_capacity, self()})
      send(live, :stop)
      assert_receive {:background_launch_classified, ^id, :outcome_unknown}

      assert {:ok, %{identity: ^id, status: :lost, classification: :outcome_unknown}} =
               GenServer.call(recovered, {:launch_receipt, id, owner})

      refute GenServer.call(recovered, :background_capacity_available)
      state = ProcessStoreServer.dets_status(recovered).state
      assert state.live_ref_index == %{}
      assert state.live_identity_index == %{}
    end
  end

  defp start_server!(name, dets_path, opts) do
    assert {:ok, pid} =
             ProcessStoreServer.start_link(Keyword.merge(opts, name: name, dets_path: dets_path))

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

    unless Keyword.get(opts, :storage_unavailable, false) do
      assert :ok = ProcessStoreServer.ensure_table(pid)
      assert :ets.info(:coding_agent_processes, :owner) == pid
      assert List.to_string(:dets.info(:coding_agent_processes_dets, :filename)) == dets_path
      assert is_pid(:dets.info(:coding_agent_processes_dets, :owner))
      assert :dets.info(:coding_agent_processes_dets, :access) == :read_write
    end

    pid
  end
end
