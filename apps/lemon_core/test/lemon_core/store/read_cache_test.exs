defmodule LemonCore.Store.ReadCacheTest do
  use ExUnit.Case, async: true

  alias LemonCore.Store.ReadCache

  setup do
    store = __MODULE__.Store

    owner =
      start_supervised!(
        {LemonCore.Store,
         name: store,
         backend: LemonCore.Store.EtsBackend,
         cached_tables: [:sessions_index, :chat, :progress, :demo_targets]}
      )

    %{store: store, owner: owner}
  end

  describe "init/2" do
    test "creates ETS tables owned by the supervised Store", %{store: store, owner: owner} do
      ReadCache.init(store, [:sessions_index, :chat, :progress, :demo_targets])

      for domain <- ReadCache.cached_domains(store) do
        table = ReadCache.table_for(store, domain)
        assert :ets.info(table, :owner) == owner
      end
    end

    test "is idempotent", %{store: store} do
      ReadCache.init(store)
      ReadCache.init(store)
      # Should not crash on repeated calls
    end

    test "is additive: re-initializing with fewer tables keeps live ones", %{store: store} do
      ReadCache.init(store, [:sessions_index, :chat, :progress, :demo_targets])
      tables = ReadCache.init(store, [])

      assert Map.has_key?(tables, :sessions_index)
      assert Map.has_key?(tables, :demo_targets)
    end
  end

  describe "cached?/2" do
    test "returns true for domains the store mirrors", %{store: store} do
      assert ReadCache.cached?(store, :chat)
      assert ReadCache.cached?(store, :runs)
      assert ReadCache.cached?(store, :progress)
      assert ReadCache.cached?(store, :sessions_index)
      assert ReadCache.cached?(store, :demo_targets)
    end

    test "returns false for domains it does not", %{store: store} do
      refute ReadCache.cached?(store, :run_history)
      refute ReadCache.cached?(store, :policies)
    end
  end

  describe "put/get/delete" do
    test "stores and retrieves values for chat domain", %{store: store} do
      ReadCache.put(store, :chat, :test_scope, %{msg: "hello"})
      assert ReadCache.get(store, :chat, :test_scope) == %{msg: "hello"}
    end

    test "stores and retrieves values for runs domain", %{store: store} do
      ReadCache.put(store, :runs, "run_123", %{events: [], summary: nil})
      assert ReadCache.get(store, :runs, "run_123") == %{events: [], summary: nil}
    end

    test "stores and retrieves values for progress domain", %{store: store} do
      ReadCache.put(store, :progress, {:scope, 42}, "run_id")
      assert ReadCache.get(store, :progress, {:scope, 42}) == "run_id"
    end

    test "returns nil for missing keys", %{store: store} do
      assert ReadCache.get(store, :chat, :nonexistent) == nil
      assert ReadCache.get(store, :runs, "nonexistent") == nil
      assert ReadCache.get(store, :progress, {:scope, 0}) == nil
      assert ReadCache.get(store, :sessions_index, "agent:missing") == nil
      assert ReadCache.get(store, :demo_targets, {"default", -1, nil}) == nil
    end

    test "overwrites existing values", %{store: store} do
      ReadCache.put(store, :chat, :key, %{v: 1})
      ReadCache.put(store, :chat, :key, %{v: 2})
      assert ReadCache.get(store, :chat, :key) == %{v: 2}
    end

    test "deletes values", %{store: store} do
      ReadCache.put(store, :chat, :key, %{v: 1})
      ReadCache.delete(store, :chat, :key)
      assert ReadCache.get(store, :chat, :key) == nil
    end

    test "put/get/delete on uncached domains is a no-op", %{store: store} do
      assert ReadCache.put(store, :unknown, :key, :value) == :ok
      assert ReadCache.get(store, :unknown, :key) == nil
      assert ReadCache.delete(store, :unknown, :key) == :ok
      assert ReadCache.list(store, :unknown) == []
    end

    test "lists cached entries for cached domains", %{store: store} do
      ReadCache.put(store, :sessions_index, "agent:test:main", %{agent_id: "test"})
      ReadCache.put(store, :demo_targets, {"default", -1001, nil}, %{peer_kind: :group})

      assert {"agent:test:main", %{agent_id: "test"}} in ReadCache.list(store, :sessions_index)

      assert {{"default", -1001, nil}, %{peer_kind: :group}} in ReadCache.list(
               store,
               :demo_targets
             )
    end
  end

  describe "concurrent access" do
    test "handles concurrent reads and writes", %{store: store} do
      tasks =
        for i <- 1..100 do
          Task.async(fn ->
            ReadCache.put(store, :chat, {:concurrent, i}, %{value: i})
            ReadCache.get(store, :chat, {:concurrent, i})
          end)
        end

      results = Enum.map(tasks, &Task.await/1)
      assert results == Enum.map(1..100, &%{value: &1})
    end
  end
end
