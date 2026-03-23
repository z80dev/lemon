defmodule LemonChannels.Adapters.Telegram.TransportPipelineTest do
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.Telegram.Transport.{
    Normalize,
    Pipeline
  }

  alias LemonChannels.Telegram.KnownTargetStore
  alias LemonCore.Store

  setup do
    clear_known_targets()
    :ok
  end

  test "callback queries refresh known targets through normalize and pipeline" do
    state = %{
      account_id: "default",
      allowed_chat_ids: nil,
      deny_unbound_chats: false,
      buffers: %{},
      media_groups: %{}
    }

    chat_id = System.unique_integer([:positive])
    update = callback_update(chat_id, "cb-1", "lemon:cancel")
    stale_ts = System.system_time(:millisecond) - 35_000
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
               updated_at_ms: stale_ts,
               first_seen_at_ms: stale_ts,
               last_message_id: 0
             })

    assert {:ok, context} = Normalize.event(state, update, 101)
    {state, actions} = Pipeline.run(context, state)

    assert [{:handle_callback_query, callback_query}] = actions
    assert callback_query["id"] == "cb-1"
    assert state.account_id == "default"

    refreshed = KnownTargetStore.get(key)
    assert refreshed[:updated_at_ms] > stale_ts
    assert refreshed[:last_message_id] == 5001
  end

  test "stale debounce flush does not submit and current debounce flush does" do
    inbound = inbound_message(800, 61, "first")
    state = %{account_id: "default", buffers: %{}, media_groups: %{}, debounce_ms: 5}

    state = LemonChannels.Adapters.Telegram.Transport.MessageBuffer.enqueue_buffer(state, inbound)
    key = LemonChannels.Adapters.Telegram.Transport.Commands.scope_key(inbound)
    first_ref = state.buffers[key].debounce_ref

    state =
      LemonChannels.Adapters.Telegram.Transport.MessageBuffer.enqueue_buffer(
        state,
        inbound_message(800, 62, "second")
      )

    current_ref = state.buffers[key].debounce_ref
    refute first_ref == current_ref

    assert {:ok, stale_context} = Normalize.event(state, {:debounce_flush, key, first_ref})
    {state_after_stale, stale_actions} = Pipeline.run(stale_context, state)
    assert stale_actions == []
    assert Map.has_key?(state_after_stale.buffers, key)

    assert {:ok, current_context} =
             Normalize.event(state_after_stale, {:debounce_flush, key, current_ref})

    {state_after_current, current_actions} = Pipeline.run(current_context, state_after_stale)

    refute Map.has_key?(state_after_current.buffers, key)
    assert [{:submit_buffer, buffer}] = current_actions
    assert buffer.inbound.message.id == "62"
  end

  defp callback_update(chat_id, callback_id, data) do
    %{
      "update_id" => 101,
      "callback_query" => %{
        "id" => callback_id,
        "from" => %{"id" => 999, "username" => "tester", "first_name" => "Test"},
        "data" => data,
        "message" => %{
          "message_id" => 5001,
          "chat" => %{"id" => chat_id, "type" => "private", "title" => "Lemon"}
        }
      }
    }
  end

  defp inbound_message(chat_id, message_id, text) do
    %{
      peer: %{id: Integer.to_string(chat_id), thread_id: nil},
      message: %{id: Integer.to_string(message_id), text: text, reply_to_id: nil},
      meta: %{chat_id: chat_id, user_msg_id: message_id}
    }
  end

  defp clear_known_targets do
    KnownTargetStore.list()
    |> Enum.each(fn {key, _value} ->
      Store.delete(:telegram_known_targets, key)
    end)
  end
end
