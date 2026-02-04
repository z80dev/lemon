defmodule LemonCore.IdempotencyTest do
  use ExUnit.Case, async: false

  alias LemonCore.Idempotency

  setup do
    # Clean up any test keys
    :ok
  end

  describe "get/2 and put/3" do
    test "returns :miss for non-existent key" do
      scope = "test_#{System.unique_integer()}"
      assert Idempotency.get(scope, "nonexistent") == :miss
    end

    test "stores and retrieves a value" do
      scope = "test_#{System.unique_integer()}"
      key = "key_#{System.unique_integer()}"

      Idempotency.put(scope, key, {:ok, "result"})
      assert {:ok, {:ok, "result"}} = Idempotency.get(scope, key)
    end

    test "overwrites existing value" do
      scope = "test_#{System.unique_integer()}"
      key = "key_#{System.unique_integer()}"

      Idempotency.put(scope, key, "first")
      Idempotency.put(scope, key, "second")

      assert {:ok, "second"} = Idempotency.get(scope, key)
    end
  end

  describe "put_new/3" do
    test "stores value when key doesn't exist" do
      scope = "test_#{System.unique_integer()}"
      key = "key_#{System.unique_integer()}"

      assert :ok = Idempotency.put_new(scope, key, "value")
      assert {:ok, "value"} = Idempotency.get(scope, key)
    end

    test "returns :exists when key already exists" do
      scope = "test_#{System.unique_integer()}"
      key = "key_#{System.unique_integer()}"

      Idempotency.put(scope, key, "original")
      assert :exists = Idempotency.put_new(scope, key, "new")
      assert {:ok, "original"} = Idempotency.get(scope, key)
    end
  end

  describe "delete/2" do
    test "deletes an existing key" do
      scope = "test_#{System.unique_integer()}"
      key = "key_#{System.unique_integer()}"

      Idempotency.put(scope, key, "value")
      assert {:ok, "value"} = Idempotency.get(scope, key)

      Idempotency.delete(scope, key)
      assert :miss = Idempotency.get(scope, key)
    end
  end

  describe "execute/3" do
    test "executes function and caches result on first call" do
      scope = "test_#{System.unique_integer()}"
      key = "key_#{System.unique_integer()}"
      counter = :counters.new(1, [])

      result = Idempotency.execute(scope, key, fn ->
        :counters.add(counter, 1, 1)
        "computed_result"
      end)

      assert result == "computed_result"
      assert :counters.get(counter, 1) == 1
    end

    test "returns cached result on subsequent calls" do
      scope = "test_#{System.unique_integer()}"
      key = "key_#{System.unique_integer()}"
      counter = :counters.new(1, [])

      # First call
      Idempotency.execute(scope, key, fn ->
        :counters.add(counter, 1, 1)
        "result"
      end)

      # Second call should not execute function
      result = Idempotency.execute(scope, key, fn ->
        :counters.add(counter, 1, 1)
        "new_result"
      end)

      assert result == "result"
      assert :counters.get(counter, 1) == 1
    end
  end
end
