defmodule LemonGateway.IntrospectionTest do
  @moduledoc """
  Tests that verify introspection events are emitted by lemon_gateway components
  through real code paths — submitting jobs through the Scheduler and ThreadWorker
  and asserting on `LemonCore.Introspection.list/1` results.
  """
  use ExUnit.Case, async: false

  alias LemonCore.Introspection
  alias LemonGateway.Types.Job

  setup do
    original = Application.get_env(:lemon_core, :introspection, [])
    Application.put_env(:lemon_core, :introspection, Keyword.put(original, :enabled, true))
    on_exit(fn -> Application.put_env(:lemon_core, :introspection, original) end)
    :ok
  end

  defp unique_token, do: System.unique_integer([:positive, :monotonic])

  # ============================================================================
  # ThreadWorker introspection tests
  # ============================================================================

  describe "ThreadWorker introspection events" do
    test "thread_started and thread_message_dispatched events are emitted on job submission" do
      token = unique_token()
      session_key = "agent:gw_introspection_tw:#{token}:main"

      job = %Job{
        run_id: "introspect_tw_#{token}",
        session_key: session_key,
        prompt: "introspection thread worker test",
        engine_id: "echo",
        queue_mode: :collect,
        meta: %{origin: :test, notify_pid: self()}
      }

      # Submit through the real Scheduler, which creates a ThreadWorker and
      # enqueues the job. The Echo engine will complete quickly.
      LemonGateway.Scheduler.submit(job)

      # Wait for the run to complete (echo engine is fast)
      assert_receive {:lemon_gateway_run_completed, ^job, _completed}, 5000

      # Allow introspection events to settle
      Process.sleep(200)

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
        Introspection.list(run_id: "introspect_tw_#{token}", limit: 20)
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

      # Wait for run to complete — the ThreadWorker exits when idle
      assert_receive {:lemon_gateway_run_completed, ^job, _completed}, 5000

      # ThreadWorker exits after queue drains; give it time to terminate
      Process.sleep(500)

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

      # Wait for run to complete
      assert_receive {:lemon_gateway_run_completed, ^job, _completed}, 5000

      Process.sleep(100)

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

      job = %Job{
        run_id: run_id,
        session_key: session_key,
        prompt: "introspection scheduler complete test",
        engine_id: "echo",
        queue_mode: :collect,
        meta: %{origin: :test, notify_pid: self()}
      }

      LemonGateway.Scheduler.submit(job)

      # Wait for run to complete so the slot gets released
      assert_receive {:lemon_gateway_run_completed, ^job, _completed}, 5000

      # Allow slot release to propagate
      Process.sleep(200)

      # scheduled_job_completed doesn't carry run_id (it's a scheduler-level event),
      # so search broadly and look for recent events
      all_events = Introspection.list(limit: 200)

      completed =
        Enum.filter(all_events, fn evt ->
          evt.event_type == :scheduled_job_completed and
            is_integer(evt.payload.in_flight) and
            is_integer(evt.payload.max)
        end)

      assert length(completed) >= 1
      [evt | _] = completed
      assert evt.engine == "lemon"
    end
  end
end
