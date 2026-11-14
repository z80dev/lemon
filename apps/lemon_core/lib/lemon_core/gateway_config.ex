defmodule LemonCore.GatewayConfig do
  @moduledoc """
  Unified gateway configuration access.

  Gateway config comes from the canonical TOML `[gateway]` section only.
  In test mode (`config_test_mode`), a full-replacement app env layer
  (`Application.get_env(:lemon_gateway, LemonGateway.Config)`) is supported
  for test isolation.
  """

  @doc """
  Load the gateway config map.

  In production, reads from TOML base only.
  In test mode, checks for full-replacement app env first.
  """
  @spec load(String.t() | nil) :: map()
  def load(cwd \\ nil) do
    if test_env?() do
      case full_replacement_config() do
        {:ok, config} -> config
        :none -> toml_base(cwd)
      end
    else
      toml_base(cwd)
    end
  end

  @doc """
  Get a single key from the gateway config.
  """
  @spec get(atom(), term()) :: term()
  def get(key, default \\ nil) when is_atom(key) do
    gateway = load()
    fetch(gateway, key, default)
  rescue
    _ -> default
  end

  # ---------------------------------------------------------------------------
  # Config sources
  # ---------------------------------------------------------------------------

  defp toml_base(cwd) do
    case LemonCore.Config.cached(cwd) do
      %{gateway: gateway} when is_map(gateway) -> gateway
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  defp full_replacement_config do
    case Application.get_env(:lemon_gateway, :"Elixir.LemonGateway.Config") do
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

  defp test_env? do
    Application.get_env(:lemon_core, :config_test_mode, false)
  end

  # ---------------------------------------------------------------------------
  # Key fetch helpers (atom/string agnostic)
  # ---------------------------------------------------------------------------

  @doc false
  def fetch(map, key, default) when is_map(map) and is_atom(key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, string_key) -> Map.get(map, string_key)
      true -> default
    end
  end

  def fetch(_map, _key, default), do: default
end
