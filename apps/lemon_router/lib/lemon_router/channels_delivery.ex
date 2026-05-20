defmodule LemonRouter.ChannelsDelivery do
  @moduledoc false

  def enqueue(payload, _opts \\ []) do
    LemonChannels.enqueue(payload)
  end
end
