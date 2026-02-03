defmodule LemonGateway.Store.EtsBackendTest do
  use ExUnit.Case, async: true

  alias LemonGateway.Store.EtsBackend

  setup do
    {:ok, state} = EtsBackend.init([])
    {:ok, state: state}
  end

  describe "init/1" do
    test "creates ETS tables" do
      {:ok, state} = EtsBackend.init([])

      assert is_reference(state.chat)
      assert is_reference(state.progress)
      assert is_reference(state.runs)
      assert is_reference(state.run_history)
    end
  end

  describe "put/4 and get/3" do
    test "stores and retrieves values", %{state: state} do
      {:ok, state} = EtsBackend.put(state, :chat, :key1, %{foo: "bar"})
      {:ok, value, _state} = EtsBackend.get(state, :chat, :key1)

      assert value == %{foo: "bar"}
    end

    test "returns nil for missing keys", %{state: state} do
      {:ok, value, _state} = EtsBackend.get(state, :chat, :missing)
      assert value == nil
    end

    test "overwrites existing values", %{state: state} do
      {:ok, state} = EtsBackend.put(state, :chat, :key1, "first")
      {:ok, state} = EtsBackend.put(state, :chat, :key1, "second")
      {:ok, value, _state} = EtsBackend.get(state, :chat, :key1)

      assert value == "second"
    end

    test "stores in different tables independently", %{state: state} do
      {:ok, state} = EtsBackend.put(state, :chat, :key1, "chat_value")
      {:ok, state} = EtsBackend.put(state, :runs, :key1, "runs_value")

      {:ok, chat_value, state} = EtsBackend.get(state, :chat, :key1)
      {:ok, runs_value, _state} = EtsBackend.get(state, :runs, :key1)

      assert chat_value == "chat_value"
      assert runs_value == "runs_value"
    end

    test "handles tuple keys", %{state: state} do
      key = {:scope, 123}
      {:ok, state} = EtsBackend.put(state, :progress, key, "run_id")
      {:ok, value, _state} = EtsBackend.get(state, :progress, key)

      assert value == "run_id"
    end
  end

  describe "delete/3" do
    test "removes a key", %{state: state} do
      {:ok, state} = EtsBackend.put(state, :chat, :key1, "value")
      {:ok, state} = EtsBackend.delete(state, :chat, :key1)
      {:ok, value, _state} = EtsBackend.get(state, :chat, :key1)

      assert value == nil
    end

    test "is idempotent for missing keys", %{state: state} do
      {:ok, _state} = EtsBackend.delete(state, :chat, :missing)
    end
  end

  describe "list/2" do
    test "returns all key-value pairs", %{state: state} do
      {:ok, state} = EtsBackend.put(state, :chat, :a, 1)
      {:ok, state} = EtsBackend.put(state, :chat, :b, 2)
      {:ok, state} = EtsBackend.put(state, :chat, :c, 3)

      {:ok, items, _state} = EtsBackend.list(state, :chat)

      assert length(items) == 3
      assert {:a, 1} in items
      assert {:b, 2} in items
      assert {:c, 3} in items
    end

    test "returns empty list for empty table", %{state: state} do
      {:ok, items, _state} = EtsBackend.list(state, :chat)
      assert items == []
    end
  end
end
