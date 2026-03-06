defmodule LemonChannels.Telegram.KnownTargetStoreTest do
  use ExUnit.Case, async: false

  alias LemonChannels.Telegram.KnownTargetStore

  test "round-trips telegram known-target entries through the typed wrapper" do
    key = {"default", 123_456, 789}
    value = %{chat_title: "Lemon", topic_name: "Refactor", updated_at_ms: 1}

    assert :ok = KnownTargetStore.put(key, value)
    assert KnownTargetStore.get(key) == value
    assert Enum.any?(KnownTargetStore.list(), fn {stored_key, stored_value} ->
             stored_key == key and stored_value == value
           end)
  end
end
