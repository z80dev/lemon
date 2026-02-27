defmodule LemonCore.Store.BackendTest do
  @moduledoc """
  Tests for the LemonCore.Store.Backend behaviour.
  """
  use ExUnit.Case, async: true

  alias LemonCore.Store.Backend

  describe "module definition" do
    test "module exists and defines a behaviour" do
      assert Code.ensure_loaded?(Backend)
      assert function_exported?(Backend, :behaviour_info, 1)
    end

    test "has proper moduledoc documentation" do
      {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(Backend)
      assert doc =~ "Behaviour for pluggable storage backends"
    end
  end

  describe "callbacks" do
    test "defines all required callbacks" do
      callbacks = Backend.behaviour_info(:callbacks)
      
      assert {:init, 1} in callbacks
      assert {:put, 4} in callbacks
      assert {:get, 3} in callbacks
      assert {:delete, 3} in callbacks
      assert {:list, 2} in callbacks
    end

    test "all callbacks have correct arities" do
      callbacks = Backend.behaviour_info(:callbacks)
      optional = Backend.behaviour_info(:optional_callbacks)

      # init/1, put/4, get/3, delete/3, list/2 (required) + list_recent/3 (optional)
      assert length(callbacks) == 6
      assert {:list_recent, 3} in optional
    end
  end

  describe "EtsBackend implementation" do
    test "EtsBackend module exists" do
      assert Code.ensure_loaded?(LemonCore.Store.EtsBackend)
    end

    test "EtsBackend implements Backend callbacks" do
      assert function_exported?(LemonCore.Store.EtsBackend, :init, 1)
      assert function_exported?(LemonCore.Store.EtsBackend, :put, 4)
      assert function_exported?(LemonCore.Store.EtsBackend, :get, 3)
      assert function_exported?(LemonCore.Store.EtsBackend, :delete, 3)
      assert function_exported?(LemonCore.Store.EtsBackend, :list, 2)
    end
  end

  describe "mock backend implementation" do
    # Define a mock backend for testing the behaviour contract
    defmodule MemoryBackend do
      @behaviour Backend

      @impl true
      def init(opts) do
        initial_data = Keyword.get(opts, :initial_data, %{})
        {:ok, initial_data}
      end

      @impl true
      def put(state, table, key, value) do
        table_data = Map.get(state, table, %{})
        new_table_data = Map.put(table_data, key, value)
        new_state = Map.put(state, table, new_table_data)
        {:ok, new_state}
      end

      @impl true
      def get(state, table, key) do
        table_data = Map.get(state, table, %{})
        value = Map.get(table_data, key)
        {:ok, value, state}
      end

      @impl true
      def delete(state, table, key) do
        table_data = Map.get(state, table, %{})
        new_table_data = Map.delete(table_data, key)
        new_state = Map.put(state, table, new_table_data)
        {:ok, new_state}
      end

      @impl true
      def list(state, table) do
        table_data = Map.get(state, table, %{})
        entries = Map.to_list(table_data)
        {:ok, entries, state}
      end
    end

    test "mock backend implements all required callbacks" do
      callbacks = Backend.behaviour_info(:callbacks)
      optional = Backend.behaviour_info(:optional_callbacks)

      required = callbacks -- optional

      for {name, arity} <- required do
        assert function_exported?(MemoryBackend, name, arity),
               "Expected #{name}/#{arity} to be implemented"
      end
    end

    test "put and get operations work correctly" do
      {:ok, state} = MemoryBackend.init([])
      
      {:ok, state} = MemoryBackend.put(state, :users, "user1", %{name: "Alice"})
      {:ok, value, _state} = MemoryBackend.get(state, :users, "user1")
      
      assert value == %{name: "Alice"}
    end

    test "get returns nil for non-existent key" do
      {:ok, state} = MemoryBackend.init([])
      
      {:ok, value, _state} = MemoryBackend.get(state, :users, "nonexistent")
      
      assert value == nil
    end

    test "delete removes key" do
      {:ok, state} = MemoryBackend.init([])
      
      {:ok, state} = MemoryBackend.put(state, :users, "user1", %{name: "Alice"})
      {:ok, state} = MemoryBackend.delete(state, :users, "user1")
      {:ok, value, _state} = MemoryBackend.get(state, :users, "user1")
      
      assert value == nil
    end

    test "list returns all entries in table" do
      {:ok, state} = MemoryBackend.init([])
      
      {:ok, state} = MemoryBackend.put(state, :users, "user1", %{name: "Alice"})
      {:ok, state} = MemoryBackend.put(state, :users, "user2", %{name: "Bob"})
      
      {:ok, entries, _state} = MemoryBackend.list(state, :users)
      
      assert length(entries) == 2
      assert {"user1", %{name: "Alice"}} in entries
      assert {"user2", %{name: "Bob"}} in entries
    end

    test "multiple tables are isolated" do
      {:ok, state} = MemoryBackend.init([])
      
      {:ok, state} = MemoryBackend.put(state, :users, "key1", "user_value")
      {:ok, state} = MemoryBackend.put(state, :items, "key1", "item_value")
      
      {:ok, user_value, _state} = MemoryBackend.get(state, :users, "key1")
      {:ok, item_value, _state} = MemoryBackend.get(state, :items, "key1")
      
      assert user_value == "user_value"
      assert item_value == "item_value"
    end
  end

  describe "state immutability" do
    defmodule ImmutableBackend do
      @behaviour Backend

      @impl true
      def init(_opts) do
        {:ok, %{}}
      end

      @impl true
      def put(state, table, key, value) do
        table_data = Map.get(state, table, %{})
        new_table_data = Map.put(table_data, key, value)
        new_state = Map.put(state, table, new_table_data)
        {:ok, new_state}
      end

      @impl true
      def get(state, table, key) do
        table_data = Map.get(state, table, %{})
        {:ok, Map.get(table_data, key), state}
      end

      @impl true
      def delete(state, table, key) do
        table_data = Map.get(state, table, %{})
        new_table_data = Map.delete(table_data, key)
        new_state = Map.put(state, table, new_table_data)
        {:ok, new_state}
      end

      @impl true
      def list(state, table) do
        table_data = Map.get(state, table, %{})
        {:ok, Map.to_list(table_data), state}
      end
    end

    test "operations return new state without modifying original" do
      {:ok, original_state} = ImmutableBackend.init([])
      
      {:ok, new_state} = ImmutableBackend.put(original_state, :test, "key", "value")
      
      # Original state should be unchanged
      assert original_state == %{}
      assert new_state == %{test: %{"key" => "value"}}
    end
  end

  describe "edge cases" do
    defmodule EdgeCaseBackend do
      @behaviour Backend

      @impl true
      def init(opts), do: {:ok, %{data: %{}, opts: opts}}

      @impl true
      def put(%{data: data} = state, table, key, value) do
        table_data = Map.get(data, table, %{})
        new_data = Map.put(data, table, Map.put(table_data, key, value))
        {:ok, %{state | data: new_data}}
      end

      @impl true
      def get(%{data: data} = state, table, key) do
        table_data = Map.get(data, table, %{})
        {:ok, Map.get(table_data, key), state}
      end

      @impl true
      def delete(%{data: data} = state, table, key) do
        table_data = Map.get(data, table, %{})
        new_data = Map.put(data, table, Map.delete(table_data, key))
        {:ok, %{state | data: new_data}}
      end

      @impl true
      def list(%{data: data} = state, table) do
        table_data = Map.get(data, table, %{})
        {:ok, Map.to_list(table_data), state}
      end
    end

    test "handles nil values" do
      {:ok, state} = EdgeCaseBackend.init([])
      
      {:ok, state} = EdgeCaseBackend.put(state, :test, "key", nil)
      {:ok, value, _state} = EdgeCaseBackend.get(state, :test, "key")
      
      assert value == nil
    end

    test "handles complex key types" do
      {:ok, state} = EdgeCaseBackend.init([])
      
      # Test with atom keys
      {:ok, state} = EdgeCaseBackend.put(state, :test, :atom_key, "value1")
      {:ok, value, _state} = EdgeCaseBackend.get(state, :test, :atom_key)
      assert value == "value1"
      
      # Test with integer keys
      {:ok, state} = EdgeCaseBackend.put(state, :test, 123, "value2")
      {:ok, value, _state} = EdgeCaseBackend.get(state, :test, 123)
      assert value == "value2"
      
      # Test with tuple keys
      {:ok, state} = EdgeCaseBackend.put(state, :test, {:composite, "key"}, "value3")
      {:ok, value, _state} = EdgeCaseBackend.get(state, :test, {:composite, "key"})
      assert value == "value3"
    end

    test "handles complex value types" do
      {:ok, state} = EdgeCaseBackend.init([])
      
      # Nested map
      {:ok, state} = EdgeCaseBackend.put(state, :test, "map", %{a: %{b: %{c: 1}}})
      {:ok, value, _state} = EdgeCaseBackend.get(state, :test, "map")
      assert value == %{a: %{b: %{c: 1}}}
      
      # List
      {:ok, state} = EdgeCaseBackend.put(state, :test, "list", [1, 2, [3, 4]])
      {:ok, value, _state} = EdgeCaseBackend.get(state, :test, "list")
      assert value == [1, 2, [3, 4]]
    end

    test "delete on non-existent key succeeds silently" do
      {:ok, state} = EdgeCaseBackend.init([])
      
      # Should not raise
      {:ok, _new_state} = EdgeCaseBackend.delete(state, :test, "nonexistent")
    end

    test "list on empty table returns empty list" do
      {:ok, state} = EdgeCaseBackend.init([])
      
      {:ok, entries, _state} = EdgeCaseBackend.list(state, :nonexistent_table)
      assert entries == []
    end
  end
end
