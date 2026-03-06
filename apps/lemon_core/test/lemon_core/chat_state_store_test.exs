defmodule LemonCore.ChatStateStoreTest do
  use ExUnit.Case, async: false

  alias LemonCore.ChatStateStore

  test "round-trips chat state through the typed wrapper" do
    key = "agent:test:main:#{System.unique_integer([:positive])}"
    value = %{last_engine: "codex", last_resume_token: "thread_123"}

    assert :ok = ChatStateStore.put(key, value)
    assert ChatStateStore.get(key) == value
    assert :ok = ChatStateStore.delete(key)
    assert ChatStateStore.get(key) == nil
  end
end
