defmodule LemonChannels.GatewayConfig do
  @moduledoc false

  # Channels read canonical gateway settings from LemonCore config and allow
  # explicit runtime overrides under the :lemon_channels app env.

  @spec get(atom(), term()) :: term()
  def get(key, default \\ nil) when is_atom(key) do
    gateway = merged_config()
    fetch(gateway, key, default)
  rescue
    _ -> default
  end

  defp merged_config do
    base_gateway_config()
    |> deep_merge(runtime_gateway_overrides())
    |> merge_telegram_overrides()
    |> merge_discord_overrides()
    |> merge_xmtp_overrides()
  end

  defp base_gateway_config do
    case LemonCore.Config.cached() do
      %{gateway: gateway} when is_map(gateway) -> gateway
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  defp runtime_gateway_overrides do
    Application.get_env(:lemon_channels, :gateway, %{})
    |> normalize_map()
  end

  defp merge_telegram_overrides(gateway) when is_map(gateway) do
    merge_nested_runtime_overrides(gateway, :telegram)
  end

  defp merge_xmtp_overrides(gateway) when is_map(gateway) do
    merge_nested_runtime_overrides(gateway, :xmtp)
  end

  defp merge_discord_overrides(gateway) when is_map(gateway) do
    merge_nested_runtime_overrides(gateway, :discord)
  end

  defp merge_nested_runtime_overrides(gateway, key) when is_map(gateway) and is_atom(key) do
    runtime = Application.get_env(:lemon_channels, key, %{})

    base =
      gateway
      |> fetch(key, %{})
      |> normalize_map()

    merged = deep_merge(base, normalize_map(runtime))
    string_key = Atom.to_string(key)

    gateway
    |> Map.delete(string_key)
    |> Map.put(key, merged)
  end

  defp normalize_map(config) when is_map(config), do: config

  defp normalize_map(config) when is_list(config) do
    if Keyword.keyword?(config), do: Enum.into(config, %{}), else: %{}
  end

  defp normalize_map(_), do: %{}

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
