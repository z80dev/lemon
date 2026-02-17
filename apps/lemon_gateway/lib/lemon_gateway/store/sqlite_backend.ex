defmodule LemonGateway.Store.SqliteBackend do
  @moduledoc """
  SQLite store backend adapter for gateway callers.
  """

  @behaviour LemonCore.Store.Backend

  defdelegate init(opts), to: LemonCore.Store.SqliteBackend
  defdelegate put(state, table, key, value), to: LemonCore.Store.SqliteBackend
  defdelegate get(state, table, key), to: LemonCore.Store.SqliteBackend
  defdelegate delete(state, table, key), to: LemonCore.Store.SqliteBackend
  defdelegate list(state, table), to: LemonCore.Store.SqliteBackend

  defdelegate list_tables(state), to: LemonCore.Store.SqliteBackend
  defdelegate close(state), to: LemonCore.Store.SqliteBackend
end
