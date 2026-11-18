defmodule LemonCore.IdempotencyTest do
  use ExUnit.Case, async: false

  alias LemonCore.{Idempotency, IdempotencyStore, Store}

  setup do
    case Store.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # Clear idempotency table to avoid cross-run collisions with persisted data.
    IdempotencyStore.list()
    |> Enum.each(fn {key, _value} -> Store.delete(:idempotency, key) end)

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

    test "stores and retrieves complex data types" do
      scope = "test_#{System.unique_integer()}"
      key = "key_#{System.unique_integer()}"

      complex_value = %{
        nested: %{list: [1, 2, 3], tuple: {:a, :b}},
        binary: <<1, 2, 3>>,
        string: "hello"
      }

      Idempotency.put(scope, key, complex_value)
      assert {:ok, ^complex_value} = Idempotency.get(scope, key)
    end

    test "stores nil as a valid value" do
      scope = "test_#{System.unique_integer()}"
      key = "key_#{System.unique_integer()}"

      Idempotency.put(scope, key, nil)
      assert {:ok, nil} = Idempotency.get(scope, key)
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

    test "put_new/3 is atomic - concurrent calls return consistent results" do
      scope = "test_#{System.unique_integer()}"
      key = "key_#{System.unique_integer()}"

      # First call succeeds
      assert :ok = Idempotency.put_new(scope, key, "first")

      # Subsequent calls return :exists
      assert :exists = Idempotency.put_new(scope, key, "second")
      assert :exists = Idempotency.put_new(scope, key, "third")

      # Value remains the first one
      assert {:ok, "first"} = Idempotency.get(scope, key)
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

    test "delete/2 is idempotent - deleting non-existent key returns :ok" do
      scope = "test_#{System.unique_integer()}"
      key = "key_#{System.unique_integer()}"

      # Delete non-existent key should not raise
      assert :ok = Idempotency.delete(scope, key)
      assert :miss = Idempotency.get(scope, key)

      # Second delete also ok
      assert :ok = Idempotency.delete(scope, key)
    end
  end

  describe "execute/3" do
    test "executes function and caches result on first call" do
      scope = "test_#{System.unique_integer()}"
      key = "key_#{System.unique_integer()}"
      counter = :counters.new(1, [])

      result =
        Idempotency.execute(scope, key, fn ->
          :counters.add(counter, 1, 1)
          "computed_result"
        end)

      assert result == {:ok, "computed_result"}
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
      result =
        Idempotency.execute(scope, key, fn ->
          :counters.add(counter, 1, 1)
          "new_result"
        end)

      assert result == {:ok, "result"}
      assert :counters.get(counter, 1) == 1
    end

    test "execute/3 keeps a raising call's claim, so the key is never re-executed" do
      scope = "test_#{System.unique_integer()}"
      key = "key_#{System.unique_integer()}"
      counter = :counters.new(1, [])

      # First call raises after it may already have had side effects.
      assert_raise RuntimeError, "test error", fn ->
        Idempotency.execute(scope, key, fn ->
          :counters.add(counter, 1, 1)
          raise "test error"
        end)
      end

      assert :counters.get(counter, 1) == 1

      # Its outcome is unknown: the claim stays pending until it expires.
      assert Idempotency.execute(scope, key, fn -> :counters.add(counter, 1, 1) end) ==
               {:error, :in_progress}

      assert Idempotency.get(scope, key) == {:error, :in_progress}
      assert :counters.get(counter, 1) == 1
    end

    test "execute/3 with different keys in same scope are independent" do
      scope = "test_#{System.unique_integer()}"
      key1 = "key_#{System.unique_integer()}_1"
      key2 = "key_#{System.unique_integer()}_2"

      result1 = Idempotency.execute(scope, key1, fn -> "result1" end)
      result2 = Idempotency.execute(scope, key2, fn -> "result2" end)

      assert result1 == {:ok, "result1"}
      assert result2 == {:ok, "result2"}

      # Verify both are cached independently
      assert {:ok, "result1"} = Idempotency.get(scope, key1)
      assert {:ok, "result2"} = Idempotency.get(scope, key2)
    end
  end

  describe "scope isolation" do
    test "different scopes with same key are isolated" do
      scope1 = "test_#{System.unique_integer()}_a"
      scope2 = "test_#{System.unique_integer()}_b"
      key = "shared_key"

      Idempotency.put(scope1, key, "value_in_scope1")
      Idempotency.put(scope2, key, "value_in_scope2")

      assert {:ok, "value_in_scope1"} = Idempotency.get(scope1, key)
      assert {:ok, "value_in_scope2"} = Idempotency.get(scope2, key)
    end

    test "deleting in one scope doesn't affect other scopes" do
      scope1 = "test_#{System.unique_integer()}_a"
      scope2 = "test_#{System.unique_integer()}_b"
      key = "shared_key"

      Idempotency.put(scope1, key, "value1")
      Idempotency.put(scope2, key, "value2")

      Idempotency.delete(scope1, key)

      assert :miss = Idempotency.get(scope1, key)
      assert {:ok, "value2"} = Idempotency.get(scope2, key)
    end

    test "execute/3 caches independently per scope" do
      scope1 = "test_#{System.unique_integer()}_a"
      scope2 = "test_#{System.unique_integer()}_b"
      key = "shared_key"
      counter = :counters.new(1, [])

      result1 =
        Idempotency.execute(scope1, key, fn ->
          :counters.add(counter, 1, 1)
          "scope1_result"
        end)

      result2 =
        Idempotency.execute(scope2, key, fn ->
          :counters.add(counter, 1, 1)
          "scope2_result"
        end)

      assert result1 == {:ok, "scope1_result"}
      assert result2 == {:ok, "scope2_result"}
      # Function was executed twice (once per scope)
      assert :counters.get(counter, 1) == 2
    end
  end

  describe "TTL expiration" do
    test "expired entries return :miss and are taken over by compare-and-swap" do
      scope = "test_#{System.unique_integer()}"
      key = "key_#{System.unique_integer()}"

      # Store with a timestamp far in the past (more than 24 hours ago)
      expired_time = System.system_time(:millisecond) - 25 * 60 * 60 * 1000

      expired_value = %{
        "result" => "old_value",
        "inserted_at_ms" => expired_time
      }

      IdempotencyStore.put(scope, key, expired_value)

      assert :miss = Idempotency.get(scope, key)

      # The expired entry no longer holds the key.
      assert :ok = Idempotency.put_new(scope, key, "new_value")
      assert {:ok, "new_value"} = Idempotency.get(scope, key)
    end

    test "non-expired entries are returned" do
      scope = "test_#{System.unique_integer()}"
      key = "key_#{System.unique_integer()}"

      # Store with current timestamp
      Idempotency.put(scope, key, "fresh_value")

      # Should return the value
      assert {:ok, "fresh_value"} = Idempotency.get(scope, key)
    end

    test "entries inside the 24 hour boundary are NOT expired" do
      scope = "test_#{System.unique_integer()}"
      key = "key_#{System.unique_integer()}"

      boundary_time = System.system_time(:millisecond) - (24 * 60 * 60 * 1000 - 1_000)

      boundary_value = %{
        "result" => "boundary_value",
        "inserted_at_ms" => boundary_time
      }

      IdempotencyStore.put(scope, key, boundary_value)

      # Should return the value (not expired - TTL uses > not >=)
      assert {:ok, "boundary_value"} = Idempotency.get(scope, key)
    end

    test "entries just under 24 hours are not expired" do
      scope = "test_#{System.unique_integer()}"
      key = "key_#{System.unique_integer()}"

      # Store with a timestamp just under 24 hours ago
      recent_time = System.system_time(:millisecond) - 23 * 60 * 60 * 1000

      recent_value = %{
        "result" => "recent_value",
        "inserted_at_ms" => recent_time
      }

      IdempotencyStore.put(scope, key, recent_value)

      # Should return the value (not expired)
      assert {:ok, "recent_value"} = Idempotency.get(scope, key)
    end
  end

  describe "legacy format compatibility" do
    test "handles legacy format without timestamp" do
      scope = "test_#{System.unique_integer()}"
      key = "key_#{System.unique_integer()}"

      # Legacy format: just the raw result without timestamp wrapper
      IdempotencyStore.put(scope, key, "legacy_value")

      # Should still return the value (no TTL check possible)
      assert {:ok, "legacy_value"} = Idempotency.get(scope, key)
    end
  end

  describe "edge cases" do
    test "handles empty string scope and key" do
      assert :miss = Idempotency.get("", "")

      Idempotency.put("", "", "empty_value")
      assert {:ok, "empty_value"} = Idempotency.get("", "")
    end

    test "handles binary scope and key with special characters" do
      scope = "test/scope:with_special.chars"
      key = "key#with@special!chars"

      Idempotency.put(scope, key, "special_value")
      assert {:ok, "special_value"} = Idempotency.get(scope, key)
    end

    test "handles unicode in scope and key" do
      scope = "test_日本語"
      key = "key_🎉"

      Idempotency.put(scope, key, "unicode_value")
      assert {:ok, "unicode_value"} = Idempotency.get(scope, key)
    end

    test "handles very long scope and key" do
      scope = String.duplicate("a", 1000)
      key = String.duplicate("b", 1000)

      Idempotency.put(scope, key, "long_value")
      assert {:ok, "long_value"} = Idempotency.get(scope, key)
    end
  end
end
