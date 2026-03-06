defmodule LemonRouter.PendingCompactionStore do
  @moduledoc """
  Router-owned typed wrapper for pending-compaction markers.
  """

  alias LemonCore.Store

  @table :pending_compaction

  @spec get(binary()) :: map() | nil
  def get(session_key) when is_binary(session_key), do: Store.get(@table, session_key)

  @spec put(binary(), map()) :: :ok
  def put(session_key, marker) when is_binary(session_key) and is_map(marker),
    do: Store.put(@table, session_key, marker)

  @spec delete(binary()) :: :ok
  def delete(session_key) when is_binary(session_key), do: Store.delete(@table, session_key)

  @spec list() :: list()
  def list, do: Store.list(@table)
end
