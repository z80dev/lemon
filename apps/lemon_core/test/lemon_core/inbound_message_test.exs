defmodule LemonCore.InboundMessageTest do
  use ExUnit.Case, async: true

  alias LemonCore.InboundMessage

  describe "new/1" do
    test "raises on missing required fields" do
      assert_raise ArgumentError, fn ->
        InboundMessage.new(
          account_id: "bot",
          peer: %{kind: :dm, id: "123", thread_id: nil},
          message: %{id: "456", text: "hello", timestamp: 1_700_000_000, reply_to_id: nil}
        )
      end
    end
  end
end
