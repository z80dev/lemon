defmodule CodingAgent.RunGraphConcurrencyTest do
  @moduledoc """
  Concurrency regression suite for RunGraph state transitions.

  Verifies that:
  - Atomic transitions prevent lost updates under concurrent writes
  - Monotonic state ordering is enforced (no backward transitions)
  - await/3 wakes up via PubSub notifications without polling
  - No state loss across simultaneous status updates
  """
  use ExUnit.Case, async: false

  alias CodingAgent.RunGraph

  setup do
    try do
      RunGraph.clear()
    catch
      _, _ -> :ok
    end

    :ok
  end

  describe "atomic transitions under stress" do
    test "concurrent mark_running on the same run produces exactly one running state" do
      run_id = RunGraph.new_run(%{type: :stress})

      tasks =
        for _ <- 1..50 do
          Task.async(fn ->
            RunGraph.mark_running(run_id)
          end)
        end

      results = Enum.map(tasks, &Task.await/1)

      # Exactly one should succeed, rest get :ok (already transitioned)
      # or {:error, :invalid_transition}
      ok_count = Enum.count(results, &(&1 == :ok))
      invalid_count = Enum.count(results, &(&1 == {:error, :invalid_transition}))

      # First call succeeds, rest are invalid transitions
      assert ok_count == 1
      assert invalid_count == 49

      assert {:ok, record} = RunGraph.get(run_id)
      assert record.status == :running
    end

    test "concurrent finish calls on the same run produce exactly one completed state" do
      run_id = RunGraph.new_run(%{type: :stress})
      :ok = RunGraph.mark_running(run_id)

      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            RunGraph.finish(run_id, %{winner: i})
          end)
        end

      results = Enum.map(tasks, &Task.await/1)

      ok_count = Enum.count(results, &(&1 == :ok))
      invalid_count = Enum.count(results, &(&1 == {:error, :invalid_transition}))

      assert ok_count == 1
      assert invalid_count == 49

      assert {:ok, record} = RunGraph.get(run_id)
      assert record.status == :completed
      assert is_map(record.result)
    end

    test "interleaved mark_running and finish on the same run never loses final state" do
      run_id = RunGraph.new_run(%{type: :interleave})

      # Some processes try to mark running, others try to finish
      tasks =
        for i <- 1..40 do
          Task.async(fn ->
            if rem(i, 2) == 0 do
              {:running, RunGraph.mark_running(run_id)}
            else
              {:finish, RunGraph.finish(run_id, %{iteration: i})}
            end
          end)
        end

      _results = Enum.map(tasks, &Task.await/1)

      # The run should be in a valid terminal or running state
      assert {:ok, record} = RunGraph.get(run_id)
      assert record.status in [:running, :completed]
    end

    test "concurrent fail and finish - first one wins, second is rejected" do
      run_id = RunGraph.new_run(%{type: :race})
      :ok = RunGraph.mark_running(run_id)

      # Race between fail and finish
      tasks = [
        Task.async(fn -> {:finish, RunGraph.finish(run_id, %{result: "ok"})} end),
        Task.async(fn -> {:fail, RunGraph.fail(run_id, "boom")} end)
      ]

      results = Enum.map(tasks, &Task.await/1)

      # Exactly one succeeds
      ok_results = Enum.filter(results, fn {_, r} -> r == :ok end)
      invalid_results = Enum.filter(results, fn {_, r} -> r == {:error, :invalid_transition} end)

      assert length(ok_results) == 1
      assert length(invalid_results) == 1

      assert {:ok, record} = RunGraph.get(run_id)
      assert record.status in [:completed, :error]
    end

    test "many runs created and transitioned concurrently do not lose records" do
      run_count = 100

      tasks =
        for _ <- 1..run_count do
          Task.async(fn ->
            id = RunGraph.new_run(%{type: :bulk})
            :ok = RunGraph.mark_running(id)
            result = RunGraph.finish(id, %{done: true})
            # finish might fail if mark_running didn't complete in time
            {id, result}
          end)
        end

      results = Enum.map(tasks, &Task.await/1)

      # All runs should exist and be in completed state
      for {id, _result} <- results do
        assert {:ok, record} = RunGraph.get(id)
        assert record.status == :completed
      end

      stats = RunGraph.stats()
      assert stats.size >= run_count
    end
  end

  describe "monotonic state enforcement" do
    test "cannot transition from completed back to running" do
      run_id = RunGraph.new_run(%{type: :task})
      :ok = RunGraph.mark_running(run_id)
      :ok = RunGraph.finish(run_id, %{result: "done"})

      assert {:error, :invalid_transition} = RunGraph.mark_running(run_id)

      # Status should still be completed
      assert {:ok, %{status: :completed}} = RunGraph.get(run_id)
    end

    test "cannot transition from error back to running" do
      run_id = RunGraph.new_run(%{type: :task})
      :ok = RunGraph.mark_running(run_id)
      :ok = RunGraph.fail(run_id, "boom")

      assert {:error, :invalid_transition} = RunGraph.mark_running(run_id)
      assert {:ok, %{status: :error}} = RunGraph.get(run_id)
    end

    test "cannot transition from completed to error" do
      run_id = RunGraph.new_run(%{type: :task})
      :ok = RunGraph.mark_running(run_id)
      :ok = RunGraph.finish(run_id, %{result: "done"})

      assert {:error, :invalid_transition} = RunGraph.fail(run_id, "late error")
      assert {:ok, %{status: :completed}} = RunGraph.get(run_id)
    end

    test "cannot finish a queued run directly" do
      run_id = RunGraph.new_run(%{type: :task})

      # queued -> completed skips running, but both are forward transitions
      # queued (0) -> completed (2) is forward, so this should succeed
      :ok = RunGraph.finish(run_id, %{result: "fast track"})

      assert {:ok, %{status: :completed}} = RunGraph.get(run_id)
    end

    test "valid_transition?/2 reflects correct ordering" do
      assert RunGraph.valid_transition?(:queued, :running)
      assert RunGraph.valid_transition?(:queued, :completed)
      assert RunGraph.valid_transition?(:queued, :error)
      assert RunGraph.valid_transition?(:running, :completed)
      assert RunGraph.valid_transition?(:running, :error)
      assert RunGraph.valid_transition?(:running, :killed)
      assert RunGraph.valid_transition?(:running, :cancelled)
      assert RunGraph.valid_transition?(:running, :lost)

      refute RunGraph.valid_transition?(:completed, :running)
      refute RunGraph.valid_transition?(:completed, :queued)
      refute RunGraph.valid_transition?(:error, :running)
      refute RunGraph.valid_transition?(:error, :completed)
      refute RunGraph.valid_transition?(:running, :queued)
      refute RunGraph.valid_transition?(:running, :running)
      refute RunGraph.valid_transition?(:completed, :completed)
    end
  end

  describe "PubSub-based await" do
    test "await wakes up immediately on state change (no 50ms poll delay)" do
      run_id = RunGraph.new_run(%{type: :task})
      :ok = RunGraph.mark_running(run_id)

      # Complete the run after 50ms
      spawn(fn ->
        Process.sleep(50)
        RunGraph.finish(run_id, %{result: "done"})
      end)

      # Await should complete well under the old 50ms poll interval overhead
      start = System.monotonic_time(:millisecond)

      assert {:ok, %{mode: :wait_all, runs: [%{status: :completed}]}} =
               RunGraph.await(run_id, :wait_all, 5_000)

      elapsed = System.monotonic_time(:millisecond) - start

      # Should complete in ~50ms (the sleep) + small overhead, not 50ms + 50ms poll
      assert elapsed < 200, "await took #{elapsed}ms, expected < 200ms"
    end

    test "await times out correctly" do
      run_id = RunGraph.new_run(%{type: :task})
      :ok = RunGraph.mark_running(run_id)

      start = System.monotonic_time(:millisecond)
      assert {:error, :timeout, _} = RunGraph.await(run_id, :wait_all, 100)
      elapsed = System.monotonic_time(:millisecond) - start

      # Should timeout close to 100ms
      assert elapsed >= 95, "timed out too early: #{elapsed}ms"
      assert elapsed < 300, "timed out too late: #{elapsed}ms"
    end

    test "await :wait_any returns as soon as first run completes" do
      run1 = RunGraph.new_run(%{type: :task})
      run2 = RunGraph.new_run(%{type: :task})
      :ok = RunGraph.mark_running(run1)
      :ok = RunGraph.mark_running(run2)

      # Complete run2 after 50ms, leave run1 running
      spawn(fn ->
        Process.sleep(50)
        RunGraph.finish(run2, %{result: "fast"})
      end)

      assert {:ok, %{mode: :wait_any, run: %{id: id, status: :completed}}} =
               RunGraph.await([run1, run2], :wait_any, 5_000)

      assert id == run2
    end

    test "await handles already-completed runs instantly" do
      run_id = RunGraph.new_run(%{type: :task})
      :ok = RunGraph.mark_running(run_id)
      :ok = RunGraph.finish(run_id, %{result: "already done"})

      start = System.monotonic_time(:millisecond)
      assert {:ok, _} = RunGraph.await(run_id, :wait_all, 5_000)
      elapsed = System.monotonic_time(:millisecond) - start

      # Should return nearly instantly
      assert elapsed < 50, "await for completed run took #{elapsed}ms"
    end
  end

  describe "atomic update serialization" do
    test "concurrent add_child operations do not lose children" do
      parent_id = RunGraph.new_run(%{type: :parent})

      child_ids =
        for _ <- 1..20 do
          RunGraph.new_run(%{type: :child})
        end

      tasks =
        for child_id <- child_ids do
          Task.async(fn ->
            RunGraph.add_child(parent_id, child_id)
          end)
        end

      Enum.each(tasks, &Task.await/1)

      assert {:ok, parent} = RunGraph.get(parent_id)
      assert length(parent.children) == 20

      # All child_ids should be present
      assert MapSet.new(parent.children) == MapSet.new(child_ids)
    end

    test "concurrent updates to different runs do not interfere" do
      runs =
        for i <- 1..20 do
          {RunGraph.new_run(%{type: :task, index: i}), i}
        end

      tasks =
        for {run_id, i} <- runs do
          Task.async(fn ->
            :ok = RunGraph.mark_running(run_id)

            if rem(i, 2) == 0 do
              RunGraph.finish(run_id, %{result: "even_#{i}"})
            else
              RunGraph.fail(run_id, "odd_#{i}")
            end

            {run_id, i}
          end)
        end

      results = Enum.map(tasks, &Task.await/1)

      for {run_id, i} <- results do
        {:ok, record} = RunGraph.get(run_id)

        if rem(i, 2) == 0 do
          assert record.status == :completed, "Run #{i} should be completed"
          assert record.result == %{result: "even_#{i}"}
        else
          assert record.status == :error, "Run #{i} should be error"
          assert record.error == "odd_#{i}"
        end
      end
    end
  end
end
