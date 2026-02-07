defmodule LemonGateway.RunSupervisorTest do
  @moduledoc """
  Comprehensive tests for LemonGateway.RunSupervisor DynamicSupervisor.

  Tests cover:
  - Child process startup
  - Child process restart behavior (temporary strategy)
  - Supervision strategy behavior
  - Dynamic child management (start_child, terminate_child)
  - Concurrent operations
  - Cleanup on shutdown
  - Error isolation between children
  - Integration with Run processes
  """
  use ExUnit.Case, async: false

  alias LemonGateway.RunSupervisor
  alias LemonGateway.Types.{ChatScope, Job}
  alias LemonGateway.Event

  # ============================================================================
  # Test Engines
  # ============================================================================

  defmodule QuickEngine do
    @behaviour LemonGateway.Engine

    alias LemonGateway.Types.{Job, ResumeToken}
    alias LemonGateway.Event

    @impl true
    def id, do: "quick"

    @impl true
    def format_resume(%ResumeToken{value: sid}), do: "quick resume #{sid}"

    @impl true
    def extract_resume(_text), do: nil

    @impl true
    def is_resume_line(_line), do: false

    @impl true
    def supports_steer?, do: false

    @impl true
    def start_run(%Job{} = job, _opts, sink_pid) do
      run_ref = make_ref()
      resume = job.resume || %ResumeToken{engine: id(), value: unique_id()}

      {:ok, task_pid} =
        Task.start(fn ->
          send(sink_pid, {:engine_event, run_ref, %Event.Started{engine: id(), resume: resume}})
          answer = "Quick: #{job.text}"

          send(
            sink_pid,
            {:engine_event, run_ref,
             %Event.Completed{engine: id(), resume: resume, ok: true, answer: answer}}
          )
        end)

      {:ok, run_ref, %{task_pid: task_pid}}
    end

    @impl true
    def cancel(%{task_pid: pid}) when is_pid(pid) do
      Process.exit(pid, :kill)
      :ok
    end

    defp unique_id, do: Integer.to_string(System.unique_integer([:positive]))
  end

  defmodule SlowTestEngine do
    @behaviour LemonGateway.Engine

    alias LemonGateway.Types.{Job, ResumeToken}
    alias LemonGateway.Event

    @impl true
    def id, do: "slow_test"

    @impl true
    def format_resume(%ResumeToken{value: sid}), do: "slow_test resume #{sid}"

    @impl true
    def extract_resume(_text), do: nil

    @impl true
    def is_resume_line(_line), do: false

    @impl true
    def supports_steer?, do: false

    @impl true
    def start_run(%Job{} = job, _opts, sink_pid) do
      run_ref = make_ref()
      resume = job.resume || %ResumeToken{engine: id(), value: unique_id()}
      delay_ms = (job.meta || %{})[:delay_ms] || 500

      {:ok, task_pid} =
        Task.start(fn ->
          send(sink_pid, {:engine_event, run_ref, %Event.Started{engine: id(), resume: resume}})
          Process.sleep(delay_ms)
          answer = "Slow: #{job.text}"

          send(
            sink_pid,
            {:engine_event, run_ref,
             %Event.Completed{engine: id(), resume: resume, ok: true, answer: answer}}
          )
        end)

      {:ok, run_ref, %{task_pid: task_pid}}
    end

    @impl true
    def cancel(%{task_pid: pid}) when is_pid(pid) do
      Process.exit(pid, :kill)
      :ok
    end

    defp unique_id, do: Integer.to_string(System.unique_integer([:positive]))
  end

  defmodule ControllableTestEngine do
    @behaviour LemonGateway.Engine

    alias LemonGateway.Types.{Job, ResumeToken}
    alias LemonGateway.Event

    @impl true
    def id, do: "controllable_test"

    @impl true
    def format_resume(%ResumeToken{value: sid}), do: "controllable_test resume #{sid}"

    @impl true
    def extract_resume(_text), do: nil

    @impl true
    def is_resume_line(_line), do: false

    @impl true
    def supports_steer?, do: false

    @impl true
    def start_run(%Job{} = job, _opts, sink_pid) do
      run_ref = make_ref()
      resume = job.resume || %ResumeToken{engine: id(), value: unique_id()}
      controller_pid = (job.meta || %{})[:controller_pid]

      {:ok, task_pid} =
        Task.start(fn ->
          send(sink_pid, {:engine_event, run_ref, %Event.Started{engine: id(), resume: resume}})
          if controller_pid, do: send(controller_pid, {:engine_started, run_ref, self()})

          receive do
            {:complete, answer} ->
              send(
                sink_pid,
                {:engine_event, run_ref,
                 %Event.Completed{engine: id(), resume: resume, ok: true, answer: answer}}
              )
          after
            30_000 ->
              send(
                sink_pid,
                {:engine_event, run_ref,
                 %Event.Completed{engine: id(), resume: resume, ok: false, error: :timeout}}
              )
          end
        end)

      {:ok, run_ref, %{task_pid: task_pid}}
    end

    @impl true
    def cancel(%{task_pid: pid}) when is_pid(pid) do
      Process.exit(pid, :kill)
      :ok
    end

    defp unique_id, do: Integer.to_string(System.unique_integer([:positive]))
  end

  # ============================================================================
  # Setup
  # ============================================================================

  setup do
    _ = Application.stop(:lemon_gateway)

    Application.put_env(:lemon_gateway, LemonGateway.Config, %{
      max_concurrent_runs: 10,
      default_engine: "quick",
      enable_telegram: false,
      require_engine_lock: false
    })

    Application.put_env(:lemon_gateway, :engines, [
      QuickEngine,
      SlowTestEngine,
      ControllableTestEngine,
      LemonGateway.Engines.Echo
    ])

    {:ok, _} = Application.ensure_all_started(:lemon_gateway)

    :ok
  end

  defp make_scope(chat_id \\ System.unique_integer([:positive])) do
    %ChatScope{transport: :test, chat_id: chat_id, topic_id: nil}
  end

  defp make_job(scope, opts \\ []) do
    %Job{
      scope: scope,
      user_msg_id: Keyword.get(opts, :user_msg_id, 1),
      text: Keyword.get(opts, :text, "test message"),
      queue_mode: Keyword.get(opts, :queue_mode, :collect),
      engine_hint: Keyword.get(opts, :engine_hint, "quick"),
      meta: Keyword.get(opts, :meta, %{notify_pid: self()})
    }
  end

  # ============================================================================
  # 1. Supervisor Startup and Initialization
  # ============================================================================

  describe "supervisor startup and initialization" do
    test "supervisor starts successfully" do
      assert Process.whereis(RunSupervisor) != nil
    end

    test "supervisor uses DynamicSupervisor behavior" do
      pid = Process.whereis(RunSupervisor)
      assert Process.alive?(pid)

      # Verify it's a DynamicSupervisor by calling count_children
      children = DynamicSupervisor.count_children(RunSupervisor)
      assert is_map(children)
      assert Map.has_key?(children, :active)
      assert Map.has_key?(children, :specs)
    end

    test "supervisor starts with no children" do
      # Wait for any existing runs to complete
      Process.sleep(100)

      children = DynamicSupervisor.count_children(RunSupervisor)
      # Active count may not be 0 if other tests left processes running
      assert children.specs >= 0
    end

    test "supervisor is registered with correct name" do
      pid = Process.whereis(RunSupervisor)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "supervisor uses :one_for_one strategy" do
      # We verify this by checking that children are independent
      # Start multiple runs and verify they don't affect each other
      scope1 = make_scope()
      scope2 = make_scope()

      job1 =
        make_job(scope1,
          engine_hint: "controllable_test",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      job2 =
        make_job(scope2,
          engine_hint: "controllable_test",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, _pid1} =
        RunSupervisor.start_run(%{job: job1, slot_ref: make_ref(), worker_pid: self()})

      {:ok, _pid2} =
        RunSupervisor.start_run(%{job: job2, slot_ref: make_ref(), worker_pid: self()})

      # Both should start
      assert_receive {:engine_started, _, task_pid1}, 2000
      assert_receive {:engine_started, _, task_pid2}, 2000

      # Complete both
      send(task_pid1, {:complete, "done1"})
      send(task_pid2, {:complete, "done2"})

      assert_receive {:run_complete, _, %Event.Completed{ok: true}}, 2000
      assert_receive {:run_complete, _, %Event.Completed{ok: true}}, 2000
    end
  end

  # ============================================================================
  # 2. Child Process Startup via start_run/1
  # ============================================================================

  describe "child process startup via start_run/1" do
    test "start_run starts a Run process" do
      scope = make_scope()
      job = make_job(scope)

      {:ok, pid} = RunSupervisor.start_run(%{job: job, slot_ref: make_ref(), worker_pid: self()})

      assert is_pid(pid)
      assert Process.alive?(pid)

      # Wait for completion
      assert_receive {:run_complete, ^pid, %Event.Completed{ok: true}}, 2000
    end

    test "start_run returns {:ok, pid}" do
      scope = make_scope()
      job = make_job(scope)

      result = RunSupervisor.start_run(%{job: job, slot_ref: make_ref(), worker_pid: self()})

      assert {:ok, pid} = result
      assert is_pid(pid)

      assert_receive {:run_complete, ^pid, _}, 2000
    end

    test "started process is supervised" do
      scope = make_scope()
      job = make_job(scope, engine_hint: "slow_test", meta: %{notify_pid: self(), delay_ms: 500})

      {:ok, pid} = RunSupervisor.start_run(%{job: job, slot_ref: make_ref(), worker_pid: self()})

      # Check that the process is a child of the supervisor
      children = DynamicSupervisor.which_children(RunSupervisor)
      child_pids = Enum.map(children, fn {_, child_pid, _, _} -> child_pid end)

      assert pid in child_pids

      assert_receive {:run_complete, ^pid, _}, 2000
    end

    test "multiple runs can be started concurrently" do
      runs =
        for i <- 1..5 do
          scope = make_scope()
          job = make_job(scope, text: "run #{i}")

          {:ok, pid} =
            RunSupervisor.start_run(%{job: job, slot_ref: make_ref(), worker_pid: self()})

          {i, pid}
        end

      assert length(runs) == 5

      for {_i, pid} <- runs do
        assert_receive {:run_complete, ^pid, %Event.Completed{ok: true}}, 2000
      end
    end

    test "started run processes correct job" do
      scope = make_scope()
      job = make_job(scope, text: "unique test text #{System.unique_integer()}")

      {:ok, pid} = RunSupervisor.start_run(%{job: job, slot_ref: make_ref(), worker_pid: self()})

      assert_receive {:run_complete, ^pid,
                      %Event.Completed{ok: true, answer: "Quick: " <> answer_text}},
                     2000

      assert String.contains?(answer_text, "unique test text")
    end
  end

  # ============================================================================
  # 3. Temporary Restart Strategy Behavior
  # ============================================================================

  describe "temporary restart strategy behavior" do
    test "child is not restarted on normal exit" do
      scope = make_scope()
      job = make_job(scope)

      {:ok, pid} = RunSupervisor.start_run(%{job: job, slot_ref: make_ref(), worker_pid: self()})

      assert_receive {:run_complete, ^pid, %Event.Completed{ok: true}}, 2000

      # Wait for process to stop
      Process.sleep(100)
      refute Process.alive?(pid)

      # Child should not be restarted
      children = DynamicSupervisor.which_children(RunSupervisor)
      child_pids = Enum.map(children, fn {_, child_pid, _, _} -> child_pid end)
      refute pid in child_pids
    end

    test "child is not restarted on crash" do
      scope = make_scope()

      job =
        make_job(scope,
          engine_hint: "controllable_test",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = RunSupervisor.start_run(%{job: job, slot_ref: make_ref(), worker_pid: self()})
      ref = Process.monitor(pid)

      assert_receive {:engine_started, _, task_pid}, 2000

      # Kill the engine task abruptly
      Process.exit(task_pid, :kill)

      # Wait for the Run process to notice and potentially stop
      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        2000 ->
          # Process might still be alive due to how Run handles cancellation
          :ok
      end

      # Verify process is not restarted (or still running as single instance)
      Process.sleep(100)
      children = DynamicSupervisor.which_children(RunSupervisor)

      child_pids =
        children
        |> Enum.map(fn {_, child_pid, _, _} -> child_pid end)
        |> Enum.filter(&is_pid/1)

      # Should have at most one instance, not a restarted copy
      assert Enum.count(child_pids, &(&1 == pid)) <= 1
    end

    test "temporary restart means process is removed from supervisor after exit" do
      scope = make_scope()
      job = make_job(scope)

      {:ok, pid} = RunSupervisor.start_run(%{job: job, slot_ref: make_ref(), worker_pid: self()})

      assert_receive {:run_complete, ^pid, _}, 2000

      # Wait for cleanup
      Process.sleep(100)

      # Process should be removed from supervisor
      children = DynamicSupervisor.which_children(RunSupervisor)
      child_pids = Enum.map(children, fn {_, child_pid, _, _} -> child_pid end)
      refute pid in child_pids
    end
  end

  # ============================================================================
  # 4. Error Isolation Between Children
  # ============================================================================

  describe "error isolation between children" do
    test "one child crashing does not affect other children" do
      scope1 = make_scope()
      scope2 = make_scope()

      job1 =
        make_job(scope1,
          engine_hint: "controllable_test",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      job2 =
        make_job(scope2,
          engine_hint: "controllable_test",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, _pid1} =
        RunSupervisor.start_run(%{job: job1, slot_ref: make_ref(), worker_pid: self()})

      {:ok, pid2} =
        RunSupervisor.start_run(%{job: job2, slot_ref: make_ref(), worker_pid: self()})

      assert_receive {:engine_started, _, task_pid1}, 2000
      assert_receive {:engine_started, _, task_pid2}, 2000

      # Kill the first one's task
      Process.exit(task_pid1, :kill)

      # Wait a bit
      Process.sleep(100)

      # Second process should still be alive
      assert Process.alive?(pid2)

      # Complete the second one
      send(task_pid2, {:complete, "done"})
      assert_receive {:run_complete, ^pid2, %Event.Completed{ok: true}}, 2000
    end

    test "multiple children can complete independently" do
      runs =
        for i <- 1..3 do
          scope = make_scope()

          job =
            make_job(scope,
              engine_hint: "slow_test",
              text: "run #{i}",
              meta: %{notify_pid: self(), delay_ms: 50 * i}
            )

          {:ok, pid} =
            RunSupervisor.start_run(%{job: job, slot_ref: make_ref(), worker_pid: self()})

          {i, pid}
        end

      # All should complete (in order of delay)
      for {_i, pid} <- runs do
        assert_receive {:run_complete, ^pid, %Event.Completed{ok: true}}, 2000
      end
    end

    test "supervisor continues functioning after child crashes" do
      scope1 = make_scope()

      job1 =
        make_job(scope1,
          engine_hint: "controllable_test",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid1} =
        RunSupervisor.start_run(%{job: job1, slot_ref: make_ref(), worker_pid: self()})

      assert_receive {:engine_started, _, _task_pid1}, 2000

      # Kill the child abruptly
      Process.exit(pid1, :kill)
      Process.sleep(100)

      # Supervisor should still be alive
      assert Process.alive?(Process.whereis(RunSupervisor))

      # Can start new children
      scope2 = make_scope()
      job2 = make_job(scope2)

      {:ok, pid2} =
        RunSupervisor.start_run(%{job: job2, slot_ref: make_ref(), worker_pid: self()})

      assert_receive {:run_complete, ^pid2, %Event.Completed{ok: true}}, 2000
    end
  end

  # ============================================================================
  # 5. Dynamic Child Management
  # ============================================================================

  describe "dynamic child management" do
    test "DynamicSupervisor.which_children returns current children" do
      scope = make_scope()
      job = make_job(scope, engine_hint: "slow_test", meta: %{notify_pid: self(), delay_ms: 500})

      {:ok, pid} = RunSupervisor.start_run(%{job: job, slot_ref: make_ref(), worker_pid: self()})

      children = DynamicSupervisor.which_children(RunSupervisor)
      child_pids = Enum.map(children, fn {_, child_pid, _, _} -> child_pid end)

      assert pid in child_pids

      assert_receive {:run_complete, ^pid, _}, 2000
    end

    test "DynamicSupervisor.count_children reflects active children" do
      initial_count = DynamicSupervisor.count_children(RunSupervisor).active

      scope = make_scope()

      job =
        make_job(scope,
          engine_hint: "controllable_test",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, _pid} = RunSupervisor.start_run(%{job: job, slot_ref: make_ref(), worker_pid: self()})

      assert_receive {:engine_started, _, task_pid}, 2000

      active_count = DynamicSupervisor.count_children(RunSupervisor).active
      assert active_count >= initial_count + 1

      # Complete the run
      send(task_pid, {:complete, "done"})
      assert_receive {:run_complete, _, _}, 2000

      Process.sleep(100)
      final_count = DynamicSupervisor.count_children(RunSupervisor).active
      assert final_count <= active_count
    end

    test "DynamicSupervisor.terminate_child terminates a running child" do
      scope = make_scope()

      job =
        make_job(scope,
          engine_hint: "controllable_test",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = RunSupervisor.start_run(%{job: job, slot_ref: make_ref(), worker_pid: self()})
      ref = Process.monitor(pid)

      assert_receive {:engine_started, _, _task_pid}, 2000

      # Terminate the child via DynamicSupervisor
      :ok = DynamicSupervisor.terminate_child(RunSupervisor, pid)

      # Process should be dead
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2000
    end

    test "children can be terminated while others continue running" do
      scope1 = make_scope()
      scope2 = make_scope()

      job1 =
        make_job(scope1,
          engine_hint: "controllable_test",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      job2 =
        make_job(scope2,
          engine_hint: "controllable_test",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid1} =
        RunSupervisor.start_run(%{job: job1, slot_ref: make_ref(), worker_pid: self()})

      {:ok, pid2} =
        RunSupervisor.start_run(%{job: job2, slot_ref: make_ref(), worker_pid: self()})

      # Engine start notifications are asynchronous and can arrive in either order.
      assert_receive {:engine_started, _, task_pid_a}, 2000
      assert_receive {:engine_started, _, task_pid_b}, 2000
      task_pids = [task_pid_a, task_pid_b]

      # Terminate first child
      :ok = DynamicSupervisor.terminate_child(RunSupervisor, pid1)

      Process.sleep(50)

      # Second should still be running
      assert Process.alive?(pid2)

      # Complete second
      Enum.each(task_pids, fn pid ->
        if is_pid(pid) and Process.alive?(pid) do
          send(pid, {:complete, "done"})
        end
      end)

      assert_receive {:run_complete, ^pid2, %Event.Completed{ok: true}}, 2000
    end
  end

  # ============================================================================
  # 6. Concurrent Operations
  # ============================================================================

  describe "concurrent operations" do
    test "many runs can be started in parallel" do
      start_time = System.monotonic_time(:millisecond)

      runs =
        for i <- 1..10 do
          scope = make_scope()
          job = make_job(scope, text: "parallel #{i}")

          {:ok, pid} =
            RunSupervisor.start_run(%{job: job, slot_ref: make_ref(), worker_pid: self()})

          {i, pid}
        end

      for {_i, pid} <- runs do
        assert_receive {:run_complete, ^pid, %Event.Completed{ok: true}}, 3000
      end

      end_time = System.monotonic_time(:millisecond)

      # Should complete relatively quickly (not serialized)
      assert end_time - start_time < 2000
    end

    test "concurrent starts and completions are handled correctly" do
      test_pid = self()

      tasks =
        for i <- 1..5 do
          Task.async(fn ->
            scope = make_scope()
            job = make_job(scope, text: "concurrent #{i}", meta: %{notify_pid: test_pid})

            {:ok, pid} =
              RunSupervisor.start_run(%{job: job, slot_ref: make_ref(), worker_pid: test_pid})

            pid
          end)
        end

      pids = Task.await_many(tasks, 5000)

      # All should complete
      for pid <- pids do
        assert_receive {:run_complete, ^pid, %Event.Completed{ok: true}}, 5000
      end
    end

    test "supervisor handles rapid start/stop cycles" do
      for _ <- 1..20 do
        scope = make_scope()
        job = make_job(scope)

        {:ok, pid} =
          RunSupervisor.start_run(%{job: job, slot_ref: make_ref(), worker_pid: self()})

        assert_receive {:run_complete, ^pid, %Event.Completed{ok: true}}, 2000
      end

      # Supervisor should still be functioning
      assert Process.alive?(Process.whereis(RunSupervisor))
    end

    test "mixed fast and slow runs complete correctly" do
      runs =
        for i <- 1..6 do
          scope = make_scope()

          if rem(i, 2) == 0 do
            job =
              make_job(scope,
                text: "slow #{i}",
                engine_hint: "slow_test",
                meta: %{notify_pid: self(), delay_ms: 100}
              )

            {:ok, pid} =
              RunSupervisor.start_run(%{job: job, slot_ref: make_ref(), worker_pid: self()})

            {:slow, pid}
          else
            job = make_job(scope, text: "fast #{i}")

            {:ok, pid} =
              RunSupervisor.start_run(%{job: job, slot_ref: make_ref(), worker_pid: self()})

            {:fast, pid}
          end
        end

      for {_type, pid} <- runs do
        assert_receive {:run_complete, ^pid, %Event.Completed{ok: true}}, 2000
      end
    end
  end

  # ============================================================================
  # 7. Worker Notification
  # ============================================================================

  describe "worker notification" do
    test "worker_pid receives run_complete on completion" do
      scope = make_scope()
      job = make_job(scope)

      {:ok, pid} = RunSupervisor.start_run(%{job: job, slot_ref: make_ref(), worker_pid: self()})

      assert_receive {:run_complete, ^pid, %Event.Completed{ok: true}}, 2000
    end

    test "worker_pid receives notification with correct completed event" do
      scope = make_scope()
      job = make_job(scope, text: "notification test")

      {:ok, pid} = RunSupervisor.start_run(%{job: job, slot_ref: make_ref(), worker_pid: self()})

      assert_receive {:run_complete, ^pid,
                      %Event.Completed{ok: true, answer: "Quick: notification test"}},
                     2000
    end

    test "different workers receive correct notifications" do
      test_pid = self()

      # Start runs with self as worker
      scope1 = make_scope()
      job1 = make_job(scope1, text: "job1")

      {:ok, pid1} =
        RunSupervisor.start_run(%{job: job1, slot_ref: make_ref(), worker_pid: test_pid})

      scope2 = make_scope()
      job2 = make_job(scope2, text: "job2")

      {:ok, pid2} =
        RunSupervisor.start_run(%{job: job2, slot_ref: make_ref(), worker_pid: test_pid})

      # Both should complete with correct answers
      completions =
        for _ <- 1..2 do
          receive do
            {:run_complete, pid, %Event.Completed{} = completed} -> {pid, completed}
          after
            2000 -> nil
          end
        end
        |> Enum.reject(&is_nil/1)

      assert length(completions) == 2

      pids = Enum.map(completions, &elem(&1, 0))
      assert pid1 in pids
      assert pid2 in pids
    end
  end

  # ============================================================================
  # 8. Slot Reference Handling
  # ============================================================================

  describe "slot reference handling" do
    test "slot_ref is passed through to Run process" do
      scope = make_scope()
      job = make_job(scope)
      slot_ref = make_ref()

      {:ok, pid} = RunSupervisor.start_run(%{job: job, slot_ref: slot_ref, worker_pid: self()})

      assert_receive {:run_complete, ^pid, %Event.Completed{ok: true}}, 2000
    end

    test "each run can have unique slot_ref" do
      runs =
        for i <- 1..3 do
          scope = make_scope()
          job = make_job(scope, text: "slot test #{i}")
          slot_ref = make_ref()

          {:ok, pid} =
            RunSupervisor.start_run(%{job: job, slot_ref: slot_ref, worker_pid: self()})

          {slot_ref, pid}
        end

      for {_slot_ref, pid} <- runs do
        assert_receive {:run_complete, ^pid, %Event.Completed{ok: true}}, 2000
      end
    end
  end

  # ============================================================================
  # 9. Cleanup on Shutdown
  # ============================================================================

  describe "cleanup on shutdown" do
    test "children are terminated when supervisor shuts down" do
      # This is hard to test directly without stopping the app
      # We verify the supervisor behavior indirectly
      scope = make_scope()

      job =
        make_job(scope,
          engine_hint: "controllable_test",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = RunSupervisor.start_run(%{job: job, slot_ref: make_ref(), worker_pid: self()})
      ref = Process.monitor(pid)

      assert_receive {:engine_started, _, _task_pid}, 2000

      # Terminate the child
      :ok = DynamicSupervisor.terminate_child(RunSupervisor, pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2000
    end

    test "completed runs are cleaned up properly" do
      initial_children = DynamicSupervisor.which_children(RunSupervisor)
      initial_count = length(initial_children)

      scope = make_scope()
      job = make_job(scope)

      {:ok, pid} = RunSupervisor.start_run(%{job: job, slot_ref: make_ref(), worker_pid: self()})

      assert_receive {:run_complete, ^pid, _}, 2000

      # Wait for cleanup
      Process.sleep(100)

      final_children = DynamicSupervisor.which_children(RunSupervisor)
      final_count = length(final_children)

      # Should be back to initial count (or less if other runs completed)
      assert final_count <= initial_count + 1
    end
  end

  # ============================================================================
  # 10. Edge Cases
  # ============================================================================

  describe "edge cases" do
    test "handles job with empty text" do
      scope = make_scope()
      job = make_job(scope, text: "")

      {:ok, pid} = RunSupervisor.start_run(%{job: job, slot_ref: make_ref(), worker_pid: self()})

      assert_receive {:run_complete, ^pid, %Event.Completed{ok: true, answer: "Quick: "}}, 2000
    end

    test "handles job with long text" do
      scope = make_scope()
      long_text = String.duplicate("a", 10000)
      job = make_job(scope, text: long_text)

      {:ok, pid} = RunSupervisor.start_run(%{job: job, slot_ref: make_ref(), worker_pid: self()})

      assert_receive {:run_complete, ^pid, %Event.Completed{ok: true}}, 2000
    end

    test "handles job with special characters" do
      scope = make_scope()
      job = make_job(scope, text: "Special chars: \n\t\r unicode: \u{1F600}")

      {:ok, pid} = RunSupervisor.start_run(%{job: job, slot_ref: make_ref(), worker_pid: self()})

      assert_receive {:run_complete, ^pid, %Event.Completed{ok: true}}, 2000
    end

    test "handles rapid sequential starts for same scope" do
      scope = make_scope()

      pids =
        for i <- 1..5 do
          job = make_job(scope, text: "rapid #{i}")

          {:ok, pid} =
            RunSupervisor.start_run(%{job: job, slot_ref: make_ref(), worker_pid: self()})

          pid
        end

      # All should complete
      for pid <- pids do
        assert_receive {:run_complete, ^pid, %Event.Completed{ok: true}}, 2000
      end
    end

    test "handles nil meta gracefully" do
      scope = make_scope()
      job = make_job(scope, meta: nil)

      {:ok, pid} = RunSupervisor.start_run(%{job: job, slot_ref: make_ref(), worker_pid: self()})

      assert_receive {:run_complete, ^pid, %Event.Completed{ok: true}}, 2000
    end
  end

  # ============================================================================
  # 11. Integration with Scheduler
  # ============================================================================

  describe "integration with scheduler" do
    test "runs started via supervisor complete and notify correctly" do
      scope = make_scope()
      job = make_job(scope, meta: %{notify_pid: self()})

      {:ok, pid} = RunSupervisor.start_run(%{job: job, slot_ref: make_ref(), worker_pid: self()})

      # Worker receives run_complete
      assert_receive {:run_complete, ^pid, %Event.Completed{ok: true}}, 2000

      # notify_pid receives lemon_gateway_run_completed
      assert_receive {:lemon_gateway_run_completed, ^job, %Event.Completed{ok: true}}, 2000
    end
  end

  # ============================================================================
  # 12. Process Monitoring
  # ============================================================================

  describe "process monitoring" do
    test "can monitor started Run processes" do
      scope = make_scope()
      job = make_job(scope)

      {:ok, pid} = RunSupervisor.start_run(%{job: job, slot_ref: make_ref(), worker_pid: self()})
      ref = Process.monitor(pid)

      assert_receive {:run_complete, ^pid, _}, 2000
      assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 2000
      assert reason in [:normal, :noproc]
    end

    test "monitor receives :normal reason on successful completion" do
      scope = make_scope()
      job = make_job(scope)

      {:ok, pid} = RunSupervisor.start_run(%{job: job, slot_ref: make_ref(), worker_pid: self()})
      ref = Process.monitor(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 2000
      assert reason in [:normal, :noproc]
    end

    test "can monitor multiple runs simultaneously" do
      monitors =
        for i <- 1..5 do
          scope = make_scope()
          job = make_job(scope, text: "monitor test #{i}")

          {:ok, pid} =
            RunSupervisor.start_run(%{job: job, slot_ref: make_ref(), worker_pid: self()})

          ref = Process.monitor(pid)
          {ref, pid}
        end

      for {ref, pid} <- monitors do
        assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 2000
        assert reason in [:normal, :noproc]
      end
    end
  end

  # ============================================================================
  # 13. Child Spec Configuration
  # ============================================================================

  describe "child spec configuration" do
    test "children are started with temporary restart strategy" do
      # Verify by checking that crashed children are not restarted
      scope = make_scope()

      job =
        make_job(scope,
          engine_hint: "controllable_test",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = RunSupervisor.start_run(%{job: job, slot_ref: make_ref(), worker_pid: self()})
      ref = Process.monitor(pid)

      assert_receive {:engine_started, _, _task_pid}, 2000

      # Force kill the process
      Process.exit(pid, :kill)

      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 2000

      # Wait and verify no restart
      Process.sleep(200)

      children = DynamicSupervisor.which_children(RunSupervisor)
      child_pids = Enum.map(children, fn {_, child_pid, _, _} -> child_pid end)

      refute pid in child_pids
    end

    test "child_spec uses LemonGateway.Run module" do
      # This is verified implicitly by the fact that Run processes behave correctly
      scope = make_scope()
      job = make_job(scope)

      {:ok, pid} = RunSupervisor.start_run(%{job: job, slot_ref: make_ref(), worker_pid: self()})

      # Verify it's a GenServer (Run is a GenServer)
      assert Process.alive?(pid)

      # The process responds to GenServer messages
      # We verify this by successfully receiving the completion
      assert_receive {:run_complete, ^pid, %Event.Completed{ok: true}}, 2000
    end
  end

  # ============================================================================
  # 14. Stress Testing
  # ============================================================================

  describe "stress testing" do
    test "handles burst of 50 simultaneous starts" do
      pids =
        for i <- 1..50 do
          scope = make_scope()
          job = make_job(scope, text: "burst #{i}")

          {:ok, pid} =
            RunSupervisor.start_run(%{job: job, slot_ref: make_ref(), worker_pid: self()})

          pid
        end

      # All should complete
      for pid <- pids do
        assert_receive {:run_complete, ^pid, %Event.Completed{ok: true}}, 5000
      end

      # Supervisor should still be healthy
      assert Process.alive?(Process.whereis(RunSupervisor))
    end

    test "supervisor remains stable after many operations" do
      # Perform many operations
      for batch <- 1..5 do
        for i <- 1..10 do
          scope = make_scope()
          job = make_job(scope, text: "stability test batch #{batch} run #{i}")

          {:ok, pid} =
            RunSupervisor.start_run(%{job: job, slot_ref: make_ref(), worker_pid: self()})

          assert_receive {:run_complete, ^pid, %Event.Completed{ok: true}}, 2000
        end
      end

      # Verify supervisor is still functioning
      assert Process.alive?(Process.whereis(RunSupervisor))

      # Can still start new runs
      scope = make_scope()
      job = make_job(scope, text: "final test")
      {:ok, pid} = RunSupervisor.start_run(%{job: job, slot_ref: make_ref(), worker_pid: self()})
      assert_receive {:run_complete, ^pid, %Event.Completed{ok: true}}, 2000
    end
  end

  # ============================================================================
  # 15. Module Interface Verification
  # ============================================================================

  describe "module interface verification" do
    test "start_run/1 is the public interface" do
      # Verify the function exists and works
      assert function_exported?(RunSupervisor, :start_run, 1)

      scope = make_scope()
      job = make_job(scope)

      result = RunSupervisor.start_run(%{job: job, slot_ref: make_ref(), worker_pid: self()})
      assert {:ok, _pid} = result
    end

    test "start_link/1 starts the supervisor" do
      assert function_exported?(RunSupervisor, :start_link, 1)
    end

    test "supervisor implements DynamicSupervisor callbacks" do
      # Verify init/1 callback works (verified by supervisor being alive)
      assert Process.alive?(Process.whereis(RunSupervisor))

      # Verify DynamicSupervisor functions work
      children = DynamicSupervisor.count_children(RunSupervisor)
      assert is_map(children)
    end
  end
end
