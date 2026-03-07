defmodule LemonControlPlane.ConfigStore do
  @moduledoc """
  Typed wrapper for control-plane system configuration.
  """

  alias LemonCore.Store

  @table :system_config

  @spec get(binary()) :: term()
  def get(key) when is_binary(key), do: Store.get(@table, key)

  @spec put(binary(), term()) :: :ok
  def put(key, value) when is_binary(key), do: Store.put(@table, key, value)

  @spec list() :: list()
  def list, do: Store.list(@table)
end
