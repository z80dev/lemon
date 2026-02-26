defmodule LemonCore.Store.EtsBackendTest do
  @moduledoc """
  Tests for the EtsBackend storage module.
  """
  use ExUnit.Case, async: false

  alias LemonCore.Store.EtsBackend

  setup do
    # Initialize the backend for each test
    {:ok, state} = EtsBackend.init([])

    on_exit(fn ->
      # Clean up all ETS tables
      for {_, table} <- state do
        try do
          :ets.delete(table)
        catch
          _, _ -> :ok
        end
      end
    end)

    {:ok, state: state}
  end

  describe "init/1" do
    test "creates the backend with initial tables" do
      {:ok, state} = EtsBackend.init([])

      assert Map.has_key?(state, :chat)
      assert Map.has_key?(state, :progress)
      assert Map.has_key?(state, :runs)
      assert Map.has_key?(state, :run_history)

      # Verify each table is a valid ETS table
      assert :ets.info(state.chat) != :undefined
      assert :ets.info(state.progress) != :undefined
      assert :ets.info(state.runs) != :undefined
      assert :ets.info(state.run_history) != :undefined
    end

    test "creates tables with correct types" do
      {:ok, state} = EtsBackend.init([])

      # chat, progress, runs are :set type
      assert :ets.info(state.chat)[:type] == :set
      assert :ets.info(state.progress)[:type] == :set
      assert :ets.info(state.runs)[:type] == :set

      # run_history is :ordered_set type
      assert :ets.info(state.run_history)[:type] == :ordered_set
    end

    test "creates protected tables" do
      {:ok, state} = EtsBackend.init([])

      assert :ets.info(state.chat)[:protection] == :protected
      assert :ets.info(state.progress)[:protection] == :protected
      assert :ets.info(state.runs)[:protection] == :protected
      assert :ets.info(state.run_history)[:protection] == :protected
    end
  end

  describe "put/4" do
    test "stores values in a table", %{state: state} do
      {:ok, new_state} = EtsBackend.put(state, :chat, "key1", "value1")

      # Verify the value was stored
      assert :ets.lookup(new_state.chat, "key1") == [{"key1", "value1"}]
    end

    test "returns updated state", %{state: state} do
      {:ok, new_state} = EtsBackend.put(state, :chat, "key1", "value1")
      assert new_state == state
    end

    test "stores values in different tables", %{state: state} do
      {:ok, state} = EtsBackend.put(state, :chat, "chat_key", "chat_value")
      {:ok, state} = EtsBackend.put(state, :progress, "progress_key", "progress_value")
      {:ok, _state} = EtsBackend.put(state, :runs, "runs_key", "runs_value")

      assert :ets.lookup(state.chat, "chat_key") == [{"chat_key", "chat_value"}]
      assert :ets.lookup(state.progress, "progress_key") == [{"progress_key", "progress_value"}]
      assert :ets.lookup(state.runs, "runs_key") == [{"runs_key", "runs_value"}]
    end
  end

  describe "get/3" do
    test "retrieves stored values", %{state: state} do
      # Store a value first
      :ets.insert(state.chat, {"key1", "value1"})

      {:ok, value, ^state} = EtsBackend.get(state, :chat, "key1")
      assert value == "value1"
    end

    test "returns nil for missing keys", %{state: state} do
      {:ok, value, ^state} = EtsBackend.get(state, :chat, "nonexistent_key")
      assert value == nil
    end

    test "returns nil for empty table", %{state: state} do
      {:ok, value, ^state} = EtsBackend.get(state, :chat, "any_key")
      assert value == nil
    end

    test "retrieves values from different tables", %{state: state} do
      :ets.insert(state.chat, {"chat_key", "chat_value"})
      :ets.insert(state.progress, {"progress_key", "progress_value"})
      :ets.insert(state.runs, {"runs_key", "runs_value"})

      {:ok, chat_val, _} = EtsBackend.get(state, :chat, "chat_key")
      {:ok, progress_val, _} = EtsBackend.get(state, :progress, "progress_key")
      {:ok, runs_val, _} = EtsBackend.get(state, :runs, "runs_key")

      assert chat_val == "chat_value"
      assert progress_val == "progress_value"
      assert runs_val == "runs_value"
    end
  end

  describe "delete/3" do
    test "removes stored values", %{state: state} do
      # Store and then delete
      :ets.insert(state.chat, {"key1", "value1"})
      assert :ets.lookup(state.chat, "key1") == [{"key1", "value1"}]

      {:ok, new_state} = EtsBackend.delete(state, :chat, "key1")
      assert :ets.lookup(new_state.chat, "key1") == []
    end

    test "returns ok when deleting non-existent key", %{state: state} do
      {:ok, new_state} = EtsBackend.delete(state, :chat, "nonexistent_key")
      assert new_state == state
    end

    test "only deletes from specified table", %{state: state} do
      :ets.insert(state.chat, {"shared_key", "chat_value"})
      :ets.insert(state.progress, {"shared_key", "progress_value"})

      {:ok, _} = EtsBackend.delete(state, :chat, "shared_key")

      # Should be deleted from chat
      assert :ets.lookup(state.chat, "shared_key") == []
      # Should still exist in progress
      assert :ets.lookup(state.progress, "shared_key") == [{"shared_key", "progress_value"}]
    end
  end

  describe "list/2" do
    test "returns all key-value pairs", %{state: state} do
      :ets.insert(state.chat, {"key1", "value1"})
      :ets.insert(state.chat, {"key2", "value2"})
      :ets.insert(state.chat, {"key3", "value3"})

      {:ok, items, _} = EtsBackend.list(state, :chat)

      assert length(items) == 3
      assert {"key1", "value1"} in items
      assert {"key2", "value2"} in items
      assert {"key3", "value3"} in items
    end

    test "returns empty list for empty table", %{state: state} do
      {:ok, items, ^state} = EtsBackend.list(state, :chat)
      assert items == []
    end

    test "returns items from correct table only", %{state: state} do
      :ets.insert(state.chat, {"chat_key", "chat_value"})
      :ets.insert(state.progress, {"progress_key", "progress_value"})

      {:ok, chat_items, _} = EtsBackend.list(state, :chat)
      {:ok, progress_items, _} = EtsBackend.list(state, :progress)

      assert length(chat_items) == 1
      assert hd(chat_items) == {"chat_key", "chat_value"}

      assert length(progress_items) == 1
      assert hd(progress_items) == {"progress_key", "progress_value"}
    end
  end

  describe "dynamic table creation" do
    test "creates table dynamically when accessing unknown table", %{state: state} do
      # Access a table not in initial state
      assert not Map.has_key?(state, :dynamic_table)

      {:ok, new_state} = EtsBackend.put(state, :dynamic_table, "key1", "value1")

      # Table should now exist
      assert Map.has_key?(new_state, :dynamic_table)
      assert :ets.info(new_state.dynamic_table) != :undefined

      # Value should be stored
      assert :ets.lookup(new_state.dynamic_table, "key1") == [{"key1", "value1"}]
    end

    test "dynamic table is created with set type", %{state: state} do
      {:ok, new_state} = EtsBackend.put(state, :dynamic_table, "key1", "value1")

      assert :ets.info(new_state.dynamic_table)[:type] == :set
    end

    test "dynamic table is protected", %{state: state} do
      {:ok, new_state} = EtsBackend.put(state, :dynamic_table, "key1", "value1")

      assert :ets.info(new_state.dynamic_table)[:protection] == :protected
    end

    test "get creates table dynamically for missing table", %{state: state} do
      {:ok, value, new_state} = EtsBackend.get(state, :unknown_table, "key1")

      assert value == nil
      assert Map.has_key?(new_state, :unknown_table)
      assert :ets.info(new_state.unknown_table) != :undefined
    end

    test "delete creates table dynamically for missing table", %{state: state} do
      {:ok, new_state} = EtsBackend.delete(state, :unknown_table, "key1")

      assert Map.has_key?(new_state, :unknown_table)
      assert :ets.info(new_state.unknown_table) != :undefined
    end

    test "list creates table dynamically for missing table", %{state: state} do
      {:ok, items, new_state} = EtsBackend.list(state, :unknown_table)

      assert items == []
      assert Map.has_key?(new_state, :unknown_table)
      assert :ets.info(new_state.unknown_table) != :undefined
    end

    test "reuses existing dynamic table on subsequent calls", %{state: state} do
      {:ok, state1} = EtsBackend.put(state, :dynamic_table, "key1", "value1")
      table_ref = state1.dynamic_table

      {:ok, state2} = EtsBackend.put(state1, :dynamic_table, "key2", "value2")

      # Should be the same table reference
      assert state2.dynamic_table == table_ref

      # Both values should be present
      assert :ets.lookup(state2.dynamic_table, "key1") == [{"key1", "value1"}]
      assert :ets.lookup(state2.dynamic_table, "key2") == [{"key2", "value2"}]
    end
  end

  describe "updating existing keys" do
    test "put overwrites existing value", %{state: state} do
      # Store initial value
      {:ok, state} = EtsBackend.put(state, :chat, "key1", "initial_value")

      # Update with new value
      {:ok, state} = EtsBackend.put(state, :chat, "key1", "updated_value")

      # Should have the new value
      {:ok, value, _} = EtsBackend.get(state, :chat, "key1")
      assert value == "updated_value"

      # Should only have one entry for this key
      {:ok, items, _} = EtsBackend.list(state, :chat)
      assert length(items) == 1
    end

    test "multiple updates to same key", %{state: state} do
      values = ["value1", "value2", "value3", "value4", "value5"]

      final_state =
        Enum.reduce(values, state, fn value, acc_state ->
          {:ok, new_state} = EtsBackend.put(acc_state, :chat, "my_key", value)
          new_state
        end)

      # Should only have the last value
      {:ok, final_value, _} = EtsBackend.get(final_state, :chat, "my_key")
      assert final_value == "value5"

      # Should only have one entry
      {:ok, items, _} = EtsBackend.list(final_state, :chat)
      assert length(items) == 1
    end
  end

  describe "different data types" do
    test "stores and retrieves strings", %{state: state} do
      {:ok, state} = EtsBackend.put(state, :chat, "string_key", "string_value")
      {:ok, value, _} = EtsBackend.get(state, :chat, "string_key")
      assert value == "string_value"
    end

    test "stores and retrieves atoms", %{state: state} do
      {:ok, state} = EtsBackend.put(state, :chat, :atom_key, :atom_value)
      {:ok, value, _} = EtsBackend.get(state, :chat, :atom_key)
      assert value == :atom_value
    end

    test "stores and retrieves integers", %{state: state} do
      {:ok, state} = EtsBackend.put(state, :chat, 42, 100)
      {:ok, value, _} = EtsBackend.get(state, :chat, 42)
      assert value == 100
    end

    test "stores and retrieves tuples", %{state: state} do
      tuple_key = {:user, 123}
      tuple_value = {:status, :active}

      {:ok, state} = EtsBackend.put(state, :chat, tuple_key, tuple_value)
      {:ok, value, _} = EtsBackend.get(state, :chat, tuple_key)
      assert value == tuple_value
    end

    test "stores and retrieves maps", %{state: state} do
      map_key = "config"
      map_value = %{host: "localhost", port: 8080, enabled: true}

      {:ok, state} = EtsBackend.put(state, :chat, map_key, map_value)
      {:ok, value, _} = EtsBackend.get(state, :chat, map_key)
      assert value == map_value
    end

    test "stores and retrieves lists", %{state: state} do
      {:ok, state} = EtsBackend.put(state, :chat, "list_key", [1, 2, 3, 4, 5])
      {:ok, value, _} = EtsBackend.get(state, :chat, "list_key")
      assert value == [1, 2, 3, 4, 5]
    end

    test "stores and retrieves nested structures", %{state: state} do
      nested_value = %{
        users: [
          %{id: 1, name: "Alice"},
          %{id: 2, name: "Bob"}
        ],
        metadata: {
          :created,
          DateTime.utc_now()
        }
      }

      {:ok, state} = EtsBackend.put(state, :chat, "nested", nested_value)
      {:ok, value, _} = EtsBackend.get(state, :chat, "nested")
      assert value == nested_value
    end

    test "stores and retrieves nil", %{state: state} do
      {:ok, state} = EtsBackend.put(state, :chat, "nil_key", nil)
      {:ok, value, _} = EtsBackend.get(state, :chat, "nil_key")
      assert value == nil
    end

    test "stores and retrieves booleans", %{state: state} do
      {:ok, state} = EtsBackend.put(state, :chat, "true_key", true)
      {:ok, state} = EtsBackend.put(state, :chat, "false_key", false)

      {:ok, true_value, _} = EtsBackend.get(state, :chat, "true_key")
      {:ok, false_value, _} = EtsBackend.get(state, :chat, "false_key")

      assert true_value == true
      assert false_value == false
    end

    test "mixed data types in same table", %{state: state} do
      {:ok, state} = EtsBackend.put(state, :chat, "string", "hello")
      {:ok, state} = EtsBackend.put(state, :chat, :atom, :world)
      {:ok, state} = EtsBackend.put(state, :chat, 42, 99)
      {:ok, state} = EtsBackend.put(state, :chat, %{key: "map"}, %{nested: "value"})
      {:ok, state} = EtsBackend.put(state, :chat, [1, 2], ["a", "b"])

      {:ok, items, _} = EtsBackend.list(state, :chat)
      assert length(items) == 5

      # Verify each value is correct
      assert {"string", "hello"} in items
      assert {:atom, :world} in items
      assert {42, 99} in items
      assert {%{key: "map"}, %{nested: "value"}} in items
      assert {[1, 2], ["a", "b"]} in items
    end
  end

  describe "ordered_set table behavior" do
    test "run_history table maintains order by key", %{state: state} do
      # Insert items out of order
      :ets.insert(state.run_history, {{"session1", 300, "run3"}, "value3"})
      :ets.insert(state.run_history, {{"session1", 100, "run1"}, "value1"})
      :ets.insert(state.run_history, {{"session1", 200, "run2"}, "value2"})

      # List should return in sorted order by key (timestamp)
      {:ok, items, _} = EtsBackend.list(state, :run_history)

      keys = Enum.map(items, &elem(&1, 0))
      assert keys == [{"session1", 100, "run1"}, {"session1", 200, "run2"}, {"session1", 300, "run3"}]
    end
  end

  describe "backend behavior compliance" do
    test "all callbacks return state in expected format" do
      {:ok, state} = EtsBackend.init([])

      # put returns {:ok, state}
      assert {:ok, state_after_put} = EtsBackend.put(state, :chat, "k", "v")
      assert is_map(state_after_put)

      # get returns {:ok, value, state}
      assert {:ok, "v", state_after_get} = EtsBackend.get(state_after_put, :chat, "k")
      assert is_map(state_after_get)

      # delete returns {:ok, state}
      assert {:ok, state_after_delete} = EtsBackend.delete(state_after_get, :chat, "k")
      assert is_map(state_after_delete)

      # list returns {:ok, items, state}
      assert {:ok, [], state_after_list} = EtsBackend.list(state_after_delete, :chat)
      assert is_map(state_after_list)
    end
  end
end
