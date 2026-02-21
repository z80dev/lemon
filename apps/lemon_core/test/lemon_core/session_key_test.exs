defmodule LemonCore.SessionKeyTest do
  use ExUnit.Case, async: true

  alias LemonCore.SessionKey

  doctest LemonCore.SessionKey

  describe "main/1" do
    test "generates a main session key with agent prefix" do
      assert SessionKey.main("my_agent") == "agent:my_agent:main"
    end
  end

  describe "channel_peer/1" do
    test "generates a channel peer session key with required fields" do
      key =
        SessionKey.channel_peer(%{
          agent_id: "bot1",
          channel_id: "telegram",
          account_id: "acct1",
          peer_kind: :dm,
          peer_id: "user42"
        })

      assert key == "agent:bot1:telegram:acct1:dm:user42"
    end

    test "includes thread_id when provided" do
      key =
        SessionKey.channel_peer(%{
          agent_id: "bot1",
          channel_id: "telegram",
          account_id: "acct1",
          peer_kind: :group,
          peer_id: "chat99",
          thread_id: "topic7"
        })

      assert key == "agent:bot1:telegram:acct1:group:chat99:thread:topic7"
    end

    test "includes both thread_id and sub_id when provided" do
      key =
        SessionKey.channel_peer(%{
          agent_id: "bot1",
          channel_id: "telegram",
          account_id: "acct1",
          peer_kind: :dm,
          peer_id: "user42",
          thread_id: "topic7",
          sub_id: "msg123"
        })

      assert key == "agent:bot1:telegram:acct1:dm:user42:thread:topic7:sub:msg123"
    end
  end

  describe "parse/1" do
    test "parses a main session key" do
      assert %{
               agent_id: "my_agent",
               kind: :main,
               channel_id: nil,
               account_id: nil,
               peer_kind: nil,
               peer_id: nil,
               thread_id: nil,
               sub_id: nil
             } = SessionKey.parse("agent:my_agent:main")
    end

    test "parses a channel peer session key" do
      assert %{
               agent_id: "bot1",
               kind: :channel_peer,
               channel_id: "telegram",
               account_id: "acct1",
               peer_kind: :dm,
               peer_id: "user42",
               thread_id: nil,
               sub_id: nil
             } = SessionKey.parse("agent:bot1:telegram:acct1:dm:user42")
    end

    test "parses a channel peer session key with thread and sub" do
      parsed = SessionKey.parse("agent:bot1:telegram:acct1:group:chat99:thread:topic7:sub:msg1")

      assert parsed.kind == :channel_peer
      assert parsed.thread_id == "topic7"
      assert parsed.sub_id == "msg1"
    end

    test "rejects non-canonical legacy telegram format" do
      assert {:error, :invalid} = SessionKey.parse("channel:telegram:bot123:chat456")

      assert {:error, :invalid} =
               SessionKey.parse("channel:telegram:bot123:chat456:thread:topic42:sub:msg123")
    end

    test "rejects invalid peer kind" do
      assert {:error, :invalid_peer_kind} =
               SessionKey.parse("agent:a:telegram:bot:not_allowed:peer42")
    end
  end

  describe "parse/1 round-trip" do
    test "main key round-trips through generate and parse" do
      key = SessionKey.main("test_agent")
      parsed = SessionKey.parse(key)

      assert parsed.agent_id == "test_agent"
      assert parsed.kind == :main
    end

    test "channel_peer key round-trips through generate and parse" do
      opts = %{
        agent_id: "bot1",
        channel_id: "telegram",
        account_id: "acct1",
        peer_kind: :dm,
        peer_id: "user42",
        thread_id: "topic7",
        sub_id: "msg123"
      }

      key = SessionKey.channel_peer(opts)
      parsed = SessionKey.parse(key)

      assert parsed.agent_id == "bot1"
      assert parsed.channel_id == "telegram"
      assert parsed.account_id == "acct1"
      assert parsed.peer_kind == :dm
      assert parsed.peer_id == "user42"
      assert parsed.thread_id == "topic7"
      assert parsed.sub_id == "msg123"
    end
  end

  describe "valid?/1" do
    test "returns true for valid main session key" do
      assert SessionKey.valid?("agent:my_agent:main")
    end

    test "returns true for valid channel peer session key" do
      assert SessionKey.valid?("agent:bot1:telegram:acct1:dm:user42")
    end

    test "returns false for invalid session key" do
      refute SessionKey.valid?("")
      refute SessionKey.valid?("not-a-session-key")
    end
  end

  describe "main?/1" do
    test "returns true for main session keys" do
      assert SessionKey.main?("agent:test:main")
    end

    test "returns false for channel peer session keys" do
      refute SessionKey.main?("agent:bot1:telegram:acct1:dm:user42")
    end
  end

  describe "channel_peer?/1" do
    test "returns true for channel peer session keys" do
      assert SessionKey.channel_peer?("agent:bot1:telegram:acct1:dm:user42")
    end

    test "returns false for main session keys" do
      refute SessionKey.channel_peer?("agent:test:main")
    end
  end

  describe "agent_id/1" do
    test "extracts agent_id from main session key" do
      assert SessionKey.agent_id("agent:my_agent:main") == "my_agent"
    end

    test "extracts agent_id from channel peer session key" do
      assert SessionKey.agent_id("agent:bot1:telegram:acct1:dm:user42") == "bot1"
    end

    test "returns nil for invalid session keys" do
      assert SessionKey.agent_id("invalid") == nil
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
