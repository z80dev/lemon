defmodule LemonCore.Store.JsonlBackendTest do
  use ExUnit.Case, async: true

  alias LemonCore.Store.JsonlBackend

  setup do
    tmp_dir = System.tmp_dir!() |> Path.join("jsonl_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end

  describe "init/1" do
    test "creates directory if it doesn't exist", %{tmp_dir: tmp_dir} do
      new_dir = Path.join(tmp_dir, "new_subdirectory")
      refute File.exists?(new_dir)

      assert {:ok, state} = JsonlBackend.init(path: new_dir)
      assert File.exists?(new_dir)
      assert state.path == new_dir
      assert state.data == %{}
      # Core and parity tables are loaded by default
      assert :chat in state.loaded_tables
      assert :progress in state.loaded_tables
    end

    test "loads existing tables from jsonl files", %{tmp_dir: tmp_dir} do
      # Create pre-existing jsonl files
      File.write!(
        Path.join(tmp_dir, "users.jsonl"),
        ~s({"op":"put","key":"user1","value":"Alice","ts":1000}\n)
      )

      File.write!(
        Path.join(tmp_dir, "products.jsonl"),
        ~s({"op":"put","key":"prod1","value":"Widget","ts":2000}\n)
      )

      assert {:ok, state} = JsonlBackend.init(path: tmp_dir)

      # Both tables should be loaded
      tables = JsonlBackend.list_tables(state) |> Enum.sort()
      assert :users in tables
      assert :products in tables

      # Data should be loaded
      assert {:ok, "Alice", _} = JsonlBackend.get(state, :users, "user1")
      assert {:ok, "Widget", _} = JsonlBackend.get(state, :products, "prod1")
    end

    test "returns error when mkdir fails due to permission", %{tmp_dir: tmp_dir} do
      # Create a file where we try to create a directory
      file_path = Path.join(tmp_dir, "a_file")
      File.write!(file_path, "content")

      # Try to create a directory inside the file (should fail)
      invalid_path = Path.join(file_path, "subdir")

      assert {:error, {:jsonl_unavailable, :mkdir_failed}} = JsonlBackend.init(path: invalid_path)
    end

    test "skips tables specified in skip_tables option", %{tmp_dir: tmp_dir} do
      # Create pre-existing jsonl files
      File.write!(
        Path.join(tmp_dir, "users.jsonl"),
        ~s({"op":"put","key":"user1","value":"Alice","ts":1000}\n)
      )

      File.write!(
        Path.join(tmp_dir, "logs.jsonl"),
        ~s({"op":"put","key":"log1","value":"Entry","ts":2000}\n)
      )

      assert {:ok, state} = JsonlBackend.init(path: tmp_dir, skip_tables: [:logs])

      tables = JsonlBackend.list_tables(state)
      assert :users in tables
      refute :logs in tables
    end
  end

  describe "put/4" do
    test "stores values and creates table file", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      assert {:ok, state} = JsonlBackend.put(state, :mytable, "key1", "value1")

      # Check in-memory state
      assert {:ok, "value1", _} = JsonlBackend.get(state, :mytable, "key1")

      # Check file was created
      assert File.exists?(Path.join(tmp_dir, "mytable.jsonl"))
    end

    test "overwrites existing values", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      assert {:ok, state} = JsonlBackend.put(state, :mytable, "key1", "original")
      assert {:ok, state} = JsonlBackend.put(state, :mytable, "key1", "updated")

      assert {:ok, "updated", _} = JsonlBackend.get(state, :mytable, "key1")
    end

    test "put_new does not overwrite existing values", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      assert {:ok, state} = JsonlBackend.put_new(state, :mytable, "key1", "original")
      assert {:exists, state} = JsonlBackend.put_new(state, :mytable, "key1", "updated")
      assert {:ok, "original", _} = JsonlBackend.get(state, :mytable, "key1")
    end

    test "stores complex data types", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      complex_value = %{
        name: "Test",
        count: 42,
        active: true,
        nested: %{a: 1, b: 2},
        list: [1, 2, 3]
      }

      assert {:ok, state} = JsonlBackend.put(state, :mytable, "complex", complex_value)
      assert {:ok, ^complex_value, _} = JsonlBackend.get(state, :mytable, "complex")
    end

    test "stores atom keys and values", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      assert {:ok, state} = JsonlBackend.put(state, :mytable, :atom_key, :atom_value)
      assert {:ok, :atom_value, _} = JsonlBackend.get(state, :mytable, :atom_key)
    end

    test "stores tuple keys and values", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      tuple_key = {:user, 123}
      tuple_value = {:ok, "result"}

      assert {:ok, state} = JsonlBackend.put(state, :mytable, tuple_key, tuple_value)
      assert {:ok, ^tuple_value, _} = JsonlBackend.get(state, :mytable, tuple_key)
    end

    test "stores nested maps with atom keys", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      value = %{status: :active, metadata: %{created_by: :admin, priority: :high}}

      assert {:ok, state} = JsonlBackend.put(state, :mytable, "key", value)
      assert {:ok, ^value, _} = JsonlBackend.get(state, :mytable, "key")
    end

    test "stores lists with mixed types", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      value = [:atom, "string", 123, %{key: :value}]

      assert {:ok, state} = JsonlBackend.put(state, :mytable, "key", value)
      assert {:ok, ^value, _} = JsonlBackend.get(state, :mytable, "key")
    end

    test "appends to file with each put", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      assert {:ok, state} = JsonlBackend.put(state, :mytable, "key1", "value1")
      assert {:ok, state} = JsonlBackend.put(state, :mytable, "key2", "value2")
      assert {:ok, _state} = JsonlBackend.put(state, :mytable, "key3", "value3")

      file_content = File.read!(Path.join(tmp_dir, "mytable.jsonl"))
      lines = String.split(file_content, "\n", trim: true)

      assert length(lines) == 3

      # Each line should be valid JSON
      for line <- lines do
        assert {:ok, _} = Jason.decode(line)
      end
    end
  end

  describe "get/3" do
    test "returns nil for missing keys", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      assert {:ok, nil, _} = JsonlBackend.get(state, :mytable, "nonexistent")
    end

    test "returns nil for missing tables", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      assert {:ok, nil, _} = JsonlBackend.get(state, :nonexistent, "key")
    end

    test "retrieves stored string values", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      assert {:ok, state} = JsonlBackend.put(state, :mytable, "key", "hello world")
      assert {:ok, "hello world", _} = JsonlBackend.get(state, :mytable, "key")
    end

    test "retrieves stored map values", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      value = %{name: "Test", count: 5}
      assert {:ok, state} = JsonlBackend.put(state, :mytable, "key", value)
      assert {:ok, ^value, _} = JsonlBackend.get(state, :mytable, "key")
    end

    test "retrieves stored list values", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      value = [1, 2, 3, 4, 5]
      assert {:ok, state} = JsonlBackend.put(state, :mytable, "key", value)
      assert {:ok, ^value, _} = JsonlBackend.get(state, :mytable, "key")
    end
  end

  describe "delete/3" do
    test "removes existing values", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      assert {:ok, _state} = JsonlBackend.put(state, :mytable, "key", "value")
      assert {:ok, "value", _} = JsonlBackend.get(state, :mytable, "key")

      assert {:ok, new_state} = JsonlBackend.delete(state, :mytable, "key")
      assert {:ok, nil, _} = JsonlBackend.get(new_state, :mytable, "key")
    end

    test "writes delete entry to file", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      assert {:ok, _state} = JsonlBackend.put(state, :mytable, "key", "value")
      assert {:ok, _state} = JsonlBackend.delete(state, :mytable, "key")

      file_content = File.read!(Path.join(tmp_dir, "mytable.jsonl"))
      lines = String.split(file_content, "\n", trim: true)

      assert length(lines) == 2

      # Last line should be a delete operation
      {:ok, last_entry} = Jason.decode(List.last(lines))
      assert last_entry["op"] == "delete"
      assert last_entry["key"] == "key"
    end

    test "succeeds even if key doesn't exist", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      assert {:ok, _} = JsonlBackend.delete(state, :mytable, "nonexistent")
    end
  end

  describe "compare_and_delete_many/2" do
    test "validates all snapshots before writing ordered delete records", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)
      assert {:ok, state} = JsonlBackend.put(state, :responses, "response", "old")
      assert {:ok, state} = JsonlBackend.put(state, :primary, "fence", "keep")

      assert {:error, :mismatch, ^state} =
               JsonlBackend.compare_and_delete_many(state, [
                 {:responses, "response", "old"},
                 {:primary, "fence", "wrong"}
               ])

      assert {:ok, state} =
               JsonlBackend.compare_and_delete_many(state, [
                 {:responses, "response", "old"},
                 {:primary, "fence", "keep"}
               ])

      assert {:ok, nil, _} = JsonlBackend.get(state, :responses, "response")
      assert {:ok, nil, _} = JsonlBackend.get(state, :primary, "fence")
    end
  end

  describe "list/2" do
    test "returns empty list for empty table", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      assert {:ok, [], _} = JsonlBackend.list(state, :empty_table)
    end

    test "returns all key-value pairs", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      assert {:ok, state} = JsonlBackend.put(state, :mytable, "key1", "value1")
      assert {:ok, state} = JsonlBackend.put(state, :mytable, "key2", "value2")
      assert {:ok, state} = JsonlBackend.put(state, :mytable, "key3", "value3")

      assert {:ok, items, _} = JsonlBackend.list(state, :mytable)

      # Convert to map for easier assertion
      items_map = Map.new(items)

      assert items_map["key1"] == "value1"
      assert items_map["key2"] == "value2"
      assert items_map["key3"] == "value3"
      assert map_size(items_map) == 3
    end

    test "does not include deleted items", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      assert {:ok, state} = JsonlBackend.put(state, :mytable, "key1", "value1")
      assert {:ok, state} = JsonlBackend.put(state, :mytable, "key2", "value2")
      assert {:ok, state} = JsonlBackend.delete(state, :mytable, "key1")

      assert {:ok, items, _} = JsonlBackend.list(state, :mytable)

      items_map = Map.new(items)
      refute Map.has_key?(items_map, "key1")
      assert items_map["key2"] == "value2"
      assert map_size(items_map) == 1
    end

    test "isolated by table name", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      assert {:ok, state} = JsonlBackend.put(state, :table_a, "key", "value_a")
      assert {:ok, state} = JsonlBackend.put(state, :table_b, "key", "value_b")

      assert {:ok, items_a, _} = JsonlBackend.list(state, :table_a)
      assert {:ok, items_b, _} = JsonlBackend.list(state, :table_b)

      assert [{"key", "value_a"}] = items_a
      assert [{"key", "value_b"}] = items_b
    end
  end

  describe "list_tables/1" do
    test "returns pre-loaded core tables for fresh state", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      tables = JsonlBackend.list_tables(state)
      assert :chat in tables
      assert :progress in tables
      assert :runs in tables
    end

    test "returns all tables including accessed ones", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)
      initial_tables = JsonlBackend.list_tables(state) |> MapSet.new()

      # Access multiple new tables
      assert {:ok, state} = JsonlBackend.put(state, :custom_users, "u1", "Alice")
      assert {:ok, state} = JsonlBackend.put(state, :custom_products, "p1", "Widget")

      tables = JsonlBackend.list_tables(state) |> MapSet.new()

      # Should include both pre-loaded and new tables
      assert MapSet.member?(tables, :custom_users)
      assert MapSet.member?(tables, :custom_products)
      assert MapSet.subset?(initial_tables, tables)
    end

    test "includes dynamically created tables", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)
      initial_count = length(JsonlBackend.list_tables(state))

      # Create a new table
      assert {:ok, state} = JsonlBackend.put(state, :new_dynamic_table, "key", "value")

      tables = JsonlBackend.list_tables(state)
      assert :new_dynamic_table in tables
      assert length(tables) == initial_count + 1
    end
  end

  describe "persistence" do
    test "data persists across init calls", %{tmp_dir: tmp_dir} do
      # First session: write data
      {:ok, state1} = JsonlBackend.init(path: tmp_dir)
      {:ok, state1} = JsonlBackend.put(state1, :mytable, "key1", "value1")
      {:ok, state1} = JsonlBackend.put(state1, :mytable, "key2", %{nested: "data"})
      {:ok, _state1} = JsonlBackend.put(state1, :other_table, "key", "other_value")

      # Second session: read data from new init
      {:ok, state2} = JsonlBackend.init(path: tmp_dir)

      assert {:ok, "value1", _} = JsonlBackend.get(state2, :mytable, "key1")
      assert {:ok, %{nested: "data"}, _} = JsonlBackend.get(state2, :mytable, "key2")
      assert {:ok, "other_value", _} = JsonlBackend.get(state2, :other_table, "key")
    end

    test "deletes persist across init calls", %{tmp_dir: tmp_dir} do
      # First session: write then delete
      {:ok, state1} = JsonlBackend.init(path: tmp_dir)
      {:ok, state1} = JsonlBackend.put(state1, :mytable, "key1", "value1")
      {:ok, state1} = JsonlBackend.put(state1, :mytable, "key2", "value2")
      {:ok, _state1} = JsonlBackend.delete(state1, :mytable, "key1")

      # Second session: verify delete persisted
      {:ok, state2} = JsonlBackend.init(path: tmp_dir)

      assert {:ok, nil, _} = JsonlBackend.get(state2, :mytable, "key1")
      assert {:ok, "value2", _} = JsonlBackend.get(state2, :mytable, "key2")
    end

    test "overwrites persist correctly across init calls", %{tmp_dir: tmp_dir} do
      # First session: write and overwrite
      {:ok, state1} = JsonlBackend.init(path: tmp_dir)
      {:ok, state1} = JsonlBackend.put(state1, :mytable, "key", "original")
      {:ok, state1} = JsonlBackend.put(state1, :mytable, "key", "updated")
      {:ok, _state1} = JsonlBackend.put(state1, :mytable, "key", "final")

      # Second session: verify final value
      {:ok, state2} = JsonlBackend.init(path: tmp_dir)

      assert {:ok, "final", _} = JsonlBackend.get(state2, :mytable, "key")
    end

    test "complex data types persist correctly", %{tmp_dir: tmp_dir} do
      complex_data = %{
        users: [:alice, :bob, :charlie],
        config: %{port: 8080, host: "localhost"},
        tuple: {:ok, "success"},
        nested: %{deep: %{deeper: %{value: :atom}}}
      }

      # First session
      {:ok, state1} = JsonlBackend.init(path: tmp_dir)
      {:ok, _state1} = JsonlBackend.put(state1, :mytable, "complex", complex_data)

      # Second session
      {:ok, state2} = JsonlBackend.init(path: tmp_dir)
      assert {:ok, ^complex_data, _} = JsonlBackend.get(state2, :mytable, "complex")
    end

    test "preserves nested atom keys across restart", %{tmp_dir: tmp_dir} do
      world = %{
        status: :in_progress,
        board: %{center: :empty, corners: [:x, :o]},
        meta: %{current_player: :x, turn: 3}
      }

      {:ok, state1} = JsonlBackend.init(path: tmp_dir)
      {:ok, _state1} = JsonlBackend.put(state1, :sim_states, "sim-1", %{world: world})

      {:ok, state2} = JsonlBackend.init(path: tmp_dir)
      assert {:ok, %{world: ^world}, _} = JsonlBackend.get(state2, :sim_states, "sim-1")
    end
  end

  describe "encoding/decoding edge cases" do
    test "handles empty string values", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      assert {:ok, state} = JsonlBackend.put(state, :mytable, "key", "")
      assert {:ok, "", _} = JsonlBackend.get(state, :mytable, "key")
    end

    test "handles nil values", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      assert {:ok, state} = JsonlBackend.put(state, :mytable, "key", nil)
      assert {:ok, nil, _} = JsonlBackend.get(state, :mytable, "key")
    end

    test "handles integer keys", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      assert {:ok, state} = JsonlBackend.put(state, :mytable, 123, "value")
      assert {:ok, "value", _} = JsonlBackend.get(state, :mytable, 123)
    end

    test "handles deeply nested structures", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

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

      assert {:ok, state} = JsonlBackend.put(state, :mytable, "deep", deep)
      assert {:ok, ^deep, _} = JsonlBackend.get(state, :mytable, "deep")
    end

    test "handles binary data in strings", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      binary_string = "Hello\nWorld\t\"Quoted\""

      assert {:ok, state} = JsonlBackend.put(state, :mytable, "key", binary_string)
      assert {:ok, ^binary_string, _} = JsonlBackend.get(state, :mytable, "key")
    end

    test "handles unicode strings", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      unicode = "Hello 🌍 世界 Привет"

      assert {:ok, state} = JsonlBackend.put(state, :mytable, "key", unicode)
      assert {:ok, ^unicode, _} = JsonlBackend.get(state, :mytable, "key")
    end

    test "handles mixed tuple and atom structures", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      # Tuple as key with map containing atoms
      key = {:session, :user, 123}
      value = %{status: :active, data: {:ok, [1, 2, 3]}}

      assert {:ok, state} = JsonlBackend.put(state, :mytable, key, value)
      assert {:ok, ^value, _} = JsonlBackend.get(state, :mytable, key)
    end

    test "handles lists of tuples", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      value = [{:ok, 1}, {:error, 2}, {:ok, 3}]

      assert {:ok, state} = JsonlBackend.put(state, :mytable, "key", value)
      assert {:ok, ^value, _} = JsonlBackend.get(state, :mytable, "key")
    end

    test "handles maps with string keys", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      value = %{"string_key" => "value", "number" => 42}

      assert {:ok, state} = JsonlBackend.put(state, :mytable, "key", value)
      assert {:ok, ^value, _} = JsonlBackend.get(state, :mytable, "key")
    end

    test "handles special float values", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      # Note: Infinity and NaN are not valid JSON, so they're typically encoded as strings
      # or the encoder might raise. Testing regular floats here.
      value = %{pi: 3.14159, negative: -0.5, zero: 0.0}

      assert {:ok, state} = JsonlBackend.put(state, :mytable, "key", value)
      assert {:ok, ^value, _} = JsonlBackend.get(state, :mytable, "key")
    end
  end

  describe "multiple tables" do
    test "can work with many tables simultaneously", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      tables = [:users, :products, :orders, :inventory, :categories]

      state =
        Enum.reduce(tables, state, fn table, acc_state ->
          {:ok, new_state} = JsonlBackend.put(acc_state, table, "key", "value_#{table}")
          new_state
        end)

      # Verify all tables have data
      for table <- tables do
        expected_value = "value_#{table}"
        assert {:ok, ^expected_value, _} = JsonlBackend.get(state, table, "key")
      end

      # Verify all files exist
      for table <- tables do
        assert File.exists?(Path.join(tmp_dir, "#{table}.jsonl"))
      end
    end

    test "table isolation - same key in different tables", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      assert {:ok, state} = JsonlBackend.put(state, :table_a, "shared_key", "value_a")
      assert {:ok, state} = JsonlBackend.put(state, :table_b, "shared_key", "value_b")

      assert {:ok, "value_a", _} = JsonlBackend.get(state, :table_a, "shared_key")
      assert {:ok, "value_b", _} = JsonlBackend.get(state, :table_b, "shared_key")
    end
  end

  describe "file format verification" do
    test "writes valid jsonl format", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      assert {:ok, _state} = JsonlBackend.put(state, :mytable, "key", "value")
      assert {:ok, _state} = JsonlBackend.delete(state, :mytable, "key")

      file_path = Path.join(tmp_dir, "mytable.jsonl")
      content = File.read!(file_path)
      lines = String.split(content, "\n", trim: true)

      # Each line should be valid JSON
      for line <- lines do
        assert {:ok, decoded} = Jason.decode(line)
        assert is_map(decoded)
        assert decoded["op"] in ["put", "delete"]
        assert is_binary(decoded["key"]) or is_map(decoded["key"])
        assert is_integer(decoded["ts"])
      end
    end

    test "put entries include value field", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      assert {:ok, _state} = JsonlBackend.put(state, :mytable, "key", "my_value")

      file_path = Path.join(tmp_dir, "mytable.jsonl")
      content = File.read!(file_path)
      {:ok, entry} = Jason.decode(content)

      assert entry["op"] == "put"
      assert entry["value"] == "my_value"
    end

    test "delete entries don't include value field", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      assert {:ok, _state} = JsonlBackend.put(state, :mytable, "key", "value")
      assert {:ok, _state} = JsonlBackend.delete(state, :mytable, "key")

      file_path = Path.join(tmp_dir, "mytable.jsonl")
      lines = File.read!(file_path) |> String.split("\n", trim: true)
      {:ok, delete_entry} = Jason.decode(List.last(lines))

      assert delete_entry["op"] == "delete"
      refute Map.has_key?(delete_entry, "value")
    end
  end

  describe "state management" do
    test "put returns updated state", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      assert {:ok, new_state} = JsonlBackend.put(state, :mytable, "key", "value")

      # New state should reflect the change
      assert {:ok, "value", _} = JsonlBackend.get(new_state, :mytable, "key")
    end

    test "get returns potentially updated state", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      # Accessing a table that might not be loaded yet will update the state
      assert {:ok, nil, new_state} = JsonlBackend.get(state, :mytable, "key")
      # mytable should now be in loaded_tables
      assert :mytable in new_state.loaded_tables
    end

    test "delete returns updated state", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      assert {:ok, _state} = JsonlBackend.put(state, :mytable, "key", "value")
      assert {:ok, new_state} = JsonlBackend.delete(state, :mytable, "key")

      assert {:ok, nil, _} = JsonlBackend.get(new_state, :mytable, "key")
    end

    test "list returns potentially updated state", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      # Accessing a table that might not be loaded yet will update the state
      assert {:ok, [], new_state} = JsonlBackend.list(state, :mytable)
      # mytable should now be in loaded_tables
      assert :mytable in new_state.loaded_tables
    end
  end

  describe "ensure_table_loaded" do
    test "lazily loads tables on first access", %{tmp_dir: tmp_dir} do
      # Create a file before init
      File.write!(
        Path.join(tmp_dir, "lazy_table.jsonl"),
        ~s({"op":"put","key":"lazy_key","value":"lazy_value","ts":1000}\n)
      )

      # Init - will discover and load lazy_table since file exists
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      # lazy_table should be discovered and loaded
      assert :lazy_table in JsonlBackend.list_tables(state)

      # Data should be accessible
      assert {:ok, "lazy_value", _} = JsonlBackend.get(state, :lazy_table, "lazy_key")
    end

    test "marks unknown tables as loaded to avoid repeated attempts", %{tmp_dir: tmp_dir} do
      {:ok, state} = JsonlBackend.init(path: tmp_dir)

      # Access a non-existent table
      assert {:ok, nil, new_state} = JsonlBackend.get(state, :nonexistent, "key")

      # Table should be marked as loaded even though file doesn't exist
      assert :nonexistent in JsonlBackend.list_tables(new_state)
    end
  end

  describe "load failures preserve authority" do
    test "startup rejects unreadable and corrupt discovered journals", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "private_journal.jsonl")
      File.mkdir!(path)
      assert {:error, {:jsonl_unavailable, :read_failed}} = JsonlBackend.init(path: tmp_dir)
      File.rmdir!(path)

      bytes = ~s({"op":"put","key":"key","value":"private-payload"}\nnot-json-private-payload\n)
      File.write!(path, bytes)
      assert {:error, {:jsonl_unavailable, :corrupt_table}} = JsonlBackend.init(path: tmp_dir)

      assert {:stop, {:backend_init_failed, {:jsonl_unavailable, :corrupt_table}}} =
               LemonCore.Store.init(
                 name: :"jsonl_startup_failure_#{System.unique_integer([:positive])}",
                 backend: JsonlBackend,
                 backend_opts: [path: tmp_dir],
                 cached_tables: [:private_journal]
               )

      assert File.read!(path) == bytes

      File.write!(path, ~s({"op":"put","key":"key","value":"repaired"}\n))
      assert {:ok, state} = JsonlBackend.init(path: tmp_dir)
      assert {:ok, "repaired", _} = JsonlBackend.get(state, :private_journal, "key")
    end

    test "every lazy operation rejects corruption without publishing a valid prefix",
         %{tmp_dir: tmp_dir} do
      assert {:ok, state} = JsonlBackend.init(path: tmp_dir)
      assert {:ok, state} = JsonlBackend.put(state, :healthy, "fence", "keep")
      healthy_path = Path.join(tmp_dir, "healthy.jsonl")
      healthy_bytes = File.read!(healthy_path)
      path = Path.join(tmp_dir, "unknown.jsonl")
      bytes = ~s({"op":"put","key":"key","value":"private-payload"}\nbroken-private-payload\n)
      File.write!(path, bytes)

      assert_failed_table_operations(state, :unknown, :corrupt_table)

      assert {:error, {:jsonl_unavailable, :corrupt_table}, failed_state} =
               JsonlBackend.compare_and_delete_many(state, [
                 {:healthy, "fence", "keep"},
                 {:unknown, "key", "private-payload"}
               ])

      refute :unknown in JsonlBackend.list_tables(failed_state)
      refute Map.has_key?(failed_state.data, :unknown)
      assert File.read!(path) == bytes
      assert File.read!(healthy_path) == healthy_bytes

      File.write!(path, ~s({"op":"put","key":"key","value":"repaired"}\n))
      assert {:ok, "repaired", repaired_state} = JsonlBackend.get(failed_state, :unknown, "key")
      assert {:exists, _} = JsonlBackend.put_new(repaired_state, :unknown, "key", "replacement")
      assert {:ok, repaired_state} = JsonlBackend.put(repaired_state, :unknown, "key", "new")
      assert {:ok, "new", _} = JsonlBackend.get(repaired_state, :unknown, "key")
    end

    test "unreadable table and dangling symlink are not absent", %{tmp_dir: tmp_dir} do
      assert {:ok, state} = JsonlBackend.init(path: tmp_dir)
      path = Path.join(tmp_dir, "unreadable.jsonl")
      File.mkdir!(path)
      assert_failed_table_operations(state, :unreadable, :read_failed)
      assert File.dir?(path)
      File.rmdir!(path)
      File.ln_s!(Path.join(tmp_dir, "missing-target"), path)
      assert_failed_table_operations(state, :unreadable, :read_failed)
      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(path)
      File.rm!(path)
      assert {:ok, nil, _} = JsonlBackend.get(state, :unreadable, "key")
    end

    test "missing backing directory does not authorize a new table", %{tmp_dir: tmp_dir} do
      assert {:ok, state} = JsonlBackend.init(path: tmp_dir)
      File.rmdir!(tmp_dir)
      assert_failed_table_operations(state, :unknown, :read_failed)
      File.mkdir!(tmp_dir)
      assert {:ok, nil, state} = JsonlBackend.get(state, :unknown, "key")
      assert {:ok, state} = JsonlBackend.put(state, :unknown, "key", "new")
      assert {:ok, "new", _} = JsonlBackend.get(state, :unknown, "key")
    end

    test "malformed operations and invalid encoded terms reject the entire journal",
         %{tmp_dir: tmp_dir} do
      assert {:ok, state} = JsonlBackend.init(path: tmp_dir)
      path = Path.join(tmp_dir, "unknown.jsonl")

      for bytes <- [
            ~s({"op":"put","key":"key"}\n),
            ~s({"op":"unknown","key":"key","value":"private-payload"}\n),
            ~s({"op":"put","key":"key","value":{"__struct__":"PrivatePayloadMissingModule","fields":{}}}\n),
            <<255, 10>>
          ] do
        File.write!(path, bytes)
        assert_failed_table_operations(state, :unknown, :corrupt_table)
        assert File.read!(path) == bytes
      end
    end

    test "skipping a corrupt startup table does not make its later access empty",
         %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "unknown.jsonl")
      File.write!(path, "private-payload-invalid-json\n")
      assert {:ok, state} = JsonlBackend.init(path: tmp_dir, skip_tables: [:unknown])
      assert_failed_table_operations(state, :unknown, :corrupt_table)
    end

    test "confirmed new tables retain empty and conditional mutation behavior",
         %{tmp_dir: tmp_dir} do
      assert {:ok, state} = JsonlBackend.init(path: tmp_dir)
      assert {:ok, nil, state} = JsonlBackend.get(state, :brand_new, "key")
      assert {:ok, [], state} = JsonlBackend.list(state, :brand_new)
      refute File.exists?(Path.join(tmp_dir, "brand_new.jsonl"))
      assert {:ok, state} = JsonlBackend.put_new(state, :brand_new, "key", "value")
      assert {:exists, state} = JsonlBackend.put_new(state, :brand_new, "key", "replacement")

      assert {:ok, state} =
               JsonlBackend.compare_and_delete_many(state, [{:brand_new, "key", "value"}])

      assert {:ok, nil, _} = JsonlBackend.get(state, :brand_new, "key")
    end
  end

  describe "returned append failures" do
    test "failed writes preserve memory and prior bytes, then recover after repair",
         %{tmp_dir: tmp_dir} do
      assert {:ok, state} = JsonlBackend.init(path: tmp_dir)
      assert {:ok, state} = JsonlBackend.put(state, :journal, "key", "original")
      path = Path.join(tmp_dir, "journal.jsonl")
      saved_path = Path.join(tmp_dir, "saved-journal")
      bytes = File.read!(path)
      File.rename!(path, saved_path)
      File.mkdir!(path)

      assert {:error, {:jsonl_unavailable, :write_failed}} =
               JsonlBackend.put(state, :journal, "key", "private-new-value")

      assert {:error, {:jsonl_unavailable, :write_failed}} =
               JsonlBackend.put_new(state, :journal, "new-key", "private-new-value")

      assert {:error, {:jsonl_unavailable, :write_failed}} =
               JsonlBackend.delete(state, :journal, "key")

      assert {:error, {:jsonl_unavailable, :write_failed}, ^state} =
               JsonlBackend.compare_and_delete_many(state, [{:journal, "key", "original"}])

      assert {:ok, "original", _} = JsonlBackend.get(state, :journal, "key")
      assert File.read!(saved_path) == bytes

      File.rmdir!(path)
      File.rename!(saved_path, path)
      assert {:ok, state} = JsonlBackend.put(state, :journal, "key", "repaired")
      assert {:ok, "repaired", _} = JsonlBackend.get(state, :journal, "key")
      assert {:ok, restarted} = JsonlBackend.init(path: tmp_dir)
      assert {:ok, "repaired", _} = JsonlBackend.get(restarted, :journal, "key")
    end

    test "ordered batch write failure returns the applied prefix and retains the fence",
         %{tmp_dir: tmp_dir} do
      assert {:ok, state} = JsonlBackend.init(path: tmp_dir)
      assert {:ok, state} = JsonlBackend.put(state, :responses, "response", "old")
      assert {:ok, state} = JsonlBackend.put(state, :fence, "key", "keep")
      path = Path.join(tmp_dir, "fence.jsonl")
      saved_path = Path.join(tmp_dir, "saved-fence")
      bytes = File.read!(path)
      File.rename!(path, saved_path)
      File.mkdir!(path)

      assert {:error, {:jsonl_unavailable, :write_failed}, partial_state} =
               JsonlBackend.compare_and_delete_many(state, [
                 {:responses, "response", "old"},
                 {:fence, "key", "keep"}
               ])

      assert {:ok, nil, _} = JsonlBackend.get(partial_state, :responses, "response")
      assert {:ok, "keep", _} = JsonlBackend.get(partial_state, :fence, "key")
      assert File.read!(saved_path) == bytes
      File.rmdir!(path)
      File.rename!(saved_path, path)
      assert {:ok, restarted} = JsonlBackend.init(path: tmp_dir)
      assert {:ok, nil, _} = JsonlBackend.get(restarted, :responses, "response")
      assert {:ok, "keep", _} = JsonlBackend.get(restarted, :fence, "key")
    end

    test "encoding failure returns a bounded error before appending", %{tmp_dir: tmp_dir} do
      assert {:ok, state} = JsonlBackend.init(path: tmp_dir)
      assert {:ok, state} = JsonlBackend.put(state, :journal, "key", "original")
      path = Path.join(tmp_dir, "journal.jsonl")
      bytes = File.read!(path)

      assert {:error, {:jsonl_unavailable, :encode_failed}} =
               JsonlBackend.put(state, :journal, "key", fn -> "private-payload" end)

      assert File.read!(path) == bytes
      assert {:ok, "original", _} = JsonlBackend.get(state, :journal, "key")
    end
  end

  describe "strict Store callers" do
    test "strict reads and atomic mutations fail closed and recover without restart",
         %{tmp_dir: tmp_dir} do
      store = start_jsonl_store(tmp_dir)
      path = Path.join(tmp_dir, "unknown.jsonl")
      bytes = "invalid-private-payload\n"
      File.write!(path, bytes)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :store_unavailable} = LemonCore.Store.fetch(store, :unknown, "key")
          assert {:error, :store_unavailable} = LemonCore.Store.fetch_all(store, :unknown)

          assert {:error, {:jsonl_unavailable, :corrupt_table}} =
                   LemonCore.Store.put(store, :unknown, "key", "private-new-value")

          assert {:error, {:jsonl_unavailable, :corrupt_table}} =
                   LemonCore.Store.put_new(store, :unknown, "key", "private-new-value")

          assert {:error, {:jsonl_unavailable, :corrupt_table}} =
                   LemonCore.Store.delete(store, :unknown, "key")

          assert {:error, {:jsonl_unavailable, :corrupt_table}} =
                   LemonCore.Store.compare_and_swap(
                     store,
                     :unknown,
                     "key",
                     nil,
                     "private-new-value"
                   )

          assert {:error, {:jsonl_unavailable, :corrupt_table}} =
                   LemonCore.Store.compare_and_delete(store, :unknown, "key", nil)

          assert {:error, {:jsonl_unavailable, :corrupt_table}} =
                   LemonCore.Store.compare_and_delete_many(store, [{:unknown, "key", nil}])

          assert {:error, {:jsonl_unavailable, :corrupt_table}} =
                   LemonCore.Store.take(store, :unknown, "key")
        end)

      refute log =~ "private-payload"
      refute log =~ "private-new-value"
      refute log =~ tmp_dir
      assert Process.alive?(store)
      assert File.read!(path) == bytes
      File.write!(path, ~s({"op":"put","key":"key","value":"repaired"}\n))
      assert {:ok, "repaired"} = LemonCore.Store.fetch(store, :unknown, "key")
      assert {:ok, [{"key", "repaired"}]} = LemonCore.Store.fetch_all(store, :unknown)
      assert :ok = LemonCore.Store.compare_and_swap(store, :unknown, "key", "repaired", "new")
    end

    test "append failure does not kill Store or publish replacement cache values",
         %{tmp_dir: tmp_dir} do
      store = start_jsonl_store(tmp_dir, [:journal])
      assert :ok = LemonCore.Store.put(store, :journal, "key", "original")
      path = Path.join(tmp_dir, "journal.jsonl")
      saved_path = Path.join(tmp_dir, "saved-journal")
      bytes = File.read!(path)
      File.rename!(path, saved_path)
      File.mkdir!(path)

      assert {:error, {:jsonl_unavailable, :write_failed}} =
               LemonCore.Store.put(store, :journal, "key", "replacement")

      assert {:error, {:jsonl_unavailable, :write_failed}} =
               LemonCore.Store.compare_and_swap(store, :journal, "key", "original", "replacement")

      assert {:error, {:jsonl_unavailable, :write_failed}} =
               LemonCore.Store.delete(store, :journal, "key")

      assert {:ok, "original"} = LemonCore.Store.fetch(store, :journal, "key")
      {:registered_name, name} = Process.info(store, :registered_name)
      assert {:ok, "original"} = LemonCore.Store.fetch(name, :journal, "key")
      assert Process.alive?(store)
      assert File.read!(saved_path) == bytes
      File.rmdir!(path)
      File.rename!(saved_path, path)
      assert :ok = LemonCore.Store.delete(store, :journal, "key")
    end
  end

  defp assert_failed_table_operations(state, table, classification) do
    error = {:error, {:jsonl_unavailable, classification}}
    assert JsonlBackend.ensure_table_loaded(state, table) == error
    assert JsonlBackend.get(state, table, "key") == error
    assert JsonlBackend.list(state, table) == error
    assert JsonlBackend.put(state, table, "key", "private-new-value") == error
    assert JsonlBackend.put_new(state, table, "key", "private-new-value") == error
    assert JsonlBackend.delete(state, table, "key") == error

    assert {:error, {:jsonl_unavailable, ^classification}, failed_state} =
             JsonlBackend.compare_and_delete_many(state, [{table, "key", nil}])

    refute table in JsonlBackend.list_tables(failed_state)
    refute Map.has_key?(failed_state.data, table)
  end

  defp start_jsonl_store(path, cached_tables \\ []) do
    name = :"jsonl_failure_store_#{System.unique_integer([:positive])}"

    start_supervised!(
      {LemonCore.Store,
       name: name, backend: JsonlBackend, backend_opts: [path: path], cached_tables: cached_tables}
    )
  end
end
