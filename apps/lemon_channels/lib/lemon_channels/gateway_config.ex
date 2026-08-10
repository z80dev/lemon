defmodule LemonChannels.GatewayConfig do
  @moduledoc """
  Gateway config as seen by channels.

  Prefers a full-replacement config held by the engine runtime — reached
  through `LemonCore.EngineInfoBridge`, so this app keeps no reference to the
  gateway — and otherwise reads the canonical config.
  """

  def get(key, default \\ nil) when is_atom(key) do
    case LemonCore.EngineInfoBridge.gateway_config() do
      {:ok, config} -> LemonCore.GatewayConfig.fetch(config, key, default)
      :none -> LemonCore.GatewayConfig.get(key, default)
    end
  rescue
    _ -> default
  end
end
