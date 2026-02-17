defmodule LemonGateway.Store.EtsBackend do
  @moduledoc """
  ETS store backend adapter for gateway callers.
  """

  @behaviour LemonCore.Store.Backend

  defdelegate init(opts), to: LemonCore.Store.EtsBackend
  defdelegate put(state, table, key, value), to: LemonCore.Store.EtsBackend
  defdelegate get(state, table, key), to: LemonCore.Store.EtsBackend
  defdelegate delete(state, table, key), to: LemonCore.Store.EtsBackend
  defdelegate list(state, table), to: LemonCore.Store.EtsBackend
end
