defmodule LemonCore.IdempotencyStore do
  @moduledoc """
  Persisted idempotency entries, keyed by scope and key.

  Owns the `:idempotency` table. Entries record when they were inserted
  under `"inserted_at_ms"` and are removed by the store's sweep 48 hours
  later; an entry without that field is kept.
  """

  use LemonCore.Store.Table,
    tables: [
      idempotency: [retention: [max_age_ms: 48 * 60 * 60 * 1000, timestamp: :inserted_at_ms]]
    ]

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
