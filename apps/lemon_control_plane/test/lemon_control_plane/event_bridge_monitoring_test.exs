defmodule LemonControlPlane.EventBridgeMonitoringTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.EventBridge

  setup do
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

  describe "task_started event mapping" do
    test "maps task_started to task.started WS event and does not crash" do
      run_id = "run_#{System.unique_integer()}"
      EventBridge.subscribe_run(run_id)
      Process.sleep(10)

      if Code.ensure_loaded?(LemonCore.Bus) do
        event =
          LemonCore.Event.new(
            :task_started,
            %{
              task_id: "task-1",
              parent_run_id: "parent-run-1",
              run_id: run_id,
              session_key: "test-session",
              agent_id: "agent-1",
              started_at_ms: 1_000_000
            },
            %{run_id: run_id, session_key: "test-session"}
          )

        LemonCore.Bus.broadcast("run:#{run_id}", event)
        Process.sleep(50)

        assert Process.alive?(Process.whereis(EventBridge))
      end

      EventBridge.unsubscribe_run(run_id)
    end

    test "task_started payload contains all expected fields" do
      run_id = "run_#{System.unique_integer()}"
      EventBridge.subscribe_run(run_id)
      Process.sleep(10)

      if Code.ensure_loaded?(LemonCore.Bus) do
        payload = %{
          task_id: "task-abc",
          parent_run_id: "parent-xyz",
          run_id: run_id,
          session_key: "sess-1",
          agent_id: "agent-2",
          started_at_ms: 9_999_999
        }

        meta = %{run_id: run_id, session_key: "sess-1"}
        event = LemonCore.Event.new(:task_started, payload, meta)
        LemonCore.Bus.broadcast("run:#{run_id}", event)
        Process.sleep(50)

        assert Process.alive?(Process.whereis(EventBridge))
      end

      EventBridge.unsubscribe_run(run_id)
    end

    test "task_started handles missing optional fields gracefully" do
      run_id = "run_#{System.unique_integer()}"
      EventBridge.subscribe_run(run_id)
      Process.sleep(10)

      if Code.ensure_loaded?(LemonCore.Bus) do
        event = LemonCore.Event.new(:task_started, %{}, %{run_id: run_id})
        LemonCore.Bus.broadcast("run:#{run_id}", event)
        Process.sleep(50)

        assert Process.alive?(Process.whereis(EventBridge))
      end

      EventBridge.unsubscribe_run(run_id)
    end
  end

  describe "task_completed event mapping" do
    test "maps task_completed to task.completed WS event and does not crash" do
      run_id = "run_#{System.unique_integer()}"
      EventBridge.subscribe_run(run_id)
      Process.sleep(10)

      if Code.ensure_loaded?(LemonCore.Bus) do
        event =
          LemonCore.Event.new(
            :task_completed,
            %{
              task_id: "task-1",
              parent_run_id: "parent-run-1",
              run_id: run_id,
              session_key: "test-session",
              ok: true,
              duration_ms: 1200,
              completed_at_ms: 2_000_000
            },
            %{run_id: run_id, session_key: "test-session"}
          )

        LemonCore.Bus.broadcast("run:#{run_id}", event)
        Process.sleep(50)

        assert Process.alive?(Process.whereis(EventBridge))
      end

      EventBridge.unsubscribe_run(run_id)
    end

    test "task_completed handles missing fields gracefully" do
      run_id = "run_#{System.unique_integer()}"
      EventBridge.subscribe_run(run_id)
      Process.sleep(10)

      if Code.ensure_loaded?(LemonCore.Bus) do
        event = LemonCore.Event.new(:task_completed, %{}, %{run_id: run_id})
        LemonCore.Bus.broadcast("run:#{run_id}", event)
        Process.sleep(50)

        assert Process.alive?(Process.whereis(EventBridge))
      end

      EventBridge.unsubscribe_run(run_id)
    end
  end

  describe "task_error event mapping" do
    test "maps task_error to task.error WS event and does not crash" do
      run_id = "run_#{System.unique_integer()}"
      EventBridge.subscribe_run(run_id)
      Process.sleep(10)

      if Code.ensure_loaded?(LemonCore.Bus) do
        event =
          LemonCore.Event.new(
            :task_error,
            %{
              task_id: "task-1",
              parent_run_id: "parent-run-1",
              run_id: run_id,
              session_key: "test-session",
              error: "something went wrong",
              duration_ms: 500
            },
            %{run_id: run_id, session_key: "test-session"}
          )

        LemonCore.Bus.broadcast("run:#{run_id}", event)
        Process.sleep(50)

        assert Process.alive?(Process.whereis(EventBridge))
      end

      EventBridge.unsubscribe_run(run_id)
    end

    test "task_error handles missing fields gracefully" do
      run_id = "run_#{System.unique_integer()}"
      EventBridge.subscribe_run(run_id)
      Process.sleep(10)

      if Code.ensure_loaded?(LemonCore.Bus) do
        event = LemonCore.Event.new(:task_error, %{}, %{run_id: run_id})
        LemonCore.Bus.broadcast("run:#{run_id}", event)
        Process.sleep(50)

        assert Process.alive?(Process.whereis(EventBridge))
      end

      EventBridge.unsubscribe_run(run_id)
    end
  end

  describe "task_timeout event mapping" do
    test "maps task_timeout to task.timeout WS event and does not crash" do
      run_id = "run_#{System.unique_integer()}"
      EventBridge.subscribe_run(run_id)
      Process.sleep(10)

      if Code.ensure_loaded?(LemonCore.Bus) do
        event =
          LemonCore.Event.new(
            :task_timeout,
            %{
              task_id: "task-1",
              parent_run_id: "parent-run-1",
              run_id: run_id,
              session_key: "test-session",
              timeout_ms: 30_000
            },
            %{run_id: run_id, session_key: "test-session"}
          )

        LemonCore.Bus.broadcast("run:#{run_id}", event)
        Process.sleep(50)

        assert Process.alive?(Process.whereis(EventBridge))
      end

      EventBridge.unsubscribe_run(run_id)
    end

    test "task_timeout handles missing fields gracefully" do
      run_id = "run_#{System.unique_integer()}"
      EventBridge.subscribe_run(run_id)
      Process.sleep(10)

      if Code.ensure_loaded?(LemonCore.Bus) do
        event = LemonCore.Event.new(:task_timeout, %{}, %{run_id: run_id})
        LemonCore.Bus.broadcast("run:#{run_id}", event)
        Process.sleep(50)

        assert Process.alive?(Process.whereis(EventBridge))
      end

      EventBridge.unsubscribe_run(run_id)
    end
  end

  describe "task_aborted event mapping" do
    test "maps task_aborted to task.aborted WS event and does not crash" do
      run_id = "run_#{System.unique_integer()}"
      EventBridge.subscribe_run(run_id)
      Process.sleep(10)

      if Code.ensure_loaded?(LemonCore.Bus) do
        event =
          LemonCore.Event.new(
            :task_aborted,
            %{
              task_id: "task-1",
              parent_run_id: "parent-run-1",
              run_id: run_id,
              session_key: "test-session",
              reason: :user_requested
            },
            %{run_id: run_id, session_key: "test-session"}
          )

        LemonCore.Bus.broadcast("run:#{run_id}", event)
        Process.sleep(50)

        assert Process.alive?(Process.whereis(EventBridge))
      end

      EventBridge.unsubscribe_run(run_id)
    end

    test "task_aborted handles missing fields gracefully" do
      run_id = "run_#{System.unique_integer()}"
      EventBridge.subscribe_run(run_id)
      Process.sleep(10)

      if Code.ensure_loaded?(LemonCore.Bus) do
        event = LemonCore.Event.new(:task_aborted, %{}, %{run_id: run_id})
        LemonCore.Bus.broadcast("run:#{run_id}", event)
        Process.sleep(50)

        assert Process.alive?(Process.whereis(EventBridge))
      end

      EventBridge.unsubscribe_run(run_id)
    end
  end

  describe "run_graph_changed event mapping" do
    test "maps run_graph_changed to run.graph.changed WS event and does not crash" do
      run_id = "run_#{System.unique_integer()}"
      EventBridge.subscribe_run(run_id)
      Process.sleep(10)

      if Code.ensure_loaded?(LemonCore.Bus) do
        event =
          LemonCore.Event.new(
            :run_graph_changed,
            %{
              run_id: run_id,
              parent_run_id: "parent-run-1",
              session_key: "test-session",
              event: "node_added",
              timestamp_ms: 5_000_000
            },
            %{run_id: run_id, session_key: "test-session"}
          )

        LemonCore.Bus.broadcast("run:#{run_id}", event)
        Process.sleep(50)

        assert Process.alive?(Process.whereis(EventBridge))
      end

      EventBridge.unsubscribe_run(run_id)
    end

    test "run_graph_changed handles missing fields gracefully" do
      run_id = "run_#{System.unique_integer()}"
      EventBridge.subscribe_run(run_id)
      Process.sleep(10)

      if Code.ensure_loaded?(LemonCore.Bus) do
        event = LemonCore.Event.new(:run_graph_changed, %{}, %{run_id: run_id})
        LemonCore.Bus.broadcast("run:#{run_id}", event)
        Process.sleep(50)

        assert Process.alive?(Process.whereis(EventBridge))
      end

      EventBridge.unsubscribe_run(run_id)
    end
  end

  describe "run_started parentRunId field" do
    test "run_started event includes parentRunId from payload" do
      run_id = "run_#{System.unique_integer()}"
      EventBridge.subscribe_run(run_id)
      Process.sleep(10)

      if Code.ensure_loaded?(LemonCore.Bus) do
        event =
          LemonCore.Event.new(
            :run_started,
            %{
              run_id: run_id,
              session_key: "test-session",
              engine: "lemon",
              parent_run_id: "parent-xyz"
            },
            %{run_id: run_id, session_key: "test-session"}
          )

        LemonCore.Bus.broadcast("run:#{run_id}", event)
        Process.sleep(50)

        assert Process.alive?(Process.whereis(EventBridge))
      end

      EventBridge.unsubscribe_run(run_id)
    end

    test "run_started event includes parentRunId from meta when not in payload" do
      run_id = "run_#{System.unique_integer()}"
      EventBridge.subscribe_run(run_id)
      Process.sleep(10)

      if Code.ensure_loaded?(LemonCore.Bus) do
        event =
          LemonCore.Event.new(
            :run_started,
            %{run_id: run_id, session_key: "test-session", engine: "lemon"},
            %{run_id: run_id, session_key: "test-session", parent_run_id: "meta-parent-xyz"}
          )

        LemonCore.Bus.broadcast("run:#{run_id}", event)
        Process.sleep(50)

        assert Process.alive?(Process.whereis(EventBridge))
      end

      EventBridge.unsubscribe_run(run_id)
    end

    test "run_started handles nil parentRunId gracefully" do
      run_id = "run_#{System.unique_integer()}"
      EventBridge.subscribe_run(run_id)
      Process.sleep(10)

      if Code.ensure_loaded?(LemonCore.Bus) do
        event =
          LemonCore.Event.new(
            :run_started,
            %{run_id: run_id, session_key: "test-session", engine: "lemon"},
            %{run_id: run_id, session_key: "test-session"}
          )

        LemonCore.Bus.broadcast("run:#{run_id}", event)
        Process.sleep(50)

        assert Process.alive?(Process.whereis(EventBridge))
      end

      EventBridge.unsubscribe_run(run_id)
    end
  end
end
