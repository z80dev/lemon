defmodule LemonCore.InboundMessageTest do
  use ExUnit.Case, async: true

  alias LemonCore.InboundMessage

  describe "new/1" do
    test "builds struct with required fields" do
      inbound =
        InboundMessage.new(
          channel_id: "demo",
          account_id: "bot",
          peer: %{kind: :dm, id: "123", thread_id: nil},
          message: %{id: "456", text: "hello", timestamp: 1_700_000_000, reply_to_id: nil}
        )

      assert %InboundMessage{
               channel_id: "demo",
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
          channel_id: "demo",
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
end
