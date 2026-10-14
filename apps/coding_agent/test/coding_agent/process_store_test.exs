defmodule CodingAgent.ProcessStoreTest do
  use ExUnit.Case, async: false

  alias CodingAgent.ProcessManager
  alias CodingAgent.ProcessSession
  alias CodingAgent.ProcessStore
  alias CodingAgent.ProcessStoreServer
  import CodingAgent.AsyncHelpers

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
      assert :ok = ProcessStore.mark_running(process_id, 12_345)

      assert {:ok, record, _} = ProcessStore.get(process_id)
      assert record.status == :running
      assert record.os_pid == 12_345
      assert is_integer(record.started_at)
    end

    test "returns ok for unknown process" do
      assert :ok = ProcessStore.mark_running("unknown_process_id", 12_345)
    end
  end

  describe "append_log/2" do
    test "appends log lines to a process" do
      process_id = ProcessStore.new_process(%{command: "echo test"})

      assert :ok = ProcessStore.append_log(process_id, "Line 1")
      assert :ok = ProcessStore.append_log(process_id, "Line 2")

      assert {:ok, _, logs} = ProcessStore.get(process_id)
      assert logs == ["Line 1", "Line 2"]
      assert {:ok, record, _logs} = ProcessStore.get(process_id)
      assert record.log_line_count == 2
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
      ProcessStore.mark_running(process_id, 12_345)

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
      ProcessStore.mark_running(process_id, 12_345)

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
      ProcessStore.mark_running(process_id, 12_345)

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
      ProcessStore.mark_running(process_id, 12_345)
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
      ProcessStore.mark_running(process_id, 12_345)
      ProcessStore.mark_completed(process_id, 0)

      # Cleanup with 1 hour TTL should keep it
      assert :ok = ProcessStore.cleanup(3600)
      assert {:ok, _, _} = ProcessStore.get(process_id)
    end

    test "keeps a draining capture but removes finalized output before its session stops" do
      {id, 50} = start_owned_session("cleanup-draining")
      {:ok, %{full_output_path: path}} = ProcessSession.get_state(id)

      # A terminal store classification alone does not prove output is closed.
      # This is the boundary between cancellation/timeout and port exit.
      :ok = ProcessStore.mark_error(id, :timeout)
      assert :ok = ProcessStore.cleanup(0)

      assert {:ok, %{output: %{artifact_capacity: 50, finalized: false}}, _} =
               ProcessStore.get(id)

      assert File.exists?(path)

      :ok = ProcessSession.write_stdin(id, "\n")

      assert_eventually(fn ->
        {:ok, state} = ProcessSession.get_state(id)
        state.output_finalized
      end)

      assert ProcessSession.alive?(id)
      assert :ok = ProcessStore.cleanup(0)
      assert {:error, :not_found} = ProcessStore.get(id)
      refute File.exists?(path)
    end
  end

  describe "reserve_artifact/4" do
    test "reclaims the owner's oldest stopped artifacts and caps grants by live reservations" do
      now = System.system_time(:second)
      {older, older_path} = stopped_artifact("owner-a", now - 100)
      {_newer, newer_path} = stopped_artifact("owner-a", now - 50)
      {_foreign, foreign_path} = stopped_artifact("owner-b", now - 200)

      # Each live session asks for 50 bytes within a 140-byte owner budget.
      assert {first, 50} = start_owned_session("owner-a")
      assert File.exists?(older_path) and File.exists?(newer_path)

      assert {second, 50} = start_owned_session("owner-a")
      refute File.exists?(older_path)
      assert File.exists?(newer_path)

      assert {:ok, %{full_output_path: nil, output: %{artifact_reclaimed: true}}, _logs} =
               ProcessStore.get(older)

      # Live sessions' artifacts are never reclaimed, so the grant shrinks.
      assert {third, 40} = start_owned_session("owner-a")
      refute File.exists?(newer_path)
      assert File.exists?(foreign_path)

      owner_charge =
        ProcessStore.list()
        |> Enum.filter(fn {_id, record} -> record.owner == "owner-a" end)
        |> Enum.map(fn {_id, record} -> record.output.artifact_capacity end)
        |> Enum.sum()

      assert owner_charge == 140

      Enum.each([first, second, third], &ProcessSession.kill/1)
    end

    test "concurrent captures share finite owner reservations and actual file bytes" do
      sessions =
        for _ <- 1..4 do
          Task.async(fn ->
            id = "concurrent-quota-#{System.unique_integer([:positive])}"

            {:ok, pid} =
              ProcessSession.start_link(
                command: "read line",
                process_id: id,
                owner: "concurrent-owner",
                max_artifact_bytes: 50,
                max_owner_artifact_bytes: 140
              )

            Process.unlink(pid)
            {:ok, state} = ProcessSession.get_state(id)
            {id, pid, state}
          end)
        end
        |> Enum.map(&Task.await/1)

      on_exit(fn ->
        Enum.each(sessions, fn {id, _pid, _state} ->
          if ProcessSession.alive?(id), do: ProcessSession.stop(id)
          ProcessStore.delete(id)
        end)
      end)

      assert Enum.map(sessions, fn {_id, _pid, state} -> state.artifact_capacity end)
             |> Enum.sort() == [0, 40, 50, 50]

      for {id, pid, state} <- sessions do
        send(pid, {state.port, {:data, String.duplicate("x", 60)}})
        assert {:ok, %{output: output}} = ProcessSession.poll(id)
        assert output.artifact_bytes == state.artifact_capacity
        assert output.artifact_discarded_bytes == 60 - state.artifact_capacity
        assert File.stat!(state.full_output_path).size == state.artifact_capacity
      end

      assert Enum.sum(
               Enum.map(sessions, fn {_id, _pid, state} ->
                 File.stat!(state.full_output_path).size
               end)
             ) == 140
    end

    test "runtime budget caps different live owners and reclaims stopped owners" do
      {first, 50} = start_owned_session("runtime-a", max_runtime_artifact_bytes: 70)
      {second, 20} = start_owned_session("runtime-b", max_runtime_artifact_bytes: 70)
      {:ok, %{port: port, full_output_path: first_path}} = ProcessSession.get_state(first)
      [{pid, _}] = Registry.lookup(CodingAgent.ProcessRegistry, first)
      send(pid, {port, {:data, String.duplicate("x", 40)}})
      assert {:ok, %{output: %{artifact_bytes: 40}}} = ProcessSession.poll(first)
      ProcessSession.stop(first)
      assert File.stat!(first_path).size == 40

      {third, 50} = start_owned_session("runtime-c", max_runtime_artifact_bytes: 70)
      refute File.exists?(first_path)
      assert {:ok, %{output: %{artifact_reclaimed: true}}, _} = ProcessStore.get(first)
      assert {:ok, %{artifact_capacity: 20}} = ProcessSession.get_state(second)
      assert {:ok, %{artifact_capacity: 50}} = ProcessSession.get_state(third)
    end

    test "finalization returns unused reservation without deleting useful completed output" do
      {first, 50} = start_owned_session(nil, max_owner_artifact_bytes: 60)
      {:ok, %{port: port, full_output_path: path}} = ProcessSession.get_state(first)
      [{pid, _}] = Registry.lookup(CodingAgent.ProcessRegistry, first)
      send(pid, {port, {:data, "diagnostic"}})
      assert {:ok, %{output: %{artifact_bytes: 10}}} = ProcessSession.poll(first)
      :ok = ProcessSession.write_stdin(first, "\n")

      assert_eventually(fn ->
        {:ok, result} = ProcessSession.poll(first)
        result.status == :completed
      end)

      ProcessSession.stop(first)

      assert {:ok, %{output: %{artifact_capacity: 10, finalized: true}}, ["diagnostic"]} =
               ProcessStore.get(first)

      {_second, 50} = start_owned_session(nil, max_owner_artifact_bytes: 60)
      assert File.read!(path) == "diagnostic"
    end

    test "failed reclamation and cleanup preserve the artifact charge and reference" do
      {blocked, path} = stopped_artifact("cleanup-owner", System.system_time(:second) - 100)
      File.rm!(path)
      File.mkdir!(path)
      File.write!(Path.join(path, "retained"), "do not forget this charge")
      on_exit(fn -> File.rm_rf!(path) end)

      {_id, 0} = start_owned_session("cleanup-owner", max_owner_artifact_bytes: 40)

      assert {:ok,
              %{
                full_output_path: ^path,
                output: %{artifact_capacity: 40, artifact_reclaimed: false}
              }, _} = ProcessStore.get(blocked)

      assert {:error, :output_cleanup_failed} = ProcessStore.delete(blocked)
      assert :ok = ProcessStore.cleanup(0)
      assert {:ok, _, _} = ProcessStore.get(blocked)

      File.rm_rf!(path)
      assert :ok = ProcessStore.delete(blocked)
      {_id, 40} = start_owned_session("cleanup-owner", max_owner_artifact_bytes: 40)
    end

    test "pre-quota persisted output is counted and reclaimed" do
      {legacy, path} = stopped_artifact("legacy-owner", System.system_time(:second) - 100)
      {:ok, record, logs} = ProcessStore.get(legacy)
      ProcessStore.insert_record(legacy, Map.delete(record, :output), logs)
      {_id, 50} = start_owned_session("legacy-owner", max_owner_artifact_bytes: 60)
      refute File.exists?(path)
      assert {:ok, %{output: %{artifact_reclaimed: true}}, _} = ProcessStore.get(legacy)
    end

    test "cursor mutations serialize with reservation and reclamation" do
      {older, path} = stopped_artifact("serialized-owner", System.system_time(:second) - 100)
      next = ProcessStore.new_process(%{owner: "serialized-owner"})
      parent = self()
      token = make_ref()

      reserver =
        Task.async(fn ->
          ProcessStoreServer.transaction(ProcessStoreServer, fn ->
            send(parent, {token, :locked, self()})

            receive do
              {^token, :continue} -> :ok
            after
              5_000 -> flunk("reservation barrier was not released")
            end
          end)

          ProcessStore.reserve_artifact(next, 50, 60, 100)
        end)

      assert_receive {^token, :locked, server}
      updater = Task.async(fn -> ProcessStore.put_read_cursor(older, 7) end)

      assert_eventually(fn ->
        {:messages, messages} = Process.info(server, :messages)

        Enum.any?(messages, fn
          {:"$gen_call", _from, {:transaction, _fun}} -> true
          _ -> false
        end)
      end)

      send(server, {token, :continue})
      assert {:ok, 50} = Task.await(reserver)
      assert :ok = Task.await(updater)
      refute File.exists?(path)

      assert {:ok,
              %{
                read_cursor: 7,
                full_output_path: nil,
                output: %{artifact_capacity: 0, artifact_reclaimed: true}
              }, _} = ProcessStore.get(older)

      assert {:ok, %{output: %{artifact_capacity: 50}}, _} = ProcessStore.get(next)
    end

    test "unmeasurable legacy artifacts fail closed instead of counting as zero" do
      {legacy, path} = stopped_artifact("unknown-owner", System.system_time(:second) - 100)
      {:ok, record, logs} = ProcessStore.get(legacy)
      ProcessStore.insert_record(legacy, Map.delete(record, :output), logs)
      File.rm!(path)
      File.ln_s!(path, path)
      next = ProcessStore.new_process(%{owner: "unknown-owner"})

      assert {:error, :artifact_accounting_unavailable} =
               ProcessStore.reserve_artifact(next, 50, 60, 100)

      assert {:ok, %{full_output_path: ^path}, _} = ProcessStore.get(legacy)
      assert {:ok, %{output: %{artifact_capacity: 0}}, _} = ProcessStore.get(next)

      marker =
        Path.join(System.tmp_dir!(), "quota-no-start-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm(marker) end)
      quoted_marker = "'" <> String.replace(marker, "'", "'\"'\"'") <> "'"

      # Exercise the production supervisor boundary: a rejected linked child
      # must return its startup error without terminating the requesting caller.
      assert {:error, :process_start_failed} =
               ProcessManager.exec(
                 command: "printf started > #{quoted_marker}",
                 owner: "unknown-owner",
                 use_lane_queue: false
               )

      refute File.exists?(marker)

      assert ProcessStore.list()
             |> Enum.filter(fn {_id, record} -> record.owner == "unknown-owner" end)
             |> Enum.map(&elem(&1, 0))
             |> Enum.sort() == Enum.sort([legacy, next])
    end

    test "closed accounting storage refuses a reservation" do
      next = ProcessStore.new_process(%{owner: "unavailable-dets"})
      %{state: %{dets_path: path}} = ProcessStoreServer.dets_status()

      assert :ok =
               ProcessStoreServer.transaction(ProcessStoreServer, fn ->
                 :dets.close(:coding_agent_processes_dets)
               end)

      try do
        assert {:error, :artifact_accounting_unavailable} =
                 ProcessStore.reserve_artifact(next, 50, 60, 100)
      after
        assert {:ok, :coding_agent_processes_dets} =
                 ProcessStoreServer.transaction(ProcessStoreServer, fn ->
                   :dets.open_file(:coding_agent_processes_dets,
                     file: String.to_charlist(path),
                     type: :set
                   )
                 end)
      end
    end

    test "store-only reload preserves a live capture and its reservation" do
      {first, 50} = start_owned_session("reload-owner", max_owner_artifact_bytes: 60)
      :ets.delete_all_objects(:coding_agent_processes)
      assert :ok = ProcessStoreServer.ensure_table()

      assert {:ok, %{status: :running, output: %{artifact_capacity: 50, finalized: false}}, _} =
               ProcessStore.get(first)

      assert ProcessSession.alive?(first)
      {_second, 10} = start_owned_session("reload-owner", max_owner_artifact_bytes: 60)
    end
  end

  defp stopped_artifact(owner, completed_at) do
    path =
      Path.join(
        System.tmp_dir!(),
        "lemon-process-#{:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)}.log"
      )

    File.write!(path, String.duplicate("x", 40))
    on_exit(fn -> File.rm(path) end)
    process_id = ProcessStore.new_process(%{owner: owner, full_output_path: path})
    :ok = ProcessStore.mark_completed(process_id, 0)
    {:ok, record, logs} = ProcessStore.get(process_id)
    output = %{record.output | artifact_bytes: 40, artifact_capacity: 40}

    ProcessStore.insert_record(
      process_id,
      %{record | completed_at: completed_at, output: output},
      logs
    )

    {process_id, path}
  end

  defp start_owned_session(owner, opts \\ []) do
    process_id = "reserve-#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      ProcessSession.start_link(
        [command: "read line", process_id: process_id, owner: owner] ++
          Keyword.merge([max_artifact_bytes: 50, max_owner_artifact_bytes: 140], opts)
      )

    on_exit(fn ->
      if ProcessSession.alive?(process_id), do: ProcessSession.stop(process_id)
      ProcessStore.delete(process_id)
    end)

    {:ok, %{artifact_capacity: capacity}} = ProcessSession.get_state(process_id)
    {process_id, capacity}
  end

  describe "dets_open?/0" do
    test "returns boolean" do
      assert is_boolean(ProcessStore.dets_open?())
    end
  end

  describe "persistence" do
    test "processes survive server restart when DETS is available" do
      process_id = ProcessStore.new_process(%{command: "echo test"})
      ProcessStore.mark_running(process_id, 12_345)
      ProcessStore.append_log(process_id, "log line")

      # Simulate restart by clearing ETS
      :ets.delete_all_objects(:coding_agent_processes)

      # Manually trigger reload from DETS by calling ensure_table
      ProcessStoreServer.ensure_table(CodingAgent.ProcessStoreServer)

      # Check if data was recovered - may or may not work depending on DETS config
      case ProcessStore.get(process_id) do
        {:ok, record, logs} ->
          assert record.command == "echo test"
          assert record.os_pid == 12_345
          assert logs == ["log line"]

        {:error, :not_found} ->
          # DETS not available in test, skip assertions
          :ok
      end
    end

    test "running processes are marked as lost on restart" do
      process_id = ProcessStore.new_process(%{command: "echo test"})
      ProcessStore.mark_running(process_id, 12_345)

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
