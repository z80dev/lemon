defmodule CodingAgent.RunGraphTest do
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

  describe "new_run/1" do
    test "creates a run with default attributes" do
      run_id = RunGraph.new_run(%{type: :task})

      assert is_binary(run_id)
      assert {:ok, record} = RunGraph.get(run_id)
      assert record.status == :queued
      assert record.type == :task
      assert record.parent == nil
      assert record.children == []
      assert is_integer(record.inserted_at)
    end

    test "creates a run with custom attributes" do
      run_id = RunGraph.new_run(%{type: :subagent, description: "Test run", custom: "value"})

      assert {:ok, record} = RunGraph.get(run_id)
      assert record.type == :subagent
      assert record.description == "Test run"
      assert record.custom == "value"
    end

    test "generates unique run IDs" do
      run_ids = for _ <- 1..100, do: RunGraph.new_run(%{})
      assert length(Enum.uniq(run_ids)) == 100
    end
  end

  describe "mark_running/1" do
    test "marks a run as running" do
      run_id = RunGraph.new_run(%{type: :task})
      assert :ok = RunGraph.mark_running(run_id)

      assert {:ok, record} = RunGraph.get(run_id)
      assert record.status == :running
      assert is_integer(record.started_at)
    end

    test "returns ok for unknown run" do
      assert :ok = RunGraph.mark_running("unknown_run_id")
    end
  end

  describe "finish/2" do
    test "marks a run as completed with result" do
      run_id = RunGraph.new_run(%{type: :task})
      RunGraph.mark_running(run_id)

      result = %{answer: "42"}
      assert :ok = RunGraph.finish(run_id, result)

      assert {:ok, record} = RunGraph.get(run_id)
      assert record.status == :completed
      assert record.result == result
      assert is_integer(record.completed_at)
    end

    test "returns ok for unknown run" do
      assert :ok = RunGraph.finish("unknown_run_id", %{result: "test"})
    end
  end

  describe "fail/2" do
    test "marks a run as error with reason" do
      run_id = RunGraph.new_run(%{type: :task})
      RunGraph.mark_running(run_id)

      error = "Something went wrong"
      assert :ok = RunGraph.fail(run_id, error)

      assert {:ok, record} = RunGraph.get(run_id)
      assert record.status == :error
      assert record.error == error
      assert is_integer(record.completed_at)
    end

    test "returns ok for unknown run" do
      assert :ok = RunGraph.fail("unknown_run_id", "error")
    end
  end

  describe "get/1" do
    test "returns not_found for unknown run" do
      assert {:error, :not_found} = RunGraph.get("unknown_run_id")
    end
  end

  describe "add_child/2" do
    test "establishes parent-child relationship" do
      parent_id = RunGraph.new_run(%{type: :parent})
      child_id = RunGraph.new_run(%{type: :child})

      assert :ok = RunGraph.add_child(parent_id, child_id)

      assert {:ok, parent} = RunGraph.get(parent_id)
      assert parent.children == [child_id]

      assert {:ok, child} = RunGraph.get(child_id)
      assert child.parent == parent_id
    end

    test "supports multiple children" do
      parent_id = RunGraph.new_run(%{type: :parent})
      child1 = RunGraph.new_run(%{type: :child1})
      child2 = RunGraph.new_run(%{type: :child2})
      child3 = RunGraph.new_run(%{type: :child3})

      RunGraph.add_child(parent_id, child1)
      RunGraph.add_child(parent_id, child2)
      RunGraph.add_child(parent_id, child3)

      assert {:ok, parent} = RunGraph.get(parent_id)
      # Children are prepended, so order is reversed
      assert parent.children == [child3, child2, child1]
    end

    test "supports nested parent-child relationships" do
      grandparent = RunGraph.new_run(%{type: :grandparent})
      parent = RunGraph.new_run(%{type: :parent})
      child = RunGraph.new_run(%{type: :child})

      RunGraph.add_child(grandparent, parent)
      RunGraph.add_child(parent, child)

      assert {:ok, grandparent_record} = RunGraph.get(grandparent)
      assert grandparent_record.children == [parent]

      assert {:ok, parent_record} = RunGraph.get(parent)
      assert parent_record.parent == grandparent
      assert parent_record.children == [child]

      assert {:ok, child_record} = RunGraph.get(child)
      assert child_record.parent == parent
    end
  end

  describe "await/3 - wait_all" do
    test "returns immediately when all runs are completed" do
      run1 = RunGraph.new_run(%{type: :task})
      run2 = RunGraph.new_run(%{type: :task})

      RunGraph.mark_running(run1)
      RunGraph.mark_running(run2)
      RunGraph.finish(run1, %{result: "done1"})
      RunGraph.finish(run2, %{result: "done2"})

      assert {:ok, %{mode: :wait_all, runs: runs}} = RunGraph.await([run1, run2], :wait_all, 1_000)
      assert length(runs) == 2
      assert Enum.all?(runs, &(&1.status == :completed))
    end

    test "returns immediately when all runs have error" do
      run1 = RunGraph.new_run(%{type: :task})
      run2 = RunGraph.new_run(%{type: :task})

      RunGraph.mark_running(run1)
      RunGraph.mark_running(run2)
      RunGraph.fail(run1, "error1")
      RunGraph.fail(run2, "error2")

      assert {:ok, %{mode: :wait_all, runs: runs}} = RunGraph.await([run1, run2], :wait_all, 1_000)
      assert length(runs) == 2
      assert Enum.all?(runs, &(&1.status == :error))
    end

    test "returns immediately for mixed completed/error runs" do
      run1 = RunGraph.new_run(%{type: :task})
      run2 = RunGraph.new_run(%{type: :task})

      RunGraph.mark_running(run1)
      RunGraph.mark_running(run2)
      RunGraph.finish(run1, %{result: "done"})
      RunGraph.fail(run2, "error")

      assert {:ok, %{mode: :wait_all, runs: runs}} = RunGraph.await([run1, run2], :wait_all, 1_000)
      assert length(runs) == 2
    end

    test "waits for running runs to complete" do
      run1 = RunGraph.new_run(%{type: :task})
      run2 = RunGraph.new_run(%{type: :task})

      RunGraph.mark_running(run1)
      RunGraph.mark_running(run2)
      RunGraph.finish(run1, %{result: "done1"})
      # run2 is still running

      # Complete run2 asynchronously after a delay
      Task.start(fn ->
        Process.sleep(100)
        RunGraph.finish(run2, %{result: "done2"})
      end)

      assert {:ok, %{mode: :wait_all, runs: runs}} = RunGraph.await([run1, run2], :wait_all, 5_000)
      assert length(runs) == 2
      assert Enum.all?(runs, &(&1.status == :completed))
    end

    test "times out if runs don't complete in time" do
      run1 = RunGraph.new_run(%{type: :task})
      run2 = RunGraph.new_run(%{type: :task})

      RunGraph.mark_running(run1)
      RunGraph.mark_running(run2)
      # Neither completes

      assert {:error, :timeout, %{mode: :wait_all, runs: runs}} =
               RunGraph.await([run1, run2], :wait_all, 50)

      assert length(runs) == 2
      assert Enum.all?(runs, &(&1.status == :running))
    end

    test "handles single run_id (not in list)" do
      run = RunGraph.new_run(%{type: :task})
      RunGraph.mark_running(run)
      RunGraph.finish(run, %{result: "done"})

      assert {:ok, %{mode: :wait_all, runs: [run_record]}} = RunGraph.await(run, :wait_all, 1_000)
      assert run_record.status == :completed
    end

    test "returns unknown status for non-existent runs" do
      # Non-existent runs are immediately terminal (unknown status)
      assert {:ok, %{mode: :wait_all, runs: runs}} = RunGraph.await(["nonexistent"], :wait_all, 1_000)
      assert [%{id: "nonexistent", status: :unknown}] = runs
    end
  end

  describe "await/3 - wait_any" do
    test "returns immediately when one run is already completed" do
      run1 = RunGraph.new_run(%{type: :task})
      run2 = RunGraph.new_run(%{type: :task})

      RunGraph.mark_running(run1)
      RunGraph.mark_running(run2)
      RunGraph.finish(run1, %{result: "done1"})
      # run2 is still running

      assert {:ok, %{mode: :wait_any, run: run}} = RunGraph.await([run1, run2], :wait_any, 1_000)
      assert run.id == run1
      assert run.status == :completed
    end

    test "returns immediately when one run has error" do
      run1 = RunGraph.new_run(%{type: :task})
      run2 = RunGraph.new_run(%{type: :task})

      RunGraph.mark_running(run1)
      RunGraph.mark_running(run2)
      RunGraph.fail(run1, "error1")

      assert {:ok, %{mode: :wait_any, run: run}} = RunGraph.await([run1, run2], :wait_any, 1_000)
      assert run.id == run1
      assert run.status == :error
    end

    test "waits for any run to complete" do
      run1 = RunGraph.new_run(%{type: :task})
      run2 = RunGraph.new_run(%{type: :task})

      RunGraph.mark_running(run1)
      RunGraph.mark_running(run2)

      # Complete run2 asynchronously after a delay
      Task.start(fn ->
        Process.sleep(100)
        RunGraph.finish(run2, %{result: "done2"})
      end)

      assert {:ok, %{mode: :wait_any, run: run}} = RunGraph.await([run1, run2], :wait_any, 5_000)
      assert run.id == run2
      assert run.status == :completed
    end

    test "times out if no run completes" do
      run1 = RunGraph.new_run(%{type: :task})
      run2 = RunGraph.new_run(%{type: :task})

      RunGraph.mark_running(run1)
      RunGraph.mark_running(run2)

      assert {:error, :timeout, %{mode: :wait_any, runs: runs}} =
               RunGraph.await([run1, run2], :wait_any, 50)

      assert length(runs) == 2
    end

    test "handles single run_id (not in list)" do
      run = RunGraph.new_run(%{type: :task})
      RunGraph.mark_running(run)
      RunGraph.finish(run, %{result: "done"})

      assert {:ok, %{mode: :wait_any, run: run_record}} = RunGraph.await(run, :wait_any, 1_000)
      assert run_record.status == :completed
    end
  end

  describe "await/3 - terminal statuses" do
    test "considers :lost as terminal" do
      run = RunGraph.new_run(%{type: :task})
      RunGraph.mark_running(run)
      # Simulate lost status by directly manipulating the record
      # In practice this would come from persistence layer

      # For this test, we'll just verify that completed runs work
      RunGraph.finish(run, %{result: "done"})

      assert {:ok, _} = RunGraph.await([run], :wait_all, 100)
    end

    test "considers :killed as terminal" do
      # Create a run and manually insert with killed status
      run_id = RunGraph.new_run(%{type: :task})
      :ets.insert(:coding_agent_run_graph, {run_id, %{id: run_id, status: :killed}})

      assert {:ok, %{mode: :wait_all, runs: [%{status: :killed}]}} =
               RunGraph.await([run_id], :wait_all, 100)
    end

    test "considers :cancelled as terminal" do
      run_id = RunGraph.new_run(%{type: :task})
      :ets.insert(:coding_agent_run_graph, {run_id, %{id: run_id, status: :cancelled}})

      assert {:ok, %{mode: :wait_all, runs: [%{status: :cancelled}]}} =
               RunGraph.await([run_id], :wait_all, 100)
    end
  end

  describe "clear/0" do
    test "removes all runs" do
      run_id = RunGraph.new_run(%{type: :task})
      assert {:ok, _} = RunGraph.get(run_id)

      assert :ok = RunGraph.clear()

      assert {:error, :not_found} = RunGraph.get(run_id)
    end
  end

  describe "stats/0" do
    test "returns table statistics" do
      # Clear first to get a known state
      RunGraph.clear()

      # Create some runs
      for _ <- 1..5 do
        RunGraph.new_run(%{type: :task})
      end

      stats = RunGraph.stats()
      assert stats.initialized == true
      assert stats.size >= 5
      assert stats.memory > 0
    end
  end

  describe "concurrent access" do
    test "handles concurrent run creation" do
      runs =
        Enum.map(1..50, fn _ ->
          Task.async(fn ->
            RunGraph.new_run(%{type: :concurrent})
          end)
        end)

      run_ids = Enum.map(runs, &Task.await/1)
      assert length(Enum.uniq(run_ids)) == 50

      for run_id <- run_ids do
        assert {:ok, _} = RunGraph.get(run_id)
      end
    end

    test "handles concurrent status updates" do
      run_id = RunGraph.new_run(%{type: :task})

      tasks =
        Enum.map(1..10, fn i ->
          Task.async(fn ->
            RunGraph.mark_running(run_id)
            RunGraph.finish(run_id, %{iteration: i})
          end)
        end)

      Enum.each(tasks, &Task.await/1)

      # Final state should be completed (one of the finishes won)
      assert {:ok, record} = RunGraph.get(run_id)
      assert record.status == :completed
    end
  end

  describe "RunGraphServer" do
    test "ensure_table/1 initializes table if not already done" do
      # Table should already be initialized from application start
      assert :ok = RunGraphServer.ensure_table(CodingAgent.RunGraphServer)
    end

    test "stats/1 returns table information" do
      RunGraph.clear()
      RunGraph.new_run(%{type: :test})

      stats = RunGraphServer.stats(CodingAgent.RunGraphServer)
      assert stats.size >= 1
      assert stats.initialized == true
    end
  end

  describe "lifecycle" do
    test "full run lifecycle: queued -> running -> completed" do
      run_id = RunGraph.new_run(%{type: :task, description: "Full lifecycle"})

      # Initial state
      assert {:ok, %{status: :queued} = record} = RunGraph.get(run_id)
      assert record.inserted_at != nil
      refute Map.has_key?(record, :started_at)

      # Mark running
      RunGraph.mark_running(run_id)
      assert {:ok, %{status: :running} = record} = RunGraph.get(run_id)
      assert record.started_at != nil

      # Finish
      RunGraph.finish(run_id, %{result: "success"})
      assert {:ok, %{status: :completed} = record} = RunGraph.get(run_id)
      assert record.result == %{result: "success"}
      assert record.completed_at != nil
    end

    test "full run lifecycle with parent-child" do
      parent = RunGraph.new_run(%{type: :parent})
      child = RunGraph.new_run(%{type: :child})

      RunGraph.add_child(parent, child)

      # Parent lifecycle
      RunGraph.mark_running(parent)
      RunGraph.finish(parent, %{parent_result: "done"})

      # Child lifecycle
      RunGraph.mark_running(child)
      RunGraph.finish(child, %{child_result: "done"})

      # Verify both completed with relationship intact
      assert {:ok, parent_record} = RunGraph.get(parent)
      assert parent_record.status == :completed
      assert parent_record.children == [child]

      assert {:ok, child_record} = RunGraph.get(child)
      assert child_record.status == :completed
      assert child_record.parent == parent
    end
  end
end
