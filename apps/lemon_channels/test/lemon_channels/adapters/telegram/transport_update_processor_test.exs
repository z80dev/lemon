defmodule LemonChannels.Adapters.Telegram.TransportUpdateProcessorTest do
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.Telegram.Transport.UpdateProcessor
  alias LemonChannels.Telegram.KnownTargetStore
  alias LemonChannels.Telegram.TransportShared
  alias LemonCore.Store

  setup do
    :ok = TransportShared.init_dedupe(:channels)
    clear_known_targets()
    :ok
  end

  test "route_authorized_inbound drops duplicate inbound updates after first accept" do
    state = transport_state()

    handle_fn = fn _state, inbound ->
      send(self(), {:accepted_inbound, inbound.meta[:update_id], inbound.message.id})
      state
    end

    inbound =
      UpdateProcessor.prepare_inbound(
        base_inbound(chat_id: 1_234, message_id: 10, text: "hello"),
        state,
        update_for_message(1_234, "hello", 10),
        9001
      )

    _state_after_first = UpdateProcessor.route_authorized_inbound(state, inbound, handle_fn)

    assert_receive {:accepted_inbound, 9001, "10"}, 200

    _state_after_second =
      UpdateProcessor.route_authorized_inbound(state, inbound, handle_fn)

    refute_receive {:accepted_inbound, 9001, "10"}, 200
  end

  test "prepare_inbound preserves reply_to_text and update metadata" do
    state = transport_state()
    inbound = base_inbound(chat_id: 2_468, message_id: 11, text: "reply chain")
    update = update_for_reply_to(2_468, "hello", 12_345, "Quoted from previous message")

    prepared = UpdateProcessor.prepare_inbound(inbound, state, update, 7_531)

    assert prepared.account_id == state.account_id
    assert prepared.meta[:update_id] == 7_531
    assert prepared.meta[:reply_to_text] == "Quoted from previous message"
    assert prepared.meta[:chat_id] == 2_468
  end

  test "maybe_index_known_target refreshes stale known-target metadata" do
    state = %{account_id: "default"}
    chat_id = System.unique_integer([:positive])
    update = update_for_message(chat_id, "topic check", System.unique_integer([:positive]))
    key = {"default", chat_id, nil}
    stale_ts = System.system_time(:millisecond) - 35_000

    prior_entry = %{
      channel_id: "telegram",
      account_id: "default",
      peer_kind: :dm,
      peer_id: Integer.to_string(chat_id),
      thread_id: nil,
      chat_id: chat_id,
      topic_id: nil,
      chat_type: "private",
      chat_title: "Lemon",
      chat_username: nil,
      chat_display_name: nil,
      topic_name: nil,
      updated_at_ms: stale_ts,
      first_seen_at_ms: stale_ts,
      last_message_id: 0
    }

    assert :ok == KnownTargetStore.put(key, prior_entry)

    _state_after = UpdateProcessor.maybe_index_known_target(state, update)
    refreshed = KnownTargetStore.get(key)

    assert refreshed[:updated_at_ms] > stale_ts
    assert refreshed[:chat_title] == "Lemon"
    assert refreshed[:first_seen_at_ms] == stale_ts
  end

  test "maybe_index_known_target does not rewrite unchanged metadata inside throttle window" do
    state = %{account_id: "default"}
    chat_id = System.unique_integer([:positive])
    update = update_for_message(chat_id, "topic check", 41)
    now = System.system_time(:millisecond)
    key = {"default", chat_id, nil}

    assert :ok ==
             KnownTargetStore.put(key, %{
               channel_id: "telegram",
               account_id: "default",
               peer_kind: :dm,
               peer_id: Integer.to_string(chat_id),
               thread_id: nil,
               chat_id: chat_id,
               topic_id: nil,
               chat_type: "private",
               chat_title: "Lemon",
               chat_username: nil,
               chat_display_name: nil,
               topic_name: nil,
               updated_at_ms: now,
               first_seen_at_ms: now - 100,
               last_message_id: 41
             })

    _state_after = UpdateProcessor.maybe_index_known_target(state, update)
    assert KnownTargetStore.get(key)[:updated_at_ms] == now
  end

  test "maybe_index_known_target writes significant changes immediately" do
    state = %{account_id: "default"}
    chat_id = System.unique_integer([:positive])
    now = System.system_time(:millisecond)
    key = {"default", chat_id, nil}

    assert :ok ==
             KnownTargetStore.put(key, %{
               channel_id: "telegram",
               account_id: "default",
               peer_kind: :dm,
               peer_id: Integer.to_string(chat_id),
               thread_id: nil,
               chat_id: chat_id,
               topic_id: nil,
               chat_type: "private",
               chat_title: "Old title",
               chat_username: nil,
               chat_display_name: nil,
               topic_name: nil,
               updated_at_ms: now,
               first_seen_at_ms: now - 100,
               last_message_id: 41
             })

    update = update_for_message(chat_id, "topic check", 42, title: "New title")
    _state_after = UpdateProcessor.maybe_index_known_target(state, update)
    refreshed = KnownTargetStore.get(key)

    assert refreshed[:chat_title] == "New title"
    assert refreshed[:last_message_id] == 42
  end

  test "maybe_index_known_target persists unchanged metadata only after write interval" do
    state = %{account_id: "default"}
    chat_id = System.unique_integer([:positive])
    refresh_boundary = System.system_time(:millisecond) - 30_000

    assert :ok ==
             KnownTargetStore.put(
               {"default", chat_id, nil},
               %{
                 channel_id: "telegram",
                 account_id: "default",
                 peer_kind: :dm,
                 peer_id: Integer.to_string(chat_id),
                 thread_id: nil,
                 chat_id: chat_id,
                 topic_id: nil,
                 chat_type: "private",
                 chat_title: "Lemon",
                 chat_username: nil,
                 chat_display_name: nil,
                 topic_name: nil,
                 updated_at_ms: refresh_boundary,
                 first_seen_at_ms: refresh_boundary,
                 last_message_id: 77
               }
             )

    update = update_for_message(chat_id, "topic check", 88)
    _state_after = UpdateProcessor.maybe_index_known_target(state, update)
    refreshed = KnownTargetStore.get({"default", chat_id, nil})

    assert refreshed[:updated_at_ms] >= refresh_boundary + 1
    assert refreshed[:last_message_id] == 88
  end

  defp transport_state do
    %{
      account_id: "default",
      dedupe_ttl_ms: 60_000,
      allowed_chat_ids: nil,
      deny_unbound_chats: false,
      allow_queue_override: false,
      debug_inbound: false,
      log_drops: false
    }
  end

  defp base_inbound(opts) do
    chat_id = Keyword.fetch!(opts, :chat_id)
    message_id = Keyword.fetch!(opts, :message_id)
    text = Keyword.fetch!(opts, :text)

    %{
      peer: %{id: Integer.to_string(chat_id), thread_id: nil},
      message: %{id: Integer.to_string(message_id), text: text, reply_to_id: nil},
      meta: %{chat_id: chat_id, user_msg_id: message_id}
    }
  end

  defp update_for_message(chat_id, text, message_id, opts \\ []) do
    %{
      "message" => %{
        "message_id" => message_id,
        "date" => 1_700_000_001,
        "chat" => %{
          "id" => chat_id,
          "type" => "private",
          "title" => Keyword.get(opts, :title, "Lemon")
        },
        "from" => %{"id" => 999, "username" => "tester", "first_name" => "Test"},
        "text" => text
      }
    }
  end

  defp update_for_reply_to(chat_id, text, message_id, reply_to_text) do
    %{
      "message" => %{
        "message_id" => message_id,
        "date" => 1_700_000_002,
        "chat" => %{"id" => chat_id, "type" => "private"},
        "from" => %{"id" => 999, "username" => "tester", "first_name" => "Test"},
        "text" => text,
        "reply_to_message" => %{"text" => reply_to_text}
      }
    }
  end

  defp clear_known_targets do
    KnownTargetStore.list()
    |> Enum.each(fn {key, _value} ->
      Store.delete(:telegram_known_targets, key)
    end)
  end
end
