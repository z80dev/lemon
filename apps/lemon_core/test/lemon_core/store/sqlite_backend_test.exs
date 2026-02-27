defmodule LemonCore.Store.SqliteBackendTest do
  @moduledoc """
  Tests for the SqliteBackend storage module.
  """
  use ExUnit.Case, async: false

  alias LemonCore.Store.SqliteBackend

  setup do
    tmp_dir = System.tmp_dir!() |> Path.join("sqlite_test_#{:rand.uniform(10000)}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end

  describe "init/1" do
    test "creates SQLite database file with directory path", %{tmp_dir: tmp_dir} do
      assert {:ok, state} = SqliteBackend.init(path: tmp_dir)
      assert File.exists?(Path.join(tmp_dir, "store.sqlite3"))
      assert state.path == Path.join(tmp_dir, "store.sqlite3")
      assert is_reference(state.conn)
      assert is_map(state.statements)
      assert %MapSet{} = state.ephemeral_tables
      assert :runs in state.ephemeral_tables
      :ok = SqliteBackend.close(state)
    end

    test "creates SQLite database file with explicit file path", %{tmp_dir: tmp_dir} do
      db_path = Path.join(tmp_dir, "custom.db")
      assert {:ok, state} = SqliteBackend.init(path: db_path)
      assert File.exists?(db_path)
      assert state.path == db_path
      :ok = SqliteBackend.close(state)
    end

    test "creates SQLite database file with .sqlite3 extension", %{tmp_dir: tmp_dir} do
      db_path = Path.join(tmp_dir, "mydata.sqlite3")
      assert {:ok, state} = SqliteBackend.init(path: db_path)
      assert File.exists?(db_path)
      assert state.path == db_path
      :ok = SqliteBackend.close(state)
    end

    test "creates SQLite database file with .sqlite extension", %{tmp_dir: tmp_dir} do
      db_path = Path.join(tmp_dir, "mydata.sqlite")
      assert {:ok, state} = SqliteBackend.init(path: db_path)
      assert File.exists?(db_path)
      assert state.path == db_path
      :ok = SqliteBackend.close(state)
    end

    test "creates parent directories if they don't exist", %{tmp_dir: tmp_dir} do
      nested_dir = Path.join([tmp_dir, "level1", "level2", "level3"])
      refute File.exists?(nested_dir)

      assert {:ok, state} = SqliteBackend.init(path: nested_dir)
      assert File.exists?(nested_dir)
      assert File.exists?(Path.join(nested_dir, "store.sqlite3"))
      :ok = SqliteBackend.close(state)
    end

    test "uses custom ephemeral_tables option", %{tmp_dir: tmp_dir} do
      assert {:ok, state} = SqliteBackend.init(path: tmp_dir, ephemeral_tables: [:temp_table, :cache])
      assert :temp_table in state.ephemeral_tables
      assert :cache in state.ephemeral_tables
      refute :runs in state.ephemeral_tables
      :ok = SqliteBackend.close(state)
    end

    test "returns error for invalid path", %{tmp_dir: tmp_dir} do
      # Create a file where we try to create a directory
      file_path = Path.join(tmp_dir, "a_file")
      File.write!(file_path, "content")

      # Try to create a directory inside the file (should fail)
      invalid_path = Path.join(file_path, "subdir")

      # Path gets normalized to include store.sqlite3
      normalized_invalid_path = Path.join(invalid_path, "store.sqlite3")
      assert {:error, {:sqlite_init_failed, ^normalized_invalid_path, _}} = SqliteBackend.init(path: invalid_path)
    end

    test "statements are prepared correctly", %{tmp_dir: tmp_dir} do
      assert {:ok, state} = SqliteBackend.init(path: tmp_dir)
      assert is_reference(state.statements.put)
      assert is_reference(state.statements.get)
      assert is_reference(state.statements.delete)
      assert is_reference(state.statements.list)
      assert is_reference(state.statements.list_tables)
      :ok = SqliteBackend.close(state)
    end
  end

  describe "put/4 and get/3 roundtrip - persistent tables" do
    setup %{tmp_dir: tmp_dir} do
      {:ok, state} = SqliteBackend.init(path: tmp_dir)
      on_exit(fn -> SqliteBackend.close(state) end)
      {:ok, state: state}
    end

    test "stores and retrieves string values", %{state: state} do
      assert {:ok, state} = SqliteBackend.put(state, :mytable, "key1", "value1")
      assert {:ok, "value1", _} = SqliteBackend.get(state, :mytable, "key1")
    end

    test "stores and retrieves integer keys and values", %{state: state} do
      assert {:ok, state} = SqliteBackend.put(state, :mytable, 123, 456)
      assert {:ok, 456, _} = SqliteBackend.get(state, :mytable, 123)
    end

    test "stores and retrieves atom keys and values", %{state: state} do
      assert {:ok, state} = SqliteBackend.put(state, :mytable, :atom_key, :atom_value)
      assert {:ok, :atom_value, _} = SqliteBackend.get(state, :mytable, :atom_key)
    end

    test "stores and retrieves tuple keys and values", %{state: state} do
      tuple_key = {:user, 123}
      tuple_value = {:ok, "success"}

      assert {:ok, state} = SqliteBackend.put(state, :mytable, tuple_key, tuple_value)
      assert {:ok, ^tuple_value, _} = SqliteBackend.get(state, :mytable, tuple_key)
    end

    test "stores and retrieves map values", %{state: state} do
      map_value = %{name: "Test", count: 42, active: true}

      assert {:ok, state} = SqliteBackend.put(state, :mytable, "key", map_value)
      assert {:ok, ^map_value, _} = SqliteBackend.get(state, :mytable, "key")
    end

    test "stores and retrieves nested structures", %{state: state} do
      nested = %{
        users: [:alice, :bob, :charlie],
        config: %{port: 8080, host: "localhost"},
        tuple: {:ok, "success"},
        nested: %{deep: %{deeper: %{value: :atom}}}
      }

      assert {:ok, state} = SqliteBackend.put(state, :mytable, "complex", nested)
      assert {:ok, ^nested, _} = SqliteBackend.get(state, :mytable, "complex")
    end

    test "stores and retrieves list values", %{state: state} do
      list_value = [1, 2, 3, :atom, %{key: "value"}]

      assert {:ok, state} = SqliteBackend.put(state, :mytable, "list_key", list_value)
      assert {:ok, ^list_value, _} = SqliteBackend.get(state, :mytable, "list_key")
    end

    test "overwrites existing values", %{state: state} do
      assert {:ok, state} = SqliteBackend.put(state, :mytable, "key", "original")
      assert {:ok, state} = SqliteBackend.put(state, :mytable, "key", "updated")
      assert {:ok, "updated", _} = SqliteBackend.get(state, :mytable, "key")
    end

    test "returns nil for missing keys", %{state: state} do
      assert {:ok, nil, _} = SqliteBackend.get(state, :mytable, "nonexistent")
    end

    test "stores and retrieves nil values", %{state: state} do
      assert {:ok, state} = SqliteBackend.put(state, :mytable, "nil_key", nil)
      assert {:ok, nil, _} = SqliteBackend.get(state, :mytable, "nil_key")
    end

    test "stores and retrieves boolean values", %{state: state} do
      assert {:ok, state} = SqliteBackend.put(state, :mytable, "true_key", true)
      assert {:ok, state} = SqliteBackend.put(state, :mytable, "false_key", false)

      assert {:ok, true, _} = SqliteBackend.get(state, :mytable, "true_key")
      assert {:ok, false, _} = SqliteBackend.get(state, :mytable, "false_key")
    end

    test "stores and retrieves empty string", %{state: state} do
      assert {:ok, state} = SqliteBackend.put(state, :mytable, "empty", "")
      assert {:ok, "", _} = SqliteBackend.get(state, :mytable, "empty")
    end

    test "stores and retrieves unicode strings", %{state: state} do
      unicode = "Hello 🌍 世界 Привет"
      assert {:ok, state} = SqliteBackend.put(state, :mytable, "unicode", unicode)
      assert {:ok, ^unicode, _} = SqliteBackend.get(state, :mytable, "unicode")
    end

    test "table isolation - same key in different tables", %{state: state} do
      assert {:ok, state} = SqliteBackend.put(state, :table_a, "shared_key", "value_a")
      assert {:ok, state} = SqliteBackend.put(state, :table_b, "shared_key", "value_b")

      assert {:ok, "value_a", _} = SqliteBackend.get(state, :table_a, "shared_key")
      assert {:ok, "value_b", _} = SqliteBackend.get(state, :table_b, "shared_key")
    end

    test "handles deeply nested structures", %{state: state} do
      deep = %{
        level1: %{
          level2: %{
            level3: %{
              level4: %{
                level5: [:deep, :data]
              }
            }
          }
        }
      }

      assert {:ok, state} = SqliteBackend.put(state, :mytable, "deep", deep)
      assert {:ok, ^deep, _} = SqliteBackend.get(state, :mytable, "deep")
    end

    test "handles lists of tuples", %{state: state} do
      value = [{:ok, 1}, {:error, 2}, {:ok, 3}]

      assert {:ok, state} = SqliteBackend.put(state, :mytable, "tuple_list", value)
      assert {:ok, ^value, _} = SqliteBackend.get(state, :mytable, "tuple_list")
    end

    test "handles maps with string keys", %{state: state} do
      value = %{"string_key" => "value", "number" => 42}

      assert {:ok, state} = SqliteBackend.put(state, :mytable, "string_map", value)
      assert {:ok, ^value, _} = SqliteBackend.get(state, :mytable, "string_map")
    end
  end

  describe "put/4 and get/3 roundtrip - ephemeral tables" do
    setup %{tmp_dir: tmp_dir} do
      {:ok, state} = SqliteBackend.init(path: tmp_dir)
      on_exit(fn -> SqliteBackend.close(state) end)
      {:ok, state: state}
    end

    test "stores and retrieves values in ephemeral table (:runs)", %{state: state} do
      assert {:ok, state} = SqliteBackend.put(state, :runs, "run1", %{status: :active})
      assert {:ok, %{status: :active}, _} = SqliteBackend.get(state, :runs, "run1")
    end

    test "ephemeral table data is not in SQLite", %{state: state, tmp_dir: tmp_dir} do
      assert {:ok, state} = SqliteBackend.put(state, :runs, "run_key", "ephemeral_value")
      assert {:ok, "ephemeral_value", _} = SqliteBackend.get(state, :runs, "run_key")

      # Close and reopen - ephemeral data should be gone
      :ok = SqliteBackend.close(state)
      {:ok, new_state} = SqliteBackend.init(path: tmp_dir)

      # Ephemeral data should not persist
      assert {:ok, nil, _} = SqliteBackend.get(new_state, :runs, "run_key")
      :ok = SqliteBackend.close(new_state)
    end

    test "ephemeral table uses ETS storage", %{state: state} do
      assert {:ok, state} = SqliteBackend.put(state, :runs, "key", "value")
      # The ephemeral_ets map should contain the :runs table
      assert map_size(state.ephemeral_ets) >= 1
      assert is_reference(state.ephemeral_ets[:runs])
    end

    test "multiple ephemeral tables can be configured", %{tmp_dir: tmp_dir} do
      {:ok, state} = SqliteBackend.init(path: tmp_dir, ephemeral_tables: [:cache, :temp, :session])
      on_exit(fn -> SqliteBackend.close(state) end)

      assert {:ok, state} = SqliteBackend.put(state, :cache, "key1", "cached")
      assert {:ok, state} = SqliteBackend.put(state, :temp, "key2", "temporary")
      assert {:ok, state} = SqliteBackend.put(state, :session, "key3", "session_data")

      assert {:ok, "cached", _} = SqliteBackend.get(state, :cache, "key1")
      assert {:ok, "temporary", _} = SqliteBackend.get(state, :temp, "key2")
      assert {:ok, "session_data", _} = SqliteBackend.get(state, :session, "key3")
    end
  end

  describe "delete/3" do
    setup %{tmp_dir: tmp_dir} do
      {:ok, state} = SqliteBackend.init(path: tmp_dir)
      on_exit(fn -> SqliteBackend.close(state) end)
      {:ok, state: state}
    end

    test "removes values from persistent tables", %{state: state} do
      assert {:ok, state} = SqliteBackend.put(state, :mytable, "key", "value")
      assert {:ok, "value", _} = SqliteBackend.get(state, :mytable, "key")

      assert {:ok, state} = SqliteBackend.delete(state, :mytable, "key")
      assert {:ok, nil, _} = SqliteBackend.get(state, :mytable, "key")
    end

    test "removes values from ephemeral tables", %{state: state} do
      assert {:ok, state} = SqliteBackend.put(state, :runs, "run_key", "run_data")
      assert {:ok, "run_data", _} = SqliteBackend.get(state, :runs, "run_key")

      assert {:ok, state} = SqliteBackend.delete(state, :runs, "run_key")
      assert {:ok, nil, _} = SqliteBackend.get(state, :runs, "run_key")
    end

    test "succeeds when deleting non-existent key from persistent table", %{state: state} do
      assert {:ok, _} = SqliteBackend.delete(state, :mytable, "nonexistent")
    end

    test "succeeds when deleting non-existent key from ephemeral table", %{state: state} do
      assert {:ok, _} = SqliteBackend.delete(state, :runs, "nonexistent")
    end

    test "only deletes from specified table", %{state: state} do
      assert {:ok, state} = SqliteBackend.put(state, :table_a, "shared_key", "value_a")
      assert {:ok, state} = SqliteBackend.put(state, :table_b, "shared_key", "value_b")

      assert {:ok, state} = SqliteBackend.delete(state, :table_a, "shared_key")

      assert {:ok, nil, _} = SqliteBackend.get(state, :table_a, "shared_key")
      assert {:ok, "value_b", _} = SqliteBackend.get(state, :table_b, "shared_key")
    end
  end

  describe "list/2" do
    setup %{tmp_dir: tmp_dir} do
      {:ok, state} = SqliteBackend.init(path: tmp_dir)
      on_exit(fn -> SqliteBackend.close(state) end)
      {:ok, state: state}
    end

    test "returns empty list for empty persistent table", %{state: state} do
      assert {:ok, [], _} = SqliteBackend.list(state, :empty_table)
    end

    test "returns empty list for empty ephemeral table", %{state: state} do
      assert {:ok, [], _} = SqliteBackend.list(state, :runs)
    end

    test "returns all key-value pairs from persistent table", %{state: state} do
      assert {:ok, state} = SqliteBackend.put(state, :mytable, "key1", "value1")
      assert {:ok, state} = SqliteBackend.put(state, :mytable, "key2", "value2")
      assert {:ok, state} = SqliteBackend.put(state, :mytable, "key3", "value3")

      assert {:ok, items, _} = SqliteBackend.list(state, :mytable)

      items_map = Map.new(items)
      assert items_map["key1"] == "value1"
      assert items_map["key2"] == "value2"
      assert items_map["key3"] == "value3"
      assert map_size(items_map) == 3
    end

    test "returns all key-value pairs from ephemeral table", %{state: state} do
      assert {:ok, state} = SqliteBackend.put(state, :runs, "run1", "data1")
      assert {:ok, state} = SqliteBackend.put(state, :runs, "run2", "data2")

      assert {:ok, items, _} = SqliteBackend.list(state, :runs)

      items_map = Map.new(items)
      assert items_map["run1"] == "data1"
      assert items_map["run2"] == "data2"
      assert map_size(items_map) == 2
    end

    test "does not include deleted items in persistent table", %{state: state} do
      assert {:ok, state} = SqliteBackend.put(state, :mytable, "key1", "value1")
      assert {:ok, state} = SqliteBackend.put(state, :mytable, "key2", "value2")
      assert {:ok, state} = SqliteBackend.delete(state, :mytable, "key1")

      assert {:ok, items, _} = SqliteBackend.list(state, :mytable)

      items_map = Map.new(items)
      refute Map.has_key?(items_map, "key1")
      assert items_map["key2"] == "value2"
      assert map_size(items_map) == 1
    end

    test "does not include deleted items in ephemeral table", %{state: state} do
      assert {:ok, state} = SqliteBackend.put(state, :runs, "run1", "data1")
      assert {:ok, state} = SqliteBackend.put(state, :runs, "run2", "data2")
      assert {:ok, state} = SqliteBackend.delete(state, :runs, "run1")

      assert {:ok, items, _} = SqliteBackend.list(state, :runs)

      items_map = Map.new(items)
      refute Map.has_key?(items_map, "run1")
      assert items_map["run2"] == "data2"
      assert map_size(items_map) == 1
    end

    test "table isolation in list", %{state: state} do
      assert {:ok, state} = SqliteBackend.put(state, :table_a, "key", "value_a")
      assert {:ok, state} = SqliteBackend.put(state, :table_b, "key", "value_b")

      assert {:ok, items_a, _} = SqliteBackend.list(state, :table_a)
      assert {:ok, items_b, _} = SqliteBackend.list(state, :table_b)

      assert [{"key", "value_a"}] = items_a
      assert [{"key", "value_b"}] = items_b
    end

    test "list returns complex data types correctly", %{state: state} do
      complex_value = %{nested: %{deep: :value}, list: [1, 2, 3]}
      assert {:ok, state} = SqliteBackend.put(state, :mytable, :complex_key, complex_value)

      assert {:ok, items, _} = SqliteBackend.list(state, :mytable)
      assert [{:complex_key, ^complex_value}] = items
    end
  end

  describe "list_tables/1" do
    setup %{tmp_dir: tmp_dir} do
      {:ok, state} = SqliteBackend.init(path: tmp_dir)
      on_exit(fn -> SqliteBackend.close(state) end)
      {:ok, state: state}
    end

    test "returns empty list for fresh database", %{state: state} do
      # Initially no persistent tables, ephemeral tables are lazily created
      tables = SqliteBackend.list_tables(state)
      assert is_list(tables)
    end

    test "returns persistent tables with data", %{state: state} do
      assert {:ok, state} = SqliteBackend.put(state, :users, "u1", "Alice")
      assert {:ok, state} = SqliteBackend.put(state, :products, "p1", "Widget")

      tables = SqliteBackend.list_tables(state)
      assert :users in tables
      assert :products in tables
    end

    test "returns ephemeral tables when accessed", %{state: state} do
      assert {:ok, state} = SqliteBackend.put(state, :runs, "run1", "data")

      tables = SqliteBackend.list_tables(state)
      assert :runs in tables
    end

    test "returns both persistent and ephemeral tables", %{state: state} do
      assert {:ok, state} = SqliteBackend.put(state, :users, "u1", "Alice")
      assert {:ok, state} = SqliteBackend.put(state, :runs, "run1", "data")

      tables = SqliteBackend.list_tables(state)
      assert :users in tables
      assert :runs in tables
    end

    test "no duplicates when same table name in both", %{state: state} do
      # This shouldn't happen in practice, but test for safety
      assert {:ok, state} = SqliteBackend.put(state, :runs, "run1", "data")

      tables = SqliteBackend.list_tables(state)
      # Should have unique values
      assert length(tables) == length(Enum.uniq(tables))
    end
  end

  describe "persistence across re-initialization" do
    test "persistent data survives close and reopen", %{tmp_dir: tmp_dir} do
      # First session
      {:ok, state1} = SqliteBackend.init(path: tmp_dir)
      {:ok, state1} = SqliteBackend.put(state1, :mytable, "key1", "value1")
      {:ok, state1} = SqliteBackend.put(state1, :mytable, "key2", %{nested: "data"})
      {:ok, state1} = SqliteBackend.put(state1, :other_table, "key", "other_value")
      :ok = SqliteBackend.close(state1)

      # Second session
      {:ok, state2} = SqliteBackend.init(path: tmp_dir)
      assert {:ok, "value1", _} = SqliteBackend.get(state2, :mytable, "key1")
      assert {:ok, %{nested: "data"}, _} = SqliteBackend.get(state2, :mytable, "key2")
      assert {:ok, "other_value", _} = SqliteBackend.get(state2, :other_table, "key")
      :ok = SqliteBackend.close(state2)
    end

    test "deletes persist across re-initialization", %{tmp_dir: tmp_dir} do
      # First session
      {:ok, state1} = SqliteBackend.init(path: tmp_dir)
      {:ok, state1} = SqliteBackend.put(state1, :mytable, "key1", "value1")
      {:ok, state1} = SqliteBackend.put(state1, :mytable, "key2", "value2")
      {:ok, state1} = SqliteBackend.delete(state1, :mytable, "key1")
      :ok = SqliteBackend.close(state1)

      # Second session
      {:ok, state2} = SqliteBackend.init(path: tmp_dir)
      assert {:ok, nil, _} = SqliteBackend.get(state2, :mytable, "key1")
      assert {:ok, "value2", _} = SqliteBackend.get(state2, :mytable, "key2")
      :ok = SqliteBackend.close(state2)
    end

    test "overwrites persist correctly across re-initialization", %{tmp_dir: tmp_dir} do
      # First session
      {:ok, state1} = SqliteBackend.init(path: tmp_dir)
      {:ok, state1} = SqliteBackend.put(state1, :mytable, "key", "original")
      {:ok, state1} = SqliteBackend.put(state1, :mytable, "key", "updated")
      {:ok, state1} = SqliteBackend.put(state1, :mytable, "key", "final")
      :ok = SqliteBackend.close(state1)

      # Second session
      {:ok, state2} = SqliteBackend.init(path: tmp_dir)
      assert {:ok, "final", _} = SqliteBackend.get(state2, :mytable, "key")
      :ok = SqliteBackend.close(state2)
    end

    test "complex data types persist correctly", %{tmp_dir: tmp_dir} do
      complex_data = %{
        users: [:alice, :bob, :charlie],
        config: %{port: 8080, host: "localhost"},
        tuple: {:ok, "success"},
        nested: %{deep: %{deeper: %{value: :atom}}}
      }

      # First session
      {:ok, state1} = SqliteBackend.init(path: tmp_dir)
      {:ok, state1} = SqliteBackend.put(state1, :mytable, "complex", complex_data)
      :ok = SqliteBackend.close(state1)

      # Second session
      {:ok, state2} = SqliteBackend.init(path: tmp_dir)
      assert {:ok, ^complex_data, _} = SqliteBackend.get(state2, :mytable, "complex")
      :ok = SqliteBackend.close(state2)
    end

    test "ephemeral data does not persist across re-initialization", %{tmp_dir: tmp_dir} do
      # First session
      {:ok, state1} = SqliteBackend.init(path: tmp_dir)
      {:ok, state1} = SqliteBackend.put(state1, :runs, "run1", %{status: :active})
      :ok = SqliteBackend.close(state1)

      # Second session
      {:ok, state2} = SqliteBackend.init(path: tmp_dir)
      assert {:ok, nil, _} = SqliteBackend.get(state2, :runs, "run1")
      :ok = SqliteBackend.close(state2)
    end

    test "mixed persistent and ephemeral data", %{tmp_dir: tmp_dir} do
      # First session
      {:ok, state1} = SqliteBackend.init(path: tmp_dir)
      {:ok, state1} = SqliteBackend.put(state1, :persistent_table, "key", "persistent_value")
      {:ok, state1} = SqliteBackend.put(state1, :runs, "run_key", "ephemeral_value")
      :ok = SqliteBackend.close(state1)

      # Second session
      {:ok, state2} = SqliteBackend.init(path: tmp_dir)
      assert {:ok, "persistent_value", _} = SqliteBackend.get(state2, :persistent_table, "key")
      assert {:ok, nil, _} = SqliteBackend.get(state2, :runs, "run_key")
      :ok = SqliteBackend.close(state2)
    end
  end

  describe "close/1" do
    test "closes connection and releases statements", %{tmp_dir: tmp_dir} do
      {:ok, state} = SqliteBackend.init(path: tmp_dir)
      assert :ok = SqliteBackend.close(state)
    end

    test "can close multiple times without error", %{tmp_dir: tmp_dir} do
      {:ok, state} = SqliteBackend.init(path: tmp_dir)
      assert :ok = SqliteBackend.close(state)
      assert :ok = SqliteBackend.close(state)
    end

    test "closes with invalid state gracefully" do
      assert :ok = SqliteBackend.close(%{})
      assert :ok = SqliteBackend.close(nil)
    end

    test "database file remains after close", %{tmp_dir: tmp_dir} do
      db_path = Path.join(tmp_dir, "store.sqlite3")
      {:ok, state} = SqliteBackend.init(path: tmp_dir)
      :ok = SqliteBackend.close(state)

      assert File.exists?(db_path)
    end
  end

  describe "multiple tables operations" do
    setup %{tmp_dir: tmp_dir} do
      {:ok, state} = SqliteBackend.init(path: tmp_dir)
      on_exit(fn -> SqliteBackend.close(state) end)
      {:ok, state: state}
    end

    test "can work with many tables simultaneously", %{state: state} do
      tables = [:users, :products, :orders, :inventory, :categories]

      state =
        Enum.reduce(tables, state, fn table, acc_state ->
          {:ok, new_state} = SqliteBackend.put(acc_state, table, "key", "value_#{table}")
          new_state
        end)

      # Verify all tables have data
      for table <- tables do
        expected_value = "value_#{table}"
        assert {:ok, ^expected_value, _} = SqliteBackend.get(state, table, "key")
      end
    end

    test "complex operations across multiple tables", %{state: state} do
      # Insert into multiple tables
      {:ok, state} = SqliteBackend.put(state, :users, "user1", %{name: "Alice", age: 30})
      {:ok, state} = SqliteBackend.put(state, :users, "user2", %{name: "Bob", age: 25})
      {:ok, state} = SqliteBackend.put(state, :products, "prod1", %{name: "Widget", price: 10.99})
      {:ok, state} = SqliteBackend.put(state, :orders, "order1", %{user: "user1", items: ["prod1"]})

      # List all tables
      {:ok, users, _} = SqliteBackend.list(state, :users)
      {:ok, products, _} = SqliteBackend.list(state, :products)
      {:ok, orders, _} = SqliteBackend.list(state, :orders)

      assert length(users) == 2
      assert length(products) == 1
      assert length(orders) == 1

      # Delete from one table
      {:ok, state} = SqliteBackend.delete(state, :users, "user1")
      {:ok, users, _} = SqliteBackend.list(state, :users)
      assert length(users) == 1

      # Verify other tables unaffected
      {:ok, products, _} = SqliteBackend.list(state, :products)
      assert length(products) == 1
    end
  end

  describe "state management" do
    setup %{tmp_dir: tmp_dir} do
      {:ok, state} = SqliteBackend.init(path: tmp_dir)
      on_exit(fn -> SqliteBackend.close(state) end)
      {:ok, state: state}
    end

    test "put returns updated state", %{state: state} do
      assert {:ok, new_state} = SqliteBackend.put(state, :mytable, "key", "value")
      assert {:ok, "value", _} = SqliteBackend.get(new_state, :mytable, "key")
    end

    test "get returns state", %{state: state} do
      assert {:ok, nil, new_state} = SqliteBackend.get(state, :mytable, "key")
      assert is_map(new_state)
    end

    test "delete returns updated state", %{state: state} do
      {:ok, state} = SqliteBackend.put(state, :mytable, "key", "value")
      assert {:ok, new_state} = SqliteBackend.delete(state, :mytable, "key")
      assert {:ok, nil, _} = SqliteBackend.get(new_state, :mytable, "key")
    end

    test "list returns state", %{state: state} do
      assert {:ok, [], new_state} = SqliteBackend.list(state, :mytable)
      assert is_map(new_state)
    end
  end

  describe "backend behavior compliance" do
    setup %{tmp_dir: tmp_dir} do
      {:ok, state} = SqliteBackend.init(path: tmp_dir)
      on_exit(fn -> SqliteBackend.close(state) end)
      {:ok, state: state}
    end

    test "all callbacks return expected formats", %{state: state} do
      # put returns {:ok, state}
      assert {:ok, state_after_put} = SqliteBackend.put(state, :mytable, "k", "v")
      assert is_map(state_after_put)

      # get returns {:ok, value, state}
      assert {:ok, "v", state_after_get} = SqliteBackend.get(state_after_put, :mytable, "k")
      assert is_map(state_after_get)

      # delete returns {:ok, state}
      assert {:ok, state_after_delete} = SqliteBackend.delete(state_after_get, :mytable, "k")
      assert is_map(state_after_delete)

      # list returns {:ok, items, state}
      assert {:ok, [], state_after_list} = SqliteBackend.list(state_after_delete, :mytable)
      assert is_map(state_after_list)
    end
  end

  describe "list_recent/3" do
    setup %{tmp_dir: tmp_dir} do
      {:ok, state} = SqliteBackend.init(path: tmp_dir)
      on_exit(fn -> SqliteBackend.close(state) end)
      {:ok, state: state}
    end

    test "list_recent returns limited results ordered by recency", %{state: state} do
      # Put 5 entries with sequential puts so updated_at_ms increases naturally
      {:ok, state} = SqliteBackend.put(state, :recent_table, "a", %{order: 1})
      Process.sleep(5)
      {:ok, state} = SqliteBackend.put(state, :recent_table, "b", %{order: 2})
      Process.sleep(5)
      {:ok, state} = SqliteBackend.put(state, :recent_table, "c", %{order: 3})
      Process.sleep(5)
      {:ok, state} = SqliteBackend.put(state, :recent_table, "d", %{order: 4})
      Process.sleep(5)
      {:ok, state} = SqliteBackend.put(state, :recent_table, "e", %{order: 5})

      assert {:ok, items, _state} = SqliteBackend.list_recent(state, :recent_table, 2)
      assert length(items) == 2

      # The two most recent entries should be returned (e and d), newest first
      keys = Enum.map(items, fn {key, _val} -> key end)
      assert keys == ["e", "d"]
    end

    test "list_recent with limit larger than entries returns all", %{state: state} do
      {:ok, state} = SqliteBackend.put(state, :small_table, "x", %{val: 1})
      Process.sleep(5)
      {:ok, state} = SqliteBackend.put(state, :small_table, "y", %{val: 2})

      assert {:ok, items, _state} = SqliteBackend.list_recent(state, :small_table, 100)
      assert length(items) == 2
    end

    test "list_recent with ephemeral table falls back to take", %{state: state} do
      # :runs is ephemeral by default
      {:ok, state} = SqliteBackend.put(state, :runs, "run_1", %{status: :done})
      {:ok, state} = SqliteBackend.put(state, :runs, "run_2", %{status: :active})
      {:ok, state} = SqliteBackend.put(state, :runs, "run_3", %{status: :pending})

      assert {:ok, items, _state} = SqliteBackend.list_recent(state, :runs, 2)
      # Ephemeral tables fall back to Enum.take, so we just verify the count
      assert length(items) == 2
    end
  end
end
