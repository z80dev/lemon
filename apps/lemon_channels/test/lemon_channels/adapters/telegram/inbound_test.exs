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
  end
end

