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

    test "builds struct with all optional fields" do
      sender = %{id: "42", username: "alice", display_name: "Alice"}
      raw = %{"original" => "data"}
      meta = %{chat_id: 123, user_msg_id: 456}

      inbound =
        InboundMessage.new(
          channel_id: "telegram",
          account_id: "bot",
          peer: %{kind: :dm, id: "123", thread_id: nil},
          message: %{id: "456", text: "hello", timestamp: 1_700_000_000, reply_to_id: nil},
          sender: sender,
          raw: raw,
          meta: meta
        )

      assert inbound.sender == sender
      assert inbound.raw == raw
      assert inbound.meta == meta
    end

    test "raises on missing required fields" do
      assert_raise ArgumentError, fn ->
        InboundMessage.new(
          account_id: "bot",
          peer: %{kind: :dm, id: "123", thread_id: nil},
          message: %{id: "456", text: "hello", timestamp: 1_700_000_000, reply_to_id: nil}
        )
      end
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

    test "maps nil sender when from field is nil" do
      inbound =
        InboundMessage.from_telegram(:polling, 100, %{
          "chat" => %{"type" => "private"},
          "date" => 1_700_000_000
        })

      assert inbound.sender == nil
    end

    test "reply_to_id is nil when reply_to_message is absent" do
      inbound =
        InboundMessage.from_telegram(:polling, 100, %{
          "chat" => %{"type" => "private"},
          "message_id" => 1,
          "text" => "hi",
          "date" => 1_700_000_000
        })

      assert inbound.message.reply_to_id == nil
    end

    test "thread_id is nil when message_thread_id is absent" do
      inbound =
        InboundMessage.from_telegram(:polling, 100, %{
          "chat" => %{"type" => "private"},
          "message_id" => 1,
          "text" => "hi",
          "date" => 1_700_000_000
        })

      assert inbound.peer.thread_id == nil
    end

    test "message id is nil when message_id is absent" do
      inbound =
        InboundMessage.from_telegram(:polling, 100, %{
          "chat" => %{"type" => "private"},
          "text" => "hi",
          "date" => 1_700_000_000
        })

      assert inbound.message.id == nil
    end

    test "text defaults to empty string when text key is missing" do
      inbound =
        InboundMessage.from_telegram(:polling, 100, %{
          "chat" => %{"type" => "private"},
          "date" => 1_700_000_000
        })

      assert inbound.message.text == ""
    end

    test "integer chat_id is converted to string in peer" do
      inbound =
        InboundMessage.from_telegram(:polling, 999, %{
          "chat" => %{"type" => "private"},
          "date" => 1_700_000_000
        })

      assert inbound.peer.id == "999"
      assert is_binary(inbound.peer.id)
    end

    test "preserves raw message in raw field" do
      raw_message = %{
        "chat" => %{"type" => "private"},
        "from" => %{"id" => 1, "username" => "bob", "first_name" => "Bob"},
        "message_id" => 10,
        "text" => "test",
        "date" => 1_700_000_000
      }

      inbound = InboundMessage.from_telegram(:polling, 100, raw_message)

      assert inbound.raw == raw_message
    end
  end
end
