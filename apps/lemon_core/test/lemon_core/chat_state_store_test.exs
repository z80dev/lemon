defmodule LemonCore.ChatStateStoreTest do
  use ExUnit.Case, async: false

  alias LemonCore.ChatStateStore

  test "round-trips chat state through the typed wrapper" do
    key = "agent:test:main:#{System.unique_integer([:positive])}"
    value = %{last_engine: "codex", last_resume_token: "thread_123"}

    assert :ok = ChatStateStore.put(key, value)

    # The store stamps its TTL on write, so a read is the value plus
    # `:expires_at`. This used to be true only of reads that missed the ETS
    # mirror and reached the backend — a caller-side cache write meant an
    # immediate read handed back the *unstamped* value instead, so one key had
    # two shapes depending on cache state. The store owns the mirror now, and
    # both paths return the stamped value.
    assert %{last_engine: "codex", last_resume_token: "thread_123", expires_at: expires_at} =
             ChatStateStore.get(key)

    assert is_integer(expires_at)
    assert expires_at > System.system_time(:millisecond)

    assert :ok = ChatStateStore.delete(key)
    assert ChatStateStore.get(key) == nil
  end
end
