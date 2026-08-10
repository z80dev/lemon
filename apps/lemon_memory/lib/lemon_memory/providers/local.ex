defmodule LemonMemory.Providers.Local do
  @moduledoc """
  Built-in memory provider backed by `LemonMemory.Store`.
  """

  @behaviour LemonMemory.Provider

  alias LemonMemory.Store

  @impl true
  def put(doc, opts) do
    store = Keyword.get(opts, :memory_store, Store)
    Store.put(store, doc)
  end

  @impl true
  def search(query, opts) when is_binary(query) do
    store = Keyword.get(opts, :memory_store, Store)
    Store.search(store, query, Keyword.drop(opts, [:memory_store]))
  end
end
