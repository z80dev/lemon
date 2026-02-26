defmodule CodingAgent.LaneQueueTest do
  use ExUnit.Case, async: true

  alias CodingAgent.LaneQueue

  setup do
    {:ok, sup} = Task.Supervisor.start_link()
    %{task_sup: sup}
  end

  # --- Original tests ---

  test "accepts caps as a map", %{task_sup: sup} do
    {:ok, pid} =
      LaneQueue.start_link(name: :lane_queue_map, caps: %{main: 2}, task_supervisor: sup)

    assert {:ok, 4} = LaneQueue.run(pid, :main, fn -> 4 end)
  end

  test "accepts caps as a keyword list", %{task_sup: sup} do
    {:ok, pid} =
      LaneQueue.start_link(
        name: :lane_queue_kw,
        caps: [main: 2, subagent: 1],
        task_supervisor: sup
      )

    assert {:ok, :ok} = LaneQueue.run(pid, :subagent, fn -> :ok end)
  end

  test "defaults to cap 1 for unknown lane", %{task_sup: sup} do
    {:ok, pid} =
      LaneQueue.start_link(name: :lane_queue_default, caps: [main: 1], task_supervisor: sup)

    results =
      1..2
      |> Task.async_stream(
        fn _ ->
          LaneQueue.run(pid, :unknown, fn ->
            Process.sleep(50)
            :done
          end)
        end,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &(&1 == {:ok, :done}))
  end

  # --- New tests ---

  test "concurrent execution respects cap of 2", %{task_sup: sup} do
    # With a cap of 2, the first 2 jobs run immediately. The 3rd must wait.
    {:ok, pid} =
      LaneQueue.start_link(
        name: :lane_queue_concurrency,
        caps: %{work: 2},
        task_supervisor: sup
      )

    test_pid = self()

    # Fill both slots with blocking jobs sequentially to avoid ordering races.
    task_1 =
      Task.async(fn ->
        LaneQueue.run(pid, :work, fn ->
          send(test_pid, {:slot_filled, 1})
          receive do: (:release -> :done)
        end)
      end)

    assert_receive {:slot_filled, 1}, 2_000

    task_2 =
      Task.async(fn ->
        LaneQueue.run(pid, :work, fn ->
          send(test_pid, {:slot_filled, 2})
          receive do: (:release -> :done)
        end)
      end)

    assert_receive {:slot_filled, 2}, 2_000

    # Both slots are now occupied. Enqueue job 3 — it should be queued.
    task_3 =
      Task.async(fn ->
        LaneQueue.run(pid, :work, fn ->
          send(test_pid, :job_3_started)
          :done
        end)
      end)

    # Job 3 should NOT have started (cap is full).
    refute_receive :job_3_started, 200

    # Release one blocking job to free a slot.
    children = Task.Supervisor.children(sup)
    Enum.each(children, fn child -> send(child, :release) end)

    # Job 3 should now start.
    assert_receive :job_3_started, 2_000

    # Clean up remaining tasks.
    Task.await(task_1, 5_000)
    Task.await(task_2, 5_000)
    Task.await(task_3, 5_000)
  end

  test "multiple independent lanes run concurrently", %{task_sup: sup} do
    # Two lanes each with cap 1. Jobs on different lanes should not block
    # each other.
    {:ok, pid} =
      LaneQueue.start_link(
        name: :lane_queue_multi_lane,
        caps: %{alpha: 1, beta: 1},
        task_supervisor: sup
      )

    test_pid = self()

    # Run one job on each lane concurrently. Both should be able to start
    # simultaneously since they are on separate lanes.
    task_a =
      Task.async(fn ->
        LaneQueue.run(pid, :alpha, fn ->
          send(test_pid, {:lane_started, :alpha})

          receive do
            :release_alpha -> :alpha_done
          end
        end)
      end)

    task_b =
      Task.async(fn ->
        LaneQueue.run(pid, :beta, fn ->
          send(test_pid, {:lane_started, :beta})

          receive do
            :release_beta -> :beta_done
          end
        end)
      end)

    # Both lanes should start without waiting for each other.
    assert_receive {:lane_started, :alpha}, 2_000
    assert_receive {:lane_started, :beta}, 2_000

    # Release both and collect results.
    children = Task.Supervisor.children(sup)
    Enum.each(children, fn child -> send(child, :release_alpha) end)
    Enum.each(children, fn child -> send(child, :release_beta) end)

    assert {:ok, :alpha_done} = Task.await(task_a, 5_000)
    assert {:ok, :beta_done} = Task.await(task_b, 5_000)
  end

  test "error in function returns {:error, _}", %{task_sup: sup} do
    {:ok, pid} =
      LaneQueue.start_link(
        name: :lane_queue_raise,
        caps: %{main: 1},
        task_supervisor: sup
      )

    result =
      LaneQueue.run(pid, :main, fn ->
        raise ArgumentError, "boom"
      end)

    assert {:error, {%ArgumentError{message: "boom"}, stacktrace}} = result
    assert is_list(stacktrace)
  end

  test "throw in function returns {:error, _}", %{task_sup: sup} do
    {:ok, pid} =
      LaneQueue.start_link(
        name: :lane_queue_throw,
        caps: %{main: 1},
        task_supervisor: sup
      )

    result =
      LaneQueue.run(pid, :main, fn ->
        throw(:oops)
      end)

    assert {:error, {:throw, :oops}} = result
  end

  test "empty queue with no jobs is healthy", %{task_sup: sup} do
    {:ok, pid} =
      LaneQueue.start_link(
        name: :lane_queue_empty,
        caps: %{main: 2},
        task_supervisor: sup
      )

    # The server should be alive and responsive even with zero jobs.
    assert Process.alive?(pid)

    # We can still run a job after doing nothing for a while.
    assert {:ok, :hello} = LaneQueue.run(pid, :main, fn -> :hello end)
  end

  test "sequential execution with cap 1 preserves FIFO order", %{task_sup: sup} do
    {:ok, pid} =
      LaneQueue.start_link(
        name: :lane_queue_fifo,
        caps: %{ordered: 1},
        task_supervisor: sup
      )

    # Use an agent to record the order of execution.
    {:ok, agent} = Agent.start_link(fn -> [] end)

    test_pid = self()

    # Enqueue all jobs from a single process to guarantee GenServer mailbox
    # ordering. Each call blocks until the job completes (cap 1 = serial),
    # so we must send the calls from a spawned process and collect results
    # via messages rather than waiting inline.
    spawn_link(fn ->
      results =
        Enum.map(1..5, fn i ->
          LaneQueue.run(pid, :ordered, fn ->
            Agent.update(agent, fn list -> list ++ [i] end)
            Process.sleep(10)
            i
          end)
        end)

      send(test_pid, {:fifo_results, results})
    end)

    assert_receive {:fifo_results, results}, 10_000

    # All jobs complete successfully.
    assert Enum.all?(results, fn {:ok, _} -> true; _ -> false end)

    # With cap 1 and a single caller, the execution order must be FIFO.
    execution_order = Agent.get(agent, & &1)
    assert execution_order == [1, 2, 3, 4, 5]

    Agent.stop(agent)
  end

  test "session lane works correctly", %{task_sup: sup} do
    {:ok, pid} =
      LaneQueue.start_link(
        name: :lane_queue_session,
        caps: %{},
        task_supervisor: sup
      )

    session_lane = {:session, "abc"}

    # Session lanes are not in the caps map, so they default to cap 1.
    result = LaneQueue.run(pid, session_lane, fn -> :session_result end)
    assert {:ok, :session_result} = result

    # Run two concurrent jobs on the same session lane to verify cap-1 behavior.
    test_pid = self()

    task_1 =
      Task.async(fn ->
        LaneQueue.run(pid, session_lane, fn ->
          send(test_pid, :session_job_1_started)

          receive do
            :release_session -> :s1
          end
        end)
      end)

    # Give job 1 time to start.
    assert_receive :session_job_1_started, 2_000

    task_2 =
      Task.async(fn ->
        LaneQueue.run(pid, session_lane, fn ->
          send(test_pid, :session_job_2_started)
          :s2
        end)
      end)

    # Job 2 should not start while job 1 is running (cap 1).
    refute_receive :session_job_2_started, 200

    # Release job 1.
    children = Task.Supervisor.children(sup)
    Enum.each(children, fn child -> send(child, :release_session) end)

    assert {:ok, :s1} = Task.await(task_1, 5_000)

    # Now job 2 should complete.
    assert_receive :session_job_2_started, 2_000
    assert {:ok, :s2} = Task.await(task_2, 5_000)
  end

  test "large batch of jobs all complete successfully", %{task_sup: sup} do
    {:ok, pid} =
      LaneQueue.start_link(
        name: :lane_queue_batch,
        caps: %{batch: 2},
        task_supervisor: sup
      )

    tasks =
      for i <- 1..10 do
        Task.async(fn ->
          LaneQueue.run(pid, :batch, fn ->
            # Simulate a small amount of work.
            Process.sleep(5)
            i * 10
          end)
        end)
      end

    results = Enum.map(tasks, &Task.await(&1, 30_000))

    # All 10 jobs should succeed.
    assert length(results) == 10
    assert Enum.all?(results, fn {:ok, val} -> is_integer(val); _ -> false end)

    # Verify we got all expected values (order of completion may vary with
    # concurrency, but all values should be present).
    values = Enum.map(results, fn {:ok, v} -> v end) |> Enum.sort()
    assert values == Enum.map(1..10, &(&1 * 10))
  end

  test "status call returns queue state", %{task_sup: sup} do
    {:ok, pid} =
      LaneQueue.start_link(
        name: :lane_queue_status,
        caps: %{main: 3, subagent: 5},
        task_supervisor: sup
      )

    status = GenServer.call(pid, :status)

    assert status.caps == %{main: 3, subagent: 5}
    assert status.jobs_count == 0
    assert is_map(status.lanes)
  end
end
