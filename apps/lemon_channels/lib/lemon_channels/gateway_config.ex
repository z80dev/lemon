defmodule LemonChannels.GatewayConfig do
  @moduledoc false

  # Thin wrapper delegating to the canonical LemonCore.GatewayConfig.
  # Kept for backward-compatibility; new code should use LemonCore.GatewayConfig directly.

  defdelegate get(key, default \\ nil), to: LemonCore.GatewayConfig
  defdelegate get_telegram(key, default \\ nil), to: LemonCore.GatewayConfig
end
