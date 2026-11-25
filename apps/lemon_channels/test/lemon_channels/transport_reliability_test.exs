defmodule LemonChannels.TransportReliabilityTest do
  use ExUnit.Case, async: true

  alias LemonChannels.Adapters.Telegram.Transport.Poller

  defmodule PollAPI do
    def get_updates(updates, offset, _timeout) do
      {:ok, %{"ok" => true, "result" => Enum.filter(updates, &(&1["update_id"] >= offset))}}
    end
  end

  @tag capture_log: true
  test "a failed Telegram update does not discard later updates or replay the batch" do
    test_pid = self()

    state = %{
      account_id: "poller-reliability-#{System.unique_integer([:positive])}",
      token: [callback_update(10, 123), callback_update(11, 123), callback_update(12, 456)],
      api_mod: PollAPI,
      offset: 10,
      poll_interval_ms: 0,
      drop_pending_updates?: false,
      drop_pending_done?: false,
      allowed_chat_ids: [123],
      deny_unbound_chats: false
    }

    callbacks = %{
      index_known_target: fn state, _update -> state end,
      handle_callback_query: fn _state, callback ->
        send(test_pid, {:handled, callback["id"]})
        if callback["id"] == "10", do: raise("update failed after a side effect")
      end,
      persist_offset: fn _state, offset -> send(test_pid, {:offset, offset}) end
    }

    next = Poller.apply_result(state, Poller.fetch(state), callbacks)
    assert_receive {:handled, "10"}
    assert_receive {:handled, "11"}
    refute_receive {:handled, "12"}, 0
    assert_receive {:offset, 11}
    assert_receive {:offset, 12}
    assert_receive {:offset, 13}
    assert next.offset == 13

    assert %{offset: 13} = Poller.apply_result(next, Poller.fetch(next), callbacks)
    refute_receive {:offset, _}, 0
    refute_receive {:handled, _}, 0
  end

  @tag capture_log: true
  test "a Telegram transport crash mid-batch re-polls only unconfirmed updates" do
    test_pid = self()
    {:ok, confirmed} = Agent.start_link(fn -> 20 end)

    state = %{
      account_id: "poller-crash-#{System.unique_integer([:positive])}",
      token: [callback_update(20, 123), callback_update(21, 123)],
      api_mod: PollAPI,
      offset: 20,
      poll_interval_ms: 0,
      drop_pending_updates?: false,
      drop_pending_done?: false,
      allowed_chat_ids: [123],
      deny_unbound_chats: false
    }

    callbacks = fn crash_on ->
      %{
        index_known_target: fn state, _update -> state end,
        handle_callback_query: fn _state, callback ->
          if callback["id"] == crash_on, do: exit(:transport_crashed)
          send(test_pid, {:handled, callback["id"]})
        end,
        persist_offset: fn _state, offset -> Agent.update(confirmed, fn _ -> offset end) end
      }
    end

    # The first update is handled and confirmed; the transport dies on the second.
    {pid, ref} =
      spawn_monitor(fn -> Poller.apply_result(state, Poller.fetch(state), callbacks.("21")) end)

    assert_receive {:DOWN, ^ref, :process, ^pid, :transport_crashed}
    assert_received {:handled, "20"}
    assert Agent.get(confirmed, & &1) == 21

    # The restarted transport resumes from the confirmed offset.
    restarted = %{state | offset: Agent.get(confirmed, & &1)}

    assert %{offset: 22} =
             Poller.apply_result(restarted, Poller.fetch(restarted), callbacks.(nil))

    assert_received {:handled, "21"}
    refute_received {:handled, "20"}
  end

  defp callback_update(id, chat_id) do
    %{
      "update_id" => id,
      "callback_query" => %{
        "id" => to_string(id),
        "from" => %{"id" => 99},
        "data" => "callback",
        "message" => %{"message_id" => id, "chat" => %{"id" => chat_id, "type" => "private"}}
      }
    }
  end
end
