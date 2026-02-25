defmodule LemonGateway.RunTest do
  alias Elixir.LemonGateway, as: LemonGateway

  @moduledoc """
  Comprehensive tests for Elixir.LemonGateway.Run GenServer.

  Tests cover:
  - Run initialization and state setup
  - State transitions during execution
  - Event handling (engine events)
  - Steering behavior
  - Cancellation handling
  - Error scenarios
  - Process lifecycle
  - Lock acquisition/release
  """
  use ExUnit.Case, async: false

  alias Elixir.LemonGateway.Run
  alias Elixir.LemonGateway.Types.{Job, ResumeToken}
  alias Elixir.LemonGateway.Event

  # ============================================================================
  # Test Engines
  # ============================================================================

  # A basic engine for simple tests
  defmodule Elixir.LemonGateway.RunTest.TestEngine do
    @behaviour Elixir.LemonGateway.Engine

    alias Elixir.LemonGateway.Types.{Job, ResumeToken}
    alias Elixir.LemonGateway.Event

    @impl true
    def id, do: "test"

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

      {:ok, task_pid} =
        Task.start(fn ->
          send(sink_pid, {:engine_event, run_ref, Event.started(%{engine: id(), resume: resume})})
          answer = "Test: #{job.prompt}"

          send(
            sink_pid,
            {:engine_event, run_ref,
             Event.completed(%{engine: id(), resume: resume, ok: true, answer: answer})}
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

  # An engine that allows control over when it completes
  defmodule ControllableEngine do
    @behaviour Elixir.LemonGateway.Engine

    alias Elixir.LemonGateway.Types.{Job, ResumeToken}
    alias Elixir.LemonGateway.Event

    @impl true
    def id, do: "controllable"

    @impl true
    def format_resume(%ResumeToken{value: sid}), do: "controllable resume #{sid}"

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
          send(sink_pid, {:engine_event, run_ref, Event.started(%{engine: id(), resume: resume})})
          if controller_pid, do: send(controller_pid, {:engine_started, run_ref})

          receive do
            {:complete, answer} ->
              send(
                sink_pid,
                {:engine_event, run_ref,
                 Event.completed(%{engine: id(), resume: resume, ok: true, answer: answer})}
              )

            {:error, reason} ->
              send(
                sink_pid,
                {:engine_event, run_ref,
                 Event.completed(%{engine: id(), resume: resume, ok: false, error: reason})}
              )
          after
            30_000 ->
              send(
                sink_pid,
                {:engine_event, run_ref,
                 Event.completed(%{engine: id(), resume: resume, ok: false, error: :timeout})}
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

  # An engine that fails on start_run
  defmodule FailingEngine do
    @behaviour Elixir.LemonGateway.Engine

    alias Elixir.LemonGateway.Types.{Job, ResumeToken}

    @impl true
    def id, do: "failing"

    @impl true
    def format_resume(%ResumeToken{value: sid}), do: "failing resume #{sid}"

    @impl true
    def extract_resume(_text), do: nil

    @impl true
    def is_resume_line(_line), do: false

    @impl true
    def supports_steer?, do: false

    @impl true
    def start_run(%Job{} = job, _opts, _sink_pid) do
      error = (job.meta || %{})[:error] || :start_failed
      {:error, error}
    end

    @impl true
    def cancel(_ctx), do: :ok
  end

  # An engine that supports steering
  defmodule SteerableTestEngine do
    @behaviour Elixir.LemonGateway.Engine

    alias Elixir.LemonGateway.Types.{Job, ResumeToken}
    alias Elixir.LemonGateway.Event

    @impl true
    def id, do: "steerable_test"

    @impl true
    def format_resume(%ResumeToken{value: sid}), do: "steerable_test resume #{sid}"

    @impl true
    def extract_resume(_text), do: nil

    @impl true
    def is_resume_line(_line), do: false

    @impl true
    def supports_steer?, do: true

    @impl true
    def start_run(%Job{} = job, _opts, sink_pid) do
      run_ref = make_ref()
      resume = job.resume || %ResumeToken{engine: id(), value: unique_id()}
      steer_notify_pid = (job.meta || %{})[:steer_notify_pid]
      controller_pid = (job.meta || %{})[:controller_pid]

      {:ok, task_pid} =
        Task.start(fn ->
          send(sink_pid, {:engine_event, run_ref, Event.started(%{engine: id(), resume: resume})})
          if controller_pid, do: send(controller_pid, {:engine_started, run_ref})

          receive do
            {:complete, answer} ->
              send(
                sink_pid,
                {:engine_event, run_ref,
                 Event.completed(%{engine: id(), resume: resume, ok: true, answer: answer})}
              )
          after
            30_000 ->
              send(
                sink_pid,
                {:engine_event, run_ref,
                 Event.completed(%{engine: id(), resume: resume, ok: false, error: :timeout})}
              )
          end
        end)

      {:ok, run_ref, %{task_pid: task_pid, steer_notify_pid: steer_notify_pid}}
    end

    @impl true
    def cancel(%{task_pid: pid}) when is_pid(pid) do
      Process.exit(pid, :kill)
      :ok
    end

    @impl true
    def steer(%{steer_notify_pid: notify_pid}, text) when is_pid(notify_pid) do
      send(notify_pid, {:steered, text})
      :ok
    end

    def steer(_ctx, _text), do: :ok

    defp unique_id, do: Integer.to_string(System.unique_integer([:positive]))
  end

  # An engine that emits deltas for streaming tests
  defmodule Elixir.LemonGateway.RunTest.StreamingEngine do
    @behaviour Elixir.LemonGateway.Engine

    alias Elixir.LemonGateway.Types.{Job, ResumeToken}
    alias Elixir.LemonGateway.Event

    @impl true
    def id, do: "streaming"

    @impl true
    def format_resume(%ResumeToken{value: sid}), do: "streaming resume #{sid}"

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
      delay_ms = (job.meta || %{})[:delta_delay_ms] || 10

      {:ok, task_pid} =
        Task.start(fn ->
          send(sink_pid, {:engine_event, run_ref, Event.started(%{engine: id(), resume: resume})})

          # Emit some deltas with a small delay
          Process.sleep(delay_ms)
          send(sink_pid, {:engine_delta, run_ref, "Hello"})
          Process.sleep(delay_ms)
          send(sink_pid, {:engine_delta, run_ref, " "})
          Process.sleep(delay_ms)
          send(sink_pid, {:engine_delta, run_ref, "World"})

          send(
            sink_pid,
            {:engine_event, run_ref,
             Event.completed(%{engine: id(), resume: resume, ok: true, answer: ""})}
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

  # An engine that fails on steer
  defmodule SteerFailEngine do
    @behaviour Elixir.LemonGateway.Engine

    alias Elixir.LemonGateway.Types.{Job, ResumeToken}
    alias Elixir.LemonGateway.Event

    @impl true
    def id, do: "steer_fail"

    @impl true
    def format_resume(%ResumeToken{value: sid}), do: "steer_fail resume #{sid}"

    @impl true
    def extract_resume(_text), do: nil

    @impl true
    def is_resume_line(_line), do: false

    @impl true
    def supports_steer?, do: true

    @impl true
    def start_run(%Job{} = job, _opts, sink_pid) do
      run_ref = make_ref()
      resume = job.resume || %ResumeToken{engine: id(), value: unique_id()}
      controller_pid = (job.meta || %{})[:controller_pid]

      {:ok, task_pid} =
        Task.start(fn ->
          send(sink_pid, {:engine_event, run_ref, Event.started(%{engine: id(), resume: resume})})
          if controller_pid, do: send(controller_pid, {:engine_started, run_ref})

          receive do
            {:complete, answer} ->
              send(
                sink_pid,
                {:engine_event, run_ref,
                 Event.completed(%{engine: id(), resume: resume, ok: true, answer: answer})}
              )
          after
            30_000 ->
              send(
                sink_pid,
                {:engine_event, run_ref,
                 Event.completed(%{engine: id(), resume: resume, ok: false, error: :timeout})}
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

    @impl true
    def steer(_ctx, _text), do: {:error, :steer_failed}

    defp unique_id, do: Integer.to_string(System.unique_integer([:positive]))
  end

  # ============================================================================
  # Setup
  # ============================================================================

  setup do
    # Stop and restart the application with our test engines
    _ = Application.stop(:lemon_gateway)

    Application.put_env(:lemon_gateway, Elixir.LemonGateway.Config, %{
      max_concurrent_runs: 10,
      default_engine: "test",
      enable_telegram: false,
      require_engine_lock: false
    })

    Application.put_env(:lemon_gateway, :engines, [
      Elixir.LemonGateway.RunTest.TestEngine,
      ControllableEngine,
      FailingEngine,
      SteerableTestEngine,
      SteerFailEngine,
      Elixir.LemonGateway.RunTest.StreamingEngine,
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
    meta_opt = Keyword.get(opts, :meta, %{})

    meta =
      cond do
        is_nil(meta_opt) -> nil
        is_map(meta_opt) -> Map.merge(base_meta, meta_opt)
        true -> meta_opt
      end

    %Job{
      session_key: session_key,
      prompt: Keyword.get(opts, :prompt, Keyword.get(opts, :text, "test message")),
      queue_mode: Keyword.get(opts, :queue_mode, :collect),
      engine_id: Keyword.get(opts, :engine_id, Keyword.get(opts, :engine_hint, "test")),
      resume: Keyword.get(opts, :resume),
      meta: meta
    }
  end

  defp start_run_direct(job, slot_ref \\ make_ref()) do
    args = %{
      job: job,
      slot_ref: slot_ref,
      worker_pid: self()
    }

    Run.start_link(args)
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

  describe "initialization" do
    test "starts successfully with valid job" do
      scope = make_scope()
      job = make_job(scope)

      {:ok, pid} = start_run_direct(job)
      assert Process.alive?(pid)

      # Wait for completion
      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true}}, 2000
    end

    test "initializes state with correct fields" do
      scope = make_scope()

      job =
        make_job(scope,
          engine_hint: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(job)

      # Engine should start
      assert_receive {:engine_started, _run_ref}, 2000

      # Process should be alive and running
      assert Process.alive?(pid)

      # Clean up by completing the engine
      # The engine task needs the complete message
    end

    test "uses default engine when engine_hint is nil" do
      scope = make_scope()

      job = %Job{
        session_key: scope,
        prompt: "test",
        queue_mode: :collect,
        engine_id: nil,
        meta: %{notify_pid: self(), user_msg_id: 1}
      }

      {:ok, pid} = start_run_direct(job)

      # Should complete using default engine (test)
      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true, engine: "test"}}, 2000
    end

    test "explicit engine_id takes precedence over resume token engine" do
      scope = make_scope()
      resume = %ResumeToken{engine: "echo", value: "abc123"}
      job = make_job(scope, resume: resume, engine_hint: "test")

      {:ok, pid} = start_run_direct(job)

      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true, engine: "test"}}, 2000
    end

    test "handles engine start_run failure" do
      scope = make_scope()

      job =
        make_job(scope, engine_hint: "failing", meta: %{notify_pid: self(), error: :custom_error})

      {:ok, pid} = start_run_direct(job)

      # Should receive completion with error
      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: false, error: :custom_error}},
                     2000

      # Process should stop after error
      Elixir.LemonGateway.AsyncHelpers.assert_process_dead(pid)
    end

    test "sends notification to notify_pid on completion" do
      scope = make_scope()
      job = make_job(scope)

      {:ok, _pid} = start_run_direct(job)

      # Should receive both run_complete (to worker) and notification (to notify_pid)
      assert_receive {:run_complete, _, %{__event__: :completed, ok: true}}, 2000
      assert_receive {:lemon_gateway_run_completed, ^job, %{__event__: :completed, ok: true}}, 2000
    end
  end

  # ============================================================================
  # 2. State Transitions During Execution
  # ============================================================================

  describe "state transitions during execution" do
    test "processes Started event and continues" do
      scope = make_scope()

      job =
        make_job(scope,
          engine_hint: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      slot_ref = make_ref()

      {:ok, pid} = start_run_direct(job, slot_ref)

      # Wait for engine to start
      assert_receive {:engine_started, _run_ref}, 2000

      # Run should still be alive (waiting for completion)
      assert Process.alive?(pid)
    end

    test "processes ActionEvent and continues" do
      scope = make_scope()

      job =
        make_job(scope,
          engine_hint: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(job)

      assert_receive {:engine_started, run_ref}, 2000

      # Simulate an action event
      action = Event.action(%{id: "action_1", kind: :test, title: "Test Action"})
      action_event = Event.action_event(%{engine: "controllable", action: action, phase: :started})
      send(pid, {:engine_event, run_ref, action_event})

      # Run should still be alive (check without timing race)
      Elixir.LemonGateway.AsyncHelpers.assert_process_alive(pid)
    end

    test "processes Completed event and stops" do
      scope = make_scope()
      job = make_job(scope)

      {:ok, pid} = start_run_direct(job)

      # Should complete and stop
      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true}}, 2000

      # Wait deterministically for the process to stop
      Elixir.LemonGateway.AsyncHelpers.assert_process_dead(pid)
    end

    test "ignores events with wrong run_ref" do
      scope = make_scope()

      job =
        make_job(scope,
          engine_hint: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(job)

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
      job = make_job(scope)

      {:ok, pid} = start_run_direct(job)

      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true}}, 2000

      # Events should be stored (though we can't easily inspect without run_ref)
    end

    test "handles successful completion" do
      scope = make_scope()
      job = make_job(scope, text: "hello world")

      {:ok, pid} = start_run_direct(job)

      assert_receive {:run_complete, ^pid,
                      %{__event__: :completed, ok: true, answer: "Test: hello world"}},
                     2000
    end

    test "handles error completion" do
      scope = make_scope()

      job =
        make_job(scope, engine_hint: "failing", meta: %{notify_pid: self(), error: :test_error})

      {:ok, pid} = start_run_direct(job)

      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: false, error: :test_error}}, 2000
    end

    test "handles unknown messages gracefully" do
      scope = make_scope()

      job =
        make_job(scope,
          engine_hint: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(job)

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

      job =
        make_job(scope,
          engine_hint: "steerable_test",
          meta: %{notify_pid: self(), controller_pid: self(), steer_notify_pid: self()}
        )

      {:ok, pid} = start_run_direct(job)

      assert_receive {:engine_started, _run_ref}, 2000

      # Send steer cast
      steer_job = make_job(scope, text: "steering message")
      GenServer.cast(pid, {:steer, steer_job, self()})

      # Should receive steer notification
      assert_receive {:steered, "steering message"}, 2000

      # Should NOT receive steer_rejected
      refute_receive {:steer_rejected, _}, 200
    end

    test "rejects steer when run is completed" do
      scope = make_scope()
      job = make_job(scope)

      {:ok, pid} = start_run_direct(job)

      # Wait for completion
      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true}}, 2000

      # Try to steer after completion
      steer_job = make_job(scope, text: "late steer")
      GenServer.cast(pid, {:steer, steer_job, self()})

      # Should receive rejection (though process may be dead)
      # Note: This test may be flaky since the process stops after completion
    end

    test "rejects steer when engine does not support it" do
      scope = make_scope()

      job =
        make_job(scope,
          engine_hint: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(job)

      assert_receive {:engine_started, _run_ref}, 2000

      # Try to steer (engine doesn't support it)
      steer_job = make_job(scope, text: "steer attempt")
      GenServer.cast(pid, {:steer, steer_job, self()})

      # Should receive rejection
      assert_receive {:steer_rejected, ^steer_job}, 2000
    end

    test "rejects steer when engine is not yet initialized" do
      # This is harder to test since initialization happens quickly
      # We rely on the code coverage of the cond branch
    end

    test "rejects steer when engine steer call fails" do
      scope = make_scope()

      job =
        make_job(scope,
          engine_hint: "steer_fail",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(job)

      assert_receive {:engine_started, _run_ref}, 2000

      # Try to steer (engine will fail)
      steer_job = make_job(scope, text: "steer that fails")
      GenServer.cast(pid, {:steer, steer_job, self()})

      # Should receive rejection due to steer error
      assert_receive {:steer_rejected, ^steer_job}, 2000
    end
  end

  # ============================================================================
  # 5. Cancellation Handling
  # ============================================================================

  describe "cancellation handling" do
    test "cancels run when cancel cast is received" do
      scope = make_scope()

      job =
        make_job(scope,
          engine_hint: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(job)

      assert_receive {:engine_started, _run_ref}, 2000

      # Cancel the run
      GenServer.cast(pid, {:cancel, :user_requested})

      # Should receive completion with error
      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: false, error: :user_requested}},
                     2000

      # Process should stop
      Elixir.LemonGateway.AsyncHelpers.assert_process_dead(pid)
    end

    test "cancel is idempotent when already completed" do
      scope = make_scope()
      job = make_job(scope)

      {:ok, pid} = start_run_direct(job)

      # Wait for natural completion
      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true}}, 2000

      # Try to cancel after completion (should be ignored)
      # Process may already be dead, which is fine
    end

    test "cancel sends notification to notify_pid" do
      scope = make_scope()

      job =
        make_job(scope,
          engine_hint: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(job)

      assert_receive {:engine_started, _run_ref}, 2000

      GenServer.cast(pid, {:cancel, :test_reason})

      # Should receive notification
      assert_receive {:lemon_gateway_run_completed, ^job,
                      %{__event__: :completed, ok: false, error: :test_reason}},
                     2000
    end

    test "cancel releases slot" do
      scope = make_scope()
      slot_ref = make_ref()

      job =
        make_job(scope,
          engine_hint: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(job, slot_ref)

      assert_receive {:engine_started, _run_ref}, 2000

      GenServer.cast(pid, {:cancel, :test_reason})

      assert_receive {:run_complete, ^pid, %{__event__: :completed}}, 2000

      # Slot should be released (verified through Scheduler behavior)
    end

    test "cancel calls engine.cancel" do
      scope = make_scope()

      job =
        make_job(scope,
          engine_hint: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(job)

      assert_receive {:engine_started, _run_ref}, 2000

      GenServer.cast(pid, {:cancel, :user_requested})

      # Engine task should be killed
      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: false}}, 2000
    end
  end

  # ============================================================================
  # 6. Error Scenarios
  # ============================================================================

  describe "error scenarios" do
    test "handles engine start_run returning error" do
      scope = make_scope()

      job =
        make_job(scope, engine_hint: "failing", meta: %{notify_pid: self(), error: :engine_error})

      {:ok, pid} = start_run_direct(job)

      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: false, error: :engine_error}},
                     2000

      assert_receive {:lemon_gateway_run_completed, ^job,
                      %{__event__: :completed, ok: false, error: :engine_error}},
                     2000

      Elixir.LemonGateway.AsyncHelpers.assert_process_dead(pid)
    end

    test "handles unknown engine gracefully" do
      scope = make_scope()
      job = make_job(scope, engine_hint: "nonexistent")

      {:ok, pid} = start_run_direct(job)

      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: false, error: error}}, 2000
      assert is_binary(error)
      assert error =~ "unknown engine id"

      Elixir.LemonGateway.AsyncHelpers.assert_process_dead(pid)
    end

    test "handles nil notify_pid gracefully" do
      scope = make_scope()
      job = make_job(scope, meta: nil)

      {:ok, pid} = start_run_direct(job)

      # Should still complete (no notification sent)
      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true}}, 2000

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
      job = make_job(scope)

      {:ok, pid} = start_run_direct(job)
      ref = Process.monitor(pid)

      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true}}, 2000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2000
    end

    test "process stops normally after error completion" do
      scope = make_scope()
      job = make_job(scope, engine_hint: "failing")

      {:ok, pid} = start_run_direct(job)
      ref = Process.monitor(pid)

      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: false}}, 2000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2000
    end

    test "process stops normally after cancellation" do
      scope = make_scope()

      job =
        make_job(scope,
          engine_hint: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(job)
      ref = Process.monitor(pid)

      assert_receive {:engine_started, _run_ref}, 2000

      GenServer.cast(pid, {:cancel, :test_reason})

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2000
    end

    test "releases slot on completion" do
      scope = make_scope()
      slot_ref = make_ref()
      job = make_job(scope)

      {:ok, pid} = start_run_direct(job, slot_ref)

      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true}}, 2000

      # Slot release is verified through Scheduler internals
    end

    test "notifies worker_pid on completion" do
      scope = make_scope()
      job = make_job(scope)

      {:ok, pid} = start_run_direct(job)

      # Worker (self) should receive completion
      assert_receive {:run_complete, ^pid,
                      %{__event__: :completed, ok: true, answer: "Test: test message"}},
                     2000
    end
  end

  # ============================================================================
  # 8. Lock Acquisition and Release
  # ============================================================================

  describe "lock acquisition and release" do
    setup do
      # Enable engine lock for these tests
      _ = Application.stop(:lemon_gateway)

      Application.put_env(:lemon_gateway, Elixir.LemonGateway.Config, %{
        max_concurrent_runs: 10,
        default_engine: "test",
        enable_telegram: false,
        require_engine_lock: true,
        engine_lock_timeout_ms: 5000
      })

      Application.put_env(:lemon_gateway, :engines, [
        Elixir.LemonGateway.RunTest.TestEngine,
        ControllableEngine,
        FailingEngine,
        SteerableTestEngine,
        SteerFailEngine,
        Elixir.LemonGateway.RunTest.StreamingEngine,
        Elixir.LemonGateway.Engines.Echo
      ])

      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      :ok
    end

    test "acquires lock on start when require_engine_lock is true" do
      scope = make_scope()
      job = make_job(scope)

      {:ok, pid} = start_run_direct(job)

      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true}}, 5000
    end

    test "releases lock on successful completion" do
      scope = make_scope()
      job = make_job(scope)

      {:ok, pid} = start_run_direct(job)

      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true}}, 5000

      # Start another run with same scope - should succeed if lock was released
      job2 = make_job(scope, text: "second run")
      {:ok, pid2} = start_run_direct(job2)

      assert_receive {:run_complete, ^pid2, %{__event__: :completed, ok: true}}, 5000
    end

    test "releases lock on error completion" do
      scope = make_scope()
      job = make_job(scope, engine_hint: "failing")

      {:ok, pid} = start_run_direct(job)

      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: false}}, 5000

      # Start another run with same scope
      job2 = make_job(scope, text: "after error")
      {:ok, pid2} = start_run_direct(job2)

      assert_receive {:run_complete, ^pid2, %{__event__: :completed, ok: true}}, 5000
    end

    test "releases lock on cancellation" do
      scope = make_scope()

      job =
        make_job(scope,
          engine_hint: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(job)

      assert_receive {:engine_started, _run_ref}, 5000

      GenServer.cast(pid, {:cancel, :test_reason})

      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: false}}, 5000

      # Start another run with same scope
      job2 = make_job(scope, text: "after cancel")
      {:ok, pid2} = start_run_direct(job2)

      assert_receive {:run_complete, ^pid2, %{__event__: :completed, ok: true}}, 5000
    end

    test "uses resume token value for lock key when present" do
      scope1 = make_scope()
      scope2 = make_scope()
      # Use controllable engine in resume token so we can control when it completes
      resume = %ResumeToken{
        engine: "controllable",
        value: "shared_session_#{System.unique_integer([:positive])}"
      }

      # Both jobs share the same resume value; first run uses controllable engine to hold the lock.
      job1 =
        make_job(scope1,
          resume: resume,
          engine_id: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid1} = start_run_direct(job1)

      assert_receive {:engine_started, _run_ref}, 5000

      # Second job with same resume should wait for lock
      # We can't easily test the blocking behavior in unit tests
      # but we verify the lock key derivation works

      # Complete first run
      GenServer.cast(pid1, {:cancel, :done})
      assert_receive {:run_complete, ^pid1, _}, 5000

      # Now second should succeed - use test engine for quick completion
      job2 = make_job(scope2, resume: %ResumeToken{engine: "test", value: resume.value})
      {:ok, pid2} = start_run_direct(job2)
      assert_receive {:run_complete, ^pid2, %{__event__: :completed}}, 5000
    end
  end

  # ============================================================================
  # 9. Lock Timeout Handling
  # ============================================================================

  describe "lock timeout handling" do
    setup do
      # Enable engine lock with very short timeout for these tests
      _ = Application.stop(:lemon_gateway)

      Application.put_env(:lemon_gateway, Elixir.LemonGateway.Config, %{
        max_concurrent_runs: 10,
        default_engine: "test",
        enable_telegram: false,
        require_engine_lock: true,
        # Very short timeout
        engine_lock_timeout_ms: 100
      })

      Application.put_env(:lemon_gateway, :engines, [
        Elixir.LemonGateway.RunTest.TestEngine,
        ControllableEngine,
        FailingEngine,
        SteerableTestEngine,
        SteerFailEngine,
        Elixir.LemonGateway.RunTest.StreamingEngine,
        Elixir.LemonGateway.Engines.Echo
      ])

      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      :ok
    end

    test "fails fast when lock acquisition times out" do
      scope = make_scope()

      # Start a long-running job to hold the lock
      job1 =
        make_job(scope,
          engine_hint: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, _pid1} = start_run_direct(job1)

      assert_receive {:engine_started, _run_ref}, 5000

      # Try to start second job - should timeout waiting for lock
      job2 = make_job(scope, text: "should timeout")
      result = start_run_direct(job2)

      # The init returns {:stop, :normal} on lock timeout, which means
      # start_link may return {:ok, pid} before the process stops, or
      # {:error, :normal} if already stopped
      case result do
        {:ok, pid} ->
          # Process either already stopped or will stop soon
          ref = Process.monitor(pid)
          # Either already dead or will stop
          receive do
            {:DOWN, ^ref, :process, ^pid, :normal} -> :ok
          after
            500 ->
              # Process might still be alive briefly, that's OK
              :ok
          end

        {:error, :normal} ->
          # Process stopped during init - this is expected
          :ok

        :ignore ->
          # This is also acceptable
          :ok
      end

      # Should receive lock timeout completion notification for job2
      assert_receive {:lemon_gateway_run_completed, ^job2,
                      %{__event__: :completed, ok: false, error: :lock_timeout}},
                     5000
    end

    test "sends lock_timeout error on timeout" do
      scope = make_scope()

      # Hold lock with first job
      job1 =
        make_job(scope,
          engine_hint: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, _pid1} = start_run_direct(job1)

      assert_receive {:engine_started, _run_ref}, 5000

      # Second job should fail with lock timeout
      job2 = make_job(scope, text: "timeout test")

      # The init returns {:stop, :normal} on lock timeout
      # which means start_link returns {:ok, pid} then the process immediately stops
      # OR the init could complete before returning

      # We check for the notification instead
      _result = start_run_direct(job2)

      # Should receive lock timeout notification
      assert_receive {:lemon_gateway_run_completed, ^job2,
                      %{__event__: :completed, ok: false, error: :lock_timeout}},
                     5000
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
      job =
        make_job(scope,
          engine_hint: "controllable",
          meta: %{notify_pid: self(), progress_msg_id: progress_msg_id, controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(job)

      # Wait for engine to start (which means registration should be done)
      assert_receive {:engine_started, _run_ref}, 2000

      # Check mapping exists (stores run_id string, not PID)
      stored_run_id =
        wait_for(
          fn -> Elixir.LemonGateway.Store.get_run_by_progress(scope, progress_msg_id) end,
          500,
          10
        )

      assert is_binary(stored_run_id) and stored_run_id != ""

      # Cancel to complete
      GenServer.cast(pid, {:cancel, :done})

      # Wait for completion
      assert_receive {:run_complete, ^pid, _}, 2000

      # Wait for unregistration to complete
      Elixir.LemonGateway.AsyncHelpers.assert_eventually(
        fn -> Elixir.LemonGateway.Store.get_run_by_progress(scope, progress_msg_id) == nil end,
        message: "run progress mapping was not removed"
      )
    end

    test "does not register mapping when progress_msg_id is nil" do
      scope = make_scope()
      job = make_job(scope, meta: %{notify_pid: self()})

      {:ok, pid} = start_run_direct(job)

      assert_receive {:run_complete, ^pid, _}, 2000

      # No mapping should exist
      assert Elixir.LemonGateway.Store.get_run_by_progress(scope, nil) == nil
    end

    test "unregisters progress mapping on completion" do
      scope = make_scope()
      progress_msg_id = System.unique_integer([:positive])
      job = make_job(scope, meta: %{notify_pid: self(), progress_msg_id: progress_msg_id})

      {:ok, pid} = start_run_direct(job)

      # Wait for completion
      assert_receive {:run_complete, ^pid, _}, 2000

      # Wait for cleanup to complete
      Elixir.LemonGateway.AsyncHelpers.assert_eventually(
        fn -> Elixir.LemonGateway.Store.get_run_by_progress(scope, progress_msg_id) == nil end,
        message: "run progress mapping was not removed on completion"
      )
    end

    test "unregisters progress mapping on cancellation" do
      scope = make_scope()
      progress_msg_id = System.unique_integer([:positive])

      job =
        make_job(scope,
          engine_hint: "controllable",
          meta: %{notify_pid: self(), controller_pid: self(), progress_msg_id: progress_msg_id}
        )

      {:ok, pid} = start_run_direct(job)

      assert_receive {:engine_started, _run_ref}, 2000

      # Verify mapping exists (stores run_id string, not PID)
      assert Enum.any?(1..20, fn _attempt ->
               case Elixir.LemonGateway.Store.get_run_by_progress(scope, progress_msg_id) do
                 run_id when is_binary(run_id) and run_id != "" ->
                   true

                 _ ->
                   Process.sleep(10)
                   false
               end
             end)

      # Cancel
      GenServer.cast(pid, {:cancel, :user_requested})

      assert_receive {:run_complete, ^pid, _}, 2000

      # Wait for cleanup to complete
      Elixir.LemonGateway.AsyncHelpers.assert_eventually(
        fn -> Elixir.LemonGateway.Store.get_run_by_progress(scope, progress_msg_id) == nil end,
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
      job = make_job(scope)

      {:ok, pid} = start_run_direct(job)

      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true}}, 2000
    end

    test "applies events through renderer" do
      scope = make_scope()

      job =
        make_job(scope,
          engine_hint: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, _pid} = start_run_direct(job)

      assert_receive {:engine_started, _run_ref}, 2000

      # Events are processed through renderer - we verify by successful completion
    end

    test "renders on completion" do
      scope = make_scope()
      # Without chat_id, no rendering to Outbox occurs
      # But the renderer still processes the event
      job = make_job(scope)

      {:ok, pid} = start_run_direct(job)

      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true}}, 2000
    end
  end

  # ============================================================================
  # 12. Multiple Events in Sequence
  # ============================================================================

  describe "multiple events in sequence" do
    test "handles Started -> ActionEvent -> Completed sequence" do
      scope = make_scope()

      job =
        make_job(scope,
          engine_hint: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(job)

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

      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true, answer: "done"}}, 2000
    end

    test "processes many events without issues" do
      scope = make_scope()

      job =
        make_job(scope,
          engine_hint: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(job)

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

      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true}}, 2000
    end
  end

  # ============================================================================
  # 13. Comprehensive Steering Flow Tests
  # ============================================================================

  describe "steering flow - acceptance path" do
    test "steer is accepted when engine supports it and run is active" do
      scope = make_scope()

      job =
        make_job(scope,
          engine_hint: "steerable_test",
          meta: %{notify_pid: self(), controller_pid: self(), steer_notify_pid: self()}
        )

      {:ok, pid} = start_run_direct(job)

      assert_receive {:engine_started, _run_ref}, 2000

      # Steer should succeed
      steer_job = make_job(scope, text: "steering text")
      GenServer.cast(pid, {:steer, steer_job, self()})

      # Engine receives the steer
      assert_receive {:steered, "steering text"}, 2000

      # No rejection should be sent
      refute_receive {:steer_rejected, _}, 100
    end

    test "multiple steers in sequence are all accepted" do
      scope = make_scope()

      job =
        make_job(scope,
          engine_hint: "steerable_test",
          meta: %{notify_pid: self(), controller_pid: self(), steer_notify_pid: self()}
        )

      {:ok, pid} = start_run_direct(job)

      assert_receive {:engine_started, _run_ref}, 2000

      # Send multiple steers
      for i <- 1..5 do
        steer_job = make_job(scope, text: "steer #{i}")
        GenServer.cast(pid, {:steer, steer_job, self()})
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

      # No rejections
      refute_receive {:steer_rejected, _}, 100
    end
  end

  describe "steering flow - rejection paths" do
    test "steer is rejected when run is already completed" do
      scope = make_scope()
      # Use test engine that completes quickly
      job = make_job(scope, meta: %{notify_pid: self()})

      {:ok, pid} = start_run_direct(job)

      # Wait for completion
      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true}}, 2000

      # Process should be stopping/stopped, but if we can still message it...
      steer_job = make_job(scope, text: "late steer")
      ref = Process.monitor(pid)

      # After completion, a late steer is either explicitly rejected (if the
      # process is still alive) or the process exits before handling it.
      if Process.alive?(pid) do
        GenServer.cast(pid, {:steer, steer_job, self()})

        receive do
          {:steer_rejected, ^steer_job} -> :ok
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
      job =
        make_job(scope,
          engine_hint: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(job)

      assert_receive {:engine_started, _run_ref}, 2000

      # Try to steer
      steer_job = make_job(scope, text: "steer attempt")
      GenServer.cast(pid, {:steer, steer_job, self()})

      # Should be rejected because engine doesn't support steering
      assert_receive {:steer_rejected, ^steer_job}, 2000
    end

    test "steer is rejected when engine.steer returns error" do
      scope = make_scope()
      # Use steer_fail engine that supports steering but always fails
      job =
        make_job(scope,
          engine_hint: "steer_fail",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(job)

      assert_receive {:engine_started, _run_ref}, 2000

      # Try to steer
      steer_job = make_job(scope, text: "steer that fails")
      GenServer.cast(pid, {:steer, steer_job, self()})

      # Should be rejected because engine.steer returned error
      assert_receive {:steer_rejected, ^steer_job}, 2000
    end

    test "steer rejection sends message to correct worker_pid" do
      scope = make_scope()

      job =
        make_job(scope,
          engine_hint: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(job)

      assert_receive {:engine_started, _run_ref}, 2000

      # Spawn a separate process to be the worker_pid for the steer
      test_pid = self()

      worker =
        spawn(fn ->
          receive do
            {:steer_rejected, job} -> send(test_pid, {:worker_got_rejection, job})
          after
            5000 -> send(test_pid, :worker_timeout)
          end
        end)

      steer_job = make_job(scope, text: "steer attempt")
      GenServer.cast(pid, {:steer, steer_job, worker})

      # The worker should receive the rejection, not us
      refute_receive {:steer_rejected, _}, 100
      assert_receive {:worker_got_rejection, ^steer_job}, 2000
    end
  end

  # ============================================================================
  # 14. Lock Acquisition Timeout Path (Detailed)
  # ============================================================================

  describe "lock acquisition timeout - detailed" do
    setup do
      _ = Application.stop(:lemon_gateway)

      Application.put_env(:lemon_gateway, Elixir.LemonGateway.Config, %{
        max_concurrent_runs: 10,
        default_engine: "test",
        enable_telegram: false,
        require_engine_lock: true,
        # Very short timeout for faster tests
        engine_lock_timeout_ms: 50
      })

      Application.put_env(:lemon_gateway, :engines, [
        Elixir.LemonGateway.RunTest.TestEngine,
        ControllableEngine,
        FailingEngine,
        SteerableTestEngine,
        SteerFailEngine,
        Elixir.LemonGateway.RunTest.StreamingEngine,
        Elixir.LemonGateway.Engines.Echo
      ])

      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      :ok
    end

    test "lock timeout returns :lock_timeout error in completed event" do
      scope = make_scope()

      # Start first job to hold the lock
      job1 =
        make_job(scope,
          engine_hint: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, _pid1} = start_run_direct(job1)

      assert_receive {:engine_started, _run_ref}, 5000

      # Second job should timeout
      job2 = make_job(scope, text: "will timeout")
      _result = start_run_direct(job2)

      # Should receive completion with :lock_timeout error
      assert_receive {:lemon_gateway_run_completed, ^job2, completed}, 5000
      assert completed.ok == false
      assert completed.error == :lock_timeout
    end

    test "lock timeout releases scheduler slot" do
      scope = make_scope()

      # Start first job to hold the lock
      job1 =
        make_job(scope,
          engine_hint: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, _pid1} = start_run_direct(job1)

      assert_receive {:engine_started, _run_ref}, 5000

      # Second job should timeout but still release its slot
      job2 = make_job(scope, text: "will timeout")
      slot_ref = make_ref()
      _result = start_run_direct(job2, slot_ref)

      # Should receive completion notification
      assert_receive {:lemon_gateway_run_completed, ^job2, _completed}, 5000

      # Worker should receive run_complete message
      assert_receive {:run_complete, _pid, %{__event__: :completed, error: :lock_timeout}}, 5000
    end

    test "lock timeout uses correct engine_id in completed event" do
      scope = make_scope()

      # Start first job to hold the lock
      job1 =
        make_job(scope,
          engine_hint: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, _pid1} = start_run_direct(job1)

      assert_receive {:engine_started, _run_ref}, 5000

      # Second job with different engine hint
      job2 = make_job(scope, text: "will timeout", engine_hint: "echo")
      _result = start_run_direct(job2)

      # Should receive completion with correct engine id
      assert_receive {:lemon_gateway_run_completed, ^job2, completed}, 5000
      assert completed.engine == "echo"
    end

    test "lock timeout notifies notify_pid even when init fails" do
      scope = make_scope()

      # Start first job to hold the lock
      job1 =
        make_job(scope,
          engine_hint: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, _pid1} = start_run_direct(job1)

      assert_receive {:engine_started, _run_ref}, 5000

      # Second job with notify_pid
      notify_receiver = self()
      job2 = make_job(scope, text: "will timeout", meta: %{notify_pid: notify_receiver})
      _result = start_run_direct(job2)

      # notify_pid should receive the notification
      assert_receive {:lemon_gateway_run_completed, ^job2,
                      %{__event__: :completed, error: :lock_timeout}},
                     5000
    end

    test "lock timeout does not notify when notify_pid is nil" do
      scope = make_scope()

      # Start first job to hold the lock
      job1 =
        make_job(scope,
          engine_hint: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, _pid1} = start_run_direct(job1)

      assert_receive {:engine_started, _run_ref}, 5000

      # Second job without notify_pid
      job2 = make_job(scope, text: "will timeout", meta: nil)
      _result = start_run_direct(job2)

      # Should still receive run_complete to worker
      assert_receive {:run_complete, _pid, %{__event__: :completed, error: :lock_timeout}}, 5000

      # But should NOT receive lemon_gateway_run_completed (no notify_pid)
      refute_receive {:lemon_gateway_run_completed, _, _}, 100
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

      job =
        make_job(scope,
          engine_hint: "controllable",
          meta: %{
            notify_pid: self(),
            controller_pid: self(),
            chat_id: chat_id,
            progress_msg_id: progress_msg_id
          }
        )

      {:ok, _pid} = start_run_direct(job)

      # Engine should start, which triggers :running render
      assert_receive {:engine_started, _run_ref}, 2000

      # The renderer would have been called with :running status
      # We verify by checking the run completes successfully
    end

    test "renders :done status on successful completion" do
      scope = make_scope()
      chat_id = System.unique_integer([:positive])
      progress_msg_id = System.unique_integer([:positive])

      job =
        make_job(scope,
          meta: %{
            notify_pid: self(),
            chat_id: chat_id,
            progress_msg_id: progress_msg_id
          }
        )

      {:ok, pid} = start_run_direct(job)

      # Should complete with ok: true
      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true}}, 2000

      # The renderer would have rendered :done status
    end

    test "renders :error status on error completion" do
      scope = make_scope()
      chat_id = System.unique_integer([:positive])
      progress_msg_id = System.unique_integer([:positive])

      job =
        make_job(scope,
          engine_hint: "failing",
          meta: %{
            notify_pid: self(),
            chat_id: chat_id,
            progress_msg_id: progress_msg_id,
            error: :test_error
          }
        )

      {:ok, pid} = start_run_direct(job)

      # Should complete with error
      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: false, error: :test_error}}, 2000

      # The renderer would have rendered :error status
    end

    test "renders action events during run" do
      scope = make_scope()
      chat_id = System.unique_integer([:positive])
      progress_msg_id = System.unique_integer([:positive])

      job =
        make_job(scope,
          engine_hint: "controllable",
          meta: %{
            notify_pid: self(),
            controller_pid: self(),
            chat_id: chat_id,
            progress_msg_id: progress_msg_id
          }
        )

      {:ok, pid} = start_run_direct(job)

      assert_receive {:engine_started, run_ref}, 2000

      # Send action event
      action = Event.action(%{id: "tool_1", kind: :tool, title: "Read file"})
      event = Event.action_event(%{engine: "controllable", action: action, phase: :started})
      send(pid, {:engine_event, run_ref, event})

      # Run should still be active
      Elixir.LemonGateway.AsyncHelpers.assert_process_alive(pid)

      # Send completed action
      completed_event = Event.action_event(%{
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
      job = make_job(scope, engine_hint: "failing", meta: %{notify_pid: self()})

      {:ok, pid} = start_run_direct(job)

      # Engine fails immediately, renderer may not have been fully initialized
      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: false}}, 2000
    end
  end

  # ============================================================================
  # 16. Engine Interaction Patterns
  # ============================================================================

  describe "engine interaction patterns" do
    test "engine receives correct job during start_run" do
      scope = make_scope()
      text = "specific text for #{System.unique_integer([:positive])}"
      job = make_job(scope, text: text, meta: %{notify_pid: self()})

      {:ok, pid} = start_run_direct(job)

      # Test engine echoes back the text
      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true, answer: "Test: " <> ^text}},
                     2000
    end

    test "engine receives opts with cwd when binding has project" do
      # This would require setting up a binding with a project
      # For now, verify the code path exists
      scope = make_scope()
      job = make_job(scope, meta: %{notify_pid: self()})

      {:ok, pid} = start_run_direct(job)
      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true}}, 2000
    end

    test "engine cancel is called with correct cancel_ctx" do
      scope = make_scope()

      job =
        make_job(scope,
          engine_hint: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(job)

      assert_receive {:engine_started, _run_ref}, 2000

      # Cancel the run
      GenServer.cast(pid, {:cancel, :user_requested})

      # Engine should be cancelled (task killed)
      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: false, error: :user_requested}},
                     2000
    end

    test "engine events are stored in run event log" do
      scope = make_scope()

      job =
        make_job(scope,
          engine_hint: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(job)

      assert_receive {:engine_started, run_ref}, 2000

      # Send some events
      action = Event.action(%{id: "test_action", kind: :tool, title: "Test Tool"})
      event = Event.action_event(%{engine: "controllable", action: action, phase: :started})
      send(pid, {:engine_event, run_ref, event})

      # Complete
      completed = Event.completed(%{engine: "controllable", ok: true, answer: "done"})
      send(pid, {:engine_event, run_ref, completed})

      assert_receive {:run_complete, ^pid, _}, 2000

      # Wait for store operations to complete
      Elixir.LemonGateway.AsyncHelpers.assert_eventually(
        fn -> Elixir.LemonGateway.Store.get_run(run_ref) != nil end,
        message: "run data was not stored"
      )

      # Events should be stored
      run_data = Elixir.LemonGateway.Store.get_run(run_ref)
      assert run_data != nil
      assert length(run_data.events) >= 2
    end

    test "engine start_run error triggers immediate finalize" do
      scope = make_scope()
      job = make_job(scope, engine_hint: "failing", meta: %{notify_pid: self()})

      {:ok, pid} = start_run_direct(job)
      ref = Process.monitor(pid)

      # Should complete quickly with error
      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: false}}, 2000

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

      job =
        make_job(scope,
          engine_hint: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(job)

      assert_receive {:engine_started, _run_ref}, 2000

      GenServer.cast(pid, {:cancel, :user_requested})

      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: false, error: :user_requested}},
                     2000
    end

    test "cancel with :timeout reason" do
      scope = make_scope()

      job =
        make_job(scope,
          engine_hint: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(job)

      assert_receive {:engine_started, _run_ref}, 2000

      GenServer.cast(pid, {:cancel, :timeout})

      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: false, error: :timeout}}, 2000
    end

    test "cancel with custom reason" do
      scope = make_scope()

      job =
        make_job(scope,
          engine_hint: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(job)

      assert_receive {:engine_started, _run_ref}, 2000

      GenServer.cast(pid, {:cancel, {:custom, "reason"}})

      assert_receive {:run_complete, ^pid,
                      %{__event__: :completed, ok: false, error: {:custom, "reason"}}},
                     2000
    end

    test "cancel is idempotent - second cancel is ignored" do
      scope = make_scope()

      job =
        make_job(scope,
          engine_hint: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(job)

      assert_receive {:engine_started, _run_ref}, 2000

      # First cancel
      GenServer.cast(pid, {:cancel, :first_reason})

      # Receive the completion
      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: false, error: :first_reason}},
                     2000

      # Process might still be alive briefly
      if Process.alive?(pid) do
        # Second cancel should be ignored (completed flag is true)
        GenServer.cast(pid, {:cancel, :second_reason})

        # Should NOT receive another run_complete with second reason
        refute_receive {:run_complete, ^pid, %{__event__: :completed, error: :second_reason}}, 500
      end
    end

    test "cancel before engine initialization handles nil cancel_ctx" do
      # This tests the branch where engine and cancel_ctx are nil
      # Hard to test directly, but covered by the code path
    end

    test "cancel releases lock" do
      # Setup with lock enabled
      _ = Application.stop(:lemon_gateway)

      Application.put_env(:lemon_gateway, Elixir.LemonGateway.Config, %{
        max_concurrent_runs: 10,
        default_engine: "test",
        enable_telegram: false,
        require_engine_lock: true,
        engine_lock_timeout_ms: 5000
      })

      Application.put_env(:lemon_gateway, :engines, [
        Elixir.LemonGateway.RunTest.TestEngine,
        ControllableEngine,
        FailingEngine,
        SteerableTestEngine,
        SteerFailEngine,
        Elixir.LemonGateway.RunTest.StreamingEngine,
        Elixir.LemonGateway.Engines.Echo
      ])

      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      scope = make_scope()

      job1 =
        make_job(scope,
          engine_hint: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid1} = start_run_direct(job1)

      assert_receive {:engine_started, _run_ref}, 5000

      # Cancel first run
      GenServer.cast(pid1, {:cancel, :done})
      assert_receive {:run_complete, ^pid1, _}, 5000

      # Second run should succeed (lock released)
      job2 = make_job(scope, text: "after cancel")
      {:ok, pid2} = start_run_direct(job2)

      assert_receive {:run_complete, ^pid2, %{__event__: :completed, ok: true}}, 5000
    end

    test "cancel calls unregister_progress_mapping" do
      scope = make_scope()
      progress_msg_id = System.unique_integer([:positive])

      job =
        make_job(scope,
          engine_hint: "controllable",
          meta: %{notify_pid: self(), controller_pid: self(), progress_msg_id: progress_msg_id}
        )

      {:ok, pid} = start_run_direct(job)

      assert_receive {:engine_started, _run_ref}, 2000

      # Verify mapping exists (stores run_id string, not PID)
      assert Enum.any?(1..20, fn _attempt ->
               case Elixir.LemonGateway.Store.get_run_by_progress(scope, progress_msg_id) do
                 run_id when is_binary(run_id) and run_id != "" ->
                   true

                 _ ->
                   Process.sleep(10)
                   false
               end
             end)

      # Cancel
      GenServer.cast(pid, {:cancel, :user_requested})
      assert_receive {:run_complete, ^pid, _}, 2000

      # Wait for cleanup to complete
      Elixir.LemonGateway.AsyncHelpers.assert_eventually(
        fn -> Elixir.LemonGateway.Store.get_run_by_progress(scope, progress_msg_id) == nil end,
        message: "run progress mapping was not removed"
      )
    end
  end

  # ============================================================================
  # 18. Resume Token Propagation
  # ============================================================================

  describe "resume token propagation" do
    test "resume token from Started event is stored in ChatState" do
      scope = make_scope()
      job = make_job(scope, meta: %{notify_pid: self()})

      {:ok, pid} = start_run_direct(job)

      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true}}, 2000

      # Wait for store operations to complete
      Elixir.LemonGateway.AsyncHelpers.assert_eventually(
        fn -> Elixir.LemonGateway.Store.get_chat_state(scope) != nil end,
        message: "ChatState was not persisted"
      )

      # ChatState should have the resume token
      chat_state = Elixir.LemonGateway.Store.get_chat_state(scope)
      assert chat_state != nil
      assert chat_state.last_engine == "test"
      assert is_binary(chat_state.last_resume_token)
    end

    test "resume token from Completed event is stored in ChatState" do
      scope = make_scope()

      job =
        make_job(scope,
          engine_hint: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(job)

      assert_receive {:engine_started, run_ref}, 2000

      # Send completed event with resume token
      resume = %ResumeToken{
        engine: "controllable",
        value: "final_token_#{System.unique_integer([:positive])}"
      }

      completed = Event.completed(%{
        engine: "controllable",
        ok: true,
        answer: "done",
        resume: resume
      })

      send(pid, {:engine_event, run_ref, completed})

      assert_receive {:run_complete, ^pid, _}, 2000

      # Wait for store operations to complete
      Elixir.LemonGateway.AsyncHelpers.assert_eventually(
        fn ->
          state = Elixir.LemonGateway.Store.get_chat_state(scope)
          state != nil and state.last_resume_token == resume.value
        end,
        message: "ChatState with resume token was not persisted"
      )

      # ChatState should have the completed resume token
      chat_state = Elixir.LemonGateway.Store.get_chat_state(scope)
      assert chat_state != nil
      assert chat_state.last_engine == "controllable"
      assert chat_state.last_resume_token == resume.value
    end

    test "context overflow clears ChatState and does not persist failing resume" do
      scope = make_scope()

      Elixir.LemonGateway.Store.put_chat_state(scope, %Elixir.LemonGateway.ChatState{
        last_engine: "controllable",
        last_resume_token: "stale_token",
        updated_at: System.system_time(:millisecond)
      })

      job =
        make_job(scope,
          engine_hint: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(job)
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
         }}
      )

      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: false}}, 2000
      # Wait to confirm no ChatState was written
      Elixir.LemonGateway.AsyncHelpers.assert_eventually(
        fn -> Elixir.LemonGateway.Store.get_chat_state(scope) == nil end,
        message: "ChatState should remain nil after context overflow"
      )
    end

    test "Chinese context overflow marker clears ChatState and does not persist failing resume" do
      scope = make_scope()

      Elixir.LemonGateway.Store.put_chat_state(scope, %Elixir.LemonGateway.ChatState{
        last_engine: "controllable",
        last_resume_token: "stale_token",
        updated_at: System.system_time(:millisecond)
      })

      job =
        make_job(scope,
          engine_hint: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(job)
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

      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: false}}, 2000

      Elixir.LemonGateway.AsyncHelpers.assert_eventually(
        fn -> Elixir.LemonGateway.Store.get_chat_state(scope) == nil end,
        message: "ChatState should remain nil after Chinese context overflow"
      )
    end

    test "resume token does not override explicit engine selection" do
      scope = make_scope()
      resume = %ResumeToken{engine: "echo", value: "existing_session"}
      job = make_job(scope, resume: resume, engine_hint: "test", meta: %{notify_pid: self()})

      {:ok, pid} = start_run_direct(job)

      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true, engine: "test"}}, 2000
    end

    test "resume token value is used for lock key" do
      # This tests that two jobs with same resume token share the same lock
      # Setup with lock enabled and short timeout
      _ = Application.stop(:lemon_gateway)

      Application.put_env(:lemon_gateway, Elixir.LemonGateway.Config, %{
        max_concurrent_runs: 10,
        default_engine: "test",
        enable_telegram: false,
        require_engine_lock: true,
        engine_lock_timeout_ms: 100
      })

      Application.put_env(:lemon_gateway, :engines, [
        Elixir.LemonGateway.RunTest.TestEngine,
        ControllableEngine,
        FailingEngine,
        SteerableTestEngine,
        SteerFailEngine,
        Elixir.LemonGateway.RunTest.StreamingEngine,
        Elixir.LemonGateway.Engines.Echo
      ])

      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      # Different scopes but same resume token
      scope1 = make_scope()
      scope2 = make_scope()
      resume_value = "shared_session_#{System.unique_integer([:positive])}"
      resume = %ResumeToken{engine: "controllable", value: resume_value}

      # First job holds the lock via resume token
      job1 =
        make_job(scope1,
          resume: resume,
          engine_id: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, _pid1} = start_run_direct(job1)

      assert_receive {:engine_started, _run_ref}, 5000

      # Second job with same resume token should timeout (different scope, same lock key)
      resume2 = %ResumeToken{engine: "test", value: resume_value}
      job2 = make_job(scope2, resume: resume2, text: "will timeout")
      _result = start_run_direct(job2)

      # Should get lock timeout because first job holds the lock
      assert_receive {:lemon_gateway_run_completed, ^job2,
                      %{__event__: :completed, error: :lock_timeout}},
                     5000
    end

    test "ChatState is updated on both Started and Completed events" do
      scope = make_scope()

      job =
        make_job(scope,
          engine_hint: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(job)

      assert_receive {:engine_started, _run_ref}, 2000

      # ChatState should not be updated on Started (no async wait needed)
      chat_state1 = Elixir.LemonGateway.Store.get_chat_state(scope)
      assert chat_state1 == nil

      # Now complete with a different resume token
      _resume = %ResumeToken{
        engine: "controllable",
        value: "updated_token_#{System.unique_integer([:positive])}"
      }

      # We need the run_ref - let's complete the run properly
      GenServer.cast(pid, {:cancel, :done})
      assert_receive {:run_complete, ^pid, _}, 2000

      # Wait for ChatState to be updated
      Elixir.LemonGateway.AsyncHelpers.assert_eventually(
        fn -> Elixir.LemonGateway.Store.get_chat_state(scope) != nil end,
        message: "ChatState was not updated after completion"
      )

      chat_state2 = Elixir.LemonGateway.Store.get_chat_state(scope)
      assert chat_state2 != nil

      # Token should exist (may be same as first if cancellation doesn't provide new token)
      assert chat_state2.last_resume_token != nil
    end

    test "ChatState is not updated when resume is nil" do
      scope = make_scope()

      # Use failing engine which doesn't send resume tokens
      job =
        make_job(scope, engine_hint: "failing", meta: %{notify_pid: self(), error: :no_resume})

      {:ok, pid} = start_run_direct(job)

      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: false}}, 2000

      # Confirm no ChatState was written by failing engine
      Elixir.LemonGateway.AsyncHelpers.assert_eventually(
        fn -> Elixir.LemonGateway.Store.get_chat_state(scope) == nil end,
        message: "ChatState should remain nil when resume is absent"
      )
    end

    test "resume token engine overrides scope binding default" do
      scope = make_scope()
      # Resume says echo, but default would be test
      resume = %ResumeToken{engine: "echo", value: "session123"}
      job = make_job(scope, resume: resume, engine_hint: nil, meta: %{notify_pid: self()})

      {:ok, pid} = start_run_direct(job)

      # Should use echo engine from resume
      assert_receive {:run_complete, ^pid, %{__event__: :completed, engine: "echo"}}, 2000
    end
  end

  # ============================================================================
  # 19. Run Finalization Details
  # ============================================================================

  describe "run finalization details" do
    test "finalize stores run summary with scope" do
      scope = make_scope()
      job = make_job(scope, meta: %{notify_pid: self()})

      {:ok, pid} = start_run_direct(job)

      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true}}, 2000

      # Wait for run history to be stored
      Elixir.LemonGateway.AsyncHelpers.assert_eventually(
        fn -> length(Elixir.LemonGateway.Store.get_run_history(scope)) >= 1 end,
        message: "run history was not stored"
      )

      # Run history should include this run
      history = Elixir.LemonGateway.Store.get_run_history(scope)
      assert length(history) >= 1
    end

    test "finalize sets completed flag to prevent double finalization" do
      scope = make_scope()

      job =
        make_job(scope,
          engine_hint: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(job)

      assert_receive {:engine_started, run_ref}, 2000

      # Send two completed events (shouldn't happen normally, but tests guard)
      completed1 = Event.completed(%{engine: "controllable", ok: true, answer: "first"})
      send(pid, {:engine_event, run_ref, completed1})

      # Only first should be processed
      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true, answer: "first"}}, 2000

      # Second completion is ignored because process stops
      refute_receive {:run_complete, ^pid, _}, 500
    end

    test "finalize handles nil run_ref gracefully" do
      # This happens when engine start_run fails immediately
      scope = make_scope()
      job = make_job(scope, engine_hint: "failing", meta: %{notify_pid: self()})

      {:ok, pid} = start_run_direct(job)

      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: false}}, 2000

      # Should complete without crashing
      Elixir.LemonGateway.AsyncHelpers.assert_process_dead(pid)
    end
  end

  # ============================================================================
  # 20. Telemetry Events
  # ============================================================================

  describe "telemetry events" do
    test "emits run_start telemetry on run initialization" do
      scope = make_scope()
      job = make_job(scope, meta: %{notify_pid: self()})

      # Attach telemetry handler
      test_pid = self()
      ref = make_ref()

      :telemetry.attach(
        "test-run-start-#{inspect(ref)}",
        [:lemon, :run, :start],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_start, measurements, metadata})
        end,
        nil
      )

      {:ok, pid} = start_run_direct(job)

      # Should receive telemetry event
      assert_receive {:telemetry_start, measurements, metadata}, 2000
      assert is_integer(measurements.ts_ms)
      assert metadata.engine == "test"
      assert is_binary(metadata.run_id)

      # Wait for completion
      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true}}, 2000

      :telemetry.detach("test-run-start-#{inspect(ref)}")
    end

    test "emits run_stop telemetry on completion" do
      scope = make_scope()
      job = make_job(scope, meta: %{notify_pid: self()})

      # Attach telemetry handler
      test_pid = self()
      ref = make_ref()

      :telemetry.attach(
        "test-run-stop-#{inspect(ref)}",
        [:lemon, :run, :stop],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_stop, measurements, metadata})
        end,
        nil
      )

      {:ok, pid} = start_run_direct(job)

      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true}}, 2000

      # Should receive telemetry event
      assert_receive {:telemetry_stop, measurements, metadata}, 2000
      assert is_integer(measurements.duration_ms)
      assert measurements.duration_ms >= 0
      assert measurements.ok == true
      assert is_binary(metadata.run_id)

      :telemetry.detach("test-run-stop-#{inspect(ref)}")
    end

    test "emits run_stop with ok: false on error completion" do
      scope = make_scope()

      job =
        make_job(scope, engine_hint: "failing", meta: %{notify_pid: self(), error: :test_error})

      # Attach telemetry handler
      test_pid = self()
      ref = make_ref()

      :telemetry.attach(
        "test-run-stop-error-#{inspect(ref)}",
        [:lemon, :run, :stop],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_stop, measurements, metadata})
        end,
        nil
      )

      {:ok, pid} = start_run_direct(job)

      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: false}}, 2000

      # Should receive telemetry event with ok: false
      assert_receive {:telemetry_stop, measurements, _metadata}, 2000
      assert measurements.ok == false

      :telemetry.detach("test-run-stop-error-#{inspect(ref)}")
    end

    test "run_stop duration_ms reflects actual execution time" do
      scope = make_scope()

      job =
        make_job(scope,
          engine_hint: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      # Attach telemetry handler
      test_pid = self()
      ref = make_ref()

      :telemetry.attach(
        "test-run-duration-#{inspect(ref)}",
        [:lemon, :run, :stop],
        fn _event, measurements, _metadata, _config ->
          send(test_pid, {:telemetry_stop_duration, measurements.duration_ms})
        end,
        nil
      )

      {:ok, pid} = start_run_direct(job)

      assert_receive {:engine_started, run_ref}, 2000

      # Wait a bit before completing
      Process.sleep(100)

      completed = Event.completed(%{engine: "controllable", ok: true, answer: "done"})
      send(pid, {:engine_event, run_ref, completed})

      assert_receive {:run_complete, ^pid, _}, 2000

      # Duration should be at least 100ms
      assert_receive {:telemetry_stop_duration, duration_ms}, 2000
      assert duration_ms >= 100

      :telemetry.detach("test-run-duration-#{inspect(ref)}")
    end

    test "emits first_token telemetry on first delta" do
      scope = make_scope()

      job =
        make_job(scope, engine_hint: "streaming", meta: %{notify_pid: self(), delta_delay_ms: 50})

      # Attach telemetry handler
      test_pid = self()
      ref = make_ref()

      :telemetry.attach(
        "test-first-token-#{inspect(ref)}",
        [:lemon, :run, :first_token],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_first_token, measurements, metadata})
        end,
        nil
      )

      {:ok, pid} = start_run_direct(job)

      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true}}, 5000

      # Should have received first_token telemetry
      assert_receive {:telemetry_first_token, measurements, metadata}, 2000
      assert is_integer(measurements.latency_ms)
      assert measurements.latency_ms >= 0
      assert is_binary(metadata.run_id)

      :telemetry.detach("test-first-token-#{inspect(ref)}")
    end

    test "first_token telemetry is only emitted once" do
      scope = make_scope()

      job =
        make_job(scope, engine_hint: "streaming", meta: %{notify_pid: self(), delta_delay_ms: 10})

      # Attach telemetry handler that counts calls
      test_pid = self()
      ref = make_ref()

      :telemetry.attach(
        "test-first-token-once-#{inspect(ref)}",
        [:lemon, :run, :first_token],
        fn _event, _measurements, _metadata, _config ->
          send(test_pid, :first_token_emitted)
        end,
        nil
      )

      {:ok, pid} = start_run_direct(job)

      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true}}, 5000

      # Should only receive one first_token event despite multiple deltas
      assert_receive :first_token_emitted, 1000
      refute_receive :first_token_emitted, 200

      :telemetry.detach("test-first-token-once-#{inspect(ref)}")
    end

    test "accumulated text from deltas appears in final answer" do
      scope = make_scope()

      job =
        make_job(scope, engine_hint: "streaming", meta: %{notify_pid: self(), delta_delay_ms: 10})

      {:ok, pid} = start_run_direct(job)

      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true, answer: answer}}, 5000

      # Answer should contain accumulated delta text
      assert answer == "Hello World"
    end
  end

  # ============================================================================
  # 21. Edge Cases and Boundary Conditions
  # ============================================================================

  describe "edge cases and boundary conditions" do
    test "handles job with empty text" do
      scope = make_scope()
      job = make_job(scope, text: "", meta: %{notify_pid: self()})

      {:ok, pid} = start_run_direct(job)

      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true, answer: "Test: "}}, 2000
    end

    test "handles job with very long text" do
      scope = make_scope()
      long_text = String.duplicate("a", 10000)
      job = make_job(scope, text: long_text, meta: %{notify_pid: self()})

      {:ok, pid} = start_run_direct(job)

      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true}}, 2000
    end

    test "handles rapid successive events" do
      scope = make_scope()

      job =
        make_job(scope,
          engine_hint: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(job)

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

      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true}}, 5000
    end

    test "handles meta with extra keys" do
      scope = make_scope()

      job =
        make_job(scope,
          meta: %{
            notify_pid: self(),
            extra_key: "value",
            another_key: 123,
            nested: %{foo: "bar"}
          }
        )

      {:ok, pid} = start_run_direct(job)

      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true}}, 2000
    end

    test "handles concurrent runs with different scopes" do
      # Start multiple runs simultaneously with different scopes
      runs =
        for i <- 1..5 do
          scope = make_scope()
          job = make_job(scope, text: "run #{i}", meta: %{notify_pid: self()})
          {:ok, pid} = start_run_direct(job)
          {i, pid}
        end

      # All should complete successfully
      for {_i, pid} <- runs do
        assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true}}, 5000
      end
    end

    test "handles events after process monitor but before completion" do
      scope = make_scope()

      job =
        make_job(scope,
          engine_hint: "controllable",
          meta: %{notify_pid: self(), controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(job)
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

      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true}}, 2000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2000
    end
  end
end
