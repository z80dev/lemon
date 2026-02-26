defmodule LemonChannels.Adapters.Discord.InboundTest do
  use ExUnit.Case, async: true

  alias LemonChannels.Adapters.Discord.Inbound

  test "normalizes guild message with attachments" do
    raw = %{
      message: %{
        "id" => "9001",
        "channel_id" => "12345",
        "guild_id" => "777",
        "content" => "hello",
        "timestamp" => "2026-02-24T10:00:00Z",
        "author" => %{"id" => "42", "username" => "z", "global_name" => "Zed"},
        "attachments" => [%{"url" => "https://example.com/a.png"}]
      },
      account_id: "default"
    }

    assert {:ok, inbound} = Inbound.normalize(raw)

    assert inbound.channel_id == "discord"
    assert inbound.peer.kind == :group
    assert inbound.peer.id == "12345"
    assert inbound.sender.id == "42"
    assert inbound.message.id == "9001"
    assert inbound.message.reply_to_id == nil
    assert String.contains?(inbound.message.text, "hello")
    assert String.contains?(inbound.message.text, "https://example.com/a.png")
    assert inbound.meta.channel_id == 12_345
    assert inbound.meta.guild_id == 777
    assert inbound.meta.user_msg_id == 9001
  end

  test "normalizes dm message without guild id" do
    raw = %{
      "message" => %{
        "id" => "11",
        "channel_id" => "222",
        "content" => "hi",
        "author" => %{"id" => "99", "username" => "user"}
      },
      "account_id" => "default"
    }

    assert {:ok, inbound} = Inbound.normalize(raw)
    assert inbound.peer.kind == :dm
    assert inbound.meta.guild_id == nil
  end
end
