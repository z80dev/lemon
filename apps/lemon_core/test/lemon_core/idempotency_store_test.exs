defmodule LemonCore.IdempotencyStoreTest do
  use ExUnit.Case, async: false

  alias LemonCore.IdempotencyStore

  test "stores and fetches idempotency entries through the typed wrapper" do
    scope = "scope_#{System.unique_integer([:positive])}"
    key = "key_#{System.unique_integer([:positive])}"
    value = %{"result" => "ok", "inserted_at_ms" => System.system_time(:millisecond)}

    assert :ok = IdempotencyStore.put(scope, key, value)
    assert IdempotencyStore.fetch(scope, key) == {:ok, value}
    assert {IdempotencyStore.key(scope, key), value} in IdempotencyStore.list()

    assert :ok = IdempotencyStore.delete(scope, key)
    assert IdempotencyStore.fetch(scope, key) == {:ok, nil}
  end

  test "put_new and compare operations are atomic on the exact stored value" do
    scope = "scope_#{System.unique_integer([:positive])}"
    key = "key_#{System.unique_integer([:positive])}"
    on_exit(fn -> IdempotencyStore.delete(scope, key) end)

    assert :ok = IdempotencyStore.put_new(scope, key, :first)
    assert {:error, :exists} = IdempotencyStore.put_new(scope, key, :second)
    assert {:error, :mismatch} = IdempotencyStore.compare_and_swap(scope, key, :second, :third)
    assert :ok = IdempotencyStore.compare_and_swap(scope, key, :first, :third)
    assert {:error, :mismatch} = IdempotencyStore.compare_and_delete(scope, key, :first)
    assert :ok = IdempotencyStore.compare_and_delete(scope, key, :third)
    assert IdempotencyStore.fetch(scope, key) == {:ok, nil}
  end
end
