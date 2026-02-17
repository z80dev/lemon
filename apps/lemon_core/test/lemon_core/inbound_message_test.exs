defmodule LemonCore.InboundMessageTest do
  use ExUnit.Case, async: true

  alias LemonCore.InboundMessage

  describe "new/1" do
    test "builds struct with required fields" do
      inbound =
        InboundMessage.new(
          channel_id: "telegram",
          account_id: "bot",
          peer: %{kind: :dm, id: "123", thread_id: nil},
          message: %{id: "456", text: "hello", timestamp: 1_700_000_000, reply_to_id: nil}
        )

      assert %InboundMessage{
               channel_id: "telegram",
               account_id: "bot",
               peer: %{kind: :dm, id: "123", thread_id: nil},
               sender: nil,
               message: %{id: "456", text: "hello", timestamp: 1_700_000_000, reply_to_id: nil},
               raw: nil,
               meta: nil
             } = inbound
    end
  end

  describe "from_telegram/3" do
    test "maps chat type to peer kind with dm fallback" do
      cases = [
        {"private", :dm},
        {"group", :group},
        {"supergroup", :group},
        {"channel", :channel},
        {"unknown", :dm}
      ]

      for {chat_type, expected_kind} <- cases do
        inbound =
          InboundMessage.from_telegram(:polling, 777, %{
            "chat" => %{"type" => chat_type},
            "date" => 1_700_000_000
          })

        assert inbound.peer.kind == expected_kind
        assert inbound.peer.id == "777"
        assert inbound.account_id == "polling"
      end
    end

    test "maps sender and normalizes ids, text defaults, and meta fields" do
      raw_message = %{
        "chat" => %{"type" => "group"},
        "from" => %{
          "id" => 42,
          "username" => "alice",
          "first_name" => "Alice"
        },
        "message_id" => 901,
        "message_thread_id" => 77,
        "reply_to_message" => %{"message_id" => 900},
        "text" => nil,
        "date" => 1_700_000_123
      }

      inbound = InboundMessage.from_telegram(:webhook, -100_123, raw_message)

      assert inbound.channel_id == "telegram"
      assert inbound.account_id == "webhook"

      assert inbound.peer == %{
               kind: :group,
               id: "-100123",
               thread_id: "77"
             }

      assert inbound.sender == %{
               id: "42",
               username: "alice",
               display_name: "Alice"
             }

      assert inbound.message == %{
               id: "901",
               text: "",
               timestamp: 1_700_000_123,
               reply_to_id: "900"
             }

      assert inbound.meta == %{
               chat_id: -100_123,
               user_msg_id: 901
             }

      assert inbound.raw == raw_message
    end
  end
end
