defmodule LemonCore.IdempotencyStore do
  @moduledoc """
  Typed wrapper for persisted idempotency entries.

  Reads are strict (`fetch/2`): an unavailable Store is an error, never an
  absent key. `LemonCore.Idempotency` owns the entry format and state machine.
  """

  alias LemonCore.Store

  @table :idempotency

  @spec key(term(), term()) :: binary()
  def key(scope, key), do: "#{scope}:#{key}"

  @spec fetch(term(), term()) :: {:ok, term() | nil} | {:error, :store_unavailable}
  def fetch(scope, key), do: Store.fetch(@table, key(scope, key))

  @spec put(term(), term(), term()) :: :ok | {:error, term()}
  def put(scope, key, value), do: Store.put(@table, key(scope, key), value)

  @spec put_new(term(), term(), term()) :: :ok | {:error, :exists | term()}
  def put_new(scope, key, value), do: Store.put_new(@table, key(scope, key), value)

  @spec compare_and_swap(term(), term(), term(), term()) :: :ok | {:error, :mismatch | term()}
  def compare_and_swap(scope, key, expected, value),
    do: Store.compare_and_swap(@table, key(scope, key), expected, value)

  @spec compare_and_delete(term(), term(), term()) :: :ok | {:error, :mismatch | term()}
  def compare_and_delete(scope, key, expected),
    do: Store.compare_and_delete(@table, key(scope, key), expected)

  @spec delete(term(), term()) :: :ok | {:error, term()}
  def delete(scope, key), do: Store.delete(@table, key(scope, key))

  @doc "All entries, for diagnostics only; `[]` when the Store cannot answer."
  @spec list() :: [{term(), term()}]
  def list, do: Store.list(@table)
end
