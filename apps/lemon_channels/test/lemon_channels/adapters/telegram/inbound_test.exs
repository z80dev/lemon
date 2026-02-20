defmodule LemonChannels.Adapters.Telegram.InboundTest do
  use ExUnit.Case, async: true

  alias LemonChannels.Adapters.Telegram.Inbound

  test "normalizes Telegram photo messages into meta.photo" do
    update = %{
      "update_id" => 1,
      "message" => %{
        "message_id" => 10,
        "date" => 1_700_000_000,
        "chat" => %{"id" => 123, "type" => "private"},
        "from" => %{
          "id" => 456,
          "username" => "alice",
          "first_name" => "Alice",
          "last_name" => "Smith"
        },
        "caption" => "What is this?",
        "photo" => [
          %{"file_id" => "small", "width" => 100, "height" => 100, "file_size" => 10_000},
          %{"file_id" => "big", "width" => 1000, "height" => 1000, "file_size" => 100_000}
        ]
      }
    }

    assert {:ok, inbound} = Inbound.normalize(update)
    assert inbound.message.text == "What is this?"
    assert inbound.channel_id == "telegram"
    assert inbound.peer.id == "123"
    assert inbound.sender.id == "456"

    assert %{
             file_id: "big",
             width: 1000,
             height: 1000,
             file_size: 100_000
           } = inbound.meta.photo

    assert inbound.meta.chat_username == nil
    assert inbound.meta.chat_display_name == nil
    assert inbound.meta.topic_id == nil
    assert inbound.meta.topic_name == nil
  end

  test "ignores forum topic creation service messages" do
    update = %{
      "update_id" => 2,
      "message" => %{
        "message_id" => 11,
        "date" => 1_700_000_001,
        "chat" => %{"id" => -100_123, "type" => "supergroup", "title" => "Lemon"},
        "from" => %{"id" => 456, "username" => "alice", "first_name" => "Alice"},
        "is_topic_message" => true,
        "message_thread_id" => 77,
        "forum_topic_created" => %{"name" => "New Topic", "icon_color" => 7_326_044}
      }
    }

    assert {:error, :forum_topic_created} = Inbound.normalize(update)
  end

  test "normalizes regular topic messages" do
    update = %{
      "update_id" => 3,
      "message" => %{
        "message_id" => 12,
        "date" => 1_700_000_002,
        "chat" => %{
          "id" => -100_123,
          "type" => "supergroup",
          "title" => "Lemon",
          "username" => "lemonroom"
        },
        "from" => %{"id" => 456, "username" => "alice", "first_name" => "Alice"},
        "is_topic_message" => true,
        "message_thread_id" => 77,
        "text" => "hello topic",
        "reply_to_message" => %{
          "forum_topic_created" => %{"name" => "Roadmap"}
        }
      }
    }

    assert {:ok, inbound} = Inbound.normalize(update)
    assert inbound.message.text == "hello topic"
    assert inbound.peer.thread_id == "77"
    assert inbound.meta.chat_title == "Lemon"
    assert inbound.meta.chat_username == "lemonroom"
    assert inbound.meta.chat_display_name == "Lemon"
    assert inbound.meta.topic_id == 77
    assert inbound.meta.topic_name == "Roadmap"
  end
end
