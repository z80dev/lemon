defmodule LemonGateway.IntrospectionTest do
  @moduledoc """
  Tests that verify introspection events are emitted by lemon_gateway components
  through real code paths — submitting jobs through the Scheduler and ThreadWorker
  and asserting on `LemonCore.Introspection.list/1` results.
  """
  use ExUnit.Case, async: false

  alias LemonCore.Introspection
  alias LemonGateway.Scheduler
  alias LemonGateway.Types.Job

  @run_timeout 60_000
  @poll_interval 200

  setup do
    original = Application.get_env(:lemon_core, :introspection, [])
    Application.put_env(:lemon_core, :introspection, Keyword.put(original, :enabled, true))
    on_exit(fn -> Application.put_env(:lemon_core, :introspection, original) end)

    # Some gateway tests stop/restart application components; ensure scheduler exists
    # so Scheduler.submit/1 actually routes jobs during this test.
    {:ok, _} = Application.ensure_all_started(:lemon_gateway)
    assert Process.whereis(Scheduler) != nil

    :ok
  end

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

      job = %Job{
        run_id: run_id,
        session_key: session_key,
        prompt: "introspection thread worker test",
        engine_id: "echo",
        queue_mode: :collect,
        meta: %{origin: :test, notify_pid: self()}
      }

      # Submit through the real Scheduler, which creates a ThreadWorker and
      # enqueues the job. The Echo engine will complete quickly.
      LemonGateway.Scheduler.submit(job)

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

      assert length(thread_started) >= 1
      [ts_evt | _] = thread_started
      assert ts_evt.engine == "lemon"

      # Verify thread_message_dispatched was emitted when the job was enqueued
      dispatched_events =
        Introspection.list(run_id: run_id, limit: 20)
        |> Enum.filter(&(&1.event_type == :thread_message_dispatched))

      assert length(dispatched_events) >= 1
      [disp_evt | _] = dispatched_events
      assert disp_evt.engine == "lemon"
      assert disp_evt.payload.queue_mode == :collect
      assert is_integer(disp_evt.payload.queue_len)
      assert disp_evt.session_key == session_key
    end

    test "thread_terminated event is emitted when ThreadWorker shuts down" do
      token = unique_token()
      session_key = "agent:gw_introspection_term:#{token}:main"

      job = %Job{
        run_id: "introspect_term_#{token}",
        session_key: session_key,
        prompt: "introspection terminate test",
        engine_id: "echo",
        queue_mode: :collect,
        meta: %{origin: :test, notify_pid: self()}
      }

      LemonGateway.Scheduler.submit(job)

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

      assert length(terminated) >= 1
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

      job = %Job{
        run_id: run_id,
        session_key: session_key,
        prompt: "introspection scheduler test",
        engine_id: "echo",
        queue_mode: :collect,
        meta: %{origin: :test, notify_pid: self()}
      }

      LemonGateway.Scheduler.submit(job)

      wait_for(fn ->
        Introspection.list(run_id: run_id, limit: 20)
        |> Enum.any?(&(&1.event_type == :scheduled_job_triggered))
      end)

      events = Introspection.list(run_id: run_id, limit: 20)
      triggered = Enum.filter(events, &(&1.event_type == :scheduled_job_triggered))

      assert length(triggered) >= 1
      [evt | _] = triggered
      assert evt.engine == "lemon"
      assert evt.payload.queue_mode == :collect
      assert evt.payload.engine_id == "echo"
      assert is_binary(evt.payload.thread_key)
    end

    test "scheduled_job_completed event is emitted when slot is released" do
      token = unique_token()
      run_id = "introspect_sched_done_#{token}"
      session_key = "agent:gw_introspection_done:#{token}:main"
      submitted_at = System.system_time(:millisecond)

      job = %Job{
        run_id: run_id,
        session_key: session_key,
        prompt: "introspection scheduler complete test",
        engine_id: "echo",
        queue_mode: :collect,
        meta: %{origin: :test, notify_pid: self()}
      }

      LemonGateway.Scheduler.submit(job)

      # Wait for a scheduler completion event after this submission timestamp.
      wait_for(fn ->
        Introspection.list(limit: 200)
        |> Enum.any?(fn evt ->
          evt.event_type == :scheduled_job_completed and
            evt.ts_ms >= submitted_at and
            is_integer(evt.payload.in_flight) and
            is_integer(evt.payload.max)
        end)
      end)

      # scheduled_job_completed doesn't carry run_id (it's a scheduler-level event),
      # so search broadly and look for recent events
      all_events = Introspection.list(limit: 200)

      completed =
        Enum.filter(all_events, fn evt ->
          evt.event_type == :scheduled_job_completed and
            evt.ts_ms >= submitted_at and
            is_integer(evt.payload.in_flight) and
            is_integer(evt.payload.max)
        end)

      assert length(completed) >= 1
      [evt | _] = completed
      assert evt.engine == "lemon"
    end
  end
end
