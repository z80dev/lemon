defmodule LemonCore.IdempotencyStore do
  @moduledoc """
  Typed wrapper for persisted idempotency entries.
  """

  alias LemonCore.Store

  @table :idempotency

  @spec key(term(), term()) :: binary()
  def key(scope, key), do: "#{scope}:#{key}"

  @spec get(term(), term()) :: term() | nil
  def get(scope, key), do: Store.get(@table, key(scope, key))

  @spec put(term(), term(), term()) :: :ok | {:error, term()}
  def put(scope, key, value), do: Store.put(@table, key(scope, key), value)

  @spec delete(term(), term()) :: :ok | {:error, term()}
  def delete(scope, key), do: Store.delete(@table, key(scope, key))

  @spec list() :: [{term(), term()}]
  def list, do: Store.list(@table)
end
