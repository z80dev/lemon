defmodule LemonControlPlane.ConfigStore do
  @moduledoc """
  Typed wrapper for control-plane system configuration.

  Reads are strict: an unreadable store is `{:error, :store_unavailable}`,
  never an unset key or an empty configuration.
  """

  alias LemonCore.Store

  @table :system_config

  @doc "Reads one stored value; `{:ok, nil}` only when the key is confirmed unset."
  @spec fetch(binary()) :: {:ok, term()} | {:error, :store_unavailable}
  def fetch(key) when is_binary(key), do: Store.fetch(@table, key)

  @spec put(binary(), term()) :: :ok
  def put(key, value) when is_binary(key), do: Store.put(@table, key, value)

  @doc "Reads every stored value."
  @spec fetch_all() :: {:ok, [{term(), term()}]} | {:error, :store_unavailable}
  def fetch_all, do: Store.fetch_all(@table)
end
