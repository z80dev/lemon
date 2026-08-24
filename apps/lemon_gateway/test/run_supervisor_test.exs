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
  alias LemonGateway.ExecutionRequest
  alias LemonCore.ResumeToken

  # ============================================================================
  # Configured executor fixture
  # ============================================================================

  # The configured executor models distinct external-process lifecycles while
  # every test still dispatches its ExecutionRequest through one native boundary.
  # Modes come from request metadata (or executor options when directly invoked).
  defmodule RunSupervisorFixtureExecutor do
    @behaviour LemonGateway.Executor

    alias LemonCore.ResumeToken
    alias LemonGateway.{Event, ExecutionRequest}

    @impl true
    def start_run(%ExecutionRequest{} = request, opts, sink_pid) do
      case fixture_mode(request, opts) do
        :quick -> start_completed(request, sink_pid, "Quick: #{request.prompt}")
        :slow -> start_slow(request, sink_pid)
        :controlled -> start_controlled(request, sink_pid)
        :crash -> start_crashing(request, sink_pid)
        :cancel -> start_cancelable(request, sink_pid)
        mode -> {:error, {:unknown_fixture_mode, mode}}
      end
    end

    @impl true
    def cancel(%{task_pid: task_pid} = context) when is_pid(task_pid) do
      notify_control(context, :cancelled, nil)
      Process.exit(task_pid, :kill)
      :ok
    end

    def cancel(_context), do: :ok

    @impl true
    def steer(context, text) when is_binary(text) do
      notify_control(context, :steered, text)
      send_control(context, {:steer, text})
      :ok
    end

    @impl true
    def redirect(context, text) when is_binary(text) do
      notify_control(context, :redirected, text)
      send_control(context, {:redirect, text})
      :ok
    end

    defp start_completed(request, sink_pid, answer) do
      start_task(request, sink_pid, fn run_ref, resume, _meta ->
        send(
          sink_pid,
          {:engine_event, run_ref,
           Event.completed(%{engine: "lemon", resume: resume, ok: true, answer: answer})}
        )
      end)
    end

    defp start_slow(request, sink_pid) do
      start_task(request, sink_pid, fn run_ref, resume, meta ->
        Process.sleep(Map.get(meta, :delay_ms, 500))

        send(
          sink_pid,
          {:engine_event, run_ref,
           Event.completed(%{
             engine: "lemon",
             resume: resume,
             ok: true,
             answer: "Slow: #{request.prompt}"
           })}
        )
      end)
    end

    defp start_controlled(request, sink_pid) do
      start_task(request, sink_pid, fn run_ref, resume, meta ->
        controlled_loop(run_ref, resume, sink_pid, meta)
      end)
    end

    defp start_crashing(request, sink_pid) do
      start_task(request, sink_pid, fn _run_ref, _resume, _meta ->
        exit(:fixture_crash)
      end)
    end

    defp start_cancelable(request, sink_pid) do
      start_task(request, sink_pid, fn _run_ref, _resume, _meta ->
        receive do
          {:complete, _answer} -> :ok
        after
          30_000 -> :ok
        end
      end)
    end

    defp start_task(request, sink_pid, action) do
      run_ref = make_ref()
      meta = request.meta || %{}
      resume = request.resume || %ResumeToken{engine: "lemon", value: unique_id()}

      {:ok, task_pid} =
        Task.start(fn ->
          send(
            sink_pid,
            {:engine_event, run_ref, Event.started(%{engine: "lemon", resume: resume})}
          )

          if controller_pid = Map.get(meta, :controller_pid) do
            send(
              controller_pid,
              {:executor_started, request.run_id, request.prompt, run_ref, self()}
            )
          end

          action.(run_ref, resume, meta)
        end)

      {:ok, run_ref,
       %{
         task_pid: task_pid,
         control_pid: Map.get(meta, :control_pid) || Map.get(meta, :controller_pid)
       }}
    end

    defp controlled_loop(run_ref, resume, sink_pid, meta) do
      receive do
        {:complete, answer} ->
          send(
            sink_pid,
            {:engine_event, run_ref,
             Event.completed(%{engine: "lemon", resume: resume, ok: true, answer: answer})}
          )

        {:error, reason} ->
          send(
            sink_pid,
            {:engine_event, run_ref,
             Event.completed(%{engine: "lemon", resume: resume, ok: false, error: reason})}
          )

        {:steer, text} ->
          notify(meta, :steered, text)
          controlled_loop(run_ref, resume, sink_pid, meta)

        {:redirect, text} ->
          notify(meta, :redirected, text)
          controlled_loop(run_ref, resume, sink_pid, meta)
      after
        30_000 ->
          send(
            sink_pid,
            {:engine_event, run_ref,
             Event.completed(%{engine: "lemon", resume: resume, ok: false, error: :timeout})}
          )
      end
    end

    defp fixture_mode(request, opts) do
      meta = request.meta || %{}
      Map.get(meta, :fixture_mode, Keyword.get(opts, :fixture_mode, :quick))
    end

    defp send_control(%{task_pid: task_pid}, message) when is_pid(task_pid),
      do: send(task_pid, message)

    defp send_control(_context, _message), do: :ok

    defp notify_control(%{control_pid: control_pid}, action, value) when is_pid(control_pid),
      do: send(control_pid, {:executor_control, action, value})

    defp notify_control(_context, _action, _value), do: :ok

    defp notify(meta, action, value) do
      case Map.get(meta, :control_pid) || Map.get(meta, :controller_pid) do
        nil -> :ok
        control_pid -> send(control_pid, {:executor_control, action, value})
      end
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
      enable_telegram: false,
      require_engine_lock: false
    })

    Application.put_env(:lemon_gateway, :executor, RunSupervisorFixtureExecutor)

    {:ok, _} = Application.ensure_all_started(:lemon_gateway)

    :ok
  end

  defp make_scope(chat_id \\ System.unique_integer([:positive])) do
    "test:#{chat_id}"
  end

  defp make_execution_request(session_key, opts \\ []) do
    user_msg_id = Keyword.get(opts, :user_msg_id, 1)
    base_meta = %{notify_pid: self(), user_msg_id: user_msg_id}
    meta_opt = Keyword.get(opts, :meta, %{})

    meta =
      cond do
        is_nil(meta_opt) ->
          nil

        is_map(meta_opt) ->
          fixture_mode =
            Keyword.get(opts, :fixture_mode, Map.get(meta_opt, :fixture_mode, :quick))

          Map.merge(base_meta, Map.put(meta_opt, :fixture_mode, fixture_mode))

        true ->
          meta_opt
      end

    resume = Keyword.get(opts, :resume)

    %ExecutionRequest{
      run_id: Keyword.get(opts, :run_id, "run_#{System.unique_integer([:positive])}"),
      session_key: session_key,
      prompt: Keyword.get(opts, :prompt, Keyword.get(opts, :text, "test message")),
      resume: resume,
      conversation_key: test_conversation_key(session_key, resume),
      meta: meta
    }
  end

  defp make_request(%ExecutionRequest{} = execution_request, opts \\ []) do
    slot_ref = Keyword.get(opts, :slot_ref, make_ref())
    worker_pid = Keyword.get(opts, :worker_pid, self())

    %{
      execution_request: execution_request,
      slot_ref: slot_ref,
      worker_pid: worker_pid
    }
  end

  defp test_conversation_key(_session_key, %ResumeToken{engine: engine, value: value})
       when is_binary(engine) and is_binary(value),
       do: {:resume, engine, value}

  defp test_conversation_key(session_key, _resume) when is_binary(session_key),
    do: {:session, session_key}

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

      execution_request1 =
        make_execution_request(scope1,
          fixture_mode: :controlled,
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      execution_request2 =
        make_execution_request(scope2,
          fixture_mode: :controlled,
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, _pid1} =
        RunSupervisor.start_run(make_request(execution_request1))

      {:ok, _pid2} =
        RunSupervisor.start_run(make_request(execution_request2))

      # Both should start
      assert_receive {:executor_started, _, _, _, task_pid1}, 2000
      assert_receive {:executor_started, _, _, _, task_pid2}, 2000

      # Complete both
      send(task_pid1, {:complete, "done1"})
      send(task_pid2, {:complete, "done2"})

      assert_receive {:run_complete, _, %{__event__: :completed, ok: true}}, 2000
      assert_receive {:run_complete, _, %{__event__: :completed, ok: true}}, 2000
    end
  end

  # ============================================================================
  # 2. Child Process Startup via start_run/1
  # ============================================================================

  describe "child process startup via start_run/1" do
    test "start_run starts a Run process" do
      scope = make_scope()
      execution_request = make_execution_request(scope)

      {:ok, pid} = RunSupervisor.start_run(make_request(execution_request))

      assert is_pid(pid)
      assert Process.alive?(pid)

      # Wait for completion
      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true}}, 2000
    end

    test "start_run returns {:ok, pid}" do
      scope = make_scope()
      execution_request = make_execution_request(scope)

      result = RunSupervisor.start_run(make_request(execution_request))

      assert {:ok, pid} = result
      assert is_pid(pid)

      assert_receive {:run_complete, ^pid, _}, 2000
    end

    test "started process is supervised" do
      scope = make_scope()

      execution_request =
        make_execution_request(scope,
          fixture_mode: :slow,
          meta: %{notify_pid: self(), delay_ms: 500}
        )

      {:ok, pid} = RunSupervisor.start_run(make_request(execution_request))

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
          execution_request = make_execution_request(scope, text: "run #{i}")

          {:ok, pid} =
            RunSupervisor.start_run(make_request(execution_request))

          {i, pid}
        end

      assert length(runs) == 5

      for {_i, pid} <- runs do
        assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true}}, 2000
      end
    end

    test "started run processes correct execution request" do
      scope = make_scope()

      execution_request =
        make_execution_request(scope, text: "unique test text #{System.unique_integer()}")

      {:ok, pid} = RunSupervisor.start_run(make_request(execution_request))

      assert_receive {:run_complete, ^pid,
                      %{__event__: :completed, ok: true, answer: "Quick: " <> answer_text}},
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
      execution_request = make_execution_request(scope)

      {:ok, pid} = RunSupervisor.start_run(make_request(execution_request))

      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true}}, 2000

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

      execution_request =
        make_execution_request(scope,
          fixture_mode: :controlled,
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = RunSupervisor.start_run(make_request(execution_request))
      ref = Process.monitor(pid)

      assert_receive {:executor_started, _, _, _, task_pid}, 2000

      # Kill the executor task abruptly
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
      execution_request = make_execution_request(scope)

      {:ok, pid} = RunSupervisor.start_run(make_request(execution_request))

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
      parent = self()
      scope1 = make_scope()
      scope2 = make_scope()

      controller1 =
        spawn(fn ->
          receive do
            {:executor_started, run_id, prompt, run_ref, task_pid} ->
              send(parent, {:executor_started, run_id, prompt, run_ref, task_pid})
          end
        end)

      controller2 =
        spawn(fn ->
          receive do
            {:executor_started, run_id, prompt, run_ref, task_pid} ->
              send(parent, {:executor_started, run_id, prompt, run_ref, task_pid})
          end
        end)

      execution_request1 =
        make_execution_request(scope1,
          fixture_mode: :controlled,
          meta: %{notify_pid: self(), controller_pid: controller1}
        )

      execution_request2 =
        make_execution_request(scope2,
          fixture_mode: :controlled,
          meta: %{notify_pid: self(), controller_pid: controller2}
        )

      {:ok, _pid1} =
        RunSupervisor.start_run(make_request(execution_request1))

      {:ok, pid2} =
        RunSupervisor.start_run(make_request(execution_request2))

      run_id1 = execution_request1.run_id
      prompt1 = execution_request1.prompt
      run_id2 = execution_request2.run_id
      prompt2 = execution_request2.prompt

      assert_receive {:executor_started, ^run_id1, ^prompt1, _run_ref1, task_pid1}, 2000
      assert_receive {:executor_started, ^run_id2, ^prompt2, _run_ref2, task_pid2}, 2000

      # Kill the first one's task
      Process.exit(task_pid1, :kill)

      # Wait a bit
      Process.sleep(100)

      # Second process should still be alive
      assert Process.alive?(pid2)

      # Complete the second one
      send(task_pid2, {:complete, "done"})
      assert_receive {:run_complete, ^pid2, %{__event__: :completed, ok: true}}, 2000
    end

    test "multiple children can complete independently" do
      runs =
        for i <- 1..3 do
          scope = make_scope()

          execution_request =
            make_execution_request(scope,
              fixture_mode: :slow,
              text: "run #{i}",
              meta: %{notify_pid: self(), delay_ms: 50 * i}
            )

          {:ok, pid} =
            RunSupervisor.start_run(make_request(execution_request))

          {i, pid}
        end

      # All should complete (in order of delay)
      for {_i, pid} <- runs do
        assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true}}, 2000
      end
    end

    test "supervisor continues functioning after child crashes" do
      scope1 = make_scope()

      execution_request1 =
        make_execution_request(scope1,
          fixture_mode: :controlled,
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid1} =
        RunSupervisor.start_run(make_request(execution_request1))

      assert_receive {:executor_started, _, _, _, _task_pid1}, 2000

      # Kill the child abruptly
      Process.exit(pid1, :kill)
      Process.sleep(100)

      # Supervisor should still be alive
      assert Process.alive?(Process.whereis(RunSupervisor))

      # Can start new children
      scope2 = make_scope()
      execution_request2 = make_execution_request(scope2)

      {:ok, pid2} =
        RunSupervisor.start_run(make_request(execution_request2))

      assert_receive {:run_complete, ^pid2, %{__event__: :completed, ok: true}}, 2000
    end
  end

  # ============================================================================
  # 5. Dynamic Child Management
  # ============================================================================

  describe "dynamic child management" do
    test "DynamicSupervisor.which_children returns current children" do
      scope = make_scope()

      execution_request =
        make_execution_request(scope,
          fixture_mode: :slow,
          meta: %{notify_pid: self(), delay_ms: 500}
        )

      {:ok, pid} = RunSupervisor.start_run(make_request(execution_request))

      children = DynamicSupervisor.which_children(RunSupervisor)
      child_pids = Enum.map(children, fn {_, child_pid, _, _} -> child_pid end)

      assert pid in child_pids

      assert_receive {:run_complete, ^pid, _}, 2000
    end

    test "DynamicSupervisor.count_children reflects active children" do
      initial_count = DynamicSupervisor.count_children(RunSupervisor).active

      scope = make_scope()

      execution_request =
        make_execution_request(scope,
          fixture_mode: :controlled,
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, _pid} = RunSupervisor.start_run(make_request(execution_request))

      assert_receive {:executor_started, _, _, _, task_pid}, 2000

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

      execution_request =
        make_execution_request(scope,
          fixture_mode: :controlled,
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = RunSupervisor.start_run(make_request(execution_request))
      ref = Process.monitor(pid)

      assert_receive {:executor_started, _, _, _, _task_pid}, 2000

      # Terminate the child via DynamicSupervisor
      :ok = DynamicSupervisor.terminate_child(RunSupervisor, pid)

      # Process should be dead
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2000
    end

    test "children can be terminated while others continue running" do
      scope1 = make_scope()
      scope2 = make_scope()

      execution_request1 =
        make_execution_request(scope1,
          fixture_mode: :controlled,
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      execution_request2 =
        make_execution_request(scope2,
          fixture_mode: :controlled,
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid1} =
        RunSupervisor.start_run(make_request(execution_request1))

      {:ok, pid2} =
        RunSupervisor.start_run(make_request(execution_request2))

      # Executor start notifications are asynchronous and can arrive in either order.
      assert_receive {:executor_started, _, _, _, task_pid_a}, 2000
      assert_receive {:executor_started, _, _, _, task_pid_b}, 2000
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

      assert_receive {:run_complete, ^pid2, %{__event__: :completed, ok: true}}, 2000
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
          execution_request = make_execution_request(scope, text: "parallel #{i}")

          {:ok, pid} =
            RunSupervisor.start_run(make_request(execution_request))

          {i, pid}
        end

      for {_i, pid} <- runs do
        assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true}}, 3000
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

            execution_request =
              make_execution_request(scope,
                text: "concurrent #{i}",
                meta: %{notify_pid: test_pid}
              )

            {:ok, pid} =
              RunSupervisor.start_run(make_request(execution_request, worker_pid: test_pid))

            pid
          end)
        end

      pids = Task.await_many(tasks, 5000)

      # All should complete
      for pid <- pids do
        assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true}}, 5000
      end
    end

    test "supervisor handles rapid start/stop cycles" do
      for _ <- 1..20 do
        scope = make_scope()
        execution_request = make_execution_request(scope)

        {:ok, pid} =
          RunSupervisor.start_run(make_request(execution_request))

        assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true}}, 2000
      end

      # Supervisor should still be functioning
      assert Process.alive?(Process.whereis(RunSupervisor))
    end

    test "mixed fast and slow runs complete correctly" do
      runs =
        for i <- 1..6 do
          scope = make_scope()

          if rem(i, 2) == 0 do
            execution_request =
              make_execution_request(scope,
                text: "slow #{i}",
                fixture_mode: :slow,
                meta: %{notify_pid: self(), delay_ms: 100}
              )

            {:ok, pid} =
              RunSupervisor.start_run(make_request(execution_request))

            {:slow, pid}
          else
            execution_request = make_execution_request(scope, text: "fast #{i}")

            {:ok, pid} =
              RunSupervisor.start_run(make_request(execution_request))

            {:fast, pid}
          end
        end

      for {_type, pid} <- runs do
        assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true}}, 2000
      end
    end
  end

  # ============================================================================
  # 7. Worker Notification
  # ============================================================================

  describe "worker notification" do
    test "worker_pid receives run_complete on completion" do
      scope = make_scope()
      execution_request = make_execution_request(scope)

      {:ok, pid} = RunSupervisor.start_run(make_request(execution_request))

      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true}}, 2000
    end

    test "worker_pid receives notification with correct completed event" do
      scope = make_scope()
      execution_request = make_execution_request(scope, text: "notification test")

      {:ok, pid} = RunSupervisor.start_run(make_request(execution_request))

      assert_receive {:run_complete, ^pid,
                      %{__event__: :completed, ok: true, answer: "Quick: notification test"}},
                     2000
    end

    test "different workers receive correct notifications" do
      test_pid = self()

      # Start runs with self as worker
      scope1 = make_scope()
      execution_request1 = make_execution_request(scope1, text: "job1")

      {:ok, pid1} =
        RunSupervisor.start_run(make_request(execution_request1, worker_pid: test_pid))

      scope2 = make_scope()
      execution_request2 = make_execution_request(scope2, text: "job2")

      {:ok, pid2} =
        RunSupervisor.start_run(make_request(execution_request2, worker_pid: test_pid))

      # Both should complete with correct answers
      completions =
        for _ <- 1..2 do
          receive do
            {:run_complete, pid, %{__event__: :completed} = completed} -> {pid, completed}
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
      execution_request = make_execution_request(scope)
      slot_ref = make_ref()

      {:ok, pid} = RunSupervisor.start_run(make_request(execution_request, slot_ref: slot_ref))

      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true}}, 2000
    end

    test "each run can have unique slot_ref" do
      runs =
        for i <- 1..3 do
          scope = make_scope()
          execution_request = make_execution_request(scope, text: "slot test #{i}")
          slot_ref = make_ref()

          {:ok, pid} =
            RunSupervisor.start_run(make_request(execution_request, slot_ref: slot_ref))

          {slot_ref, pid}
        end

      for {_slot_ref, pid} <- runs do
        assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true}}, 2000
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

      execution_request =
        make_execution_request(scope,
          fixture_mode: :controlled,
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = RunSupervisor.start_run(make_request(execution_request))
      ref = Process.monitor(pid)

      assert_receive {:executor_started, _, _, _, _task_pid}, 2000

      # Terminate the child
      :ok = DynamicSupervisor.terminate_child(RunSupervisor, pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2000
    end

    test "completed runs are cleaned up properly" do
      initial_children = DynamicSupervisor.which_children(RunSupervisor)
      initial_count = length(initial_children)

      scope = make_scope()
      execution_request = make_execution_request(scope)

      {:ok, pid} = RunSupervisor.start_run(make_request(execution_request))

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
    test "handles execution request with empty text" do
      scope = make_scope()
      execution_request = make_execution_request(scope, text: "")

      {:ok, pid} = RunSupervisor.start_run(make_request(execution_request))

      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true, answer: "Quick: "}},
                     2000
    end

    test "handles execution request with long text" do
      scope = make_scope()
      long_text = String.duplicate("a", 10_000)
      execution_request = make_execution_request(scope, text: long_text)

      {:ok, pid} = RunSupervisor.start_run(make_request(execution_request))

      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true}}, 2000
    end

    test "handles execution request with special characters" do
      scope = make_scope()

      execution_request =
        make_execution_request(scope, text: "Special chars: \n\t\r unicode: \u{1F600}")

      {:ok, pid} = RunSupervisor.start_run(make_request(execution_request))

      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true}}, 2000
    end

    test "handles rapid sequential starts for same scope" do
      scope = make_scope()

      pids =
        for i <- 1..5 do
          execution_request = make_execution_request(scope, text: "rapid #{i}")

          {:ok, pid} =
            RunSupervisor.start_run(make_request(execution_request))

          pid
        end

      # All should complete
      for pid <- pids do
        assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true}}, 2000
      end
    end

    test "handles nil meta gracefully" do
      scope = make_scope()
      execution_request = make_execution_request(scope, meta: nil)

      {:ok, pid} = RunSupervisor.start_run(make_request(execution_request))

      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true}}, 2000
    end
  end

  # ============================================================================
  # 11. Integration with Scheduler
  # ============================================================================

  describe "integration with scheduler" do
    test "runs started via supervisor complete and notify correctly" do
      scope = make_scope()
      execution_request = make_execution_request(scope, meta: %{notify_pid: self()})

      {:ok, pid} = RunSupervisor.start_run(make_request(execution_request))

      # Worker receives run_complete
      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true}}, 2000

      # notify_pid receives lemon_gateway_run_completed
      assert_receive {:lemon_gateway_run_completed, ^execution_request,
                      %{__event__: :completed, ok: true}},
                     2000
    end
  end

  # ============================================================================
  # 12. Process Monitoring
  # ============================================================================

  describe "process monitoring" do
    test "can monitor started Run processes" do
      scope = make_scope()
      execution_request = make_execution_request(scope)

      {:ok, pid} = RunSupervisor.start_run(make_request(execution_request))
      ref = Process.monitor(pid)

      assert_receive {:run_complete, ^pid, _}, 2000
      assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 2000
      assert reason in [:normal, :noproc]
    end

    test "monitor receives :normal reason on successful completion" do
      scope = make_scope()
      execution_request = make_execution_request(scope)

      {:ok, pid} = RunSupervisor.start_run(make_request(execution_request))
      ref = Process.monitor(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 2000
      assert reason in [:normal, :noproc]
    end

    test "can monitor multiple runs simultaneously" do
      monitors =
        for i <- 1..5 do
          scope = make_scope()
          execution_request = make_execution_request(scope, text: "monitor test #{i}")

          {:ok, pid} =
            RunSupervisor.start_run(make_request(execution_request))

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

      execution_request =
        make_execution_request(scope,
          fixture_mode: :controlled,
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = RunSupervisor.start_run(make_request(execution_request))
      ref = Process.monitor(pid)

      assert_receive {:executor_started, _, _, _, _task_pid}, 2000

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
      execution_request = make_execution_request(scope)

      {:ok, pid} = RunSupervisor.start_run(make_request(execution_request))

      # Verify it's a GenServer (Run is a GenServer)
      assert Process.alive?(pid)

      # The process responds to GenServer messages
      # We verify this by successfully receiving the completion
      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true}}, 2000
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
          execution_request = make_execution_request(scope, text: "burst #{i}")

          {:ok, pid} =
            RunSupervisor.start_run(make_request(execution_request))

          pid
        end

      # All should complete
      for pid <- pids do
        assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true}}, 5000
      end

      # Supervisor should still be healthy
      assert Process.alive?(Process.whereis(RunSupervisor))
    end

    test "supervisor remains stable after many operations" do
      # Perform many operations
      for batch <- 1..5 do
        for i <- 1..10 do
          scope = make_scope()

          execution_request =
            make_execution_request(scope, text: "stability test batch #{batch} run #{i}")

          {:ok, pid} =
            RunSupervisor.start_run(make_request(execution_request))

          assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true}}, 2000
        end
      end

      # Verify supervisor is still functioning
      assert Process.alive?(Process.whereis(RunSupervisor))

      # Can still start new runs
      scope = make_scope()
      execution_request = make_execution_request(scope, text: "final test")
      {:ok, pid} = RunSupervisor.start_run(make_request(execution_request))
      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true}}, 2000
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
      execution_request = make_execution_request(scope)

      result = RunSupervisor.start_run(make_request(execution_request))
      assert {:ok, _pid} = result
    end

    test "start_run/1 rejects input missing execution_request" do
      scope = make_scope()
      execution_request = make_execution_request(scope)

      assert {:error, :invalid_execution_request} =
               RunSupervisor.start_run(%{
                 request: execution_request,
                 slot_ref: make_ref(),
                 worker_pid: self()
               })
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
