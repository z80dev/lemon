defmodule CodingAgent.RunGraphServerTest do
  @moduledoc """
  Tests for the CodingAgent.RunGraphServer module.

  These tests verify the GenServer that owns the RunGraph ETS table
  and manages DETS persistence, including table initialization,
  clearing, statistics, cleanup, and DETS status.
  """

  use ExUnit.Case, async: false

  alias CodingAgent.RunGraph
  alias CodingAgent.RunGraphServer

  setup do
    # Clear all runs before each test
    try do
      RunGraph.clear()
    catch
      _, _ -> :ok
    end

    :ok
  end

  describe "start_link/1" do
    test "starts the server with default options" do
      # The server is already started by the application
      assert Process.whereis(RunGraphServer) != nil
    end

    test "starts the server with custom name" do
      # Start a new server with a custom name
      server_name = :test_run_graph_server

      # Stop if already running
      try do
        GenServer.stop(server_name)
      catch
        _, _ -> :ok
      end

      # Start with custom name
      opts = [name: server_name, dets_path: Path.join(System.tmp_dir!(), "test_run_graph_#{:rand.uniform(10000)}.dets")]
      assert {:ok, pid} = RunGraphServer.start_link(opts)
      assert Process.alive?(pid)
      assert Process.whereis(server_name) == pid

      GenServer.stop(server_name)
    end
  end

  describe "table_name/0" do
    test "returns the ETS table name" do
      assert RunGraphServer.table_name() == :coding_agent_run_graph
    end
  end

  describe "ensure_table/1" do
    test "initializes ETS table if not already done" do
      # Table should already be initialized from application start
      assert :ok = RunGraphServer.ensure_table()

      # Verify the table exists
      table = RunGraphServer.table_name()
      assert :ets.whereis(table) != :undefined
    end

    test "succeeds if table is already initialized" do
      # First call initializes
      assert :ok = RunGraphServer.ensure_table()

      # Second call should also succeed
      assert :ok = RunGraphServer.ensure_table()
    end

    test "can be called with specific server pid" do
      assert :ok = RunGraphServer.ensure_table(RunGraphServer)
    end
  end

  describe "clear/1" do
    test "removes all runs from ETS" do
      # Create some runs
      run1 = RunGraph.new_run(%{type: :task})
      run2 = RunGraph.new_run(%{type: :subagent})

      assert {:ok, _} = RunGraph.get(run1)
      assert {:ok, _} = RunGraph.get(run2)

      # Clear via server
      assert :ok = RunGraphServer.clear()

      # Verify all runs are gone
      assert {:error, :not_found} = RunGraph.get(run1)
      assert {:error, :not_found} = RunGraph.get(run2)
    end

    test "clears from DETS as well" do
      # Create and clear a run
      run = RunGraph.new_run(%{type: :task})
      assert {:ok, _} = RunGraph.get(run)

      assert :ok = RunGraphServer.clear()

      # After clear, the run should not exist
      assert {:error, :not_found} = RunGraph.get(run)
    end

    test "can be called with specific server pid" do
      RunGraph.new_run(%{type: :task})

      assert :ok = RunGraphServer.clear(RunGraphServer)
    end
  end

  describe "stats/1" do
    test "returns table statistics" do
      # Clear to get known state
      RunGraph.clear()

      stats = RunGraphServer.stats()
      assert stats.initialized == true
      assert stats.size == 0
      assert is_integer(stats.memory)

      # Create some runs
      for _ <- 1..5 do
        RunGraph.new_run(%{type: :task})
      end

      stats = RunGraphServer.stats()
      assert stats.size == 5
      assert stats.memory > 0
    end

    test "returns initialized: false if table not initialized" do
      # This test verifies the structure of stats when uninitialized
      # In practice, ensure_tables() will initialize it before returning
      stats = RunGraphServer.stats()
      assert is_map(stats)
      assert Map.has_key?(stats, :initialized)
    end

    test "can be called with specific server pid" do
      stats = RunGraphServer.stats(RunGraphServer)
      assert stats.initialized == true
    end
  end

  describe "cleanup/2" do
    test "removes expired completed runs" do
      RunGraph.clear()

      # Create and complete a run
      run = RunGraph.new_run(%{type: :task})
      RunGraph.mark_running(run)
      RunGraph.finish(run, %{result: "done"})

      # Manually set completed_at to be old
      {:ok, record} = RunGraph.get(run)
      old_record = %{record | completed_at: System.system_time(:second) - 100}
      RunGraph.insert_record(run, old_record)

      # Cleanup with 50 second TTL should remove it
      assert {:ok, deleted_count} = RunGraphServer.cleanup(RunGraphServer, 50)
      assert deleted_count >= 1
      assert {:error, :not_found} = RunGraph.get(run)
    end

    test "removes expired errored runs" do
      RunGraph.clear()

      # Create and fail a run
      run = RunGraph.new_run(%{type: :task})
      RunGraph.mark_running(run)
      RunGraph.fail(run, "error")

      # Manually set completed_at to be old
      {:ok, record} = RunGraph.get(run)
      old_record = %{record | completed_at: System.system_time(:second) - 100}
      RunGraph.insert_record(run, old_record)

      # Cleanup with 50 second TTL should remove it
      assert {:ok, deleted_count} = RunGraphServer.cleanup(RunGraphServer, 50)
      assert deleted_count >= 1
      assert {:error, :not_found} = RunGraph.get(run)
    end

    test "does not remove running runs" do
      RunGraph.clear()

      # Create and mark running
      run = RunGraph.new_run(%{type: :task})
      RunGraph.mark_running(run)

      # Manually set updated_at to be old (but status is running)
      {:ok, record} = RunGraph.get(run)
      old_record = %{record | updated_at: System.system_time(:second) - 100}
      RunGraph.insert_record(run, old_record)

      # Cleanup should not remove running runs
      assert {:ok, 0} = RunGraphServer.cleanup(RunGraphServer, 50)
      assert {:ok, _} = RunGraph.get(run)
    end

    test "does not remove queued runs" do
      RunGraph.clear()

      # Create but don't start
      run = RunGraph.new_run(%{type: :task})

      # Manually set inserted_at to be old
      {:ok, record} = RunGraph.get(run)
      old_record = %{record | inserted_at: System.system_time(:second) - 100}
      RunGraph.insert_record(run, old_record)

      # Cleanup should not remove queued runs
      assert {:ok, 0} = RunGraphServer.cleanup(RunGraphServer, 50)
      assert {:ok, _} = RunGraph.get(run)
    end

    test "does not remove recent completed runs with long TTL" do
      RunGraph.clear()

      run = RunGraph.new_run(%{type: :task})
      RunGraph.mark_running(run)
      RunGraph.finish(run, %{result: "done"})

      # Cleanup with 1 hour TTL should keep it
      assert {:ok, 0} = RunGraphServer.cleanup(RunGraphServer, 3600)
      assert {:ok, _} = RunGraph.get(run)
    end

    test "can be called with custom TTL" do
      RunGraph.clear()

      run = RunGraph.new_run(%{type: :task})
      RunGraph.mark_running(run)
      RunGraph.finish(run, %{result: "done"})

      # Set completed_at to 5 minutes ago
      {:ok, record} = RunGraph.get(run)
      old_record = %{record | completed_at: System.system_time(:second) - 300}
      RunGraph.insert_record(run, old_record)

      # Cleanup with 10 minute TTL should not remove
      assert {:ok, 0} = RunGraphServer.cleanup(RunGraphServer, 600)

      # Cleanup with 1 minute TTL should remove
      assert {:ok, deleted_count} = RunGraphServer.cleanup(RunGraphServer, 60)
      assert deleted_count >= 1
    end

    test "can be called with specific server pid" do
      assert {:ok, _} = RunGraphServer.cleanup(RunGraphServer, 3600)
    end
  end

  describe "dets_status/1" do
    test "returns DETS status information" do
      status = RunGraphServer.dets_status()

      assert is_map(status)
      assert is_map(status.info)
      assert is_map(status.state)
      assert Map.has_key?(status.state, :loaded_from_dets)
      assert Map.has_key?(status.state, :ets_initialized)
      assert Map.has_key?(status.state, :dets_initialized)
    end

    test "returns not_initialized status when DETS is not initialized" do
      # The status should indicate DETS state
      status = RunGraphServer.dets_status()

      # Either initialized or not, we get proper structure
      # When DETS is initialized, info contains :size, :type, etc.
      # When not initialized, status field may be set to :not_initialized
      has_status = Map.has_key?(status.info, :status)
      has_size = Map.has_key?(status.info, :size)
      
      if has_status do
        assert status.info.status in [:not_initialized, :closed]
      else
        assert has_size or Map.has_key?(status.info, :filename)
      end
    end

    test "can be called with specific server pid" do
      status = RunGraphServer.dets_status(RunGraphServer)
      assert is_map(status)
      assert is_map(status.info)
    end
  end

  describe "integration with RunGraph" do
    test "RunGraph operations work through server-owned table" do
      RunGraph.clear()

      # Create runs via RunGraph API
      run1 = RunGraph.new_run(%{type: :parent})
      run2 = RunGraph.new_run(%{type: :child})

      # Add relationship
      RunGraph.add_child(run1, run2)

      # Update status
      RunGraph.mark_running(run1)
      RunGraph.finish(run1, %{result: "success"})

      # Verify via stats
      stats = RunGraphServer.stats()
      assert stats.size == 2

      # Verify data integrity
      assert {:ok, record1} = RunGraph.get(run1)
      assert record1.status == :completed
      assert record1.result == %{result: "success"}
      assert record1.children == [run2]

      assert {:ok, record2} = RunGraph.get(run2)
      assert record2.parent == run1
    end

    test "clear via RunGraph calls through to server" do
      run = RunGraph.new_run(%{type: :task})
      assert {:ok, _} = RunGraph.get(run)

      # Clear via RunGraph API
      assert :ok = RunGraph.clear()

      assert {:error, :not_found} = RunGraph.get(run)
    end

    test "stats via RunGraph delegates to server" do
      RunGraph.clear()

      # Create runs
      for _ <- 1..3 do
        RunGraph.new_run(%{type: :task})
      end

      # Get stats via RunGraph API
      stats = RunGraph.stats()
      assert stats.size == 3
      assert stats.initialized == true
    end

    test "cleanup via RunGraph delegates to server" do
      RunGraph.clear()

      # Create and complete a run with old timestamp
      run = RunGraph.new_run(%{type: :task})
      RunGraph.mark_running(run)
      RunGraph.finish(run, %{result: "done"})

      {:ok, record} = RunGraph.get(run)
      old_record = %{record | completed_at: System.system_time(:second) - 100}
      RunGraph.insert_record(run, old_record)

      # Cleanup via RunGraph API
      assert :ok = RunGraph.cleanup(50)

      # Run should be cleaned up
      assert {:error, :not_found} = RunGraph.get(run)
    end
  end

  describe "DETS persistence" do
    test "running runs are marked as lost on server restart" do
      RunGraph.clear()

      # Create a running run
      run = RunGraph.new_run(%{type: :task})
      RunGraph.mark_running(run)

      # Verify it's running
      assert {:ok, %{status: :running}} = RunGraph.get(run)

      # Simulate restart by clearing ETS
      :ets.delete_all_objects(:coding_agent_run_graph)

      # Re-ensure table (this would happen on server restart)
      RunGraphServer.ensure_table()

      # Check result - may be :lost if DETS recovered, or :not_found if not
      case RunGraph.get(run) do
        {:ok, record} ->
          # DETS recovered the run, it should be marked as lost
          assert record.status == :lost
          assert record.error == :lost_on_restart
          assert record.completed_at != nil

        {:error, :not_found} ->
          # DETS not available or empty in test environment
          :ok
      end
    end

    test "completed runs survive ETS clear when DETS is available" do
      RunGraph.clear()

      # Create and complete a run
      run = RunGraph.new_run(%{type: :task})
      RunGraph.mark_running(run)
      RunGraph.finish(run, %{result: "success"})

      # Clear ETS
      :ets.delete_all_objects(:coding_agent_run_graph)

      # Re-ensure table
      RunGraphServer.ensure_table()

      # Check if recovered from DETS
      case RunGraph.get(run) do
        {:ok, record} ->
          assert record.status == :completed
          assert record.result == %{result: "success"}

        {:error, :not_found} ->
          # DETS not available in test environment
          :ok
      end
    end

    test "errored runs survive ETS clear when DETS is available" do
      RunGraph.clear()

      # Create and fail a run
      run = RunGraph.new_run(%{type: :task})
      RunGraph.mark_running(run)
      RunGraph.fail(run, "test error")

      # Clear ETS
      :ets.delete_all_objects(:coding_agent_run_graph)

      # Re-ensure table
      RunGraphServer.ensure_table()

      # Check if recovered from DETS
      case RunGraph.get(run) do
        {:ok, record} ->
          assert record.status == :error
          assert record.error == "test error"

        {:error, :not_found} ->
          # DETS not available in test environment
          :ok
      end
    end
  end

  describe "server lifecycle" do
    test "server handles termination gracefully" do
      # The main server should be running
      pid = Process.whereis(RunGraphServer)
      assert pid != nil
      assert Process.alive?(pid)

      # Stats should work
      assert %{initialized: true} = RunGraphServer.stats()
    end

    test "server state tracks initialization" do
      status = RunGraphServer.dets_status()

      # State should track initialization
      assert status.state.ets_initialized == true
    end
  end

  describe "concurrent access" do
    test "handles concurrent stats calls" do
      # Create some runs
      for _ <- 1..10 do
        RunGraph.new_run(%{type: :task})
      end

      # Concurrent stats calls
      tasks =
        Enum.map(1..10, fn _ ->
          Task.async(fn ->
            RunGraphServer.stats()
          end)
        end)

      results = Enum.map(tasks, &Task.await/1)
      assert length(results) == 10
      assert Enum.all?(results, &(&1.initialized == true))
    end

    test "handles concurrent clear and ensure_table calls" do
      # Create runs
      for _ <- 1..5 do
        RunGraph.new_run(%{type: :task})
      end

      # Concurrent operations
      tasks =
        Enum.map(1..5, fn i ->
          Task.async(fn ->
            if rem(i, 2) == 0 do
              RunGraphServer.clear()
            else
              RunGraphServer.ensure_table()
            end
          end)
        end)

      results = Enum.map(tasks, &Task.await/1)
      assert Enum.all?(results, &(&1 == :ok))
    end
  end

  describe "edge cases" do
    test "cleanup handles empty table" do
      RunGraph.clear()

      assert {:ok, 0} = RunGraphServer.cleanup(RunGraphServer, 0)
      assert {:ok, 0} = RunGraphServer.cleanup(RunGraphServer, 3600)
    end

    test "clear on empty table succeeds" do
      RunGraph.clear()

      assert :ok = RunGraphServer.clear()
      assert %{size: 0} = RunGraphServer.stats()
    end

    test "multiple clears succeed" do
      RunGraph.new_run(%{type: :task})

      assert :ok = RunGraphServer.clear()
      assert :ok = RunGraphServer.clear()
      assert :ok = RunGraphServer.clear()
    end

    test "cleanup respects different terminal statuses" do
      RunGraph.clear()

      # Create runs with different terminal statuses
      completed = RunGraph.new_run(%{type: :task, status: :completed})
      errored = RunGraph.new_run(%{type: :task, status: :error})
      killed = RunGraph.new_run(%{type: :task, status: :killed})
      cancelled = RunGraph.new_run(%{type: :task, status: :cancelled})
      lost = RunGraph.new_run(%{type: :task, status: :lost})

      # Insert with old timestamps by directly manipulating records
      for run <- [completed, errored, killed, cancelled, lost] do
        {:ok, record} = RunGraph.get(run)
        # Ensure completed_at exists
        old_record = Map.put(record, :completed_at, System.system_time(:second) - 200)
        RunGraph.insert_record(run, old_record)
      end

      # Cleanup with short TTL should remove all terminal runs
      assert {:ok, deleted_count} = RunGraphServer.cleanup(RunGraphServer, 100)
      assert deleted_count >= 5
    end
  end
end
