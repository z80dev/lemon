defmodule LemonPlatformTest.TelegramPluginComplianceTest do
  @moduledoc """
  The kit's `PluginCase` run against the Telegram adapter.

  The deliver probe uses a payload kind Telegram does not implement, so the
  suite proves `deliver/1` reports the failure without ever reaching the
  Telegram API.
  """

  use LemonPlatformTest.PluginCase,
    async: false,
    adapter: LemonChannels.Adapters.Telegram,
    deliver_probe: {__MODULE__, :unsupported_payload},
    inbound_fixtures: {__MODULE__, :updates}

  alias LemonChannels.OutboundPayload

  def unsupported_payload(_context) do
    OutboundPayload.new(
      channel_id: "telegram",
      account_id: "compliance",
      peer: %{kind: :dm, id: "1", thread_id: nil},
      kind: :carrier_pigeon,
      content: "never sent"
    )
  end

  def updates(_context) do
    [
      %{
        "update_id" => 1,
        "message" => %{
          "message_id" => 10,
          "date" => 1_700_000_000,
          "text" => "hello from a private chat",
          "chat" => %{"id" => 4242, "type" => "private"},
          "from" => %{"id" => 99, "username" => "someone", "first_name" => "Some"}
        }
      },
      %{
        "update_id" => 2,
        "channel_post" => %{
          "message_id" => 11,
          "date" => 1_700_000_001,
          "text" => "hello from a channel",
          "chat" => %{"id" => -100, "type" => "channel"}
        }
      }
    ]
  end
end
