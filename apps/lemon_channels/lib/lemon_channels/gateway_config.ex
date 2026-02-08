defmodule LemonChannels.GatewayConfig do
  @moduledoc false

  # lemon_channels is allowed to run in isolation in tests. Many components
  # historically read configuration from the LemonGateway.Config GenServer,
  # but that process may not be started in lemon_channels-only test runs.

  @spec get(atom(), term()) :: term()
  def get(key, default \\ nil) when is_atom(key) do
    if Process.whereis(LemonGateway.Config) do
      LemonGateway.Config.get(key)
    else
      fallback_get(key, default)
    end
  rescue
    _ -> default
  end

  defp fallback_get(:telegram, default) do
    Application.get_env(:lemon_gateway, :telegram) || default
  end

  defp fallback_get(:discord, default) do
    Application.get_env(:lemon_gateway, :discord) || default
  end

  defp fallback_get(:enable_discord, default) do
    Application.get_env(:lemon_gateway, :enable_discord, default)
  end

  defp fallback_get(:enable_telegram, default) do
    Application.get_env(:lemon_gateway, :enable_telegram, default)
  end

  defp fallback_get(key, default) do
    Application.get_env(:lemon_gateway, LemonGateway.Config, %{})
    |> Map.get(key, default)
  end
end

