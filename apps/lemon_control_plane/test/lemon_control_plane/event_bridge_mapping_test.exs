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
