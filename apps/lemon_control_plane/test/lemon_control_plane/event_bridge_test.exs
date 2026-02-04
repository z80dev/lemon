defmodule LemonControlPlane.EventBridgeTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.EventBridge

  setup do
    # Start EventBridge if not running
    case Process.whereis(EventBridge) do
      nil ->
        {:ok, pid} = EventBridge.start_link([])
        on_exit(fn ->
          if Process.alive?(pid), do: GenServer.stop(pid)
        end)
        {:ok, bridge_pid: pid}

      pid ->
        {:ok, bridge_pid: pid}
    end
  end

  describe "subscribe_run/1" do
    test "subscribes to run topic" do
      run_id = "run_#{System.unique_integer()}"

      # Should not raise
      assert :ok = EventBridge.subscribe_run(run_id)
    end
  end

  describe "unsubscribe_run/1" do
    test "unsubscribes from run topic" do
      run_id = "run_#{System.unique_integer()}"

      EventBridge.subscribe_run(run_id)
      assert :ok = EventBridge.unsubscribe_run(run_id)
    end
  end

  describe "event forwarding" do
    test "processes run_started events" do
      run_id = "run_#{System.unique_integer()}"

      # Subscribe to the run
      EventBridge.subscribe_run(run_id)
      Process.sleep(10)

      # The EventBridge should be subscribed to run:run_id topic now
      # Events broadcast to that topic should be processed
      if Code.ensure_loaded?(LemonCore.Bus) do
        event = LemonCore.Event.new(
          :run_started,
          %{run_id: run_id, session_key: "test", engine: "lemon"},
          %{run_id: run_id, session_key: "test"}
        )

        # This won't deliver to us directly (we're not in Presence)
        # but it should not crash the EventBridge
        LemonCore.Bus.broadcast("run:#{run_id}", event)

        # Give time for processing
        Process.sleep(50)

        # EventBridge should still be alive
        assert Process.alive?(Process.whereis(EventBridge))
      end

      EventBridge.unsubscribe_run(run_id)
    end

    test "processes delta events" do
      run_id = "run_#{System.unique_integer()}"

      EventBridge.subscribe_run(run_id)
      Process.sleep(10)

      if Code.ensure_loaded?(LemonCore.Bus) do
        delta = LemonGateway.Event.Delta.new(run_id, 1, "Hello")

        event = LemonCore.Event.new(:delta, delta, %{run_id: run_id, session_key: "test"})
        LemonCore.Bus.broadcast("run:#{run_id}", event)

        Process.sleep(50)

        # EventBridge should still be alive (didn't crash on the event)
        assert Process.alive?(Process.whereis(EventBridge))
      end

      EventBridge.unsubscribe_run(run_id)
    end

    test "processes run_completed events" do
      run_id = "run_#{System.unique_integer()}"

      EventBridge.subscribe_run(run_id)
      Process.sleep(10)

      if Code.ensure_loaded?(LemonCore.Bus) do
        event = LemonCore.Event.new(
          :run_completed,
          %{completed: %{ok: true, answer: "Done"}, duration_ms: 100},
          %{run_id: run_id, session_key: "test"}
        )

        LemonCore.Bus.broadcast("run:#{run_id}", event)

        Process.sleep(50)
        assert Process.alive?(Process.whereis(EventBridge))
      end

      EventBridge.unsubscribe_run(run_id)
    end
  end

  describe "static topic subscriptions" do
    test "subscribes to exec_approvals topic on init" do
      # EventBridge should be subscribed to exec_approvals
      if Code.ensure_loaded?(LemonCore.Bus) do
        event = LemonCore.Event.new(
          :approval_requested,
          %{pending: %{id: "approval-1", run_id: "run-1", tool: "bash", rationale: "test"}},
          %{}
        )

        LemonCore.Bus.broadcast("exec_approvals", event)

        Process.sleep(50)
        assert Process.alive?(Process.whereis(EventBridge))
      end
    end

    test "subscribes to cron topic on init" do
      if Code.ensure_loaded?(LemonCore.Bus) do
        event = LemonCore.Event.new(
          :cron_run_started,
          %{run: %{id: "cron-run-1", job_id: "job-1"}, job: %{name: "test job"}},
          %{}
        )

        LemonCore.Bus.broadcast("cron", event)

        Process.sleep(50)
        assert Process.alive?(Process.whereis(EventBridge))
      end
    end
  end
end
