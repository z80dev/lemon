defmodule LemonRouter.SessionKeyTest do
  use ExUnit.Case, async: true

  alias LemonCore.SessionKey

  describe "main/1" do
    test "generates main session key" do
      assert SessionKey.main("my-agent") == "agent:my-agent:main"
    end
  end

  describe "channel_peer/1" do
    test "generates channel peer key without thread" do
      key =
        SessionKey.channel_peer(%{
          agent_id: "my-agent",
          channel_id: "telegram",
          account_id: "bot123",
          peer_kind: :dm,
          peer_id: "user456"
        })

      assert key == "agent:my-agent:telegram:bot123:dm:user456"
    end

    test "generates channel peer key with sub_id" do
      key =
        SessionKey.channel_peer(%{
          agent_id: "my-agent",
          channel_id: "telegram",
          account_id: "bot123",
          peer_kind: :dm,
          peer_id: "user456",
          sub_id: "msg123"
        })

      assert key == "agent:my-agent:telegram:bot123:dm:user456:sub:msg123"
    end

    test "generates channel peer key with thread" do
      key =
        SessionKey.channel_peer(%{
          agent_id: "my-agent",
          channel_id: "telegram",
          account_id: "bot123",
          peer_kind: :group,
          peer_id: "chat789",
          thread_id: "topic42"
        })

      assert key == "agent:my-agent:telegram:bot123:group:chat789:thread:topic42"
    end

    test "generates channel peer key with thread and sub_id" do
      key =
        SessionKey.channel_peer(%{
          agent_id: "my-agent",
          channel_id: "telegram",
          account_id: "bot123",
          peer_kind: :group,
          peer_id: "chat789",
          thread_id: "topic42",
          sub_id: "msg123"
        })

      assert key == "agent:my-agent:telegram:bot123:group:chat789:thread:topic42:sub:msg123"
    end
  end

  describe "parse/1" do
    test "parses main session key" do
      assert %{
               agent_id: "my-agent",
               kind: :main,
               channel_id: nil,
               account_id: nil,
               peer_kind: nil,
               peer_id: nil,
               thread_id: nil,
               sub_id: nil
             } = SessionKey.parse("agent:my-agent:main")
    end

    test "parses channel peer key without thread" do
      assert %{
               agent_id: "my-agent",
               kind: :channel_peer,
               channel_id: "telegram",
               account_id: "bot123",
               peer_kind: :dm,
               peer_id: "user456",
               thread_id: nil,
               sub_id: nil
             } = SessionKey.parse("agent:my-agent:telegram:bot123:dm:user456")
    end

    test "parses channel peer key with thread" do
      assert %{
               agent_id: "my-agent",
               kind: :channel_peer,
               channel_id: "telegram",
               account_id: "bot123",
               peer_kind: :group,
               peer_id: "chat789",
               thread_id: "topic42",
               sub_id: nil
             } = SessionKey.parse("agent:my-agent:telegram:bot123:group:chat789:thread:topic42")
    end

    test "parses channel peer key with thread and sub_id" do
      assert %{
               agent_id: "my-agent",
               kind: :channel_peer,
               channel_id: "telegram",
               account_id: "bot123",
               peer_kind: :group,
               peer_id: "chat789",
               thread_id: "topic42",
               sub_id: "msg123"
             } =
               SessionKey.parse(
                 "agent:my-agent:telegram:bot123:group:chat789:thread:topic42:sub:msg123"
               )
    end

    test "returns error for invalid key" do
      assert {:error, :invalid} = SessionKey.parse("invalid")
      assert {:error, :invalid} = SessionKey.parse("")
      assert {:error, :invalid} = SessionKey.parse("foo:bar")
    end

    test "returns error for invalid peer_kind" do
      # Invalid peer_kind should return error, not create a new atom
      assert {:error, :invalid_peer_kind} =
               SessionKey.parse("agent:my-agent:telegram:bot123:malicious_kind:user456")

      assert {:error, :invalid_peer_kind} =
               SessionKey.parse("agent:my-agent:telegram:bot123:badtype:user456:thread:topic")
    end

    test "accepts only whitelisted peer_kind values" do
      # Valid peer kinds should work
      assert %{peer_kind: :dm} = SessionKey.parse("agent:a:tg:bot:dm:123")
      assert %{peer_kind: :group} = SessionKey.parse("agent:a:tg:bot:group:123")
      assert %{peer_kind: :channel} = SessionKey.parse("agent:a:tg:bot:channel:123")

      # Invalid peer kinds should fail
      assert {:error, :invalid_peer_kind} = SessionKey.parse("agent:a:tg:bot:invalid:123")
      assert {:error, :invalid_peer_kind} = SessionKey.parse("agent:a:tg:bot:unknown_type:123")
    end
  end

  describe "allowed_peer_kinds/0" do
    test "returns list of allowed peer_kind strings" do
      allowed = SessionKey.allowed_peer_kinds()
      assert is_list(allowed)
      assert "dm" in allowed
      assert "group" in allowed
      assert "channel" in allowed
    end
  end

  describe "roundtrip" do
    test "main key roundtrips" do
      original = SessionKey.main("test-agent")
      parsed = SessionKey.parse(original)
      assert parsed.agent_id == "test-agent"
      assert parsed.kind == :main
    end

    test "channel peer key roundtrips" do
      original =
        SessionKey.channel_peer(%{
          agent_id: "test",
          channel_id: "tg",
          account_id: "bot",
          peer_kind: :dm,
          peer_id: "123"
        })

      parsed = SessionKey.parse(original)
      assert parsed.agent_id == "test"
      assert parsed.channel_id == "tg"
      assert parsed.peer_id == "123"
    end
  end

  describe "valid?/1" do
    test "returns true for valid keys" do
      assert SessionKey.valid?("agent:foo:main")
      assert SessionKey.valid?("agent:foo:telegram:bot:dm:123")
      assert SessionKey.valid?("agent:foo:telegram:bot:dm:123:sub:1")
    end

    test "returns false for invalid keys" do
      refute SessionKey.valid?("invalid")
      refute SessionKey.valid?("")
    end
  end

  describe "agent_id/1" do
    test "extracts agent ID" do
      assert SessionKey.agent_id("agent:my-agent:main") == "my-agent"
      assert SessionKey.agent_id("agent:other:telegram:bot:dm:123") == "other"
    end

    test "returns nil for invalid key" do
      assert SessionKey.agent_id("invalid") == nil
    end
  end

  describe "main?/1 and channel_peer?/1" do
    test "main? returns true for main keys" do
      assert SessionKey.main?("agent:foo:main")
      refute SessionKey.main?("agent:foo:telegram:bot:dm:123")
    end

    test "channel_peer? returns true for channel peer keys" do
      assert SessionKey.channel_peer?("agent:foo:telegram:bot:dm:123")
      refute SessionKey.channel_peer?("agent:foo:main")
    end
  end
end
