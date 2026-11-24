defmodule LemonCore.StoreCacheWarmTest do
  @moduledoc """
  A table is published as cached only after its warm-up succeeded (#618).

  An unwarmed mirror is empty, so publishing it would turn a backend read
  failure into an authoritative empty table.
  """

  use ExUnit.Case, async: false

  alias LemonCore.Store
  alias LemonCore.Store.{EtsBackend, Hooks}

  defmodule FlakyListBackend do
    @moduledoc """
    ETS backend whose `list/2` of the tables named in the `:flaky_tables`
    persistent term fails with `{:error, :corrupt}`. Seeds `:seed` rows at init.
    """
    @behaviour LemonCore.Store.Backend

    @impl true
    def init(opts) do
      {:ok, state} = EtsBackend.init([])

      state =
        Enum.reduce(Keyword.get(opts, :seed, []), state, fn {table, key, value}, acc ->
          {:ok, acc} = EtsBackend.put(acc, table, key, value)
          acc
        end)

      {:ok, state}
    end

    @impl true
    def list(state, table) do
      if table in :persistent_term.get({__MODULE__, :flaky_tables}, []),
        do: {:error, :corrupt},
        else: EtsBackend.list(state, table)
    end

    @impl true
    defdelegate put(state, table, key, value), to: EtsBackend
    @impl true
    defdelegate put_new(state, table, key, value), to: EtsBackend
    @impl true
    defdelegate get(state, table, key), to: EtsBackend
    @impl true
    defdelegate delete(state, table, key), to: EtsBackend
  end

  setup do
    on_exit(fn -> :persistent_term.erase({FlakyListBackend, :flaky_tables}) end)
    :ok
  end

  defp fail_lists(tables), do: :persistent_term.put({FlakyListBackend, :flaky_tables}, tables)

  defp store_spec(name) do
    seed = [
      {:sessions_index, "agent:a:main", %{agent_id: "a"}},
      {:hot_index, {:scope, 1}, "run-1"}
    ]

    Supervisor.child_spec(
      {Store,
       name: name,
       backend: FlakyListBackend,
       backend_opts: [seed: seed],
       cached_tables: [:sessions_index, :hot_index]},
      id: name
    )
  end

  defp unique(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"

  test "a table whose warm-up failed is not published and strict reads surface the error" do
    fail_lists([:hot_index])
    store = unique(:warm_failed)
    start_supervised!(store_spec(store))

    published = Hooks.published(store, :cached_tables, [])
    assert :sessions_index in published
    refute :hot_index in published

    assert {:error, :store_unavailable} = Store.fetch_all(store, :hot_index)
  end

  test "reads of a table whose warm-up failed reach the backend instead of an empty mirror" do
    fail_lists([:hot_index])
    store = unique(:warm_failed_list)
    start_supervised!(store_spec(store))

    # The backend recovers; the table was never warmed, so the answer must come
    # from the backend and not from the empty ETS mirror.
    fail_lists([])

    assert Store.list(store, :hot_index) == [{{:scope, 1}, "run-1"}]
    assert {:ok, [{{:scope, 1}, "run-1"}]} = Store.fetch_all(store, :hot_index)
    assert Store.get(store, :hot_index, {:scope, 1}) == "run-1"

    # Writes to the unpublished table do not populate the mirror either.
    :ok = Store.put(store, :hot_index, {:scope, 2}, "run-2")
    assert LemonCore.Store.ReadCache.get(store, :hot_index, {:scope, 2}) == nil
    assert Store.get(store, :hot_index, {:scope, 2}) == "run-2"
  end

  test "a restart re-publishes only the tables that warmed" do
    store = unique(:warm_restart)
    start_supervised!(store_spec(store))
    assert Enum.sort(Hooks.published(store, :cached_tables, [])) == [:hot_index, :sessions_index]

    stop_supervised!(store)
    fail_lists([:sessions_index])
    start_supervised!(store_spec(store))

    assert Hooks.published(store, :cached_tables, []) == [:hot_index]
    assert {:error, :store_unavailable} = Store.fetch_all(store, :sessions_index)
    assert Store.list(store, :hot_index) == [{{:scope, 1}, "run-1"}]

    stop_supervised!(store)
    fail_lists([])
    start_supervised!(store_spec(store))

    assert Enum.sort(Hooks.published(store, :cached_tables, [])) == [:hot_index, :sessions_index]
    assert Store.list(store, :sessions_index) == [{"agent:a:main", %{agent_id: "a"}}]
  end

  test "a stopped store unpublishes its mirrors" do
    store = unique(:warm_stopped)
    start_supervised!(store_spec(store))
    assert Hooks.published(store, :cached_tables, []) != []

    stop_supervised!(store)
    assert Hooks.published(store, :cached_tables, []) == []
    assert Store.list(store, :sessions_index) == []
  end

  test "re-registering a table whose warm-up failed retries the warm" do
    store = unique(:warm_register)
    fail_lists([:hot_index])
    start_supervised!(store_spec(store))
    refute :hot_index in Hooks.published(store, :cached_tables, [])

    fail_lists([])
    :ok = Store.register_cached_table(store, :hot_index)
    on_exit(fn -> Store.unregister_cached_table(store, :hot_index) end)

    assert :hot_index in Hooks.published(store, :cached_tables, [])
    assert Store.list(store, :hot_index) == [{{:scope, 1}, "run-1"}]
  end
end
