defmodule LemonChannels.Adapters.Telegram.TransportSharedDedupeTest do
  use ExUnit.Case, async: false

  alias LemonChannels.Telegram.TransportShared

  setup do
    :ok = TransportShared.init_dedupe(:channels)
    :ok
  end

  test "inbound_message_dedupe_key includes thread id" do
    inbound = %{
      peer: %{id: "chat-1", thread_id: "topic-7"},
      message: %{id: "42"}
    }

    assert {"chat-1", "topic-7", "42"} == TransportShared.inbound_message_dedupe_key(inbound)
  end

  test "same message id in different threads is not treated as a duplicate" do
    uniq = Integer.to_string(System.unique_integer([:positive]))

    key_a = TransportShared.message_dedupe_key("chat-" <> uniq, "topic-a", "42")
    key_b = TransportShared.message_dedupe_key("chat-" <> uniq, "topic-b", "42")

    assert :new == TransportShared.check_and_mark_dedupe(:channels, key_a, 60_000)
    assert :seen == TransportShared.check_and_mark_dedupe(:channels, key_a, 60_000)
    assert :new == TransportShared.check_and_mark_dedupe(:channels, key_b, 60_000)
  end
end
