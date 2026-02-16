defmodule LemonChannels.GatewayConfig do
  @moduledoc false

  # lemon_channels is allowed to run in isolation in tests. Many components
  # historically read configuration from the LemonGateway.Config GenServer.
  # This module now provides a process-independent boundary for channels by
  # reading canonical LemonCore config plus runtime app-env overrides.

  @spec get(atom(), term()) :: term()
  def get(key, default \\ nil) when is_atom(key) do
    gateway = merged_gateway_config()
    fetch(gateway, key, default)
  rescue
    _ -> default
  end

  defp merged_gateway_config do
    gateway_source_config()
    |> merge_telegram_overrides()
  end

  defp gateway_source_config do
    case Application.get_env(:lemon_gateway, LemonGateway.Config) do
      nil ->
        base_gateway_config()

      runtime ->
        runtime
        |> normalize_gateway_env()
    end
  end

  defp base_gateway_config do
    case LemonCore.Config.cached() do
      %{gateway: gateway} when is_map(gateway) -> gateway
      _ -> %{}
    end
  end

  # Keep compatibility with LemonGateway.ConfigLoader override semantics:
  # - map -> map
  # - keyword list -> map
  # - non-keyword list -> bindings list
  defp normalize_gateway_env(config) when is_map(config), do: config
  defp normalize_gateway_env(config) when is_list(config) and config == [], do: %{}

  defp normalize_gateway_env(config) when is_list(config) do
    if Keyword.keyword?(config) do
      Enum.into(config, %{})
    else
      %{bindings: config}
    end
  end

  defp normalize_gateway_env(_), do: %{}

  defp normalize_map(config) when is_map(config), do: config
  defp normalize_map(config) when is_list(config) and config == [], do: %{}

  defp normalize_map(config) when is_list(config) do
    if Keyword.keyword?(config) do
      Enum.into(config, %{})
    else
      %{}
    end
  end

  defp normalize_map(_), do: %{}

  defp merge_telegram_overrides(gateway) when is_map(gateway) do
    telegram_runtime = Application.get_env(:lemon_gateway, :telegram)

    telegram_base =
      gateway
      |> fetch(:telegram, %{})
      |> normalize_map()

    merged_telegram =
      case telegram_runtime do
        nil ->
          telegram_base

        runtime ->
          deep_merge(telegram_base, normalize_map(runtime))
      end

    gateway
    |> Map.delete("telegram")
    |> Map.put(:telegram, merged_telegram)
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Enum.reduce(right, left, fn {right_key, right_value}, acc ->
      target_key = equivalent_key(acc, right_key) || right_key
      left_value = Map.get(acc, target_key)
      merged_value = deep_merge(left_value, right_value)
      Map.put(acc, target_key, merged_value)
    end)
  end

  defp deep_merge(_left, right), do: right

  defp equivalent_key(map, key) when is_map(map) and is_binary(key) do
    Enum.find(Map.keys(map), fn
      existing when is_atom(existing) -> Atom.to_string(existing) == key
      _ -> false
    end)
  end

  defp equivalent_key(map, key) when is_map(map) and is_atom(key) do
    string_key = Atom.to_string(key)

    if Map.has_key?(map, string_key) do
      string_key
    else
      nil
    end
  end

  defp fetch(map, key, default) when is_map(map) and is_atom(key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(map, key) ->
        Map.get(map, key)

      Map.has_key?(map, string_key) ->
        Map.get(map, string_key)

      true ->
        default
    end
  end
end
