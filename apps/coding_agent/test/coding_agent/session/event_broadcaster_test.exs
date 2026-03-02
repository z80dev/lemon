defmodule CodingAgent.Session.EventBroadcasterTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Session.EventBroadcaster

  describe "broadcast/2" do
    test "sends event to direct subscribers" do
      state = %{
        session_manager: %{header: %{id: "session_1"}},
        event_listeners: [{self(), make_ref()}],
        event_streams: %{}
      }

      EventBroadcaster.broadcast(state, {:agent_start})

      assert_receive {:session_event, "session_1", {:agent_start}}
    end

    test "sends event to multiple direct subscribers" do
      # Spawn a helper to be a second subscriber
      test_pid = self()

      helper =
        spawn(fn ->
          receive do
            msg -> send(test_pid, {:helper_received, msg})
          end
        end)

      state = %{
        session_manager: %{header: %{id: "session_2"}},
        event_listeners: [{self(), make_ref()}, {helper, make_ref()}],
        event_streams: %{}
      }

      EventBroadcaster.broadcast(state, {:agent_end, []})

      assert_receive {:session_event, "session_2", {:agent_end, []}}
      assert_receive {:helper_received, {:session_event, "session_2", {:agent_end, []}}}
    end

    test "returns :ok with no subscribers" do
      state = %{
        session_manager: %{header: %{id: "session_3"}},
        event_listeners: [],
        event_streams: %{}
      }

      assert :ok = EventBroadcaster.broadcast(state, {:agent_start})
    end

    test "handles various event types" do
      state = %{
        session_manager: %{header: %{id: "s1"}},
        event_listeners: [{self(), make_ref()}],
        event_streams: %{}
      }

      EventBroadcaster.broadcast(state, {:error, :timeout, nil})
      assert_receive {:session_event, "s1", {:error, :timeout, nil}}

      EventBroadcaster.broadcast(state, {:canceled, :user_abort})
      assert_receive {:session_event, "s1", {:canceled, :user_abort}}

      EventBroadcaster.broadcast(state, {:tool_execution_start, "tc_1", "read", %{}})

      assert_receive {:session_event, "s1",
                      {:tool_execution_start, "tc_1", "read", %{}}}
    end
  end
end
