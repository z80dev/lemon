defmodule CodingAgent.LaneQueueTest do
  use ExUnit.Case, async: false

  alias CodingAgent.LaneQueue

  setup do
    {:ok, sup} = Task.Supervisor.start_link()
    %{task_sup: sup}
  end

  # --- Original tests ---

  test "status responds while a launch callback is blocked on IO", %{task_sup: sup} do
    queue =
      start_supervised!(
        {LaneQueue,
         name: :lane_queue_callback_responsiveness,
         caps: %{background_exec: 1},
         task_supervisor: sup}
      )

    owner = self()

    caller =
      Task.async(fn ->
        LaneQueue.run(queue, :background_exec, fn ->
          send(owner, {:callback_waiting, self()})
          receive do: (:finish_io -> :finished)
        end)
      end)

    assert_receive {:callback_waiting, worker}
    assert %{jobs_count: 1} = GenServer.call(queue, :status)
    send(worker, :finish_io)
    assert {:ok, :finished} = Task.await(caller)
  end

  test "accepts caps as a map", %{task_sup: sup} do
    {:ok, pid} =
      LaneQueue.start_link(
        name: :lane_queue_map,
        caps: %{background_exec: 2},
        task_supervisor: sup
      )

    assert {:ok, 4} = LaneQueue.run(pid, :background_exec, fn -> 4 end)
  end

  test "accepts caps as a keyword list", %{task_sup: sup} do
    {:ok, pid} =
      LaneQueue.start_link(
        name: :lane_queue_kw,
        caps: [background_exec: 2],
        task_supervisor: sup
      )

    assert {:ok, :ok} = LaneQueue.run(pid, :background_exec, fn -> :ok end)
  end

  test "concurrent execution respects cap of 2", %{task_sup: sup} do
    # With a cap of 2, the first 2 jobs run immediately. The 3rd must wait.
    {:ok, pid} =
      LaneQueue.start_link(
        name: :lane_queue_concurrency,
        caps: %{background_exec: 2},
        task_supervisor: sup
      )

    test_pid = self()

    # Fill both slots with blocking jobs sequentially to avoid ordering races.
    task_1 =
      Task.async(fn ->
        LaneQueue.run(pid, :background_exec, fn ->
          send(test_pid, {:slot_filled, 1})
          receive do: (:release -> :done)
        end)
      end)

    assert_receive {:slot_filled, 1}, 2_000

    task_2 =
      Task.async(fn ->
        LaneQueue.run(pid, :background_exec, fn ->
          send(test_pid, {:slot_filled, 2})
          receive do: (:release -> :done)
        end)
      end)

    assert_receive {:slot_filled, 2}, 2_000

    # Both slots are now occupied. Enqueue job 3 — it should be queued.
    task_3 =
      Task.async(fn ->
        LaneQueue.run(pid, :background_exec, fn ->
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

  test "error in function returns {:error, _}", %{task_sup: sup} do
    {:ok, pid} =
      LaneQueue.start_link(
        name: :lane_queue_raise,
        caps: %{background_exec: 1},
        task_supervisor: sup
      )

    result =
      LaneQueue.run(pid, :background_exec, fn ->
        raise ArgumentError, "boom"
      end)

    assert {:error, {%ArgumentError{message: "boom"}, stacktrace}} = result
    assert is_list(stacktrace)
  end

  test "throw in function returns {:error, _}", %{task_sup: sup} do
    {:ok, pid} =
      LaneQueue.start_link(
        name: :lane_queue_throw,
        caps: %{background_exec: 1},
        task_supervisor: sup
      )

    result =
      LaneQueue.run(pid, :background_exec, fn ->
        throw(:oops)
      end)

    assert {:error, {:throw, :oops}} = result
  end

  test "empty queue with no jobs is healthy", %{task_sup: sup} do
    {:ok, pid} =
      LaneQueue.start_link(
        name: :lane_queue_empty,
        caps: %{background_exec: 2},
        task_supervisor: sup
      )

    # The server should be alive and responsive even with zero jobs.
    assert Process.alive?(pid)

    # We can still run a job after doing nothing for a while.
    assert {:ok, :hello} = LaneQueue.run(pid, :background_exec, fn -> :hello end)
  end

  test "completed task replies consume their monitor without a duplicate DOWN warning", %{
    task_sup: sup
  } do
    {:ok, pid} =
      LaneQueue.start_link(
        name: :lane_queue_monitor_cleanup,
        caps: %{background_exec: 1},
        task_supervisor: sup
      )

    log =
      ExUnit.CaptureLog.capture_log([level: :warning], fn ->
        assert {:ok, :done} = LaneQueue.run(pid, :background_exec, fn -> :done end)
        Process.sleep(20)
      end)

    refute log =~ "complete_job unknown task_ref"
  end

  test "drops a queued job when its caller exits", %{task_sup: sup} do
    {:ok, pid} =
      LaneQueue.start_link(
        name: :lane_queue_caller_cancel,
        caps: %{background_exec: 1},
        task_supervisor: sup
      )

    test_pid = self()

    first =
      Task.async(fn ->
        LaneQueue.run(pid, :background_exec, fn ->
          send(test_pid, :first_started)
          receive do: (:release -> :first_done)
        end)
      end)

    assert_receive :first_started, 1_000

    caller =
      spawn(fn ->
        LaneQueue.run(pid, :background_exec, fn ->
          send(test_pid, :cancelled_job_started)
          :unexpected
        end)
      end)

    wait_until(fn -> GenServer.call(pid, :status).jobs_count == 2 end)
    Process.exit(caller, :kill)
    wait_until(fn -> GenServer.call(pid, :status).jobs_count == 1 end)

    Enum.each(Task.Supervisor.children(sup), &send(&1, :release))
    assert {:ok, :first_done} = Task.await(first, 1_000)
    refute_receive :cancelled_job_started, 100
    assert GenServer.call(pid, :status).jobs_count == 0
  end

  test "contains task-supervisor admission failure and continues with the next job" do
    missing_supervisor = :lane_queue_late_task_supervisor

    {:ok, pid} =
      LaneQueue.start_link(
        name: :lane_queue_admission_failure,
        caps: %{background_exec: 1},
        task_supervisor: missing_supervisor
      )

    assert {:error, {:task_start_failed, :task_supervisor_unavailable}} =
             LaneQueue.run(pid, :background_exec, fn -> :never end)

    assert Process.alive?(pid)
    assert GenServer.call(pid, :status).jobs_count == 0

    start_supervised!({Task.Supervisor, name: missing_supervisor})
    assert {:ok, :recovered} = LaneQueue.run(pid, :background_exec, fn -> :recovered end)
    assert Process.alive?(pid)
  end

  test "reports exhausted supervisor capacity without running the queued job" do
    supervisor = start_supervised!({Task.Supervisor, max_children: 1})

    {:ok, blocker} =
      LemonCore.TaskSupervisor.start_child(supervisor, fn ->
        receive do: (:release -> :ok)
      end)

    queue =
      start_supervised!(
        {LaneQueue,
         name: :lane_queue_capacity_failure,
         caps: %{background_exec: 1},
         task_supervisor: supervisor}
      )

    assert {:error, {:task_start_failed, :task_capacity_reached}} =
             LaneQueue.run(queue, :background_exec, fn -> flunk("rejected job ran") end)

    assert Process.alive?(queue)
    assert GenServer.call(queue, :status).jobs_count == 0
    assert Task.Supervisor.children(supervisor) == [blocker]
  end

  test "sequential execution with cap 1 preserves FIFO order", %{task_sup: sup} do
    {:ok, pid} =
      LaneQueue.start_link(
        name: :lane_queue_fifo,
        caps: %{background_exec: 1},
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
          LaneQueue.run(pid, :background_exec, fn ->
            Agent.update(agent, fn list -> list ++ [i] end)
            Process.sleep(10)
            i
          end)
        end)

      send(test_pid, {:fifo_results, results})
    end)

    assert_receive {:fifo_results, results}, 10_000

    # All jobs complete successfully.
    assert Enum.all?(results, fn
             {:ok, _} -> true
             _ -> false
           end)

    # With cap 1 and a single caller, the execution order must be FIFO.
    execution_order = Agent.get(agent, & &1)
    assert execution_order == [1, 2, 3, 4, 5]

    Agent.stop(agent)
  end

  test "large batch of jobs all complete successfully", %{task_sup: sup} do
    {:ok, pid} =
      LaneQueue.start_link(
        name: :lane_queue_batch,
        caps: %{background_exec: 2},
        task_supervisor: sup
      )

    tasks =
      for i <- 1..10 do
        Task.async(fn ->
          LaneQueue.run(pid, :background_exec, fn ->
            # Simulate a small amount of work.
            Process.sleep(5)
            i * 10
          end)
        end)
      end

    results = Enum.map(tasks, &Task.await(&1, 30_000))

    # All 10 jobs should succeed.
    assert length(results) == 10

    assert Enum.all?(results, fn
             {:ok, val} -> is_integer(val)
             _ -> false
           end)

    # Verify we got all expected values (order of completion may vary with
    # concurrency, but all values should be present).
    values = Enum.map(results, fn {:ok, v} -> v end) |> Enum.sort()
    assert values == Enum.map(1..10, &(&1 * 10))
  end

  test "status call returns queue state", %{task_sup: sup} do
    {:ok, pid} =
      LaneQueue.start_link(
        name: :lane_queue_status,
        caps: %{background_exec: 3},
        task_supervisor: sup
      )

    status = GenServer.call(pid, :status)

    assert status.caps == %{background_exec: 3}
    assert status.jobs_count == 0
    assert is_map(status.lanes)
  end

  defp wait_until(fun, attempts \\ 1000)
  defp wait_until(_fun, 0), do: flunk("condition did not become true")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end
end
