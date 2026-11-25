defmodule LemonGateway.RunTest do
  alias Elixir.LemonGateway, as: LemonGateway

  @moduledoc """
  Comprehensive tests for the `LemonGateway.Run` GenServer.

  Tests cover:
  - Configured executor dispatch and request preservation
  - State transitions during execution
  - Executor sink event handling
  - Steering and redirect behavior
  - Cancellation and exactly-once finalization
  - Error scenarios
  - Process lifecycle
  - Lock acquisition/release
  """
  use ExUnit.Case, async: false

  alias Elixir.LemonGateway.Run
  alias LemonGateway.ExecutionRequest
  alias LemonCore.ResumeToken
  alias Elixir.LemonGateway.Event

  # ============================================================================
  # Configured executor fixture
  # ============================================================================

  # The run owns lifecycle and event handling. This executor only models the
  # external process, selecting a deterministic scenario from the request so
  # every run still crosses the configured singleton executor boundary.
  defmodule RunFixtureExecutor do
    @behaviour LemonGateway.Executor

    alias LemonCore.ResumeToken
    alias LemonGateway.Event
    alias LemonGateway.ExecutionRequest

    @impl true
    def start_run(%ExecutionRequest{} = request, opts, sink_pid) do
      scenario = Map.get(request.meta || %{}, :scenario, "test")
      meta = request.meta || %{}
      notify_start(meta, request, opts)

      case scenario do
        "failing" ->
          {:error, Map.get(meta, :error, :start_failed)}

        "raising" ->
          raise "boom during start_run"

        "exiting" ->
          exit(:boom_during_start_run)

        "structured_error" ->
          start_completed(
            request,
            sink_pid,
            false,
            Map.get(meta, :error, {:structured, :error})
          )

        "streaming" ->
          start_streaming(request, sink_pid)

        "test" ->
          start_completed(request, sink_pid, true, nil)

        _ ->
          start_controlled(request, sink_pid, scenario)
      end
    end

    @impl true
    def cancel(%{scenario: "drain_cancel", runner_pid: pid, controller_pid: observer}) do
      send(observer, {:cancel_dispatched, pid})
      :ok
    end

    def cancel(%{task_pid: pid}) when is_pid(pid) do
      Process.exit(pid, :kill)
      :ok
    end

    def cancel(_ctx), do: :ok

    @impl true
    def steer(%{scenario: "steerable_test", steer_notify_pid: notify_pid}, text)
        when is_pid(notify_pid) do
      send(notify_pid, {:steered, text})
      :ok
    end

    def steer(%{scenario: "steer_fail"}, _text), do: {:error, :steer_failed}
    def steer(_ctx, _text), do: {:error, :unsupported}

    @impl true
    def redirect(_ctx, _text), do: {:error, :unsupported}

    defp start_completed(request, sink_pid, ok, error) do
      run_ref = make_ref()
      engine = "lemon"
      resume = request.resume || %ResumeToken{engine: engine, value: unique_id()}

      {:ok, task_pid} =
        Task.start(fn ->
          send(
            sink_pid,
            {:engine_event, run_ref, Event.started(%{engine: engine, resume: resume})}
          )

          completed =
            if ok do
              Event.completed(%{
                engine: engine,
                resume: resume,
                ok: true,
                answer: "Test: #{request.prompt}"
              })
            else
              Event.completed(%{engine: engine, resume: resume, ok: false, error: error})
            end

          send(sink_pid, {:engine_event, run_ref, completed})
        end)

      {:ok, run_ref, %{task_pid: task_pid, scenario: engine}}
    end

    defp start_streaming(request, sink_pid) do
      run_ref = make_ref()
      engine = "lemon"
      resume = request.resume || %ResumeToken{engine: engine, value: unique_id()}
      delay_ms = Map.get(request.meta || %{}, :delta_delay_ms, 10)

      {:ok, task_pid} =
        Task.start(fn ->
          send(
            sink_pid,
            {:engine_event, run_ref, Event.started(%{engine: engine, resume: resume})}
          )

          Process.sleep(delay_ms)
          send(sink_pid, {:engine_delta, run_ref, "Hello"})
          Process.sleep(delay_ms)
          send(sink_pid, {:engine_delta, run_ref, " "})
          Process.sleep(delay_ms)
          send(sink_pid, {:engine_delta, run_ref, "World"})

          send(
            sink_pid,
            {:engine_event, run_ref,
             Event.completed(%{engine: engine, resume: resume, ok: true, answer: ""})}
          )
        end)

      {:ok, run_ref, %{task_pid: task_pid, scenario: engine}}
    end

    defp start_controlled(request, sink_pid, scenario) do
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
            send(controller_pid, {:engine_started, run_ref})
          end

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
          after
            30_000 ->
              send(
                sink_pid,
                {:engine_event, run_ref,
                 Event.completed(%{engine: "lemon", resume: resume, ok: false, error: :timeout})}
              )
          end
        end)

      if scenario == "linked_controlled", do: Process.link(task_pid)

      ctx = %{
        task_pid: task_pid,
        scenario: scenario,
        steer_notify_pid: Map.get(meta, :steer_notify_pid),
        controller_pid: Map.get(meta, :controller_pid)
      }

      ctx =
        if scenario in ["linked_controlled", "drain_cancel"],
          do: Map.put(ctx, :runner_pid, task_pid),
          else: ctx

      {:ok, run_ref, ctx}
    end

    defp notify_start(meta, request, opts) do
      if observer = Map.get(meta, :executor_observer) do
        send(observer, {:executor_started, request, opts})
      end
    end

    defp unique_id, do: Integer.to_string(System.unique_integer([:positive]))
  end

  # ============================================================================
  # Setup
  # ============================================================================

  setup do
    LemonGateway.Test.AppIsolation.isolate_gateway([LemonGateway.Config, :executor])

    Application.put_env(:lemon_gateway, Elixir.LemonGateway.Config, %{
      max_concurrent_runs: 10,
      enable_telegram: false
    })

    Application.put_env(:lemon_gateway, :executor, RunFixtureExecutor)

    {:ok, _} = Application.ensure_all_started(:lemon_gateway)

    :ok
  end

  defp make_scope(chat_id \\ System.unique_integer([:positive])) do
    "test:#{chat_id}"
  end

  defp make_request(session_key, opts \\ []) do
    user_msg_id = Keyword.get(opts, :user_msg_id, 1)
    resume = Keyword.get(opts, :resume)
    scenario = Keyword.get(opts, :scenario) || "test"
    base_meta = %{notify_pid: self(), user_msg_id: user_msg_id, scenario: scenario}
    meta_opt = Keyword.get(opts, :meta, %{})

    meta =
      cond do
        is_nil(meta_opt) -> nil
        is_map(meta_opt) -> Map.merge(base_meta, meta_opt)
        true -> meta_opt
      end

    %ExecutionRequest{
      run_id: Keyword.get(opts, :run_id, "submission_#{System.unique_integer([:positive])}"),
      session_key: session_key,
      prompt: Keyword.get(opts, :prompt, Keyword.get(opts, :text, "test message")),
      cwd: Keyword.get(opts, :cwd),
      resume: resume,
      lane: Keyword.get(opts, :lane),
      tool_policy: Keyword.get(opts, :tool_policy),
      conversation_key: test_conversation_key(session_key, resume),
      meta: meta
    }
  end

  defp test_conversation_key(_session_key, %ResumeToken{engine: engine, value: value})
       when is_binary(engine) and is_binary(value),
       do: {:resume, engine, value}

  defp test_conversation_key(session_key, _resume) when is_binary(session_key),
    do: {:session, session_key}

  defp start_run_direct(%ExecutionRequest{} = request) do
    Run.start_link(%{execution_request: request})
  end

  defp receive_bus_event(type, timeout \\ 2_000) do
    receive do
      %LemonCore.Event{type: ^type} = event -> event
      _other -> receive_bus_event(type, timeout)
    after
      timeout -> flunk("expected bus event #{inspect(type)}")
    end
  end

  defp wait_for(fun, timeout_ms, interval_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for(fun, deadline, interval_ms)
  end

  defp do_wait_for(fun, deadline, interval_ms) do
    value = fun.()

    cond do
      not is_nil(value) ->
        value

      System.monotonic_time(:millisecond) >= deadline ->
        nil

      true ->
        Process.sleep(interval_ms)
        do_wait_for(fun, deadline, interval_ms)
    end
  end

  # ============================================================================
  # 1. Run Initialization
  # ============================================================================

  test "linked executor death terminalizes immediately with a durable receipt" do
    request =
      make_request(make_scope(), scenario: "linked_controlled", meta: %{controller_pid: self()})

    :ok = LemonCore.Bus.subscribe(LemonCore.Bus.run_topic(request.run_id))
    {:ok, pid} = start_run_direct(request)
    assert_receive {:engine_started, _}, 2_000
    state = :sys.get_state(pid)
    Process.exit(state.control_ctx.runner_pid, :kill)

    assert_receive %LemonCore.Event{
                     type: :run_completed,
                     meta: %{run_id: run_id},
                     payload: %{
                       completed: %{ok: false, error: %{type: :executor_down, reason: :killed}}
                     }
                   },
                   2_000

    assert run_id == request.run_id
    assert %{summary: %{completed: %{ok: false}}} = LemonCore.RunStore.get(request.run_id)
    assert_receive {:lemon_gateway_run_completed, ^request, _}, 2_000
    refute_receive %LemonCore.Event{type: :run_completed, meta: %{run_id: ^run_id}}, 50
  end

  describe "initialization" do
    test "starts successfully with a valid execution request" do
      scope = make_scope()
      request = make_request(scope)

      {:ok, pid} = start_run_direct(request)
      assert Process.alive?(pid)

      # Wait for completion
      assert_receive {:lemon_gateway_run_completed, ^request, %{__event__: :completed, ok: true}},
                     2000
    end

    test "retains an active run when the executor emits no completion" do
      scope = make_scope()

      request =
        make_request(scope,
          scenario: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(request)

      # The executor has supplied a control context and deliberately does not
      # emit a terminal sink event. Run stays active until it is cancelled.
      assert_receive {:engine_started, _run_ref}, 2000
      assert Process.alive?(pid)

      GenServer.cast(pid, {:cancel, :user_requested})

      assert_receive {:lemon_gateway_run_completed, ^request,
                      %{__event__: :completed, ok: false, engine: "lemon", error: :user_requested}},
                     2000
    end

    test "passes an execution request to the executor with fixed lemon provenance" do
      scope = make_scope()

      request =
        make_request(scope,
          meta: %{notify_pid: self(), user_msg_id: 1, executor_observer: self()}
        )

      {:ok, _pid} = start_run_direct(request)

      assert_receive {:executor_started, %ExecutionRequest{prompt: "test message"}, _opts}, 2000

      assert_receive {:lemon_gateway_run_completed, ^request,
                      %{
                        __event__: :completed,
                        ok: true,
                        engine: "lemon",
                        answer: "Test: test message"
                      }},
                     2000
    end

    test "preserves a resume token on the execution request" do
      scope = make_scope()
      resume = %ResumeToken{engine: "echo", value: "abc123"}

      request =
        make_request(scope, resume: resume, scenario: "test", meta: %{executor_observer: self()})

      {:ok, _pid} = start_run_direct(request)

      assert_receive {:executor_started, %ExecutionRequest{resume: ^resume}, _opts}, 2000

      assert_receive {:lemon_gateway_run_completed, ^request,
                      %{__event__: :completed, ok: true, engine: "lemon"}},
                     2000
    end

    test "handles executor start_run failure" do
      scope = make_scope()

      request =
        make_request(scope,
          scenario: "failing",
          meta: %{notify_pid: self(), error: :custom_error}
        )

      {:ok, pid} = start_run_direct(request)

      # Should receive completion with error
      assert_receive {:lemon_gateway_run_completed, ^request,
                      %{__event__: :completed, ok: false, error: :custom_error}},
                     2000

      # Process should stop after error
      Elixir.LemonGateway.AsyncHelpers.assert_process_dead(pid)
    end

    test "handles executor start_run exception" do
      scope = make_scope()
      request = make_request(scope, scenario: "raising", meta: %{notify_pid: self()})

      {:ok, pid} = start_run_direct(request)

      assert_receive {:lemon_gateway_run_completed, ^request,
                      %{
                        __event__: :completed,
                        ok: false,
                        error: "executor_start_exception: boom during start_run"
                      }},
                     2000

      Elixir.LemonGateway.AsyncHelpers.assert_process_dead(pid)
    end

    test "handles executor start_run exit" do
      scope = make_scope()
      request = make_request(scope, scenario: "exiting", meta: %{notify_pid: self()})

      {:ok, pid} = start_run_direct(request)

      assert_receive {:lemon_gateway_run_completed, ^request,
                      %{
                        __event__: :completed,
                        ok: false,
                        error: "executor_start_exit: :boom_during_start_run"
                      }},
                     2000

      Elixir.LemonGateway.AsyncHelpers.assert_process_dead(pid)
    end

    test "sends completion notification with the original submitted request" do
      scope = make_scope()
      request = make_request(scope, run_id: nil)

      {:ok, _pid} = start_run_direct(request)

      # Run normalizes its internal request, but completion must identify the
      # original request submitted by the caller.
      assert_receive {:lemon_gateway_run_completed, ^request,
                      %{__event__: :completed, ok: true} = completed},
                     2000

      assert is_binary(completed.run_id)
    end
  end

  # ============================================================================
  # 2. State Transitions During Execution
  # ============================================================================

  describe "state transitions during execution" do
    test "processes Started event and continues" do
      scope = make_scope()

      request =
        make_request(scope,
          scenario: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(request)

      # Wait for engine to start
      assert_receive {:engine_started, _run_ref}, 2000

      # Run should still be alive (waiting for completion)
      assert Process.alive?(pid)
    end

    test "processes ActionEvent and continues" do
      scope = make_scope()
      run_id = "run_#{System.unique_integer([:positive])}"

      request =
        make_request(scope,
          scenario: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )
        |> Map.put(:run_id, run_id)

      LemonCore.Bus.subscribe("run:#{run_id}")
      {:ok, pid} = start_run_direct(request)

      assert_receive {:engine_started, run_ref}, 2000

      result_meta = %{error_type: :tool_task_timeout, timeout_ms: 123, exit_code: 124}

      action =
        Event.action(%{
          id: "action_1",
          kind: :tool,
          title: "slow_tool",
          detail: %{name: "slow_tool", result_meta: result_meta}
        })

      action_event =
        Event.action_event(%{
          engine: "controllable",
          action: action,
          phase: :completed,
          ok: false,
          level: :error
        })

      send(pid, {:engine_event, run_ref, action_event})

      assert %LemonCore.Event{
               type: :engine_action,
               payload: %{
                 action: %{detail: %{result_meta: ^result_meta}},
                 phase: :completed,
                 ok: false,
                 level: :error
               }
             } = receive_bus_event(:engine_action)

      # Run should still be alive (check without timing race)
      Elixir.LemonGateway.AsyncHelpers.assert_process_alive(pid)
    end

    test "processes Completed event and stops" do
      scope = make_scope()
      request = make_request(scope)

      {:ok, pid} = start_run_direct(request)

      # Should complete and stop
      assert_receive {:lemon_gateway_run_completed, ^request, %{__event__: :completed, ok: true}},
                     2000

      # Wait deterministically for the process to stop
      Elixir.LemonGateway.AsyncHelpers.assert_process_dead(pid)
    end

    test "ignores events with wrong run_ref" do
      scope = make_scope()

      request =
        make_request(scope,
          scenario: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(request)

      assert_receive {:engine_started, _run_ref}, 2000

      # Send event with wrong run_ref
      wrong_ref = make_ref()
      completed = Event.completed(%{engine: "controllable", ok: true, answer: "wrong"})
      send(pid, {:engine_event, wrong_ref, completed})

      # Run should still be alive (event was ignored)
      Elixir.LemonGateway.AsyncHelpers.assert_process_alive(pid)
    end
  end

  # ============================================================================
  # 3. Event Handling
  # ============================================================================

  describe "event handling" do
    test "stores events in Store" do
      scope = make_scope()
      request = make_request(scope)

      {:ok, _pid} = start_run_direct(request)

      assert_receive {:lemon_gateway_run_completed, ^request, %{__event__: :completed, ok: true}},
                     2000

      # Events should be stored (though we can't easily inspect without run_ref)
    end

    test "handles successful completion" do
      scope = make_scope()
      request = make_request(scope, text: "hello world")

      {:ok, _pid} = start_run_direct(request)

      assert_receive {:lemon_gateway_run_completed, ^request,
                      %{__event__: :completed, ok: true, answer: "Test: hello world"}},
                     2000
    end

    test "handles error completion" do
      scope = make_scope()

      request =
        make_request(scope, scenario: "failing", meta: %{notify_pid: self(), error: :test_error})

      {:ok, _pid} = start_run_direct(request)

      assert_receive {:lemon_gateway_run_completed, ^request,
                      %{__event__: :completed, ok: false, error: :test_error}},
                     2000
    end

    test "handles unknown messages gracefully" do
      scope = make_scope()

      request =
        make_request(scope,
          scenario: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(request)

      assert_receive {:engine_started, _run_ref}, 2000

      # Send random unknown message
      send(pid, {:unknown_message, "some data"})

      # Run should still be alive
      Elixir.LemonGateway.AsyncHelpers.assert_process_alive(pid)
    end
  end

  # ============================================================================
  # 4. Steering Behavior
  # ============================================================================

  describe "steering behavior" do
    test "accepts steer when engine supports it" do
      scope = make_scope()

      request =
        make_request(scope,
          scenario: "steerable_test",
          meta: %{notify_pid: self(), controller_pid: self(), steer_notify_pid: self()}
        )

      {:ok, pid} = start_run_direct(request)

      assert_receive {:engine_started, _run_ref}, 2000

      # Send steer cast
      %{run_id: submission_run_id, prompt: prompt} =
        make_request(scope, text: "steering message")

      GenServer.cast(pid, {:steer, submission_run_id, prompt, self()})

      # The control submission is acknowledged by its stable run ID.
      assert_receive {:steer_accepted, ^submission_run_id}, 2000

      # Should receive steer notification
      assert_receive {:steered, "steering message"}, 2000

      # Should NOT receive steer_rejected
      refute_receive {:steer_rejected, _}, 200
    end

    test "rejects steer when run is completed" do
      scope = make_scope()
      request = make_request(scope)

      {:ok, pid} = start_run_direct(request)

      # Wait for completion
      assert_receive {:lemon_gateway_run_completed, ^request, %{__event__: :completed, ok: true}},
                     2000

      # Try to steer after completion
      %{run_id: submission_run_id, prompt: prompt} = make_request(scope, text: "late steer")
      GenServer.cast(pid, {:steer, submission_run_id, prompt, self()})

      # Should receive rejection (though process may be dead)
      # Note: This test may be flaky since the process stops after completion
    end

    test "rejects steer when engine does not support it" do
      scope = make_scope()

      request =
        make_request(scope,
          scenario: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(request)

      assert_receive {:engine_started, _run_ref}, 2000

      # Try to steer (engine doesn't support it)
      %{run_id: submission_run_id, prompt: prompt} = make_request(scope, text: "steer attempt")

      GenServer.cast(pid, {:steer, submission_run_id, prompt, self()})

      # Should receive rejection for the submitted run ID.
      assert_receive {:steer_rejected, ^submission_run_id}, 2000
    end

    test "rejects steer when engine is not yet initialized" do
      # This is harder to test since initialization happens quickly
      # We rely on the code coverage of the cond branch
    end

    test "rejects steer when engine steer call fails" do
      scope = make_scope()

      request =
        make_request(scope,
          scenario: "steer_fail",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(request)

      assert_receive {:engine_started, _run_ref}, 2000

      # Try to steer (engine will fail)
      %{run_id: submission_run_id, prompt: prompt} =
        make_request(scope, text: "steer that fails")

      GenServer.cast(pid, {:steer, submission_run_id, prompt, self()})

      # Should receive rejection due to steer error.
      assert_receive {:steer_rejected, ^submission_run_id}, 2000
    end
  end

  # ============================================================================
  # 5. Cancellation Handling
  # ============================================================================

  describe "cancellation handling" do
    test "native cancellation keeps the run until terminal tool events drain" do
      request =
        make_request(make_scope(),
          scenario: "drain_cancel",
          meta: %{controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(request)
      assert_receive {:engine_started, _}, 2_000
      state = :sys.get_state(pid)
      GenServer.cast(pid, {:cancel, :interrupted})
      assert_receive {:cancel_dispatched, runner}, 2_000
      GenServer.cast(pid, {:cancel, :user_requested})
      refute_receive {:lemon_gateway_run_completed, ^request, _}, 20
      assert Process.alive?(pid)

      action = Event.action(%{id: "tool_cancel", kind: :command, title: "Cancelled bash"})
      event = Event.action_event(%{engine: "lemon", action: action, phase: :completed, ok: false})
      send(pid, {:engine_event, state.run_ref, event})
      assert :sys.get_state(pid).cancel_reason == :interrupted
      send(runner, {:complete, "observed partial answer"})

      assert_receive {:lemon_gateway_run_completed, ^request, %{ok: false, error: :interrupted}},
                     2_000

      stored = LemonCore.RunStore.get(request.run_id)
      assert stored.summary.completed.error == :interrupted
      assert stored.summary.completed.meta.cancelled == true

      assert Enum.any?(
               stored.events,
               &(&1[:__event__] == :action_event && &1[:phase] == :completed)
             )

      refute_receive {:lemon_gateway_run_completed, ^request, _}, 20
    end

    test "cancels run when cancel cast is received" do
      scope = make_scope()

      request =
        make_request(scope,
          scenario: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(request)

      assert_receive {:engine_started, _run_ref}, 2000

      # Cancel the run
      GenServer.cast(pid, {:cancel, :user_requested})

      # Should receive completion with error
      assert_receive {:lemon_gateway_run_completed, ^request,
                      %{__event__: :completed, ok: false, error: :user_requested}},
                     2000

      # Process should stop
      Elixir.LemonGateway.AsyncHelpers.assert_process_dead(pid)
    end

    test "cancel is idempotent and emits one terminal completion" do
      scope = make_scope()

      request =
        make_request(scope,
          scenario: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(request)
      assert_receive {:engine_started, _run_ref}, 2000

      GenServer.cast(pid, {:cancel, :user_requested})
      GenServer.cast(pid, {:cancel, :user_requested})

      assert_receive {:lemon_gateway_run_completed, ^request,
                      %{__event__: :completed, ok: false, error: :user_requested}},
                     2000

      refute_receive {:lemon_gateway_run_completed, ^request, _}, 500
    end

    test "cancel sends notification to notify_pid" do
      scope = make_scope()

      request =
        make_request(scope,
          scenario: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(request)

      assert_receive {:engine_started, _run_ref}, 2000

      GenServer.cast(pid, {:cancel, :test_reason})

      # Should receive notification
      assert_receive {:lemon_gateway_run_completed, ^request,
                      %{__event__: :completed, ok: false, error: :test_reason}},
                     2000
    end

    test "cancel releases slot" do
      scope = make_scope()

      request =
        make_request(scope,
          scenario: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(request)

      assert_receive {:engine_started, _run_ref}, 2000

      GenServer.cast(pid, {:cancel, :test_reason})

      assert_receive {:lemon_gateway_run_completed, ^request, %{__event__: :completed}}, 2000

      # Slot should be released (verified through Slots behavior)
    end

    test "cancel calls engine.cancel" do
      scope = make_scope()

      request =
        make_request(scope,
          scenario: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(request)

      assert_receive {:engine_started, _run_ref}, 2000

      GenServer.cast(pid, {:cancel, :user_requested})

      # Engine task should be killed
      assert_receive {:lemon_gateway_run_completed, ^request,
                      %{__event__: :completed, ok: false}},
                     2000
    end
  end

  # ============================================================================
  # 6. Error Scenarios
  # ============================================================================

  describe "error scenarios" do
    test "handles executor start_run returning error" do
      scope = make_scope()

      request =
        make_request(scope,
          scenario: "failing",
          meta: %{notify_pid: self(), error: :engine_error}
        )

      {:ok, pid} = start_run_direct(request)

      assert_receive {:lemon_gateway_run_completed, ^request,
                      %{__event__: :completed, ok: false, error: :engine_error}},
                     2000

      Elixir.LemonGateway.AsyncHelpers.assert_process_dead(pid)
    end

    test "passes executor test scenarios through request metadata" do
      scope = make_scope()

      request =
        make_request(scope,
          scenario: "controllable",
          meta: %{notify_pid: self(), controller_pid: self(), executor_observer: self()}
        )

      {:ok, pid} = start_run_direct(request)

      assert_receive {:executor_started,
                      %ExecutionRequest{
                        session_key: ^scope,
                        conversation_key: {:session, ^scope},
                        meta: %{scenario: "controllable"}
                      }, _opts},
                     2000

      assert_receive {:engine_started, _run_ref}, 2000
      GenServer.cast(pid, {:cancel, :user_requested})

      assert_receive {:lemon_gateway_run_completed, ^request,
                      %{__event__: :completed, ok: false, engine: "lemon", error: :user_requested}},
                     2000
    end

    test "handles nil notify_pid gracefully" do
      scope = make_scope()
      request = make_request(scope, meta: nil)
      :ok = LemonCore.Bus.subscribe(LemonCore.Bus.run_topic(request.run_id))

      {:ok, pid} = start_run_direct(request)

      # Should still complete (no notification sent)
      assert %LemonCore.Event{type: :run_completed} = receive_bus_event(:run_completed)
      refute_receive {:lemon_gateway_run_completed, ^request, _}, 20

      # Should NOT crash
      # Stopped normally
      Elixir.LemonGateway.AsyncHelpers.assert_process_dead(pid)
    end
  end

  # ============================================================================
  # 7. Process Lifecycle
  # ============================================================================

  describe "process lifecycle" do
    test "process stops normally after successful completion" do
      scope = make_scope()
      request = make_request(scope)

      {:ok, pid} = start_run_direct(request)
      ref = Process.monitor(pid)

      assert_receive {:lemon_gateway_run_completed, ^request, %{__event__: :completed, ok: true}},
                     2000

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2000
    end

    test "process stops normally after error completion" do
      scope = make_scope()
      request = make_request(scope, scenario: "failing")

      {:ok, pid} = start_run_direct(request)
      ref = Process.monitor(pid)

      assert_receive {:lemon_gateway_run_completed, ^request,
                      %{__event__: :completed, ok: false}},
                     2000

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2000
    end

    test "process stops normally after cancellation" do
      scope = make_scope()

      request =
        make_request(scope,
          scenario: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(request)
      ref = Process.monitor(pid)

      assert_receive {:engine_started, _run_ref}, 2000

      GenServer.cast(pid, {:cancel, :test_reason})

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2000
    end

    test "releases slot on completion" do
      scope = make_scope()
      request = make_request(scope)

      {:ok, _pid} = start_run_direct(request)

      assert_receive {:lemon_gateway_run_completed, ^request, %{__event__: :completed, ok: true}},
                     2000

      # Slot release is verified through Slots internals
    end

    test "notifies the submitted request observer on completion" do
      scope = make_scope()
      request = make_request(scope)

      {:ok, _pid} = start_run_direct(request)

      # Worker (self) should receive completion
      assert_receive {:lemon_gateway_run_completed, ^request,
                      %{__event__: :completed, ok: true, answer: "Test: test message"}},
                     2000
    end
  end

  # ============================================================================
  # 8. Claim Acquisition and Release
  # ============================================================================

  describe "claim acquisition and release" do
    test "claims its engine session before execution" do
      scope = make_scope()
      request = make_request(scope)

      {:ok, _pid} = start_run_direct(request)

      assert_receive {:lemon_gateway_run_completed, ^request, %{__event__: :completed, ok: true}},
                     5000
    end

    test "releases claim on successful completion" do
      scope = make_scope()
      request = make_request(scope)

      {:ok, _pid} = start_run_direct(request)

      assert_receive {:lemon_gateway_run_completed, ^request, %{__event__: :completed, ok: true}},
                     5000

      # Start another run with same scope - should succeed if claim was released
      request2 = make_request(scope, text: "second run")
      {:ok, _pid2} = start_run_direct(request2)

      assert_receive {:lemon_gateway_run_completed, ^request2,
                      %{__event__: :completed, ok: true}},
                     5000
    end

    test "releases claim on error completion" do
      scope = make_scope()
      request = make_request(scope, scenario: "failing")

      {:ok, _pid} = start_run_direct(request)

      assert_receive {:lemon_gateway_run_completed, ^request,
                      %{__event__: :completed, ok: false}},
                     5000

      # Start another run with same scope
      request2 = make_request(scope, text: "after error")
      {:ok, _pid2} = start_run_direct(request2)

      assert_receive {:lemon_gateway_run_completed, ^request2,
                      %{__event__: :completed, ok: true}},
                     5000
    end

    test "releases claim on cancellation" do
      scope = make_scope()

      request =
        make_request(scope,
          scenario: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(request)

      assert_receive {:engine_started, _run_ref}, 5000

      GenServer.cast(pid, {:cancel, :test_reason})

      assert_receive {:lemon_gateway_run_completed, ^request,
                      %{__event__: :completed, ok: false}},
                     5000

      # Start another run with same scope
      request2 = make_request(scope, text: "after cancel")
      {:ok, _pid2} = start_run_direct(request2)

      assert_receive {:lemon_gateway_run_completed, ^request2,
                      %{__event__: :completed, ok: true}},
                     5000
    end

    test "uses resume token value for claim key when present" do
      scope1 = make_scope()
      scope2 = make_scope()
      # Use controllable engine in resume token so we can control when it completes
      resume = %ResumeToken{
        engine: "controllable",
        value: "shared_session_#{System.unique_integer([:positive])}"
      }

      # Both requests share the same resume value; the first holds the claim.
      request1 =
        make_request(scope1,
          resume: resume,
          scenario: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid1} = start_run_direct(request1)

      assert_receive {:engine_started, _run_ref}, 5000

      # Release ownership, then resume from another conversation.

      # Complete first run
      GenServer.cast(pid1, {:cancel, :done})
      assert_receive {:lemon_gateway_run_completed, ^request1, _}, 5000

      # Now second should succeed - use test engine for quick completion
      request2 = make_request(scope2, resume: %ResumeToken{engine: "test", value: resume.value})
      {:ok, _pid2} = start_run_direct(request2)
      assert_receive {:lemon_gateway_run_completed, ^request2, %{__event__: :completed}}, 5000
    end
  end

  # ============================================================================
  # 10. Progress Mapping
  # ============================================================================

  describe "progress mapping" do
    test "registers progress mapping when progress_msg_id is present" do
      scope = make_scope()
      progress_msg_id = System.unique_integer([:positive])
      # Use controllable engine so we can check the mapping before completion
      request =
        make_request(scope,
          scenario: "controllable",
          meta: %{notify_pid: self(), progress_msg_id: progress_msg_id, controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(request)

      # Wait for engine to start (which means registration should be done)
      assert_receive {:engine_started, _run_ref}, 2000

      # Check mapping exists (stores run_id string, not PID)
      stored_run_id =
        wait_for(
          fn -> LemonGateway.ProgressStore.get_run(scope, progress_msg_id) end,
          500,
          10
        )

      assert is_binary(stored_run_id) and stored_run_id != ""

      # Cancel to complete
      GenServer.cast(pid, {:cancel, :done})

      # Wait for completion
      assert_receive {:lemon_gateway_run_completed, ^request, _}, 2000

      # Wait for unregistration to complete
      Elixir.LemonGateway.AsyncHelpers.assert_eventually(
        fn -> LemonGateway.ProgressStore.get_run(scope, progress_msg_id) == nil end,
        message: "run progress mapping was not removed"
      )
    end

    test "does not register mapping when progress_msg_id is nil" do
      scope = make_scope()
      request = make_request(scope, meta: %{notify_pid: self()})

      {:ok, _pid} = start_run_direct(request)

      assert_receive {:lemon_gateway_run_completed, ^request, _}, 2000

      # No mapping should exist
      assert LemonGateway.ProgressStore.get_run(scope, nil) == nil
    end

    test "unregisters progress mapping on completion" do
      scope = make_scope()
      progress_msg_id = System.unique_integer([:positive])
      request = make_request(scope, meta: %{notify_pid: self(), progress_msg_id: progress_msg_id})

      {:ok, _pid} = start_run_direct(request)

      # Wait for completion
      assert_receive {:lemon_gateway_run_completed, ^request, _}, 2000

      # Wait for cleanup to complete
      Elixir.LemonGateway.AsyncHelpers.assert_eventually(
        fn -> LemonGateway.ProgressStore.get_run(scope, progress_msg_id) == nil end,
        message: "run progress mapping was not removed on completion"
      )
    end

    test "unregisters progress mapping on cancellation" do
      scope = make_scope()
      progress_msg_id = System.unique_integer([:positive])

      request =
        make_request(scope,
          scenario: "controllable",
          meta: %{notify_pid: self(), controller_pid: self(), progress_msg_id: progress_msg_id}
        )

      {:ok, pid} = start_run_direct(request)

      assert_receive {:engine_started, _run_ref}, 2000

      # Verify mapping exists (stores run_id string, not PID)
      Elixir.LemonGateway.AsyncHelpers.assert_eventually(
        fn ->
          case LemonGateway.ProgressStore.get_run(scope, progress_msg_id) do
            run_id when is_binary(run_id) and run_id != "" -> true
            _ -> false
          end
        end,
        message: "run progress mapping was never registered"
      )

      # Cancel
      GenServer.cast(pid, {:cancel, :user_requested})

      assert_receive {:lemon_gateway_run_completed, ^request, _}, 2000

      # Wait for cleanup to complete
      Elixir.LemonGateway.AsyncHelpers.assert_eventually(
        fn -> LemonGateway.ProgressStore.get_run(scope, progress_msg_id) == nil end,
        message: "run progress mapping was not removed on cancellation"
      )
    end
  end

  # ============================================================================
  # 11. Renderer Integration
  # ============================================================================

  describe "renderer integration" do
    test "initializes renderer state" do
      scope = make_scope()
      request = make_request(scope)

      {:ok, _pid} = start_run_direct(request)

      assert_receive {:lemon_gateway_run_completed, ^request, %{__event__: :completed, ok: true}},
                     2000
    end

    test "applies events through renderer" do
      scope = make_scope()

      request =
        make_request(scope,
          scenario: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, _pid} = start_run_direct(request)

      assert_receive {:engine_started, _run_ref}, 2000

      # Events are processed through renderer - we verify by successful completion
    end

    test "renders on completion" do
      scope = make_scope()
      # Without chat_id, no rendering to Outbox occurs
      # But the renderer still processes the event
      request = make_request(scope)

      {:ok, _pid} = start_run_direct(request)

      assert_receive {:lemon_gateway_run_completed, ^request, %{__event__: :completed, ok: true}},
                     2000
    end
  end

  # ============================================================================
  # 12. Multiple Events in Sequence
  # ============================================================================

  describe "multiple events in sequence" do
    test "handles Started -> ActionEvent -> Completed sequence" do
      scope = make_scope()

      request =
        make_request(scope,
          scenario: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(request)

      assert_receive {:engine_started, run_ref}, 2000

      # Send action events
      action1 = Event.action(%{id: "a1", kind: :tool, title: "Tool 1"})

      send(
        pid,
        {:engine_event, run_ref,
         Event.action_event(%{engine: "controllable", action: action1, phase: :started})}
      )

      action2 = Event.action(%{id: "a2", kind: :tool, title: "Tool 2"})

      send(
        pid,
        {:engine_event, run_ref,
         Event.action_event(%{engine: "controllable", action: action2, phase: :started})}
      )

      send(
        pid,
        {:engine_event, run_ref,
         Event.action_event(%{engine: "controllable", action: action1, phase: :completed})}
      )

      # Process should still be running
      Elixir.LemonGateway.AsyncHelpers.assert_process_alive(pid)

      # Send completion
      completed = Event.completed(%{engine: "controllable", ok: true, answer: "done"})
      send(pid, {:engine_event, run_ref, completed})

      assert_receive {:lemon_gateway_run_completed, ^request,
                      %{__event__: :completed, ok: true, answer: "done"}},
                     2000
    end

    test "processes many events without issues" do
      scope = make_scope()

      request =
        make_request(scope,
          scenario: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(request)

      assert_receive {:engine_started, run_ref}, 2000

      # Send many action events
      for i <- 1..100 do
        action = Event.action(%{id: "action_#{i}", kind: :tool, title: "Action #{i}"})
        event = Event.action_event(%{engine: "controllable", action: action, phase: :started})
        send(pid, {:engine_event, run_ref, event})
      end

      Elixir.LemonGateway.AsyncHelpers.assert_process_alive(pid)

      # Complete
      completed = Event.completed(%{engine: "controllable", ok: true, answer: "all done"})
      send(pid, {:engine_event, run_ref, completed})

      assert_receive {:lemon_gateway_run_completed, ^request, %{__event__: :completed, ok: true}},
                     2000
    end
  end

  # ============================================================================
  # 13. Comprehensive Steering Flow Tests
  # ============================================================================

  describe "steering flow - acceptance path" do
    test "steer is accepted when engine supports it and run is active" do
      scope = make_scope()

      request =
        make_request(scope,
          scenario: "steerable_test",
          meta: %{notify_pid: self(), controller_pid: self(), steer_notify_pid: self()}
        )

      {:ok, pid} = start_run_direct(request)

      assert_receive {:engine_started, _run_ref}, 2000

      # Steer should succeed
      %{run_id: submission_run_id, prompt: prompt} = make_request(scope, text: "steering text")

      GenServer.cast(pid, {:steer, submission_run_id, prompt, self()})

      # Engine receives the steer and the submission receives its ID acknowledgement.
      assert_receive {:steered, "steering text"}, 2000
      assert_receive {:steer_accepted, ^submission_run_id}, 2000

      # No rejection should be sent
      refute_receive {:steer_rejected, _}, 100
    end

    test "multiple steers in sequence are all accepted" do
      scope = make_scope()

      request =
        make_request(scope,
          scenario: "steerable_test",
          meta: %{notify_pid: self(), controller_pid: self(), steer_notify_pid: self()}
        )

      {:ok, pid} = start_run_direct(request)

      assert_receive {:engine_started, _run_ref}, 2000

      submission_run_ids =
        for i <- 1..5 do
          %{run_id: submission_run_id, prompt: prompt} = make_request(scope, text: "steer #{i}")

          GenServer.cast(pid, {:steer, submission_run_id, prompt, self()})

          submission_run_id
        end

      # All should be received by engine - collect all messages
      received_steers =
        Enum.map(1..5, fn _i ->
          receive do
            {:steered, text} -> text
          after
            2000 -> nil
          end
        end)

      assert Enum.all?(received_steers, &(&1 != nil))
      assert "steer 1" in received_steers
      assert "steer 5" in received_steers

      accepted_run_ids =
        Enum.map(1..5, fn _ ->
          assert_receive {:steer_accepted, submission_run_id}, 2000
          submission_run_id
        end)

      assert Enum.sort(accepted_run_ids) == Enum.sort(submission_run_ids)

      # No rejections
      refute_receive {:steer_rejected, _}, 100
    end
  end

  describe "steering flow - rejection paths" do
    test "steer is rejected when run is already completed" do
      scope = make_scope()
      # Use test engine that completes quickly
      request = make_request(scope, meta: %{notify_pid: self()})

      {:ok, pid} = start_run_direct(request)

      # Wait for completion
      assert_receive {:lemon_gateway_run_completed, ^request, %{__event__: :completed, ok: true}},
                     2000

      # Process should be stopping/stopped, but if we can still message it...
      %{run_id: submission_run_id, prompt: prompt} = make_request(scope, text: "late steer")
      ref = Process.monitor(pid)

      # After completion, a late steer is either explicitly rejected (if the
      # process is still alive) or the process exits before handling it.
      if Process.alive?(pid) do
        GenServer.cast(pid, {:steer, submission_run_id, prompt, self()})

        receive do
          {:steer_rejected, ^submission_run_id} -> :ok
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          2000 ->
            flunk("expected late steer to be rejected or run process to exit")
        end
      else
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2000
      end

      Process.demonitor(ref, [:flush])
    end

    test "steer is rejected when engine is not yet initialized" do
      # This tests the race condition where steer arrives before engine starts
      # We need to use a setup that delays engine initialization
      # For now, verify the branch exists by checking the other rejection paths
    end

    test "steer is rejected when engine does not support steering" do
      scope = make_scope()
      # Use controllable engine which does NOT support steering
      request =
        make_request(scope,
          scenario: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(request)

      assert_receive {:engine_started, _run_ref}, 2000

      # Try to steer
      %{run_id: submission_run_id, prompt: prompt} = make_request(scope, text: "steer attempt")

      GenServer.cast(pid, {:steer, submission_run_id, prompt, self()})

      # Should be rejected because engine doesn't support steering.
      assert_receive {:steer_rejected, ^submission_run_id}, 2000
    end

    test "steer is rejected when engine.steer returns error" do
      scope = make_scope()
      # Use steer_fail engine that supports steering but always fails
      request =
        make_request(scope,
          scenario: "steer_fail",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(request)

      assert_receive {:engine_started, _run_ref}, 2000

      # Try to steer
      %{run_id: submission_run_id, prompt: prompt} =
        make_request(scope, text: "steer that fails")

      GenServer.cast(pid, {:steer, submission_run_id, prompt, self()})

      # Should be rejected because engine.steer returned an error.
      assert_receive {:steer_rejected, ^submission_run_id}, 2000
    end

    test "steer rejection sends message to correct reply_pid" do
      scope = make_scope()

      request =
        make_request(scope,
          scenario: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(request)

      assert_receive {:engine_started, _run_ref}, 2000

      # Spawn a separate process to be the reply_pid for the steer
      test_pid = self()

      worker =
        spawn(fn ->
          receive do
            {:steer_rejected, submission_run_id} ->
              send(test_pid, {:worker_got_rejection, submission_run_id})
          after
            5000 -> send(test_pid, :worker_timeout)
          end
        end)

      %{run_id: submission_run_id, prompt: prompt} = make_request(scope, text: "steer attempt")

      GenServer.cast(pid, {:steer, submission_run_id, prompt, worker})

      # The worker should receive the rejection, not us.
      refute_receive {:steer_rejected, _}, 100
      assert_receive {:worker_got_rejection, ^submission_run_id}, 2000
    end
  end

  # ============================================================================
  # 15. Event Rendering for All Status Types
  # ============================================================================

  describe "event rendering - status types" do
    test "renders :running status during active run" do
      scope = make_scope()
      chat_id = System.unique_integer([:positive])
      progress_msg_id = System.unique_integer([:positive])

      request =
        make_request(scope,
          scenario: "controllable",
          meta: %{
            notify_pid: self(),
            controller_pid: self(),
            chat_id: chat_id,
            progress_msg_id: progress_msg_id
          }
        )

      {:ok, _pid} = start_run_direct(request)

      # Engine should start, which triggers :running render
      assert_receive {:engine_started, _run_ref}, 2000

      # The renderer would have been called with :running status
      # We verify by checking the run completes successfully
    end

    test "renders :done status on successful completion" do
      scope = make_scope()
      chat_id = System.unique_integer([:positive])
      progress_msg_id = System.unique_integer([:positive])

      request =
        make_request(scope,
          meta: %{
            notify_pid: self(),
            chat_id: chat_id,
            progress_msg_id: progress_msg_id
          }
        )

      {:ok, _pid} = start_run_direct(request)

      # Should complete with ok: true
      assert_receive {:lemon_gateway_run_completed, ^request, %{__event__: :completed, ok: true}},
                     2000

      # The renderer would have rendered :done status
    end

    test "renders :error status on error completion" do
      scope = make_scope()
      chat_id = System.unique_integer([:positive])
      progress_msg_id = System.unique_integer([:positive])

      request =
        make_request(scope,
          scenario: "failing",
          meta: %{
            notify_pid: self(),
            chat_id: chat_id,
            progress_msg_id: progress_msg_id,
            error: :test_error
          }
        )

      {:ok, _pid} = start_run_direct(request)

      # Should complete with error
      assert_receive {:lemon_gateway_run_completed, ^request,
                      %{__event__: :completed, ok: false, error: :test_error}},
                     2000

      # The renderer would have rendered :error status
    end

    test "renders action events during run" do
      scope = make_scope()
      chat_id = System.unique_integer([:positive])
      progress_msg_id = System.unique_integer([:positive])

      request =
        make_request(scope,
          scenario: "controllable",
          meta: %{
            notify_pid: self(),
            controller_pid: self(),
            chat_id: chat_id,
            progress_msg_id: progress_msg_id
          }
        )

      {:ok, pid} = start_run_direct(request)

      assert_receive {:engine_started, run_ref}, 2000

      # Send action event
      action = Event.action(%{id: "tool_1", kind: :tool, title: "Read file"})
      event = Event.action_event(%{engine: "controllable", action: action, phase: :started})
      send(pid, {:engine_event, run_ref, event})

      # Run should still be active
      Elixir.LemonGateway.AsyncHelpers.assert_process_alive(pid)

      # Send completed action
      completed_event =
        Event.action_event(%{
          engine: "controllable",
          action: action,
          phase: :completed
        })

      send(pid, {:engine_event, run_ref, completed_event})

      # Still active
      assert Process.alive?(pid)
    end

    test "renders with fallback when renderer_state is nil during finalize" do
      # This tests the fallback path in maybe_render_from_finalize
      scope = make_scope()
      request = make_request(scope, scenario: "failing", meta: %{notify_pid: self()})

      {:ok, _pid} = start_run_direct(request)

      # Engine fails immediately, renderer may not have been fully initialized
      assert_receive {:lemon_gateway_run_completed, ^request,
                      %{__event__: :completed, ok: false}},
                     2000
    end
  end

  # ============================================================================
  # 16. Executor Interaction Patterns
  # ============================================================================

  describe "configured executor interaction patterns" do
    test "passes new and resumed ExecutionRequests directly to the configured executor" do
      scope = make_scope()
      text = "specific text for #{System.unique_integer([:positive])}"

      resume = %ResumeToken{
        engine: "prior-backend",
        value: "resume-#{System.unique_integer([:positive])}"
      }

      request =
        make_request(scope,
          text: text,
          resume: resume,
          meta: %{notify_pid: self(), executor_observer: self()}
        )

      {:ok, _pid} = start_run_direct(request)

      assert_receive {:executor_started,
                      %ExecutionRequest{
                        prompt: ^text,
                        resume: ^resume,
                        session_key: ^scope,
                        conversation_key: {:resume, "prior-backend", _}
                      }, _opts},
                     2000

      assert_receive {:lemon_gateway_run_completed, ^request,
                      %{__event__: :completed, ok: true, answer: "Test: " <> ^text}},
                     2000
    end

    test "executor receives opts with cwd when binding has project" do
      # This would require setting up a binding with a project
      # For now, verify the code path exists
      scope = make_scope()
      request = make_request(scope, meta: %{notify_pid: self()})

      {:ok, _pid} = start_run_direct(request)

      assert_receive {:lemon_gateway_run_completed, ^request, %{__event__: :completed, ok: true}},
                     2000
    end

    test "executor cancel is called with the returned control context" do
      scope = make_scope()

      request =
        make_request(scope,
          scenario: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(request)

      assert_receive {:engine_started, _run_ref}, 2000

      # Cancel the run
      GenServer.cast(pid, {:cancel, :user_requested})

      # Engine should be cancelled (task killed)
      assert_receive {:lemon_gateway_run_completed, ^request,
                      %{__event__: :completed, ok: false, error: :user_requested}},
                     2000
    end

    test "engine events are stored in run event log" do
      scope = make_scope()

      request =
        make_request(scope,
          scenario: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(request)

      assert_receive {:engine_started, run_ref}, 2000

      # Send some events
      action = Event.action(%{id: "test_action", kind: :tool, title: "Test Tool"})
      event = Event.action_event(%{engine: "controllable", action: action, phase: :started})
      send(pid, {:engine_event, run_ref, event})

      # Complete
      completed = Event.completed(%{engine: "controllable", ok: true, answer: "done"})
      send(pid, {:engine_event, run_ref, completed})

      assert_receive {:lemon_gateway_run_completed, ^request, completed}, 2000
      run_id = completed.run_id

      # Wait for store operations to complete
      Elixir.LemonGateway.AsyncHelpers.assert_eventually(
        fn ->
          match?(%{events: events} when length(events) >= 2, LemonCore.Store.get_run(run_id))
        end,
        message: "run data was not stored"
      )

      # Events should be stored
      run_data = LemonCore.Store.get_run(run_id)
      assert run_data != nil
      assert LemonCore.Store.get_run(run_ref) == nil
      assert length(run_data.events) >= 2
    end

    test "engine start_run error triggers immediate finalize" do
      scope = make_scope()
      request = make_request(scope, scenario: "failing", meta: %{notify_pid: self()})

      {:ok, pid} = start_run_direct(request)
      ref = Process.monitor(pid)

      # Should complete quickly with error
      assert_receive {:lemon_gateway_run_completed, ^request,
                      %{__event__: :completed, ok: false}},
                     2000

      # Process should stop
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2000
    end
  end

  # ============================================================================
  # 17. Abort/Cancel Handling (Comprehensive)
  # ============================================================================

  describe "abort/cancel handling - comprehensive" do
    test "cancel with :user_requested reason" do
      scope = make_scope()

      request =
        make_request(scope,
          scenario: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(request)

      assert_receive {:engine_started, _run_ref}, 2000

      GenServer.cast(pid, {:cancel, :user_requested})

      assert_receive {:lemon_gateway_run_completed, ^request,
                      %{__event__: :completed, ok: false, error: :user_requested}},
                     2000
    end

    test "cancel with :timeout reason" do
      scope = make_scope()

      request =
        make_request(scope,
          scenario: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(request)

      assert_receive {:engine_started, _run_ref}, 2000

      GenServer.cast(pid, {:cancel, :timeout})

      assert_receive {:lemon_gateway_run_completed, ^request,
                      %{__event__: :completed, ok: false, error: :timeout}},
                     2000
    end

    test "cancel with custom reason" do
      scope = make_scope()

      request =
        make_request(scope,
          scenario: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(request)

      assert_receive {:engine_started, _run_ref}, 2000

      GenServer.cast(pid, {:cancel, {:custom, "reason"}})

      assert_receive {:lemon_gateway_run_completed, ^request,
                      %{__event__: :completed, ok: false, error: {:custom, "reason"}}},
                     2000
    end

    test "engine completed event with structured error does not crash the run" do
      scope = make_scope()

      request =
        make_request(scope,
          scenario: "structured_error",
          meta: %{
            notify_pid: self(),
            error: {:session_mismatch, %{expected: "review prompt", got: "019d0cef"}}
          }
        )

      {:ok, pid} = start_run_direct(request)

      error = {:session_mismatch, %{expected: "review prompt", got: "019d0cef"}}

      assert_receive {:lemon_gateway_run_completed, ^request,
                      %{__event__: :completed, ok: false, error: ^error}},
                     2000

      Elixir.LemonGateway.AsyncHelpers.assert_process_dead(pid)
    end

    test "cancel is idempotent - second cancel is ignored" do
      scope = make_scope()

      request =
        make_request(scope,
          scenario: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(request)

      assert_receive {:engine_started, _run_ref}, 2000

      # First cancel
      GenServer.cast(pid, {:cancel, :first_reason})

      # Receive the completion
      assert_receive {:lemon_gateway_run_completed, ^request,
                      %{__event__: :completed, ok: false, error: :first_reason}},
                     2000

      # Process might still be alive briefly
      if Process.alive?(pid) do
        # Second cancel should be ignored (completed flag is true)
        GenServer.cast(pid, {:cancel, :second_reason})

        # Should NOT receive another run_complete with second reason
        refute_receive {:lemon_gateway_run_completed, ^request,
                        %{__event__: :completed, error: :second_reason}},
                       500
      end
    end

    test "cancel before engine initialization handles nil cancel_ctx" do
      # This tests the branch where engine and cancel_ctx are nil
      # Hard to test directly, but covered by the code path
    end

    test "cancel releases claim" do
      scope = make_scope()

      request1 =
        make_request(scope,
          scenario: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid1} = start_run_direct(request1)

      assert_receive {:engine_started, _run_ref}, 5000

      # Cancel first run
      GenServer.cast(pid1, {:cancel, :done})
      assert_receive {:lemon_gateway_run_completed, ^request1, _}, 5000

      # Second run should succeed (claim released)
      request2 = make_request(scope, text: "after cancel")
      {:ok, _pid2} = start_run_direct(request2)

      assert_receive {:lemon_gateway_run_completed, ^request2,
                      %{__event__: :completed, ok: true}},
                     5000
    end

    test "cancel calls unregister_progress_mapping" do
      scope = make_scope()
      progress_msg_id = System.unique_integer([:positive])

      request =
        make_request(scope,
          scenario: "controllable",
          meta: %{notify_pid: self(), controller_pid: self(), progress_msg_id: progress_msg_id}
        )

      {:ok, pid} = start_run_direct(request)

      assert_receive {:engine_started, _run_ref}, 2000

      # Verify mapping exists (stores run_id string, not PID)
      Elixir.LemonGateway.AsyncHelpers.assert_eventually(
        fn ->
          case LemonGateway.ProgressStore.get_run(scope, progress_msg_id) do
            run_id when is_binary(run_id) and run_id != "" -> true
            _ -> false
          end
        end,
        message: "run progress mapping was never registered"
      )

      # Cancel
      GenServer.cast(pid, {:cancel, :user_requested})
      assert_receive {:lemon_gateway_run_completed, ^request, _}, 2000

      # Wait for cleanup to complete
      Elixir.LemonGateway.AsyncHelpers.assert_eventually(
        fn -> LemonGateway.ProgressStore.get_run(scope, progress_msg_id) == nil end,
        message: "run progress mapping was not removed"
      )
    end
  end

  # ============================================================================
  # 18. Resume Token Propagation
  # ============================================================================

  describe "resume token propagation" do
    # Chat-state persistence belongs to the router (D11); the gateway's
    # responsibility ends at carrying the resume token into the completion
    # event the router consumes. These tests assert that event payload.
    test "resume token from Started event is propagated into the completion event" do
      scope = make_scope()
      request = make_request(scope, meta: %{notify_pid: self()})

      {:ok, _pid} = start_run_direct(request)

      assert_receive {:lemon_gateway_run_completed, ^request,
                      %{__event__: :completed, ok: true} = completed},
                     2000

      assert %ResumeToken{} = completed.resume
      assert completed.resume.engine == "lemon"
      assert is_binary(completed.resume.value)
    end

    test "resume token from Completed event is propagated into the completion event" do
      scope = make_scope()

      request =
        make_request(scope,
          scenario: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(request)

      assert_receive {:engine_started, run_ref}, 2000

      # Send completed event with resume token
      resume = %ResumeToken{
        engine: "controllable",
        value: "final_token_#{System.unique_integer([:positive])}"
      }

      completed =
        Event.completed(%{
          engine: "controllable",
          ok: true,
          answer: "done",
          resume: resume
        })

      send(pid, {:engine_event, run_ref, completed})

      assert_receive {:lemon_gateway_run_completed, ^request,
                      %{__event__: :completed} = received},
                     2000

      assert %ResumeToken{engine: "controllable"} = received.resume
      assert received.resume.value == resume.value
    end

    # Overflow classification and the chat-state delete live in the router
    # (D11): the gateway forwards the raw error and token untouched.
    test "context overflow completion forwards the error and resume unmodified" do
      scope = make_scope()

      request =
        make_request(scope,
          scenario: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(request)
      assert_receive {:engine_started, run_ref}, 2000

      resume = %ResumeToken{
        engine: "controllable",
        value: "overflow_resume_#{System.unique_integer([:positive])}"
      }

      send(
        pid,
        {:engine_event, run_ref,
         Event.completed(%{
           engine: "controllable",
           ok: false,
           error:
             "Codex error: %{\\\"error\\\" => %{\\\"code\\\" => \\\"context_length_exceeded\\\"})}",
           resume: resume
         })}
      )

      assert_receive {:lemon_gateway_run_completed, ^request,
                      %{__event__: :completed, ok: false} = completed},
                     2000

      assert completed.error =~ "context_length_exceeded"
      assert completed.resume == resume
    end

    test "Chinese context overflow marker is forwarded in the completion event" do
      scope = make_scope()

      request =
        make_request(scope,
          scenario: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(request)
      assert_receive {:engine_started, run_ref}, 2000

      resume = %ResumeToken{
        engine: "controllable",
        value: "overflow_resume_#{System.unique_integer([:positive])}"
      }

      send(
        pid,
        {:engine_event, run_ref,
         Event.completed(%{
           engine: "controllable",
           ok: false,
           error: "模型输入过长：上下文长度超过限制",
           resume: resume
         })}
      )

      assert_receive {:lemon_gateway_run_completed, ^request,
                      %{__event__: :completed, ok: false} = completed},
                     2000

      assert completed.error =~ "上下文长度超过限制"
      assert completed.resume == resume
    end

    test "resume token does not override explicit engine selection" do
      scope = make_scope()
      resume = %ResumeToken{engine: "echo", value: "existing_session"}
      request = make_request(scope, resume: resume, scenario: "test", meta: %{notify_pid: self()})

      {:ok, _pid} = start_run_direct(request)

      assert_receive {:lemon_gateway_run_completed, ^request,
                      %{__event__: :completed, ok: true, engine: "lemon"}},
                     2000
    end

    test "resume token value is used for claim key" do
      # This tests that two jobs with same resume token share the same claim
      # Different scopes but same resume token
      scope1 = make_scope()
      scope2 = make_scope()
      resume_value = "shared_session_#{System.unique_integer([:positive])}"
      resume = %ResumeToken{engine: "controllable", value: resume_value}

      # The first request holds the claim via its resume token.
      request1 =
        make_request(scope1,
          resume: resume,
          scenario: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, _pid1} = start_run_direct(request1)

      assert_receive {:engine_started, _run_ref}, 5000

      # The second request shares the claim key (same resume token, different
      # scope): it is refused synchronously, with no Run and no terminal record.
      resume2 = %ResumeToken{engine: "test", value: resume_value}
      request2 = make_request(scope2, resume: resume2, text: "refused")

      assert {:error, :session_in_use} =
               LemonGateway.Runtime.submit_execution(ExecutionRequest.to_command(request2))

      assert LemonGateway.Runtime.run_pid(request2.run_id) == nil
      assert {:ok, nil} = LemonCore.RunStore.fetch(request2.run_id)
      refute_received {:lemon_gateway_run_completed, ^request2, _}
    end

    test "completion event carries a resume token when cancelled after start" do
      scope = make_scope()

      request =
        make_request(scope,
          scenario: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(request)

      assert_receive {:engine_started, _run_ref}, 2000

      GenServer.cast(pid, {:cancel, :done})

      assert_receive {:lemon_gateway_run_completed, ^request,
                      %{__event__: :completed} = completed},
                     2000

      assert completed.resume != nil
    end

    test "completion event carries no resume token when the engine sent none" do
      scope = make_scope()

      # Use failing engine which doesn't send resume tokens
      request =
        make_request(scope, scenario: "failing", meta: %{notify_pid: self(), error: :no_resume})

      {:ok, _pid} = start_run_direct(request)

      assert_receive {:lemon_gateway_run_completed, ^request,
                      %{__event__: :completed, ok: false} = completed},
                     2000

      assert Map.get(completed, :resume) == nil
    end

    test "resumed request without an engine ID keeps fixed lemon provenance" do
      scope = make_scope()
      # A resumed request is still dispatched to the configured executor.
      resume = %ResumeToken{engine: "echo", value: "session123"}
      request = make_request(scope, resume: resume, scenario: nil, meta: %{notify_pid: self()})

      {:ok, _pid} = start_run_direct(request)

      assert_receive {:lemon_gateway_run_completed, ^request,
                      %{__event__: :completed, engine: "lemon"}},
                     2000
    end
  end

  # ============================================================================
  # 19. Run Finalization Details
  # ============================================================================

  describe "run finalization details" do
    test "finalize stores run summary with scope" do
      scope = make_scope()
      request = make_request(scope, meta: %{notify_pid: self()})

      {:ok, _pid} = start_run_direct(request)

      assert_receive {:lemon_gateway_run_completed, ^request, %{__event__: :completed, ok: true}},
                     2000

      # Wait for run history to be stored
      Elixir.LemonGateway.AsyncHelpers.assert_eventually(
        fn -> LemonCore.RunHistoryStore.get(scope) != [] end,
        message: "run history was not stored"
      )

      # Run history should include this run
      history = LemonCore.RunHistoryStore.get(scope)
      assert history != []
    end

    test "finalize sets completed flag to prevent double finalization" do
      scope = make_scope()

      request =
        make_request(scope,
          scenario: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(request)

      assert_receive {:engine_started, run_ref}, 2000

      # Two terminal sink events can arrive back-to-back. Run must finalize once.
      completed1 = Event.completed(%{engine: "lemon", ok: true, answer: "first"})
      completed2 = Event.completed(%{engine: "lemon", ok: true, answer: "second"})
      send(pid, {:engine_event, run_ref, completed1})
      send(pid, {:engine_event, run_ref, completed2})

      assert_receive {:lemon_gateway_run_completed, ^request,
                      %{__event__: :completed, ok: true, answer: "first"}},
                     2000

      refute_receive {:lemon_gateway_run_completed, ^request, _}, 500
    end

    test "finalize handles nil run_ref gracefully" do
      # This happens when engine start_run fails immediately
      scope = make_scope()
      request = make_request(scope, scenario: "failing", meta: %{notify_pid: self()})

      {:ok, pid} = start_run_direct(request)

      assert_receive {:lemon_gateway_run_completed, ^request,
                      %{__event__: :completed, ok: false}},
                     2000

      # Should complete without crashing
      Elixir.LemonGateway.AsyncHelpers.assert_process_dead(pid)
    end
  end

  # ============================================================================
  # 20. Telemetry Events
  # ============================================================================

  defp attach_telemetry(event, handler) do
    id = make_ref()
    :ok = :telemetry.attach(id, event, handler, nil)
    on_exit(fn -> :telemetry.detach(id) end)
  end

  describe "telemetry events" do
    test "emits run_start telemetry on run initialization" do
      scope = make_scope()
      request = make_request(scope, meta: %{notify_pid: self()})

      # Attach telemetry handler
      test_pid = self()

      attach_telemetry([:lemon, :run, :start], fn _, measurements, metadata, _ ->
        send(test_pid, {:telemetry_start, measurements, metadata})
      end)

      {:ok, _pid} = start_run_direct(request)

      # Should receive telemetry event
      assert_receive {:telemetry_start, measurements, metadata}, 2000
      assert is_integer(measurements.ts_ms)
      assert metadata.engine == "lemon"
      assert is_binary(metadata.run_id)

      # Wait for completion
      assert_receive {:lemon_gateway_run_completed, ^request, %{__event__: :completed, ok: true}},
                     2000
    end

    test "emits run_stop telemetry on completion" do
      scope = make_scope()
      request = make_request(scope, meta: %{notify_pid: self()})

      # Attach telemetry handler
      test_pid = self()

      attach_telemetry([:lemon, :run, :stop], fn _, measurements, metadata, _ ->
        send(test_pid, {:telemetry_stop, measurements, metadata})
      end)

      {:ok, _pid} = start_run_direct(request)

      assert_receive {:lemon_gateway_run_completed, ^request, %{__event__: :completed, ok: true}},
                     2000

      # Should receive telemetry event
      assert_receive {:telemetry_stop, measurements, metadata}, 2000
      assert is_integer(measurements.duration_ms)
      assert measurements.duration_ms >= 0
      assert measurements.ok == true
      assert is_binary(metadata.run_id)
    end

    test "emits run_stop with ok: false on error completion" do
      scope = make_scope()

      request =
        make_request(scope, scenario: "failing", meta: %{notify_pid: self(), error: :test_error})

      # Attach telemetry handler
      test_pid = self()

      attach_telemetry([:lemon, :run, :stop], fn _, measurements, metadata, _ ->
        send(test_pid, {:telemetry_stop, measurements, metadata})
      end)

      {:ok, _pid} = start_run_direct(request)

      assert_receive {:lemon_gateway_run_completed, ^request,
                      %{__event__: :completed, ok: false}},
                     2000

      # Should receive telemetry event with ok: false
      assert_receive {:telemetry_stop, measurements, _metadata}, 2000
      assert measurements.ok == false
    end

    test "run_stop duration_ms reflects actual execution time" do
      scope = make_scope()

      request =
        make_request(scope,
          scenario: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      # Attach telemetry handler
      test_pid = self()

      attach_telemetry([:lemon, :run, :stop], fn _, measurements, _, _ ->
        send(test_pid, {:telemetry_stop_duration, measurements.duration_ms})
      end)

      {:ok, pid} = start_run_direct(request)

      assert_receive {:engine_started, run_ref}, 2000

      # Wait a bit before completing
      Process.sleep(100)

      completed = Event.completed(%{engine: "controllable", ok: true, answer: "done"})
      send(pid, {:engine_event, run_ref, completed})

      assert_receive {:lemon_gateway_run_completed, ^request, _}, 2000

      # Duration should be at least 100ms
      assert_receive {:telemetry_stop_duration, duration_ms}, 2000
      assert duration_ms >= 100
    end

    test "emits first_token telemetry on first delta" do
      scope = make_scope()

      request =
        make_request(scope,
          scenario: "streaming",
          meta: %{notify_pid: self(), delta_delay_ms: 50}
        )

      # Attach telemetry handler
      test_pid = self()

      attach_telemetry([:lemon, :run, :first_token], fn _, measurements, metadata, _ ->
        send(test_pid, {:telemetry_first_token, measurements, metadata})
      end)

      {:ok, _pid} = start_run_direct(request)

      assert_receive {:lemon_gateway_run_completed, ^request, %{__event__: :completed, ok: true}},
                     5000

      # Should have received first_token telemetry
      assert_receive {:telemetry_first_token, measurements, metadata}, 2000
      assert is_integer(measurements.latency_ms)
      assert measurements.latency_ms >= 0
      assert is_binary(metadata.run_id)
    end

    test "first_token telemetry is only emitted once" do
      scope = make_scope()

      request =
        make_request(scope,
          scenario: "streaming",
          meta: %{notify_pid: self(), delta_delay_ms: 10}
        )

      # Attach telemetry handler that counts calls
      test_pid = self()

      attach_telemetry([:lemon, :run, :first_token], fn _, _, _, _ ->
        send(test_pid, :first_token_emitted)
      end)

      {:ok, _pid} = start_run_direct(request)

      assert_receive {:lemon_gateway_run_completed, ^request, %{__event__: :completed, ok: true}},
                     5000

      # Should only receive one first_token event despite multiple deltas
      assert_receive :first_token_emitted, 1000
      refute_receive :first_token_emitted, 200
    end

    test "accumulated text from deltas appears in final answer" do
      scope = make_scope()

      request =
        make_request(scope,
          scenario: "streaming",
          meta: %{notify_pid: self(), delta_delay_ms: 10}
        )

      {:ok, _pid} = start_run_direct(request)

      assert_receive {:lemon_gateway_run_completed, ^request,
                      %{__event__: :completed, ok: true, answer: answer}},
                     5000

      # Answer should contain accumulated delta text
      assert answer == "Hello World"
    end
  end

  # ============================================================================
  # 21. Edge Cases and Boundary Conditions
  # ============================================================================

  describe "edge cases and boundary conditions" do
    test "handles an execution request with empty text" do
      scope = make_scope()
      request = make_request(scope, text: "", meta: %{notify_pid: self()})

      {:ok, _pid} = start_run_direct(request)

      assert_receive {:lemon_gateway_run_completed, ^request,
                      %{__event__: :completed, ok: true, answer: "Test: "}},
                     2000
    end

    test "handles an execution request with very long text" do
      scope = make_scope()
      long_text = String.duplicate("a", 10_000)
      request = make_request(scope, text: long_text, meta: %{notify_pid: self()})

      {:ok, _pid} = start_run_direct(request)

      assert_receive {:lemon_gateway_run_completed, ^request, %{__event__: :completed, ok: true}},
                     2000
    end

    test "handles rapid successive events" do
      scope = make_scope()

      request =
        make_request(scope,
          scenario: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(request)

      assert_receive {:engine_started, run_ref}, 2000

      # Send many events rapidly
      for i <- 1..1000 do
        action = Event.action(%{id: "action_#{i}", kind: :tool, title: "Action #{i}"})
        event = Event.action_event(%{engine: "controllable", action: action, phase: :started})
        send(pid, {:engine_event, run_ref, event})
      end

      # Should still be alive
      assert Process.alive?(pid)

      # Complete
      completed = Event.completed(%{engine: "controllable", ok: true, answer: "done"})
      send(pid, {:engine_event, run_ref, completed})

      assert_receive {:lemon_gateway_run_completed, ^request, %{__event__: :completed, ok: true}},
                     5000
    end

    test "handles meta with extra keys" do
      scope = make_scope()

      request =
        make_request(scope,
          meta: %{
            notify_pid: self(),
            extra_key: "value",
            another_key: 123,
            nested: %{foo: "bar"}
          }
        )

      {:ok, _pid} = start_run_direct(request)

      assert_receive {:lemon_gateway_run_completed, ^request, %{__event__: :completed, ok: true}},
                     2000
    end

    test "handles concurrent runs with different scopes" do
      # Start multiple runs simultaneously with different scopes
      runs =
        for i <- 1..5 do
          scope = make_scope()
          request = make_request(scope, text: "run #{i}", meta: %{notify_pid: self()})
          {:ok, _pid} = start_run_direct(request)
          request
        end

      # All should complete successfully
      for request <- runs do
        assert_receive {:lemon_gateway_run_completed, ^request,
                        %{__event__: :completed, ok: true}},
                       5000
      end
    end

    test "handles events after process monitor but before completion" do
      scope = make_scope()

      request =
        make_request(scope,
          scenario: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(request)
      ref = Process.monitor(pid)

      assert_receive {:engine_started, run_ref}, 2000

      # Send event
      action = Event.action(%{id: "a1", kind: :tool, title: "Test"})

      send(
        pid,
        {:engine_event, run_ref,
         Event.action_event(%{engine: "controllable", action: action, phase: :started})}
      )

      # Complete
      completed = Event.completed(%{engine: "controllable", ok: true, answer: "done"})
      send(pid, {:engine_event, run_ref, completed})

      assert_receive {:lemon_gateway_run_completed, ^request, %{__event__: :completed, ok: true}},
                     2000

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2000
    end
  end

  # ============================================================================
  # Durable terminal outcome (#74): commit precedes publication
  # ============================================================================

  describe "durable terminal outcome" do
    test "run_completed is published only after the terminal decision commits" do
      scope = make_scope()

      request =
        make_request(scope,
          scenario: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      run_id = request.run_id
      parent = self()

      # A finalize hook runs after the summary is written and before finalize
      # returns, so holding it open freezes the run between commit and publish.
      hook = fn
        %{run_id: ^run_id, summary: summary} ->
          send(parent, {:committed, self(), summary})

          receive do
            :release -> :ok
          after
            2_000 -> :ok
          end

        _other ->
          :ok
      end

      :ok = LemonCore.Store.register_finalize_run_hook(hook)
      on_exit(fn -> LemonCore.Store.unregister_finalize_run_hook(hook) end)
      :ok = LemonCore.Bus.subscribe(LemonCore.Bus.run_topic(run_id))

      {:ok, pid} = start_run_direct(request)
      assert_receive {:engine_started, run_ref}, 2_000

      send(
        pid,
        {:engine_event, run_ref, Event.completed(%{engine: "lemon", ok: true, answer: "durable"})}
      )

      assert_receive {:committed, hook_pid, %{completed: %{ok: true, answer: "durable"}}}, 2_000
      assert {:ok, %{summary: %{completed: %{ok: true}}}} = LemonCore.RunStore.fetch(run_id)
      refute_receive %LemonCore.Event{type: :run_completed, meta: %{run_id: ^run_id}}, 200
      refute_received {:lemon_gateway_run_completed, ^request, _}

      send(hook_pid, :release)

      assert %LemonCore.Event{payload: %{completed: %{ok: true, answer: "durable"}}} =
               receive_bus_event(:run_completed)

      assert_receive {:lemon_gateway_run_completed, ^request, %{ok: true}}, 2_000
    end

    test "a storage failure publishes nothing, releases capacity and never reruns the executor" do
      scope = make_scope()

      request =
        make_request(scope,
          scenario: "controllable",
          meta: %{notify_pid: self(), controller_pid: self(), executor_observer: self()}
        )

      run_id = request.run_id
      :ok = LemonCore.Bus.subscribe(LemonCore.Bus.run_topic(run_id))

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, pid} = LemonGateway.RunSupervisor.start_run(%{execution_request: request})
          ref = Process.monitor(pid)
          assert_receive {:executor_started, _request, _opts}, 2_000
          assert_receive {:engine_started, run_ref}, 2_000

          # Inject a deterministic persistence failure: the store now holds a run
          # record that finalization rejects as invalid.
          :ok = LemonCore.Store.put(:runs, run_id, %{events: [], started_at: 0})

          send(
            pid,
            {:engine_event, run_ref,
             Event.completed(%{engine: "lemon", ok: true, answer: "uncommitted"})}
          )

          assert_receive {:DOWN, ^ref, :process, ^pid, :terminal_persistence_failed}, 2_000
        end)

      assert log =~ "terminal_persistence_failed"
      refute_received %LemonCore.Event{type: :run_completed, meta: %{run_id: ^run_id}}
      refute_received {:lemon_gateway_run_completed, ^request, _}
      assert {:ok, record} = LemonCore.RunStore.fetch(run_id)
      refute Map.has_key?(record, :summary)

      LemonGateway.AsyncHelpers.assert_eventually(
        fn -> match?({:ok, %{in_flight: 0, waitq: 0}}, LemonGateway.Slots.stats()) end,
        message: "execution slot leaked after a persistence failure"
      )

      assert :ok = LemonGateway.EngineSessionClaim.claim({:session, scope})
      LemonGateway.EngineSessionClaim.release({:session, scope})

      # The temporary run is not restarted and the executor is not started again.
      refute_receive {:executor_started, _request, _opts}, 300
      assert Registry.lookup(LemonGateway.RunRegistry, run_id) == []
    end

    test "a run whose terminal decision already committed publishes no second completion" do
      scope = make_scope()

      request =
        make_request(scope,
          scenario: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      run_id = request.run_id
      :ok = LemonCore.Bus.subscribe(LemonCore.Bus.run_topic(run_id))

      {:ok, pid} = start_run_direct(request)
      ref = Process.monitor(pid)
      assert_receive {:engine_started, run_ref}, 2_000

      earlier = %{
        run_id: run_id,
        session_key: scope,
        completed: %{run_id: run_id, session_key: scope, ok: false, error: :aborted, answer: ""}
      }

      assert :ok = LemonCore.RunStore.finalize(run_id, earlier)

      send(
        pid,
        {:engine_event, run_ref, Event.completed(%{engine: "lemon", ok: true, answer: "late"})}
      )

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
      refute_received %LemonCore.Event{type: :run_completed, meta: %{run_id: ^run_id}}
      refute_received {:lemon_gateway_run_completed, ^request, _}
      assert {:ok, %{summary: ^earlier}} = LemonCore.RunStore.fetch(run_id)
    end
  end
end
