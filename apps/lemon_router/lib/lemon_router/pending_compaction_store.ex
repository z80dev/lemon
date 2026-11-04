defmodule LemonRouter.PendingCompactionStore do
  @moduledoc """
  Router-owned typed wrapper for pending-compaction markers.

  Marker lifecycle policy, prompt preparation, and post-submit consumption live
  in `LemonRouter.PendingCompaction`; this module remains the storage boundary.
  """

  alias LemonCore.Store

  @table :pending_compaction

  @spec get(binary()) :: map() | nil
  def get(session_key) when is_binary(session_key), do: Store.get(@table, session_key)

  @spec put(binary(), map()) :: :ok | {:error, term()}
  def put(session_key, marker) when is_binary(session_key) and is_map(marker),
    do: Store.put(@table, session_key, marker)

  @spec delete(binary()) :: :ok | {:error, term()}
  def delete(session_key) when is_binary(session_key), do: Store.delete(@table, session_key)

  @doc "Deletes only the exact inspected marker; a replacement returns `{:error, :mismatch}`."
  @spec compare_and_delete(binary(), map()) :: :ok | {:error, term()}
  def compare_and_delete(session_key, marker)
      when is_binary(session_key) and is_map(marker),
      do: Store.compare_and_delete(@table, session_key, marker)

  @spec list() :: list()
  def list, do: Store.list(@table)
end
