defmodule LemonCore.SessionKeyTest do
  use ExUnit.Case, async: true

  alias LemonCore.SessionKey

  describe "parse/1 validation" do
    test "rejects non-canonical legacy telegram format" do
      assert {:error, :invalid} = SessionKey.parse("channel:telegram:bot123:chat456")

      assert {:error, :invalid} =
               SessionKey.parse("channel:telegram:bot123:chat456:thread:topic42:sub:msg123")
    end
  end

  describe "extras handling" do
    test "rejects unknown key/value extras" do
      assert {:error, :invalid} ==
               SessionKey.parse(
                 "agent:a:telegram:bot:dm:peer42:future_key:future_value:thread:topic42:sub:msg123"
               )
    end

    test "returns invalid for odd trailing extras" do
      assert {:error, :invalid} = SessionKey.parse("agent:a:telegram:bot:dm:peer42:thread")

      assert {:error, :invalid} =
               SessionKey.parse("agent:a:telegram:bot:dm:peer42:sub:msg123:extra")
    end

    test "returns invalid for duplicate extras" do
      assert {:error, :invalid} =
               SessionKey.parse("agent:a:telegram:bot:dm:peer42:thread:topic42:thread:topic99")
    end
  end

  describe "allowed_peer_kinds/0" do
    test "includes expected values and excludes dynamic untrusted values" do
      allowed = SessionKey.allowed_peer_kinds() |> MapSet.new()

      assert MapSet.subset?(MapSet.new(["dm", "group", "channel", "main", "unknown"]), allowed)
      refute MapSet.member?(allowed, "malicious_kind_1")
      refute MapSet.member?(allowed, "peer_kind_from_user_input")
    end
  end

  describe "main?/1, channel_peer?/1 and agent_id/1 for invalid keys" do
    test "return false/nil for malformed inputs" do
      for invalid <- [
            "",
            "not-a-session-key",
            "agent:a:telegram:bot:dm:peer42:thread",
            "agent:a:telegram:bot:not_allowed:peer42"
          ] do
        refute SessionKey.main?(invalid)
        refute SessionKey.channel_peer?(invalid)
        assert SessionKey.agent_id(invalid) == nil
      end
    end
  end
end
