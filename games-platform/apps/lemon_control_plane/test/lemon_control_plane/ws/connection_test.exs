defmodule LemonControlPlane.WS.ConnectionTest do
  use ExUnit.Case, async: true

  alias LemonControlPlane.WS.Connection

  describe "handle_info/2 event delivery" do
    setup do
      # Create a minimal state for testing
      state = %Connection{
        conn_id: "test-conn-#{System.unique_integer()}",
        auth: %{role: :operator, scopes: [:read, :write], client_id: "test-client"},
        connected: true,
        event_seq: 0,
        state_version: %{},
        subscriptions: MapSet.new()
      }

      {:ok, state: state}
    end

    test "handles 3-tuple events without state version", %{state: state} do
      event_name = "test.event"
      payload = %{"data" => "value"}

      {:push, {:text, frame}, new_state} =
        Connection.handle_info({:event, event_name, payload}, state)

      # Event seq should increment
      assert new_state.event_seq == 1

      # State version should remain unchanged
      assert new_state.state_version == %{}

      # Frame should be valid JSON
      assert {:ok, decoded} = Jason.decode(frame)
      assert decoded["type"] == "event"
      assert decoded["event"] == event_name
    end

    test "handles 4-tuple events with state version update", %{state: state} do
      event_name = "presence"
      payload = %{"connections" => [], "count" => 0}
      new_state_version = %{presence: 1, health: 0, cron: 0}

      {:push, {:text, frame}, new_state} =
        Connection.handle_info({:event, event_name, payload, new_state_version}, state)

      # Event seq should increment
      assert new_state.event_seq == 1

      # State version should be updated from the 4-tuple
      assert new_state.state_version == new_state_version

      # Frame should be valid JSON with stateVersion
      assert {:ok, decoded} = Jason.decode(frame)
      assert decoded["type"] == "event"
      assert decoded["event"] == event_name
    end

    test "accumulates state version across multiple 4-tuple events", %{state: state} do
      # First event
      {:push, {:text, _}, state1} =
        Connection.handle_info(
          {:event, "presence", %{}, %{presence: 1, health: 0, cron: 0}},
          state
        )

      assert state1.state_version == %{presence: 1, health: 0, cron: 0}
      assert state1.event_seq == 1

      # Second event updates some values
      {:push, {:text, _}, state2} =
        Connection.handle_info(
          {:event, "tick", %{}, %{presence: 1, health: 0, cron: 1}},
          state1
        )

      assert state2.state_version == %{presence: 1, health: 0, cron: 1}
      assert state2.event_seq == 2

      # Third event with different increments
      {:push, {:text, _}, state3} =
        Connection.handle_info(
          {:event, "presence", %{}, %{presence: 2, health: 1, cron: 1}},
          state2
        )

      assert state3.state_version == %{presence: 2, health: 1, cron: 1}
      assert state3.event_seq == 3
    end

    test "event_seq increments for all event types", %{state: state} do
      # 3-tuple event
      {:push, {:text, _}, state1} =
        Connection.handle_info({:event, "test", %{}}, state)

      assert state1.event_seq == 1

      # 4-tuple event
      {:push, {:text, _}, state2} =
        Connection.handle_info({:event, "test2", %{}, %{presence: 0}}, state1)

      assert state2.event_seq == 2
    end
  end

  describe "handle_info/2 push_frame" do
    setup do
      state = %Connection{
        conn_id: "test-conn-#{System.unique_integer()}",
        auth: nil,
        connected: false,
        event_seq: 0,
        state_version: %{},
        subscriptions: MapSet.new()
      }

      {:ok, state: state}
    end

    test "handles push_frame messages", %{state: state} do
      frame = ~s({"type":"evt","event":"test"})

      {:push, {:text, pushed_frame}, new_state} =
        Connection.handle_info({:push_frame, frame}, state)

      assert pushed_frame == frame
      # State should not change
      assert new_state == state
    end
  end

  describe "handle_info/2 unknown messages" do
    setup do
      state = %Connection{
        conn_id: "test-conn-#{System.unique_integer()}",
        auth: nil,
        connected: false,
        event_seq: 0,
        state_version: %{},
        subscriptions: MapSet.new()
      }

      {:ok, state: state}
    end

    test "handles unknown messages gracefully", %{state: state} do
      {:ok, new_state} = Connection.handle_info(:unknown_message, state)
      assert new_state == state
    end
  end
end
