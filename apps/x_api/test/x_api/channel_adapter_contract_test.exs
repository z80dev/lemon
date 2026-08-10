defmodule XApi.ChannelAdapterContractTest do
  @moduledoc """
  The satellite's adapter, held to the published `LemonChannels.Plugin` contract.

  This is the shape a third-party integration takes: x_api depends on
  `lemon_channels` and on `lemon_platform_test`, the platform depends on neither
  x_api nor this test, and the registration round-trip proves the platform can
  discover an adapter it has no compile-time knowledge of.

  `deliver/1` is probed with an `:edit` payload, which `XApi.ChannelAdapter`
  refuses locally — no request ever reaches the X API.
  """

  use LemonPlatformTest.PluginCase,
    async: false,
    adapter: XApi.ChannelAdapter,
    start_adapter: true,
    deliver_probe: {__MODULE__, :edit_payload}

  alias LemonChannels.OutboundPayload

  def edit_payload(_context) do
    OutboundPayload.new(
      channel_id: "x_api",
      account_id: "compliance",
      peer: %{kind: :channel, id: "1", thread_id: nil},
      kind: :edit,
      content: %{message_id: "1", text: "never sent"}
    )
  end
end
