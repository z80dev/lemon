defmodule LemonCore.SessionKeyTest do
  use ExUnit.Case, async: true

  alias LemonCore.SessionKey

  describe "parse/1 legacy telegram format" do
    test "parses legacy key without extras" do
      assert %{
               agent_id: "default",
               kind: :channel_peer,
               channel_id: "telegram",
               account_id: "bot123",
               peer_kind: :dm,
               peer_id: "chat456",
               thread_id: nil,
               sub_id: nil
             } = SessionKey.parse("channel:telegram:bot123:chat456")
    end

    test "parses legacy key with thread and sub extras" do
      assert %{
               thread_id: "topic42",
               sub_id: "msg123"
             } = SessionKey.parse("channel:telegram:bot123:chat456:thread:topic42:sub:msg123")
    end
  end

  describe "extras handling" do
    test "ignores unknown key/value extras" do
      assert %{
               thread_id: "topic42",
               sub_id: "msg123"
             } =
               SessionKey.parse(
                 "agent:a:telegram:bot:dm:peer42:future_key:future_value:thread:topic42:sub:msg123"
               )
    end

    test "returns invalid for odd trailing extras" do
      assert {:error, :invalid} = SessionKey.parse("agent:a:telegram:bot:dm:peer42:thread")

      assert {:error, :invalid} =
               SessionKey.parse("agent:a:telegram:bot:dm:peer42:sub:msg123:extra")
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
