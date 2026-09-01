defmodule LemonRouter.ChannelsDelivery do
  @moduledoc """
  The one place router-owned and automation-origin notifications enter
  `lemon_channels`.

  Callers hand over a channels outbound payload struct, or a plain map with
  the same fields when they must not depend on channels at all (automation is
  the case: it depends on the router, not on channels). Rendering stays in
  channels; this module does not build platform-specific payloads.
  """

  @spec enqueue(map(), keyword()) :: {:ok, reference()} | {:error, term()}
  def enqueue(payload, _opts \\ []) do
    LemonChannels.enqueue(payload)
  end
end
