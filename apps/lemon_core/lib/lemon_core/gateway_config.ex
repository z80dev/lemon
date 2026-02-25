defmodule LemonCore.GatewayConfig do
  @moduledoc """
  Unified gateway configuration access.

  Merges config from multiple layers (highest priority wins):

  1. Per-transport app env overrides (`:lemon_channels` `:telegram` / `:discord` / `:xmtp`)
  2. Channels gateway override (`Application.get_env(:lemon_channels, :gateway)`)
  3. Full-replacement app env (`Application.get_env(:lemon_gateway, LemonGateway.Config)`)
     When set (even to `%{}`), this replaces the TOML base entirely (critical for test isolation).
  4. TOML base from `LemonCore.Config.cached/1`
  """

  @doc """
  Load the fully-merged gateway config map.

  If `cwd` is given, it is forwarded to `LemonCore.Config.cached/1` for project-level
  TOML overlay.
  """
  @spec load(String.t() | nil) :: map()
  def load(cwd \\ nil) do
    base = base_config(cwd)

    base
    |> deep_merge(channels_gateway_overrides())
    |> merge_transport_overrides(:telegram)
    |> merge_transport_overrides(:discord)
    |> merge_transport_overrides(:xmtp)
  end

  @doc """
  Get a single key from the merged gateway config.
  """
  @spec get(atom(), term()) :: term()
  def get(key, default \\ nil) when is_atom(key) do
    gateway = load()
    fetch(gateway, key, default)
  rescue
    _ -> default
  end

  # ---------------------------------------------------------------------------
  # Layer 1: base config
  # ---------------------------------------------------------------------------

  defp base_config(cwd) do
    # When :lemon_gateway app env is set for LemonGateway.Config, use it as
    # full-replacement (test isolation semantics).
    case full_replacement_config() do
      {:ok, config} ->
        config

      :none ->
        # Fall through to TOML
        case LemonCore.Config.cached(cwd) do
          %{gateway: gateway} when is_map(gateway) -> gateway
          _ -> %{}
        end
    end
  rescue
    _ -> %{}
  end

  defp full_replacement_config do
    case Application.get_env(:lemon_gateway, LemonGateway.Config) do
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

  # ---------------------------------------------------------------------------
  # Layer 2: :lemon_channels :gateway overrides
  # ---------------------------------------------------------------------------

  defp channels_gateway_overrides do
    Application.get_env(:lemon_channels, :gateway, %{})
    |> normalize_map()
  end

  # ---------------------------------------------------------------------------
  # Layer 3: per-transport overrides from :lemon_channels app env
  # ---------------------------------------------------------------------------

  defp merge_transport_overrides(gateway, transport_key) when is_atom(transport_key) do
    runtime = Application.get_env(:lemon_channels, transport_key, %{})

    base =
      gateway
      |> fetch(transport_key, %{})
      |> normalize_map()

    merged = deep_merge(base, normalize_map(runtime))
    string_key = Atom.to_string(transport_key)

    gateway
    |> Map.delete(string_key)
    |> Map.put(transport_key, merged)
  end

  # ---------------------------------------------------------------------------
  # Deep merge with atom/string key coexistence
  # ---------------------------------------------------------------------------

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Enum.reduce(right, left, fn {right_key, right_value}, acc ->
      target_key = equivalent_key(acc, right_key) || right_key
      left_value = Map.get(acc, target_key)
      merged_value = deep_merge(left_value, right_value)
      Map.put(acc, target_key, merged_value)
    end)
  end

  defp deep_merge(_left, right), do: right

  @doc false
  def equivalent_key(map, key) when is_map(map) and is_binary(key) do
    Enum.find(Map.keys(map), fn
      existing when is_atom(existing) -> Atom.to_string(existing) == key
      _ -> false
    end)
  end

  def equivalent_key(map, key) when is_map(map) and is_atom(key) do
    string_key = Atom.to_string(key)

    if Map.has_key?(map, string_key) do
      string_key
    else
      nil
    end
  end

  def equivalent_key(_map, _key), do: nil

  # ---------------------------------------------------------------------------
  # Key fetch helpers (atom/string agnostic)
  # ---------------------------------------------------------------------------

  defp fetch(map, key, default) when is_map(map) and is_atom(key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, string_key) -> Map.get(map, string_key)
      true -> default
    end
  end

  defp fetch(_map, _key, default), do: default

  defp normalize_map(config) when is_map(config), do: config

  defp normalize_map(config) when is_list(config) do
    if Keyword.keyword?(config), do: Enum.into(config, %{}), else: %{}
  end

  defp normalize_map(_), do: %{}
end
