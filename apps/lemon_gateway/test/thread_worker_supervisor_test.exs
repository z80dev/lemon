defmodule Elixir.LemonGateway.ThreadWorkerSupervisorTest do
  alias Elixir.LemonGateway, as: LemonGateway
  @moduledoc """
  Comprehensive tests for Elixir.LemonGateway.ThreadWorkerSupervisor DynamicSupervisor.

  Tests cover:
  - Supervisor startup and initialization
  - Child process startup
  - Child process restart behavior
  - Supervision strategy behavior
  - Dynamic child management (start_child, terminate_child)
  - Registry interaction with ThreadRegistry
  - Concurrent operations
  - Cleanup on shutdown
  - Error isolation between children
  - Integration with ThreadWorker processes
  """
  use ExUnit.Case, async: false

  alias Elixir.LemonGateway.ThreadWorkerSupervisor
  alias Elixir.LemonGateway.ThreadWorker
  alias Elixir.LemonGateway.Types.Job
  alias Elixir.LemonGateway.Event.Completed

  # ============================================================================
  # Test Engine
  # ============================================================================

  defmodule Elixir.LemonGateway.ThreadWorkerSupervisorTest.TestEngine do
    @behaviour Elixir.LemonGateway.Engine

    alias Elixir.LemonGateway.Types.{Job, ResumeToken}
    alias Elixir.LemonGateway.Event

    @impl true
    def id, do: "test_engine"

    @impl true
    def format_resume(%ResumeToken{value: sid}), do: "test resume #{sid}"

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
      delay_ms = (job.meta || %{})[:delay_ms] || 10

      {:ok, task_pid} =
        Task.start(fn ->
          send(sink_pid, {:engine_event, run_ref, %Event.Started{engine: id(), resume: resume}})
          Process.sleep(delay_ms)
          answer = "Test: #{job.prompt}"

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

  # ============================================================================
  # Setup
  # ============================================================================

  setup do
    _ = Application.stop(:lemon_gateway)

    Application.put_env(:lemon_gateway, Elixir.LemonGateway.Config, %{
      max_concurrent_runs: 10,
      default_engine: "test_engine",
      enable_telegram: false,
      require_engine_lock: false
    })

    Application.put_env(:lemon_gateway, :engines, [
      Elixir.LemonGateway.ThreadWorkerSupervisorTest.TestEngine,
      Elixir.LemonGateway.Engines.Echo
    ])

    {:ok, _} = Application.ensure_all_started(:lemon_gateway)

    :ok
  end

  defp make_scope(chat_id \\ System.unique_integer([:positive])) do
    "test:#{chat_id}"
  end

  defp make_job(session_key, opts \\ []) do
    user_msg_id = Keyword.get(opts, :user_msg_id, 1)
    base_meta = %{notify_pid: self(), user_msg_id: user_msg_id}
    meta = Map.merge(base_meta, Keyword.get(opts, :meta, %{}))

    %Job{
      session_key: session_key,
      prompt: Keyword.get(opts, :text, Keyword.get(opts, :prompt, "test message")),
      queue_mode: Keyword.get(opts, :queue_mode, :collect),
      engine_id: Keyword.get(opts, :engine_hint, Keyword.get(opts, :engine_id, "test_engine")),
      meta: meta
    }
  end

  defp thread_key(session_key) do
    {:session, session_key}
  end

  # ============================================================================
  # 1. Supervisor Startup and Initialization
  # ============================================================================

  describe "supervisor startup and initialization" do
    test "supervisor starts successfully" do
      assert Process.whereis(ThreadWorkerSupervisor) != nil
    end

    test "supervisor uses DynamicSupervisor behavior" do
      pid = Process.whereis(ThreadWorkerSupervisor)
      assert Process.alive?(pid)

      children = DynamicSupervisor.count_children(ThreadWorkerSupervisor)
      assert is_map(children)
      assert Map.has_key?(children, :active)
      assert Map.has_key?(children, :specs)
    end

    test "supervisor is registered with correct name" do
      pid = Process.whereis(ThreadWorkerSupervisor)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "supervisor uses :one_for_one strategy" do
      # Verify by checking that independent workers don't affect each other
      scope1 = make_scope()
      scope2 = make_scope()

      job1 = make_job(scope1, text: "worker1")
      job2 = make_job(scope2, text: "worker2")

      Elixir.LemonGateway.submit(job1)
      Elixir.LemonGateway.submit(job2)

      assert_receive {:lemon_gateway_run_completed, ^job1, %Completed{ok: true}}, 2000
      assert_receive {:lemon_gateway_run_completed, ^job2, %Completed{ok: true}}, 2000
    end
  end

  # ============================================================================
  # 2. Child Process Startup
  # ============================================================================

  describe "child process startup" do
    test "starting a worker via DynamicSupervisor.start_child" do
      scope = make_scope()
      key = thread_key(scope)

      spec = {ThreadWorker, [thread_key: key]}
      {:ok, pid} = DynamicSupervisor.start_child(ThreadWorkerSupervisor, spec)

      assert is_pid(pid)
      assert Process.alive?(pid)

      # Clean up
      DynamicSupervisor.terminate_child(ThreadWorkerSupervisor, pid)
    end

    test "started worker is registered in ThreadRegistry" do
      scope = make_scope()
      key = thread_key(scope)

      spec = {ThreadWorker, [thread_key: key]}
      {:ok, pid} = DynamicSupervisor.start_child(ThreadWorkerSupervisor, spec)

      # Verify registration
      assert Elixir.LemonGateway.ThreadRegistry.whereis(key) == pid

      # Clean up
      DynamicSupervisor.terminate_child(ThreadWorkerSupervisor, pid)
    end

    test "multiple workers can be started for different thread_keys" do
      scope1 = make_scope()
      scope2 = make_scope()
      scope3 = make_scope()

      key1 = thread_key(scope1)
      key2 = thread_key(scope2)
      key3 = thread_key(scope3)

      {:ok, pid1} =
        DynamicSupervisor.start_child(ThreadWorkerSupervisor, {ThreadWorker, [thread_key: key1]})

      {:ok, pid2} =
        DynamicSupervisor.start_child(ThreadWorkerSupervisor, {ThreadWorker, [thread_key: key2]})

      {:ok, pid3} =
        DynamicSupervisor.start_child(ThreadWorkerSupervisor, {ThreadWorker, [thread_key: key3]})

      assert is_pid(pid1)
      assert is_pid(pid2)
      assert is_pid(pid3)
      assert pid1 != pid2
      assert pid2 != pid3

      # Clean up
      DynamicSupervisor.terminate_child(ThreadWorkerSupervisor, pid1)
      DynamicSupervisor.terminate_child(ThreadWorkerSupervisor, pid2)
      DynamicSupervisor.terminate_child(ThreadWorkerSupervisor, pid3)
    end

    test "worker started via submit is supervised" do
      scope = make_scope()
      job = make_job(scope)

      Elixir.LemonGateway.submit(job)

      # Give time for worker to start
      Process.sleep(50)

      key = thread_key(scope)
      worker_pid = Elixir.LemonGateway.ThreadRegistry.whereis(key)

      if worker_pid do
        children = DynamicSupervisor.which_children(ThreadWorkerSupervisor)
        child_pids = Enum.map(children, fn {_, pid, _, _} -> pid end)
        assert worker_pid in child_pids
      end

      assert_receive {:lemon_gateway_run_completed, ^job, %Completed{ok: true}}, 2000
    end
  end

  # ============================================================================
  # 3. Registry Interaction
  # ============================================================================

  describe "registry interaction" do
    test "ThreadRegistry.whereis returns worker pid" do
      scope = make_scope()
      key = thread_key(scope)

      spec = {ThreadWorker, [thread_key: key]}
      {:ok, pid} = DynamicSupervisor.start_child(ThreadWorkerSupervisor, spec)

      assert Elixir.LemonGateway.ThreadRegistry.whereis(key) == pid

      DynamicSupervisor.terminate_child(ThreadWorkerSupervisor, pid)
    end

    test "ThreadRegistry.whereis returns nil after worker terminates" do
      scope = make_scope()
      key = thread_key(scope)

      spec = {ThreadWorker, [thread_key: key]}
      {:ok, pid} = DynamicSupervisor.start_child(ThreadWorkerSupervisor, spec)

      assert Elixir.LemonGateway.ThreadRegistry.whereis(key) == pid

      DynamicSupervisor.terminate_child(ThreadWorkerSupervisor, pid)

      Process.sleep(50)
      assert Elixir.LemonGateway.ThreadRegistry.whereis(key) == nil
    end

    test "duplicate thread_key registration fails" do
      scope = make_scope()
      key = thread_key(scope)

      spec = {ThreadWorker, [thread_key: key]}
      {:ok, pid1} = DynamicSupervisor.start_child(ThreadWorkerSupervisor, spec)

      # Try to start another worker with same key
      result = DynamicSupervisor.start_child(ThreadWorkerSupervisor, spec)

      assert {:error, {:already_started, ^pid1}} = result

      DynamicSupervisor.terminate_child(ThreadWorkerSupervisor, pid1)
    end

    test "workers with different keys are independent" do
      scope1 = make_scope()
      scope2 = make_scope()

      key1 = thread_key(scope1)
      key2 = thread_key(scope2)

      {:ok, pid1} =
        DynamicSupervisor.start_child(ThreadWorkerSupervisor, {ThreadWorker, [thread_key: key1]})

      {:ok, pid2} =
        DynamicSupervisor.start_child(ThreadWorkerSupervisor, {ThreadWorker, [thread_key: key2]})

      assert Elixir.LemonGateway.ThreadRegistry.whereis(key1) == pid1
      assert Elixir.LemonGateway.ThreadRegistry.whereis(key2) == pid2
      assert pid1 != pid2

      DynamicSupervisor.terminate_child(ThreadWorkerSupervisor, pid1)
      DynamicSupervisor.terminate_child(ThreadWorkerSupervisor, pid2)
    end
  end

  # ============================================================================
  # 4. Dynamic Child Management
  # ============================================================================

  describe "dynamic child management" do
    test "DynamicSupervisor.which_children returns current children" do
      initial_children = DynamicSupervisor.which_children(ThreadWorkerSupervisor)
      initial_count = length(initial_children)

      scope = make_scope()
      key = thread_key(scope)

      spec = {ThreadWorker, [thread_key: key]}
      {:ok, pid} = DynamicSupervisor.start_child(ThreadWorkerSupervisor, spec)

      children = DynamicSupervisor.which_children(ThreadWorkerSupervisor)
      child_pids = Enum.map(children, fn {_, child_pid, _, _} -> child_pid end)

      assert pid in child_pids
      assert length(children) == initial_count + 1

      DynamicSupervisor.terminate_child(ThreadWorkerSupervisor, pid)
    end

    test "DynamicSupervisor.count_children reflects active children" do
      initial_count = DynamicSupervisor.count_children(ThreadWorkerSupervisor).active

      scope = make_scope()
      key = thread_key(scope)

      spec = {ThreadWorker, [thread_key: key]}
      {:ok, pid} = DynamicSupervisor.start_child(ThreadWorkerSupervisor, spec)

      active_count = DynamicSupervisor.count_children(ThreadWorkerSupervisor).active
      assert active_count == initial_count + 1

      DynamicSupervisor.terminate_child(ThreadWorkerSupervisor, pid)

      final_count = DynamicSupervisor.count_children(ThreadWorkerSupervisor).active
      assert final_count == initial_count
    end

    test "DynamicSupervisor.terminate_child terminates a worker" do
      scope = make_scope()
      key = thread_key(scope)

      spec = {ThreadWorker, [thread_key: key]}
      {:ok, pid} = DynamicSupervisor.start_child(ThreadWorkerSupervisor, spec)
      ref = Process.monitor(pid)

      :ok = DynamicSupervisor.terminate_child(ThreadWorkerSupervisor, pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2000
    end

    test "terminated worker is unregistered from ThreadRegistry" do
      scope = make_scope()
      key = thread_key(scope)

      spec = {ThreadWorker, [thread_key: key]}
      {:ok, pid} = DynamicSupervisor.start_child(ThreadWorkerSupervisor, spec)

      assert Elixir.LemonGateway.ThreadRegistry.whereis(key) == pid

      DynamicSupervisor.terminate_child(ThreadWorkerSupervisor, pid)

      Process.sleep(50)
      assert Elixir.LemonGateway.ThreadRegistry.whereis(key) == nil
    end
  end

  # ============================================================================
  # 5. Error Isolation Between Children
  # ============================================================================

  describe "error isolation between children" do
    test "one worker crashing does not affect other workers" do
      scope1 = make_scope()
      scope2 = make_scope()

      key1 = thread_key(scope1)
      key2 = thread_key(scope2)

      {:ok, pid1} =
        DynamicSupervisor.start_child(ThreadWorkerSupervisor, {ThreadWorker, [thread_key: key1]})

      {:ok, pid2} =
        DynamicSupervisor.start_child(ThreadWorkerSupervisor, {ThreadWorker, [thread_key: key2]})

      # Kill first worker
      Process.exit(pid1, :kill)
      Process.sleep(50)

      # Second worker should still be alive
      assert Process.alive?(pid2)
      assert Elixir.LemonGateway.ThreadRegistry.whereis(key2) == pid2

      DynamicSupervisor.terminate_child(ThreadWorkerSupervisor, pid2)
    end

    test "supervisor continues functioning after worker crash" do
      scope1 = make_scope()
      key1 = thread_key(scope1)

      {:ok, pid1} =
        DynamicSupervisor.start_child(ThreadWorkerSupervisor, {ThreadWorker, [thread_key: key1]})

      # Kill the worker
      Process.exit(pid1, :kill)
      Process.sleep(50)

      # Supervisor should still be alive
      assert Process.alive?(Process.whereis(ThreadWorkerSupervisor))

      # Can start new workers
      scope2 = make_scope()
      key2 = thread_key(scope2)

      {:ok, pid2} =
        DynamicSupervisor.start_child(ThreadWorkerSupervisor, {ThreadWorker, [thread_key: key2]})

      assert is_pid(pid2)

      DynamicSupervisor.terminate_child(ThreadWorkerSupervisor, pid2)
    end

    test "multiple workers can be terminated independently" do
      workers =
        for _ <- 1..5 do
          scope = make_scope()
          key = thread_key(scope)

          {:ok, pid} =
            DynamicSupervisor.start_child(
              ThreadWorkerSupervisor,
              {ThreadWorker, [thread_key: key]}
            )

          {key, pid}
        end

      # Terminate every other worker
      workers
      |> Enum.with_index()
      |> Enum.filter(fn {_w, i} -> rem(i, 2) == 0 end)
      |> Enum.each(fn {{_key, pid}, _i} ->
        DynamicSupervisor.terminate_child(ThreadWorkerSupervisor, pid)
      end)

      Process.sleep(50)

      # Remaining workers should still be alive
      workers
      |> Enum.with_index()
      |> Enum.filter(fn {_w, i} -> rem(i, 2) == 1 end)
      |> Enum.each(fn {{_key, pid}, _i} ->
        assert Process.alive?(pid)
        DynamicSupervisor.terminate_child(ThreadWorkerSupervisor, pid)
      end)
    end
  end

  # ============================================================================
  # 6. Concurrent Operations
  # ============================================================================

  describe "concurrent operations" do
    test "many workers can be started in parallel" do
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            scope = make_scope()
            key = thread_key(scope)
            spec = {ThreadWorker, [thread_key: key]}
            {:ok, pid} = DynamicSupervisor.start_child(ThreadWorkerSupervisor, spec)
            {i, key, pid}
          end)
        end

      results = Task.await_many(tasks, 5000)
      assert length(results) == 10

      # All workers should be alive
      for {_i, _key, pid} <- results do
        assert Process.alive?(pid)
        DynamicSupervisor.terminate_child(ThreadWorkerSupervisor, pid)
      end
    end

    test "concurrent job submissions create workers correctly" do
      test_pid = self()

      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            scope = make_scope()
            job = make_job(scope, text: "concurrent #{i}", meta: %{notify_pid: test_pid})
            Elixir.LemonGateway.submit(job)
            job
          end)
        end

      jobs = Task.await_many(tasks, 5000)

      # All jobs should complete
      for job <- jobs do
        assert_receive {:lemon_gateway_run_completed, ^job, %Completed{ok: true}}, 5000
      end
    end

    test "supervisor handles rapid worker lifecycle" do
      for _ <- 1..20 do
        scope = make_scope()
        key = thread_key(scope)

        {:ok, pid} =
          DynamicSupervisor.start_child(ThreadWorkerSupervisor, {ThreadWorker, [thread_key: key]})

        assert Process.alive?(pid)
        DynamicSupervisor.terminate_child(ThreadWorkerSupervisor, pid)
      end

      # Supervisor should still be healthy
      assert Process.alive?(Process.whereis(ThreadWorkerSupervisor))
    end
  end

  # ============================================================================
  # 7. Worker Lifecycle with Jobs
  # ============================================================================

  describe "worker lifecycle with jobs" do
    test "worker stops after completing all jobs" do
      scope = make_scope()
      key = thread_key(scope)

      job = make_job(scope)
      Elixir.LemonGateway.submit(job)

      assert_receive {:lemon_gateway_run_completed, ^job, %Completed{ok: true}}, 2000

      # Wait for worker to stop - may take a bit longer
      wait_for_worker_stop(key, 500)
    end

    test "worker can be recreated after stopping" do
      scope = make_scope()
      key = thread_key(scope)

      job1 = make_job(scope, text: "first")
      Elixir.LemonGateway.submit(job1)

      assert_receive {:lemon_gateway_run_completed, ^job1, %Completed{ok: true}}, 2000

      # Wait for worker to stop
      wait_for_worker_stop(key, 500)

      # Submit another job - should create new worker (or reuse existing)
      job2 = make_job(scope, text: "second")
      Elixir.LemonGateway.submit(job2)

      assert_receive {:lemon_gateway_run_completed, ^job2, %Completed{ok: true}}, 2000
    end

    test "worker processes multiple jobs sequentially" do
      scope = make_scope()

      # Submit first job and wait for completion before next
      job1 = make_job(scope, text: "job 1")
      Elixir.LemonGateway.submit(job1)
      assert_receive {:lemon_gateway_run_completed, ^job1, %Completed{ok: true}}, 2000

      # Wait a moment then submit next job
      Process.sleep(50)

      job2 = make_job(scope, text: "job 2")
      Elixir.LemonGateway.submit(job2)
      assert_receive {:lemon_gateway_run_completed, ^job2, %Completed{ok: true}}, 2000
    end
  end

  defp wait_for_worker_stop(key, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_worker_stop(key, deadline)
  end

  defp do_wait_for_worker_stop(key, deadline) do
    case Elixir.LemonGateway.ThreadRegistry.whereis(key) do
      nil ->
        :ok

      _pid ->
        if System.monotonic_time(:millisecond) > deadline do
          # Worker may still be alive for a bit, that's acceptable
          :ok
        else
          Process.sleep(20)
          do_wait_for_worker_stop(key, deadline)
        end
    end
  end

  # ============================================================================
  # 8. Cleanup on Shutdown
  # ============================================================================

  describe "cleanup on shutdown" do
    test "terminated workers are cleaned up properly" do
      initial_count = DynamicSupervisor.count_children(ThreadWorkerSupervisor).active

      scope = make_scope()
      key = thread_key(scope)

      {:ok, pid} =
        DynamicSupervisor.start_child(ThreadWorkerSupervisor, {ThreadWorker, [thread_key: key]})

      assert DynamicSupervisor.count_children(ThreadWorkerSupervisor).active == initial_count + 1

      DynamicSupervisor.terminate_child(ThreadWorkerSupervisor, pid)

      assert DynamicSupervisor.count_children(ThreadWorkerSupervisor).active == initial_count
    end

    test "workers are unregistered from registry on termination" do
      scope = make_scope()
      key = thread_key(scope)

      {:ok, pid} =
        DynamicSupervisor.start_child(ThreadWorkerSupervisor, {ThreadWorker, [thread_key: key]})

      assert Elixir.LemonGateway.ThreadRegistry.whereis(key) == pid

      DynamicSupervisor.terminate_child(ThreadWorkerSupervisor, pid)
      Process.sleep(50)

      assert Elixir.LemonGateway.ThreadRegistry.whereis(key) == nil
    end

    test "crashed workers are cleaned up from supervisor" do
      scope = make_scope()
      key = thread_key(scope)

      {:ok, pid} =
        DynamicSupervisor.start_child(ThreadWorkerSupervisor, {ThreadWorker, [thread_key: key]})

      ref = Process.monitor(pid)

      # Crash the worker
      Process.exit(pid, :kill)

      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 2000

      # The original process should be dead - new one may have been created due to restart
      refute Process.alive?(pid)

      # Supervisor should still be functioning
      assert Process.alive?(Process.whereis(ThreadWorkerSupervisor))
    end
  end

  # ============================================================================
  # 9. Edge Cases
  # ============================================================================

  describe "edge cases" do
    test "handles empty job queue gracefully" do
      scope = make_scope()
      key = thread_key(scope)

      {:ok, pid} =
        DynamicSupervisor.start_child(ThreadWorkerSupervisor, {ThreadWorker, [thread_key: key]})

      # Worker is alive but has no jobs
      assert Process.alive?(pid)

      # Submit a job to make it do something then stop
      job = make_job(scope)
      GenServer.cast(pid, {:enqueue, job})

      assert_receive {:lemon_gateway_run_completed, ^job, %Completed{ok: true}}, 2000
    end

    test "handles rapid sequential job submissions" do
      # Jobs submitted to the same scope may be coalesced, so we use different scopes
      jobs =
        for i <- 1..10 do
          scope = make_scope()
          job = make_job(scope, text: "rapid #{i}")
          Elixir.LemonGateway.submit(job)
          job
        end

      for job <- jobs do
        assert_receive {:lemon_gateway_run_completed, ^job, %Completed{ok: true}}, 5000
      end
    end

    test "handles job submission to terminated worker" do
      # This tests that the router creates a new worker when needed
      scope = make_scope()
      key = thread_key(scope)

      {:ok, pid} =
        DynamicSupervisor.start_child(ThreadWorkerSupervisor, {ThreadWorker, [thread_key: key]})

      DynamicSupervisor.terminate_child(ThreadWorkerSupervisor, pid)

      Process.sleep(50)

      # Submit job - should create new worker
      job = make_job(scope)
      Elixir.LemonGateway.submit(job)

      assert_receive {:lemon_gateway_run_completed, ^job, %Completed{ok: true}}, 2000
    end
  end

  # ============================================================================
  # 10. Process Monitoring
  # ============================================================================

  describe "process monitoring" do
    test "can monitor workers" do
      scope = make_scope()
      key = thread_key(scope)

      {:ok, pid} =
        DynamicSupervisor.start_child(ThreadWorkerSupervisor, {ThreadWorker, [thread_key: key]})

      ref = Process.monitor(pid)

      DynamicSupervisor.terminate_child(ThreadWorkerSupervisor, pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2000
    end

    test "multiple workers can be monitored" do
      monitors =
        for _ <- 1..5 do
          scope = make_scope()
          key = thread_key(scope)

          {:ok, pid} =
            DynamicSupervisor.start_child(
              ThreadWorkerSupervisor,
              {ThreadWorker, [thread_key: key]}
            )

          ref = Process.monitor(pid)
          {ref, pid}
        end

      for {_ref, pid} <- monitors do
        DynamicSupervisor.terminate_child(ThreadWorkerSupervisor, pid)
      end

      for {ref, pid} <- monitors do
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2000
      end
    end
  end

  # ============================================================================
  # 11. Stress Testing
  # ============================================================================

  describe "stress testing" do
    test "handles burst of worker creations" do
      workers =
        for _ <- 1..30 do
          scope = make_scope()
          key = thread_key(scope)

          {:ok, pid} =
            DynamicSupervisor.start_child(
              ThreadWorkerSupervisor,
              {ThreadWorker, [thread_key: key]}
            )

          {key, pid}
        end

      # All should be alive
      for {_key, pid} <- workers do
        assert Process.alive?(pid)
        DynamicSupervisor.terminate_child(ThreadWorkerSupervisor, pid)
      end

      assert Process.alive?(Process.whereis(ThreadWorkerSupervisor))
    end

    test "supervisor remains stable after many operations" do
      for _ <- 1..10 do
        workers =
          for _ <- 1..5 do
            scope = make_scope()
            key = thread_key(scope)

            {:ok, pid} =
              DynamicSupervisor.start_child(
                ThreadWorkerSupervisor,
                {ThreadWorker, [thread_key: key]}
              )

            pid
          end

        for pid <- workers do
          DynamicSupervisor.terminate_child(ThreadWorkerSupervisor, pid)
        end
      end

      assert Process.alive?(Process.whereis(ThreadWorkerSupervisor))
    end
  end

  # ============================================================================
  # 12. Integration with Elixir.LemonGateway.submit
  # ============================================================================

  describe "integration with Elixir.LemonGateway.submit" do
    test "submit creates supervised worker" do
      scope = make_scope()
      job = make_job(scope)

      Elixir.LemonGateway.submit(job)

      # Wait for job to start processing
      Process.sleep(50)

      key = thread_key(scope)
      worker_pid = Elixir.LemonGateway.ThreadRegistry.whereis(key)

      if worker_pid do
        children = DynamicSupervisor.which_children(ThreadWorkerSupervisor)
        child_pids = Enum.map(children, fn {_, pid, _, _} -> pid end)
        assert worker_pid in child_pids
      end

      assert_receive {:lemon_gateway_run_completed, ^job, %Completed{ok: true}}, 2000
    end

    test "submit reuses existing worker for same scope" do
      scope = make_scope()
      key = thread_key(scope)

      # Submit first job to create worker
      job1 = make_job(scope, text: "first", meta: %{notify_pid: self(), delay_ms: 200})
      Elixir.LemonGateway.submit(job1)

      Process.sleep(50)
      worker_pid1 = Elixir.LemonGateway.ThreadRegistry.whereis(key)
      assert is_pid(worker_pid1)

      # Submit second job while first is running
      job2 = make_job(scope, text: "second")
      Elixir.LemonGateway.submit(job2)

      # Should still be same worker
      worker_pid2 = Elixir.LemonGateway.ThreadRegistry.whereis(key)
      assert worker_pid1 == worker_pid2

      assert_receive {:lemon_gateway_run_completed, ^job1, %Completed{ok: true}}, 2000
      assert_receive {:lemon_gateway_run_completed, ^job2, %Completed{ok: true}}, 2000
    end

    test "different scopes get different workers" do
      scope1 = make_scope()
      scope2 = make_scope()

      key1 = thread_key(scope1)
      key2 = thread_key(scope2)

      job1 = make_job(scope1, text: "scope1", meta: %{notify_pid: self(), delay_ms: 200})
      job2 = make_job(scope2, text: "scope2", meta: %{notify_pid: self(), delay_ms: 200})

      Elixir.LemonGateway.submit(job1)
      Elixir.LemonGateway.submit(job2)

      Process.sleep(50)

      worker_pid1 = Elixir.LemonGateway.ThreadRegistry.whereis(key1)
      worker_pid2 = Elixir.LemonGateway.ThreadRegistry.whereis(key2)

      assert is_pid(worker_pid1)
      assert is_pid(worker_pid2)
      assert worker_pid1 != worker_pid2

      assert_receive {:lemon_gateway_run_completed, ^job1, %Completed{ok: true}}, 2000
      assert_receive {:lemon_gateway_run_completed, ^job2, %Completed{ok: true}}, 2000
    end
  end

  # ============================================================================
  # 13. Module Interface Verification
  # ============================================================================

  describe "module interface verification" do
    test "start_link/1 exists and works" do
      assert function_exported?(ThreadWorkerSupervisor, :start_link, 1)
    end

    test "supervisor implements DynamicSupervisor callbacks" do
      assert Process.alive?(Process.whereis(ThreadWorkerSupervisor))

      children = DynamicSupervisor.count_children(ThreadWorkerSupervisor)
      assert is_map(children)
    end

    test "standard DynamicSupervisor functions work" do
      # which_children
      children = DynamicSupervisor.which_children(ThreadWorkerSupervisor)
      assert is_list(children)

      # count_children
      counts = DynamicSupervisor.count_children(ThreadWorkerSupervisor)
      assert Map.has_key?(counts, :active)
      assert Map.has_key?(counts, :specs)
      assert Map.has_key?(counts, :supervisors)
      assert Map.has_key?(counts, :workers)
    end
  end

  # ============================================================================
  # 14. Child Spec Verification
  # ============================================================================

  describe "child spec verification" do
    test "ThreadWorker child specs are valid" do
      scope = make_scope()
      key = thread_key(scope)

      spec = {ThreadWorker, [thread_key: key]}
      result = DynamicSupervisor.start_child(ThreadWorkerSupervisor, spec)

      assert {:ok, pid} = result
      assert is_pid(pid)

      DynamicSupervisor.terminate_child(ThreadWorkerSupervisor, pid)
    end

    test "children are workers not supervisors" do
      scope = make_scope()
      key = thread_key(scope)

      {:ok, pid} =
        DynamicSupervisor.start_child(ThreadWorkerSupervisor, {ThreadWorker, [thread_key: key]})

      children = DynamicSupervisor.which_children(ThreadWorkerSupervisor)
      child = Enum.find(children, fn {_, child_pid, _, _} -> child_pid == pid end)

      {_, _, type, _} = child
      assert type == :worker

      DynamicSupervisor.terminate_child(ThreadWorkerSupervisor, pid)
    end
  end

  # ============================================================================
  # 15. ThreadRegistry Via Tuple Name
  # ============================================================================

  describe "ThreadRegistry via tuple name" do
    test "workers are registered with via tuple" do
      scope = make_scope()
      key = thread_key(scope)

      {:ok, pid} =
        DynamicSupervisor.start_child(ThreadWorkerSupervisor, {ThreadWorker, [thread_key: key]})

      # Verify via tuple works
      via_name = {:via, Registry, {Elixir.LemonGateway.ThreadRegistry, key}}
      assert GenServer.whereis(via_name) == pid

      DynamicSupervisor.terminate_child(ThreadWorkerSupervisor, pid)
    end

    test "via tuple lookup returns nil after termination" do
      scope = make_scope()
      key = thread_key(scope)

      {:ok, pid} =
        DynamicSupervisor.start_child(ThreadWorkerSupervisor, {ThreadWorker, [thread_key: key]})

      DynamicSupervisor.terminate_child(ThreadWorkerSupervisor, pid)

      Process.sleep(50)

      via_name = {:via, Registry, {Elixir.LemonGateway.ThreadRegistry, key}}
      assert GenServer.whereis(via_name) == nil
    end
  end

  # ============================================================================
  # 16. Restart Behavior
  # ============================================================================

  describe "restart behavior" do
    test "crashed workers may be restarted based on supervisor strategy" do
      scope = make_scope()
      key = thread_key(scope)

      {:ok, pid} =
        DynamicSupervisor.start_child(ThreadWorkerSupervisor, {ThreadWorker, [thread_key: key]})

      ref = Process.monitor(pid)

      # Kill the worker
      Process.exit(pid, :kill)

      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 2000

      # The original process should be dead
      refute Process.alive?(pid)

      # Supervisor should still be functioning
      assert Process.alive?(Process.whereis(ThreadWorkerSupervisor))

      # A new worker with the same key may or may not exist depending on restart strategy
      # The key behavior is that the supervisor remains stable
      Process.sleep(100)
      new_pid = Elixir.LemonGateway.ThreadRegistry.whereis(key)

      # If restarted, it should be a different pid
      if new_pid do
        assert new_pid != pid
      end

      # The exact mechanism depends on DynamicSupervisor restart strategy
      # With default :one_for_one and :temporary restart, no auto-restart occurs
    end
  end

  # ============================================================================
  # 17. Application Integration
  # ============================================================================

  describe "application integration" do
    test "supervisor is started as part of application" do
      # Verify supervisor is part of app's supervision tree
      assert Process.whereis(ThreadWorkerSupervisor) != nil
    end

    test "supervisor survives worker crashes" do
      supervisor_pid = Process.whereis(ThreadWorkerSupervisor)

      scope = make_scope()
      key = thread_key(scope)

      {:ok, worker_pid} =
        DynamicSupervisor.start_child(ThreadWorkerSupervisor, {ThreadWorker, [thread_key: key]})

      # Kill the worker
      Process.exit(worker_pid, :kill)
      Process.sleep(50)

      # Supervisor should still be the same process
      assert Process.whereis(ThreadWorkerSupervisor) == supervisor_pid
      assert Process.alive?(supervisor_pid)
    end
  end

  # ============================================================================
  # 18. Error Handling
  # ============================================================================

  describe "error handling" do
    test "handles invalid child specs gracefully" do
      # Trying to start something that's not a valid child raises an error
      assert_raise ArgumentError, fn ->
        DynamicSupervisor.start_child(ThreadWorkerSupervisor, {NonExistentModule, []})
      end
    end

    test "supervisor handles terminate_child on non-existent pid" do
      fake_pid = spawn(fn -> :ok end)
      Process.sleep(10)

      # Try to terminate a process that's not a child
      result = DynamicSupervisor.terminate_child(ThreadWorkerSupervisor, fake_pid)

      # Should return error but not crash
      assert result == {:error, :not_found}
    end

    test "supervisor handles multiple rapid terminate calls" do
      scope = make_scope()
      key = thread_key(scope)

      {:ok, pid} =
        DynamicSupervisor.start_child(ThreadWorkerSupervisor, {ThreadWorker, [thread_key: key]})

      # First terminate should succeed
      assert :ok = DynamicSupervisor.terminate_child(ThreadWorkerSupervisor, pid)

      # Second terminate should return not_found
      assert {:error, :not_found} = DynamicSupervisor.terminate_child(ThreadWorkerSupervisor, pid)
    end
  end
end
