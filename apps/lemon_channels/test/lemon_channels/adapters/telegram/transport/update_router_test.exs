defmodule LemonChannels.Adapters.Telegram.Transport.UpdateRouterTest do
  use ExUnit.Case, async: true

  alias LemonChannels.Adapters.Telegram.Transport.UpdateRouter

  # ---------------------------------------------------------------------------
  # should_ignore_for_trigger?/3
  # ---------------------------------------------------------------------------

  describe "should_ignore_for_trigger?/3" do
    test "returns false for DM peer (never ignored)" do
      state = base_state()
      inbound = build_inbound(:dm, 123, nil)

      refute UpdateRouter.should_ignore_for_trigger?(state, inbound, "hello")
    end

    test "returns false for group peer when trigger mode is :all" do
      state = base_state()
      inbound = build_inbound(:group, 123, nil)

      # Default trigger mode is :all, so nothing should be ignored
      refute UpdateRouter.should_ignore_for_trigger?(state, inbound, "hello")
    end

    test "returns false when inbound has malformed peer" do
      state = base_state()
      inbound = %{peer: %{kind: :group, id: nil, thread_id: nil}, meta: %{}, message: %{text: ""}, raw: %{}}

      # Should rescue and return false
      refute UpdateRouter.should_ignore_for_trigger?(state, inbound, "hello")
    end
  end

  # ---------------------------------------------------------------------------
  # authorized_callback_query?/2
  # ---------------------------------------------------------------------------

  describe "authorized_callback_query?/2" do
    test "returns true when no allowed_chat_ids restriction and deny_unbound_chats is false" do
      state = base_state(allowed_chat_ids: nil, deny_unbound_chats: false)

      cb = %{
        "message" => %{
          "chat" => %{"id" => 123}
        }
      }

      assert UpdateRouter.authorized_callback_query?(state, cb)
    end

    test "returns false when chat_id is not in allowed list" do
      state = base_state(allowed_chat_ids: [100, 200], deny_unbound_chats: false)

      cb = %{
        "message" => %{
          "chat" => %{"id" => 999}
        }
      }

      refute UpdateRouter.authorized_callback_query?(state, cb)
    end

    test "returns true when chat_id is in allowed list" do
      state = base_state(allowed_chat_ids: [100, 200], deny_unbound_chats: false)

      cb = %{
        "message" => %{
          "chat" => %{"id" => 200}
        }
      }

      assert UpdateRouter.authorized_callback_query?(state, cb)
    end

    test "returns false when callback query has no message" do
      state = base_state()
      cb = %{}

      refute UpdateRouter.authorized_callback_query?(state, cb)
    end

    test "returns false when chat id is not an integer" do
      state = base_state()

      cb = %{
        "message" => %{
          "chat" => %{"id" => "not_an_int"}
        }
      }

      refute UpdateRouter.authorized_callback_query?(state, cb)
    end

    test "returns false for non-map callback query" do
      state = base_state()
      refute UpdateRouter.authorized_callback_query?(state, nil)
      refute UpdateRouter.authorized_callback_query?(state, "string")
    end
  end

  # ---------------------------------------------------------------------------
  # inbound_message_from_update/1
  # ---------------------------------------------------------------------------

  describe "inbound_message_from_update/1" do
    test "extracts message from regular message update" do
      message = %{"text" => "hello", "message_id" => 1}
      update = %{"message" => message}

      assert UpdateRouter.inbound_message_from_update(update) == message
    end

    test "extracts message from edited_message update" do
      message = %{"text" => "edited", "message_id" => 2}
      update = %{"edited_message" => message}

      assert UpdateRouter.inbound_message_from_update(update) == message
    end

    test "extracts message from channel_post update" do
      message = %{"text" => "channel post", "message_id" => 3}
      update = %{"channel_post" => message}

      assert UpdateRouter.inbound_message_from_update(update) == message
    end

    test "returns empty map for unrecognized update type" do
      update = %{"unknown_type" => %{}}
      assert UpdateRouter.inbound_message_from_update(update) == %{}
    end

    test "returns empty map for non-map input" do
      assert UpdateRouter.inbound_message_from_update(nil) == %{}
      assert UpdateRouter.inbound_message_from_update("string") == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # maybe_log_drop/3
  # ---------------------------------------------------------------------------

  describe "maybe_log_drop/3" do
    test "returns :ok when debug is enabled" do
      state = base_state(debug_inbound: true)
      inbound = build_inbound(:dm, 123, nil)
      assert UpdateRouter.maybe_log_drop(state, inbound, :test_reason) == :ok
    end

    test "returns :ok when debug is disabled" do
      state = base_state(debug_inbound: false, log_drops: false)
      inbound = build_inbound(:dm, 123, nil)
      assert UpdateRouter.maybe_log_drop(state, inbound, :test_reason) == :ok
    end

    test "returns :ok when log_drops is enabled" do
      state = base_state(log_drops: true)
      inbound = build_inbound(:dm, 123, nil)
      assert UpdateRouter.maybe_log_drop(state, inbound, :chat_not_allowed) == :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp base_state(opts \\ []) do
    %{
      bot_username: Keyword.get(opts, :bot_username, "test_bot"),
      bot_id: Keyword.get(opts, :bot_id, 12345),
      allowed_chat_ids: Keyword.get(opts, :allowed_chat_ids, nil),
      deny_unbound_chats: Keyword.get(opts, :deny_unbound_chats, false),
      debug_inbound: Keyword.get(opts, :debug_inbound, false),
      log_drops: Keyword.get(opts, :log_drops, false),
      account_id: "test"
    }
  end

  defp build_inbound(kind, chat_id, thread_id) do
    %LemonCore.InboundMessage{
      channel_id: "telegram",
      account_id: "test",
      peer: %{kind: kind, id: to_string(chat_id), thread_id: thread_id && to_string(thread_id)},
      sender: %{id: "99", username: "tester", display_name: "Test"},
      message: %{id: "1", text: "", timestamp: 1, reply_to_id: nil},
      raw: %{
        "message" => %{
          "text" => "",
          "chat" => %{"id" => chat_id, "type" => kind_to_chat_type(kind)},
          "from" => %{"id" => 99, "username" => "tester"},
          "message_id" => 1,
          "date" => 1
        }
      },
      meta: %{chat_id: chat_id}
    }
  end

  defp kind_to_chat_type(:dm), do: "private"
  defp kind_to_chat_type(:group), do: "supergroup"
  defp kind_to_chat_type(:channel), do: "channel"
end
