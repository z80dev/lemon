defmodule LemonCore.IdempotencyStoreTest do
  use ExUnit.Case, async: false

  alias LemonCore.IdempotencyStore

  test "stores and fetches idempotency entries through the typed wrapper" do
    scope = "scope_#{System.unique_integer([:positive])}"
    key = "key_#{System.unique_integer([:positive])}"
    value = %{"result" => "ok", "inserted_at_ms" => System.system_time(:millisecond)}

    assert :ok = IdempotencyStore.put(scope, key, value)
    assert IdempotencyStore.get(scope, key) == value
    assert {IdempotencyStore.key(scope, key), value} in IdempotencyStore.list()

    assert :ok = IdempotencyStore.delete(scope, key)
    assert IdempotencyStore.get(scope, key) == nil
  end
end
