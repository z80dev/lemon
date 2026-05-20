defmodule LemonCore.MemoryProviders.Local do
  @moduledoc """
  Built-in memory provider backed by `LemonCore.MemoryStore`.
  """

  @behaviour LemonCore.MemoryProvider

  alias LemonCore.MemoryStore

  @impl true
  def put(doc, opts) do
    store = Keyword.get(opts, :memory_store, MemoryStore)
    MemoryStore.put(store, doc)
  end

  @impl true
  def search(query, opts) when is_binary(query) do
    store = Keyword.get(opts, :memory_store, MemoryStore)
    MemoryStore.search(store, query, Keyword.drop(opts, [:memory_store]))
  end
end
