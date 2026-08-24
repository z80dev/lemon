defmodule LemonGateway.IntrospectionTest do
  @moduledoc """
  Tests that verify introspection events are emitted by lemon_gateway components
  through real code paths — submitting jobs through the Scheduler and ThreadWorker
  and asserting on `LemonCore.Introspection.list/1` results.
  """
  use ExUnit.Case, async: false

  alias LemonCore.Introspection
  alias LemonGateway.ExecutionRequest

  defmodule IntrospectionFixtureExecutor do
    @behaviour LemonGateway.Executor

    alias LemonCore.ResumeToken
    alias LemonGateway.Event
    alias LemonGateway.ExecutionRequest

    @impl true
    def start_run(%ExecutionRequest{} = request, _opts, sink_pid) do
      run_ref = make_ref()
      resume = request.resume || %ResumeToken{engine: "lemon", value: unique_id()}

      {:ok, task_pid} =
        Task.start(fn ->
          send(
            sink_pid,
            {:engine_event, run_ref, Event.started(%{engine: "lemon", resume: resume})}
          )

          send(
            sink_pid,
            {:engine_event, run_ref,
             Event.completed(%{
               engine: "lemon",
               resume: resume,
               ok: true,
               answer: "Test: #{request.prompt}"
             })}
          )
        end)

      {:ok, run_ref, %{task_pid: task_pid}}
    end

    @impl true
    def cancel(%{task_pid: pid}) when is_pid(pid) do
      Process.exit(pid, :kill)
      :ok
    end

    def cancel(_context), do: :ok

    @impl true
    def steer(_context, _text), do: {:error, :unsupported}

    @impl true
    def redirect(_context, _text), do: {:error, :unsupported}

    defp unique_id, do: Integer.to_string(System.unique_integer([:positive]))
  end

  @run_timeout 20_000
  @poll_interval 100

  setup do
    original = Application.get_env(:lemon_core, :introspection, [])
    original_config = Application.get_env(:lemon_gateway, LemonGateway.Config)
    original_executor = Application.get_env(:lemon_gateway, :executor)
    original_transports = Application.get_env(:lemon_gateway, :transports)
    original_commands = Application.get_env(:lemon_gateway, :commands)

    Application.put_env(:lemon_core, :introspection, Keyword.put(original, :enabled, true))

    _ = Application.stop(:lemon_gateway)

    Application.put_env(:lemon_gateway, LemonGateway.Config, %{
      max_concurrent_runs: 1
    })

    Application.put_env(:lemon_gateway, :executor, IntrospectionFixtureExecutor)
    Application.put_env(:lemon_gateway, :transports, [])
    Application.put_env(:lemon_gateway, :commands, [])

    {:ok, _} = Application.ensure_all_started(:lemon_gateway)

    on_exit(fn ->
      Application.stop(:lemon_gateway)
      Application.put_env(:lemon_core, :introspection, original)
      restore_env(LemonGateway.Config, original_config)
      restore_env(:executor, original_executor)
      restore_env(:transports, original_transports)
      restore_env(:commands, original_commands)
      Application.ensure_all_started(:lemon_gateway)
    end)

    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:lemon_gateway, key)
  defp restore_env(key, value), do: Application.put_env(:lemon_gateway, key, value)

  defp unique_token, do: System.unique_integer([:positive, :monotonic])

  defp wait_for(fun, timeout_ms \\ @run_timeout) when is_function(fun, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for(fun, deadline)
  end

  defp do_wait_for(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("timed out waiting for introspection condition")

      true ->
        Process.sleep(@poll_interval)
        do_wait_for(fun, deadline)
    end
  end

  # ============================================================================
  # ThreadWorker introspection tests
  # ============================================================================

  describe "ThreadWorker introspection events" do
    test "thread_started and thread_message_dispatched events are emitted on job submission" do
      token = unique_token()
      run_id = "introspect_tw_#{token}"
      session_key = "agent:gw_introspection_tw:#{token}:main"

      request = %ExecutionRequest{
        run_id: run_id,
        session_key: session_key,
        prompt: "introspection thread worker test",
        conversation_key: {:session, session_key},
        meta: %{origin: :test, notify_pid: self()}
      }

      # Submit through the real Scheduler, which creates a ThreadWorker and
      # enqueues the request. The configured executor completes quickly.
      LemonGateway.Scheduler.submit_execution(request)

      # Wait until the dispatcher event for this run is persisted.
      wait_for(fn ->
        Introspection.list(run_id: run_id, limit: 20)
        |> Enum.any?(&(&1.event_type == :thread_message_dispatched))
      end)

      # Verify thread_started was emitted when the ThreadWorker was created
      # We search broadly since the ThreadWorker doesn't get run_id/session_key in init
      all_events = Introspection.list(limit: 100)

      thread_started =
        Enum.filter(all_events, fn evt ->
          evt.event_type == :thread_started and
            is_binary(evt.payload.thread_key) and
            String.contains?(evt.payload.thread_key, session_key)
        end)

      assert thread_started != []
      [ts_evt | _] = thread_started
      assert ts_evt.engine == "lemon"

      # Verify thread_message_dispatched was emitted when the job was enqueued
      dispatched_events =
        Introspection.list(run_id: run_id, limit: 20)
        |> Enum.filter(&(&1.event_type == :thread_message_dispatched))

      assert dispatched_events != []
      [disp_evt | _] = dispatched_events
      assert disp_evt.engine == "lemon"
      assert is_integer(disp_evt.payload.queue_len)
      assert disp_evt.session_key == session_key
    end

    test "thread_terminated event is emitted when ThreadWorker shuts down" do
      token = unique_token()
      session_key = "agent:gw_introspection_term:#{token}:main"

      request = %ExecutionRequest{
        run_id: "introspect_term_#{token}",
        session_key: session_key,
        prompt: "introspection terminate test",
        conversation_key: {:session, session_key},
        meta: %{origin: :test, notify_pid: self()}
      }

      LemonGateway.Scheduler.submit_execution(request)

      # Wait for thread termination event for this worker key.
      wait_for(fn ->
        Introspection.list(limit: 200)
        |> Enum.any?(fn evt ->
          evt.event_type == :thread_terminated and
            is_binary(evt.payload.thread_key) and
            String.contains?(evt.payload.thread_key, session_key)
        end)
      end)

      all_events = Introspection.list(limit: 200)

      terminated =
        Enum.filter(all_events, fn evt ->
          evt.event_type == :thread_terminated and
            is_binary(evt.payload.thread_key) and
            String.contains?(evt.payload.thread_key, session_key)
        end)

      assert terminated != []
      [term_evt | _] = terminated
      assert term_evt.engine == "lemon"
      assert is_integer(term_evt.payload.queue_len)
    end
  end

  # ============================================================================
  # Scheduler introspection tests
  # ============================================================================

  describe "Scheduler introspection events" do
    test "scheduled_job_triggered event is emitted on job submission" do
      token = unique_token()
      run_id = "introspect_sched_#{token}"
      session_key = "agent:gw_introspection_sched:#{token}:main"

      request = %ExecutionRequest{
        run_id: run_id,
        session_key: session_key,
        prompt: "introspection scheduler test",
        conversation_key: {:session, session_key},
        meta: %{origin: :test, notify_pid: self()}
      }

      LemonGateway.Scheduler.submit_execution(request)

      wait_for(fn ->
        Introspection.list(run_id: run_id, limit: 20)
        |> Enum.any?(&(&1.event_type == :scheduled_job_triggered))
      end)

      events = Introspection.list(run_id: run_id, limit: 20)
      triggered = Enum.filter(events, &(&1.event_type == :scheduled_job_triggered))

      assert triggered != []
      [evt | _] = triggered
      assert evt.engine == "lemon"
      assert is_binary(evt.payload.thread_key)
    end

    test "scheduled_job_completed event is emitted when slot is released" do
      token = unique_token()
      run_id = "introspect_sched_done_#{token}"
      session_key = "agent:gw_introspection_done:#{token}:main"
      expected_thread_key = "{:session, #{inspect(session_key)}}"

      request = %ExecutionRequest{
        run_id: run_id,
        session_key: session_key,
        prompt: "introspection scheduler complete test",
        conversation_key: {:session, session_key},
        meta: %{origin: :test, notify_pid: self()}
      }

      LemonGateway.Scheduler.submit_execution(request)

      wait_for(fn ->
        Introspection.list(limit: 200)
        |> Enum.any?(fn evt ->
          evt.event_type == :scheduled_job_completed and
            evt.payload.thread_key == expected_thread_key and
            is_integer(evt.payload.in_flight) and
            is_integer(evt.payload.max)
        end)
      end)

      all_events = Introspection.list(limit: 200)

      completed =
        Enum.filter(all_events, fn evt ->
          evt.event_type == :scheduled_job_completed and
            evt.payload.thread_key == expected_thread_key and
            is_integer(evt.payload.in_flight) and
            is_integer(evt.payload.max)
        end)

      assert completed != []
      [evt | _] = completed
      assert evt.engine == "lemon"
    end
  end
end
