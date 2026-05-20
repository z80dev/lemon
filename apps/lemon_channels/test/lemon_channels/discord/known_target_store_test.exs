defmodule LemonChannels.Discord.KnownTargetStoreTest do
  use ExUnit.Case, async: false

  alias LemonChannels.Discord.KnownTargetStore

  test "round-trips discord known-target entries through the typed wrapper" do
    key = {"default", 123_456, 789}
    value = %{channel_name: "ops", thread_name: "deploys", updated_at_ms: 1}

    assert :ok = KnownTargetStore.put(key, value)
    assert KnownTargetStore.get(key) == value

    assert Enum.any?(KnownTargetStore.list(), fn {stored_key, stored_value} ->
             stored_key == key and stored_value == value
           end)
  end
end
