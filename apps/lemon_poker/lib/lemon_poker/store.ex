defmodule LemonPoker.Store do
  @moduledoc """
  Poker-specific runtime store configuration.

  By default, poker runs use the canonical Lemon store configuration so provider
  API keys stored via `mix lemon.secrets.*` stay available.

  Optional isolation can be enabled with `LEMON_POKER_ISOLATE_STORE=true`, which
  points poker at a dedicated SQLite path (`LEMON_POKER_STORE_PATH`).
  """

  @default_ephemeral_tables [:runs]
  @isolate_store_env "LEMON_POKER_ISOLATE_STORE"

  @doc """
  Install optional runtime store overrides for poker runs.
  """
  @spec install_runtime_override!() :: :ok
  def install_runtime_override! do
    config = runtime_override_config()

    Application.put_env(:lemon_poker, __MODULE__, config, persistent: true)

    if config == [] do
      Application.delete_env(:lemon_core, :store_runtime_override)
    else
      Application.put_env(:lemon_core, :store_runtime_override, config, persistent: true)
    end

    :ok
  end

  @doc """
  Returns optional poker runtime store override config.
  """
  @spec runtime_override_config() :: keyword() | []
  def runtime_override_config do
    if isolate_store?() do
      [
        backend: LemonCore.Store.SqliteBackend,
        backend_opts: [
          path: store_path(),
          ephemeral_tables: @default_ephemeral_tables
        ]
      ]
    else
      []
    end
  end

  @doc """
  Returns the poker store path.
  """
  @spec store_path() :: String.t()
  def store_path do
    case System.get_env("LEMON_POKER_STORE_PATH") do
      path when is_binary(path) and path != "" ->
        Path.expand(path)

      _ ->
        Path.expand("~/.lemon/poker-store")
    end
  end

  @doc """
  Returns whether poker should isolate its store from the main Lemon runtime.
  """
  @spec isolate_store?() :: boolean()
  def isolate_store? do
    case System.get_env(@isolate_store_env) do
      value when is_binary(value) ->
        value
        |> String.trim()
        |> String.downcase()
        |> then(&(&1 in ["1", "true", "yes", "on"]))

      _ ->
        false
    end
  end
end
