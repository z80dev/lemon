defmodule LemonChannels.Outbox.DedupeTest do
  use ExUnit.Case, async: false

  alias LemonChannels.Outbox.Dedupe

  setup do
    # Start the dedupe process if not running
    case Process.whereis(Dedupe) do
      nil ->
        {:ok, _pid} = Dedupe.start_link([])
        :ok

      _pid ->
        :ok
    end
  end

  describe "check/2 and mark/2" do
    test "returns :new for unseen key" do
      key = "test_#{System.unique_integer()}"
      assert Dedupe.check("channel", key) == :new
    end

    test "returns :duplicate for seen key" do
      key = "test_#{System.unique_integer()}"

      Dedupe.mark("channel", key)
      assert Dedupe.check("channel", key) == :duplicate
    end

    test "different channels have separate keys" do
      key = "test_#{System.unique_integer()}"

      Dedupe.mark("channel_a", key)

      assert Dedupe.check("channel_a", key) == :duplicate
      assert Dedupe.check("channel_b", key) == :new
    end
  end
end
