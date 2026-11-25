defmodule LemonCore.GatewayConfig do
  @moduledoc """
  Unified gateway configuration access.

  Gateway config comes from the canonical TOML `[gateway]` section only, read
  through `LemonCore.Config.cached/1`: reads are ETS lookups, see config
  reloads without a restart, and keep serving the last good config when a
  reload fails (`LemonCore.ConfigCache`). A config that cannot be loaded at all
  raises `LemonCore.Config.ValidationError`; it is never read as empty.

  In test mode (`config_test_mode`), a full-replacement app env layer
  (`Application.get_env(:lemon_gateway, :"Elixir.LemonGateway.Config")`, a
  test-only key) replaces the TOML section for test isolation.
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
  end

  # ---------------------------------------------------------------------------
  # Config sources
  # ---------------------------------------------------------------------------

  defp toml_base(cwd), do: LemonCore.Config.cached(cwd).gateway

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
