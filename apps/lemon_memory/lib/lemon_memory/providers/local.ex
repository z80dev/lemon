defmodule LemonMemory.Providers.Local do
  @moduledoc """
  Built-in memory provider backed by `LemonMemory.Store`.
  """

  @behaviour LemonMemory.Provider

  alias LemonMemory.Store

  @impl true
  def put(doc, opts) do
    store = Keyword.get(opts, :memory_store, Store)
    Store.put_sync(store, doc)
  end
end
