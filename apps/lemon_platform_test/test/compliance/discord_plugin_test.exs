defmodule LemonPlatformTest.DiscordPluginComplianceTest do
  @moduledoc """
  The kit's `PluginCase` run against the Discord adapter.
  """

  use LemonPlatformTest.PluginCase,
    async: false,
    adapter: LemonChannels.Adapters.Discord,
    deliver_probe: {__MODULE__, :unsupported_payload}

  alias LemonChannels.OutboundPayload

  def unsupported_payload(_context) do
    OutboundPayload.new(
      channel_id: "discord",
      account_id: "compliance",
      peer: %{kind: :channel, id: "1", thread_id: nil},
      kind: :carrier_pigeon,
      content: "never sent"
    )
  end
end
