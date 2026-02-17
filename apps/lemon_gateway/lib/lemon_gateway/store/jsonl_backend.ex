defmodule LemonGateway.Store.JsonlBackend do
  @moduledoc """
  JSONL store backend adapter for gateway callers.
  """

  @behaviour LemonCore.Store.Backend

  defdelegate init(opts), to: LemonCore.Store.JsonlBackend
  defdelegate put(state, table, key, value), to: LemonCore.Store.JsonlBackend
  defdelegate get(state, table, key), to: LemonCore.Store.JsonlBackend
  defdelegate delete(state, table, key), to: LemonCore.Store.JsonlBackend
  defdelegate list(state, table), to: LemonCore.Store.JsonlBackend

  defdelegate list_tables(state), to: LemonCore.Store.JsonlBackend
  defdelegate ensure_table_loaded(state, table), to: LemonCore.Store.JsonlBackend
end
