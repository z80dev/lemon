defmodule LemonChannels.TransportReliabilityTest do
  use ExUnit.Case, async: true

  alias LemonChannels.Adapters.Telegram.Transport.Poller
  alias LemonChannels.Adapters.WhatsApp.Transport, as: WhatsAppTransport

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
    assert_receive {:offset, 13}
    assert next.offset == 13

    assert %{offset: 13} = Poller.apply_result(next, Poller.fetch(next), callbacks)
    assert_receive {:offset, 13}
    refute_receive {:handled, _}, 0
  end

  @tag capture_log: true
  test "a WhatsApp command timeout is outcome-unknown, never delivery success or safe retry" do
    reply_ref = make_ref()
    command_id = "pending-command"
    state = %{pending_commands: %{command_id => {{self(), reply_ref}, nil}}}

    assert {:noreply, %{pending_commands: %{}} = next} =
             WhatsAppTransport.handle_info({:command_timeout, command_id}, state)

    assert_receive {^reply_ref, {:error, :outcome_unknown}}
    assert {:noreply, ^next} = WhatsAppTransport.handle_info({:command_timeout, command_id}, next)
    refute_receive {^reply_ref, _}, 0
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
