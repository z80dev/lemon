defmodule LemonRouter.PendingCompactionStoreTest do
  use ExUnit.Case, async: false

  alias LemonRouter.PendingCompactionStore

  test "round-trips pending compaction markers through the typed wrapper" do
    session_key = "agent:test:main:#{System.unique_integer([:positive])}"
    marker = %{reason: "near_limit", set_at_ms: System.system_time(:millisecond)}

    assert :ok = PendingCompactionStore.put(session_key, marker)
    assert PendingCompactionStore.get(session_key) == marker
    assert :ok = PendingCompactionStore.delete(session_key)
    assert PendingCompactionStore.get(session_key) == nil
  end
end
