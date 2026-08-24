defmodule LemonCore.Store.ReadCacheTest do
  use ExUnit.Case, async: true

  alias LemonCore.Store.ReadCache

  describe "init/2" do
    test "creates ETS tables for cached domains" do
      ReadCache.init(LemonCore.Store, [:sessions_index, :demo_targets])

      for domain <- ReadCache.cached_domains() do
        table = ReadCache.table_for(domain)
        assert :ets.whereis(table) != :undefined
      end
    end

    test "is idempotent" do
      ReadCache.init()
      ReadCache.init()
      # Should not crash on repeated calls
    end

    test "is additive: re-initializing with fewer tables keeps live ones" do
      ReadCache.init(LemonCore.Store, [:sessions_index, :demo_targets])
      tables = ReadCache.init(LemonCore.Store, [])

      assert Map.has_key?(tables, :sessions_index)
      assert Map.has_key?(tables, :demo_targets)
    end
  end

  describe "cached?/2" do
    setup do
      ReadCache.init(LemonCore.Store, [:sessions_index, :demo_targets])
      :ok
    end

    test "returns true for domains the store mirrors" do
      assert ReadCache.cached?(:chat)
      assert ReadCache.cached?(:runs)
      assert ReadCache.cached?(:progress)
      assert ReadCache.cached?(:sessions_index)
      assert ReadCache.cached?(:demo_targets)
    end

    test "returns false for domains it does not" do
      refute ReadCache.cached?(:run_history)
      refute ReadCache.cached?(:policies)
    end
  end

  describe "put/get/delete" do
    setup do
      ReadCache.init(LemonCore.Store, [:sessions_index, :demo_targets])
      :ok
    end

    test "stores and retrieves values for chat domain" do
      ReadCache.put(:chat, :test_scope, %{msg: "hello"})
      assert ReadCache.get(:chat, :test_scope) == %{msg: "hello"}
    end

    test "stores and retrieves values for runs domain" do
      ReadCache.put(:runs, "run_123", %{events: [], summary: nil})
      assert ReadCache.get(:runs, "run_123") == %{events: [], summary: nil}
    end

    test "stores and retrieves values for progress domain" do
      ReadCache.put(:progress, {:scope, 42}, "run_id")
      assert ReadCache.get(:progress, {:scope, 42}) == "run_id"
    end

    test "returns nil for missing keys" do
      assert ReadCache.get(:chat, :nonexistent) == nil
      assert ReadCache.get(:runs, "nonexistent") == nil
      assert ReadCache.get(:progress, {:scope, 0}) == nil
      assert ReadCache.get(:sessions_index, "agent:missing") == nil
      assert ReadCache.get(:demo_targets, {"default", -1, nil}) == nil
    end

    test "overwrites existing values" do
      ReadCache.put(:chat, :key, %{v: 1})
      ReadCache.put(:chat, :key, %{v: 2})
      assert ReadCache.get(:chat, :key) == %{v: 2}
    end

    test "deletes values" do
      ReadCache.put(:chat, :key, %{v: 1})
      ReadCache.delete(:chat, :key)
      assert ReadCache.get(:chat, :key) == nil
    end

    test "put/get/delete on uncached domains is a no-op" do
      assert ReadCache.put(:unknown, :key, :value) == :ok
      assert ReadCache.get(:unknown, :key) == nil
      assert ReadCache.delete(:unknown, :key) == :ok
      assert ReadCache.list(:unknown) == []
    end

    test "lists cached entries for cached domains" do
      ReadCache.put(:sessions_index, "agent:test:main", %{agent_id: "test"})
      ReadCache.put(:demo_targets, {"default", -1001, nil}, %{peer_kind: :group})

      assert {"agent:test:main", %{agent_id: "test"}} in ReadCache.list(:sessions_index)

      assert {{"default", -1001, nil}, %{peer_kind: :group}} in ReadCache.list(
               :demo_targets
             )
    end
  end

  describe "concurrent access" do
    setup do
      ReadCache.init(LemonCore.Store, [:sessions_index, :demo_targets])
      :ok
    end

    test "handles concurrent reads and writes" do
      tasks =
        for i <- 1..100 do
          Task.async(fn ->
            ReadCache.put(:chat, {:concurrent, i}, %{value: i})
            ReadCache.get(:chat, {:concurrent, i})
          end)
        end

      results = Enum.map(tasks, &Task.await/1)
      assert Enum.all?(results, fn r -> is_map(r) end)
    end
  end
end
