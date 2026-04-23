defmodule LemonChannels.GatewayConfig do
  @moduledoc false

  @gateway_config_key :"Elixir.LemonGateway.Config"

  def get(key, default \\ nil) when is_atom(key) do
    case full_replacement_config() do
      {:ok, config} -> LemonCore.GatewayConfig.fetch(config, key, default)
      :none -> LemonCore.GatewayConfig.get(key, default)
    end
  rescue
    _ -> default
  end

  defp full_replacement_config do
    case Application.get_env(:lemon_gateway, @gateway_config_key) do
      nil ->
        :none

      config when is_map(config) ->
        {:ok, config}

      config when is_list(config) ->
        if Keyword.keyword?(config) do
          {:ok, Enum.into(config, %{})}
        else
          {:ok, %{bindings: config}}
        end

      _ ->
        :none
    end
  end
end
