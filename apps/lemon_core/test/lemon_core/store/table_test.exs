defmodule LemonCore.Store.TableTest do
  @moduledoc """
  Table declarations: what a domain module can say about a table, how the
  store applies it, and what registration refuses.
  """

  use ExUnit.Case, async: true

  alias LemonCore.Store
  alias LemonCore.Store.EtsBackend
  alias LemonCore.Store.ReadCache
  alias LemonCore.Store.Table

  defmodule TableTestDeclared do
    @moduledoc false
    use LemonCore.Store.Table,
      tables: [
        table_test_plain: [],
        table_test_cached: [cached: true, version: 2],
        table_test_absolute: [retention: [expires_at: :expires_at]],
        table_test_aged: [retention: [max_age_ms: 1_000, timestamp: :inserted_at_ms]],
        table_test_dated: [retention: [max_age_ms: 1_000, timestamp: {__MODULE__, :dated_at}]]
      ]

    def dated_at({ts, _id}, _value) when is_integer(ts), do: ts
    def dated_at(_key, _value), do: nil
  end

  defmodule TableTestRival do
    @moduledoc false
    use LemonCore.Store.Table, tables: [table_test_plain: []]
  end

  defmodule TableTestNotATable do
    @moduledoc false
  end

  defp start_store(name, opts) do
    spec = Supervisor.child_spec({Store, Keyword.put(opts, :name, name)}, id: name)
    start_supervised!(spec)
    name
  end

  defp unique(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"

  describe "declare!/2" do
    test "records name, owner and defaults" do
      assert [plain, cached | _] = TableTestDeclared.__store_tables__()

      assert %Table{
               name: :table_test_plain,
               owner: TableTestDeclared,
               cached: false,
               retention: nil,
               persistence: :durable,
               version: 1
             } = plain

      assert %Table{name: :table_test_cached, cached: true, version: 2} = cached
    end

    test "refuses what the store cannot honour" do
      assert_raise ArgumentError, ~r/declares no tables/, fn ->
        Table.declare!(TableTestDeclared, [])
      end

      assert_raise ArgumentError, ~r/unknown options \[:ttl\]/, fn ->
        Table.declare!(TableTestDeclared, bad: [ttl: 1])
      end

      assert_raise ArgumentError, ~r/positive :max_age_ms/, fn ->
        Table.declare!(TableTestDeclared, bad: [retention: [max_age_ms: 0, timestamp: :ts]])
      end

      assert_raise ArgumentError, ~r/:timestamp must be a field or \{module, function\}/, fn ->
        Table.declare!(TableTestDeclared, bad: [retention: [max_age_ms: 1, timestamp: 42]])
      end

      assert_raise ArgumentError, ~r/persistence must be :durable or :ephemeral/, fn ->
        Table.declare!(TableTestDeclared, bad: [persistence: :memory])
      end
    end
  end

  describe "expired?/4" do
    test "an absolute expiry compares the stored field with now" do
      table = %Table{name: :t, owner: TableTestDeclared, retention: [expires_at: :expires_at]}

      assert Table.expired?(table, :k, %{expires_at: 99}, 100)
      refute Table.expired?(table, :k, %{expires_at: 100}, 100)
      refute Table.expired?(table, :k, %{"expires_at" => 101}, 100)
      assert Table.expired?(table, :k, %{"expires_at" => 1}, 100)
      refute Table.expired?(table, :k, %{other: 1}, 100)
      refute Table.expired?(table, :k, "not a map", 100)
    end

    test "an age is measured from a field, under its atom or string key" do
      table = %Table{
        name: :t,
        owner: TableTestDeclared,
        retention: [max_age_ms: 1_000, timestamp: :inserted_at_ms]
      }

      assert Table.expired?(table, :k, %{inserted_at_ms: 0}, 2_000)
      assert Table.expired?(table, :k, %{"inserted_at_ms" => 0}, 2_000)
      refute Table.expired?(table, :k, %{inserted_at_ms: 1_500}, 2_000)
      refute Table.expired?(table, :k, %{}, 2_000)
    end

    test "an age can come from the owner's own function over key and value" do
      table = %Table{
        name: :t,
        owner: TableTestDeclared,
        retention: [max_age_ms: 1_000, timestamp: {TableTestDeclared, :dated_at}]
      }

      assert Table.expired?(table, {0, "id"}, %{}, 2_000)
      refute Table.expired?(table, {1_999, "id"}, %{}, 2_000)
      refute Table.expired?(table, "undated", %{}, 2_000)
    end

    test "a table without retention never expires" do
      refute Table.expired?(%Table{name: :t, owner: TableTestDeclared}, :k, %{expires_at: 0}, 100)
    end
  end

  describe "registration" do
    test "a module's tables are applied by the store it registers with" do
      store = unique(:table_test_register)
      on_exit(fn -> Table.clear(store) end)
      :ok = Table.register(store, TableTestDeclared)
      start_store(store, backend: EtsBackend, table_modules: [])

      assert Enum.map(Store.registered_tables(store), & &1.name) |> Enum.sort() ==
               Enum.sort([
                 :table_test_absolute,
                 :table_test_aged,
                 :table_test_cached,
                 :table_test_dated,
                 :table_test_plain
               ])

      # TableTestDeclared cached: mirrored, so a read is served from ETS.
      :ok = Store.put(store, :table_test_cached, "k", "v")
      assert ReadCache.get(store, :table_test_cached, "k") == "v"

      # Not declared cached: readable, not mirrored.
      :ok = Store.put(store, :table_test_plain, "k", "v")
      assert ReadCache.get(store, :table_test_plain, "k") == nil
      assert Store.get(store, :table_test_plain, "k") == "v"
    end

    test "a running store applies a late registration at once" do
      store = start_store(unique(:table_test_late), backend: EtsBackend, table_modules: [])
      on_exit(fn -> Table.clear(store) end)

      :ok = Store.put(store, :table_test_cached, "early", "v")
      refute ReadCache.cached?(store, :table_test_cached)

      :ok = Table.register(store, TableTestDeclared)

      assert ReadCache.cached?(store, :table_test_cached)
      assert ReadCache.get(store, :table_test_cached, "early") == "v"
    end

    test "a table another module owns is refused" do
      store = unique(:table_test_rival)
      on_exit(fn -> Table.clear(store) end)
      :ok = Table.register(store, TableTestDeclared)

      assert_raise ArgumentError, ~r/cannot register :table_test_plain/, fn ->
        Table.register(store, TableTestRival)
      end

      assert %Table{owner: TableTestDeclared} = Table.fetch(store, :table_test_plain)
    end

    test "re-registering from the owner replaces the declaration" do
      store = unique(:table_test_replace)
      on_exit(fn -> Table.clear(store) end)
      :ok = Table.register(store, TableTestDeclared)

      [plain | _] = TableTestDeclared.__store_tables__()
      assert :ok = Store.register_table(store, %{plain | version: 3})
      assert %Table{version: 3} = Table.fetch(store, :table_test_plain)
    end

    test "a module without declarations cannot register" do
      assert_raise ArgumentError, ~r/does not declare store tables/, fn ->
        Table.register(unique(:table_test_none), TableTestNotATable)
      end
    end
  end

  describe "retention in the store" do
    setup do
      store = unique(:table_test_sweep)
      on_exit(fn -> Table.clear(store) end)
      :ok = Table.register(store, TableTestDeclared)
      start_store(store, backend: EtsBackend, table_modules: [])
      %{store: store}
    end

    test "each declared retention form expires its rows and keeps the rest", %{store: store} do
      now = System.system_time(:millisecond)

      :ok = Store.put(store, :table_test_absolute, :old, %{expires_at: now - 1})
      :ok = Store.put(store, :table_test_absolute, :live, %{expires_at: now + 60_000})
      :ok = Store.put(store, :table_test_aged, :old, %{inserted_at_ms: now - 5_000})
      :ok = Store.put(store, :table_test_aged, :live, %{inserted_at_ms: now})
      :ok = Store.put(store, :table_test_aged, :undated, %{note: "kept"})
      :ok = Store.put(store, :table_test_dated, {now - 5_000, "old"}, %{})
      :ok = Store.put(store, :table_test_dated, {now, "live"}, %{})
      :ok = Store.put(store, :table_test_plain, :old, %{expires_at: 0, inserted_at_ms: 0})

      :ok = Store.sweep(store)

      assert Store.list(store, :table_test_absolute) |> Enum.map(&elem(&1, 0)) == [:live]

      assert Store.list(store, :table_test_aged) |> Enum.map(&elem(&1, 0)) |> Enum.sort() ==
               [:live, :undated]

      assert Store.list(store, :table_test_dated) |> Enum.map(&elem(&1, 0)) == [{now, "live"}]
      assert Store.list(store, :table_test_plain) |> Enum.map(&elem(&1, 0)) == [:old]
    end
  end

  describe "backends" do
    @tag :tmp_dir
    test "the SQLite backend keeps an ephemeral table in memory", %{tmp_dir: tmp_dir} do
      {:ok, state} = Store.SqliteBackend.init(path: Path.join(tmp_dir, "store.sqlite3"))

      {:ok, state} =
        Store.SqliteBackend.register_table(state, %Table{
          name: :table_test_memory,
          owner: TableTestDeclared,
          persistence: :ephemeral
        })

      {:ok, state} = Store.SqliteBackend.put(state, :table_test_memory, "k", "v")
      {:ok, state} = Store.SqliteBackend.put(state, :table_test_plain, "k", "v")

      assert :table_test_memory in MapSet.to_list(state.ephemeral_tables)
      refute :table_test_plain in MapSet.to_list(state.ephemeral_tables)
      assert {:ok, "v", _} = Store.SqliteBackend.get(state, :table_test_memory, "k")

      # A durable declaration changes nothing.
      {:ok, ^state} =
        Store.SqliteBackend.register_table(state, %Table{
          name: :table_test_plain,
          owner: TableTestDeclared
        })
    end
  end
end
