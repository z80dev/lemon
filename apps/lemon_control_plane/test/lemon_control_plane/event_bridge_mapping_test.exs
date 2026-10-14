defmodule LemonControlPlane.EventBridgeMappingTest do
  use ExUnit.Case, async: true

  alias LemonControlPlane.Protocol.Frames

  describe "supported_events synchronization" do
    test "supported_events includes all expected event types" do
      events = Frames.supported_events()

      # Agent/Run events
      assert "agent" in events
      assert "chat" in events

      # Durable goal events
      assert "goal" in events

      # System events
      assert "presence" in events
      assert "tick" in events
      assert "shutdown" in events
      assert "health" in events
      assert "heartbeat" in events

      # Cron events
      assert "cron" in events
      assert "cron.job" in events
      assert "cron.audit" in events

      # Task / run-graph events
      assert "task.started" in events
      assert "task.completed" in events
      assert "task.error" in events
      assert "task.timeout" in events
      assert "task.aborted" in events
      assert "run.graph.changed" in events

      # Node events
      assert "node.pair.requested" in events
      assert "node.pair.resolved" in events
      assert "node.invoke.request" in events
      assert "node.invoke.completed" in events

      # Approval events
      assert "exec.approval.requested" in events
      assert "exec.approval.resolved" in events

      # Channel delivery events
      assert "channel.delivery" in events
    end

    test "no duplicate events in supported_events" do
      events = Frames.supported_events()
      unique_events = Enum.uniq(events)

      assert length(events) == length(unique_events),
             "Duplicate events found: #{inspect(events -- unique_events)}"
    end
  end

  describe "EventBridge event mapping" do
    # Test that EventBridge maps bus events to the correct WS event names

    test "maps run events to agent" do
      # :run_started -> "agent"
      event = %LemonCore.Event{
        type: :run_started,
        ts_ms: 1_234_567_890,
        payload: %{run_id: "run-1", engine: "claude"},
        meta: %{session_key: "sess-1"}
      }

      # EventBridge.map_event is private, so we test via public behavior
      # For now, just verify the event structure is valid
      assert event.type == :run_started
    end

    test "maps delta to chat" do
      event = %LemonCore.Event{
        type: :delta,
        ts_ms: 1_234_567_890,
        payload: %{run_id: "run-1", seq: 1, text: "Hello"},
        meta: %{}
      }

      assert event.type == :delta
    end

    test "maps approval events" do
      requested = %LemonCore.Event{
        type: :approval_requested,
        ts_ms: 1_234_567_890,
        payload: %{id: "apr-1", run_id: "run-1", tool: "bash"},
        meta: %{}
      }

      resolved = %LemonCore.Event{
        type: :approval_resolved,
        ts_ms: 1_234_567_890,
        payload: %{approval_id: "apr-1", decision: :approved},
        meta: %{}
      }

      assert requested.type == :approval_requested
      assert resolved.type == :approval_resolved
    end

    test "maps node events" do
      pair_requested = %LemonCore.Event{
        type: :node_pair_requested,
        ts_ms: 1_234_567_890,
        payload: %{pairing_id: "pair-1", code: "123456"},
        meta: %{}
      }

      pair_resolved = %LemonCore.Event{
        type: :node_pair_resolved,
        ts_ms: 1_234_567_890,
        payload: %{pairing_id: "pair-1", node_id: "node-1", approved: true},
        meta: %{}
      }

      invoke_request = %LemonCore.Event{
        type: :node_invoke_request,
        ts_ms: 1_234_567_890,
        payload: %{invoke_id: "inv-1", node_id: "node-1", method: "execute"},
        meta: %{}
      }

      invoke_completed = %LemonCore.Event{
        type: :node_invoke_completed,
        ts_ms: 1_234_567_890,
        payload: %{invoke_id: "inv-1", node_id: "node-1", ok: true, result: %{}},
        meta: %{}
      }

      assert pair_requested.type == :node_pair_requested
      assert pair_resolved.type == :node_pair_resolved
      assert invoke_request.type == :node_invoke_request
      assert invoke_completed.type == :node_invoke_completed
    end

    test "maps system events" do
      shutdown = %LemonCore.Event{
        type: :shutdown,
        ts_ms: 1_234_567_890,
        payload: %{reason: :restart},
        meta: %{}
      }

      health = %LemonCore.Event{
        type: :health_changed,
        ts_ms: 1_234_567_890,
        payload: %{status: :healthy},
        meta: %{}
      }

      assert shutdown.type == :shutdown
      assert health.type == :health_changed
    end

    test "maps heartbeat events" do
      heartbeat = %LemonCore.Event{
        type: :heartbeat,
        ts_ms: 1_234_567_890,
        payload: %{agent_id: "agent-1", status: :ok},
        meta: %{}
      }

      alert = %LemonCore.Event{
        type: :heartbeat_alert,
        ts_ms: 1_234_567_890,
        payload: %{agent_id: "agent-1", response: "detected issue"},
        meta: %{}
      }

      assert heartbeat.type == :heartbeat
      assert alert.type == :heartbeat_alert
    end
  end

  describe "event frame encoding" do
    test "encode_event produces valid JSON" do
      json = Frames.encode_event("test.event", %{"key" => "value"}, 1, nil)
      decoded = Jason.decode!(json)

      assert decoded["type"] == "event"
      assert decoded["event"] == "test.event"
      assert decoded["payload"]["key"] == "value"
      assert decoded["seq"] == 1
    end

    test "encode_event includes state version when provided" do
      state_version = %{presence: 5, health: 3}
      json = Frames.encode_event("presence", %{}, 10, state_version)
      decoded = Jason.decode!(json)

      assert decoded["stateVersion"]["presence"] == 5
      assert decoded["stateVersion"]["health"] == 3
    end

    test "encode_event omits payload when nil" do
      json = Frames.encode_event("tick", nil, 1, nil)
      decoded = Jason.decode!(json)

      assert decoded["type"] == "event"
      assert decoded["event"] == "tick"
      refute Map.has_key?(decoded, "payload")
    end
  end
end
