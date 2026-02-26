defmodule LemonCore.SessionKeyTest do
  @moduledoc """
  Tests for the SessionKey module.
  """
  use ExUnit.Case, async: true

  alias LemonCore.SessionKey

  doctest LemonCore.SessionKey

  describe "main/1" do
    test "generates main session key for agent" do
      key = SessionKey.main("my_agent")
      assert key == "agent:my_agent:main"
    end

    test "generates main session key with different agent IDs" do
      assert SessionKey.main("agent_1") == "agent:agent_1:main"
      assert SessionKey.main("test-bot") == "agent:test-bot:main"
      assert SessionKey.main("my.agent.id") == "agent:my.agent.id:main"
    end

    test "generates main session key with special characters in agent ID" do
      assert SessionKey.main("agent_123_test") == "agent:agent_123_test:main"
      assert SessionKey.main("UPPER_CASE") == "agent:UPPER_CASE:main"
    end
  end

  describe "channel_peer/1" do
    test "generates channel peer session key with required fields" do
      opts = %{
        agent_id: "my_agent",
        channel_id: "chan_123",
        account_id: "acc_456",
        peer_kind: :dm,
        peer_id: "peer_789"
      }

      key = SessionKey.channel_peer(opts)
      assert key == "agent:my_agent:chan_123:acc_456:dm:peer_789"
    end

    test "generates channel peer session key with different peer kinds" do
      base_opts = %{
        agent_id: "agent_1",
        channel_id: "channel_1",
        account_id: "account_1",
        peer_id: "peer_1"
      }

      assert SessionKey.channel_peer(Map.put(base_opts, :peer_kind, :dm)) ==
               "agent:agent_1:channel_1:account_1:dm:peer_1"

      assert SessionKey.channel_peer(Map.put(base_opts, :peer_kind, :group)) ==
               "agent:agent_1:channel_1:account_1:group:peer_1"

      assert SessionKey.channel_peer(Map.put(base_opts, :peer_kind, :channel)) ==
               "agent:agent_1:channel_1:account_1:channel:peer_1"

      assert SessionKey.channel_peer(Map.put(base_opts, :peer_kind, :unknown)) ==
               "agent:agent_1:channel_1:account_1:unknown:peer_1"

      assert SessionKey.channel_peer(Map.put(base_opts, :peer_kind, :main)) ==
               "agent:agent_1:channel_1:account_1:main:peer_1"
    end

    test "generates channel peer session key with thread_id" do
      opts = %{
        agent_id: "my_agent",
        channel_id: "chan_123",
        account_id: "acc_456",
        peer_kind: :dm,
        peer_id: "peer_789",
        thread_id: "thread_abc"
      }

      key = SessionKey.channel_peer(opts)
      assert key == "agent:my_agent:chan_123:acc_456:dm:peer_789:thread:thread_abc"
    end

    test "generates channel peer session key with sub_id" do
      opts = %{
        agent_id: "my_agent",
        channel_id: "chan_123",
        account_id: "acc_456",
        peer_kind: :dm,
        peer_id: "peer_789",
        sub_id: "sub_def"
      }

      key = SessionKey.channel_peer(opts)
      assert key == "agent:my_agent:chan_123:acc_456:dm:peer_789:sub:sub_def"
    end

    test "generates channel peer session key with both thread_id and sub_id" do
      opts = %{
        agent_id: "my_agent",
        channel_id: "chan_123",
        account_id: "acc_456",
        peer_kind: :dm,
        peer_id: "peer_789",
        thread_id: "thread_abc",
        sub_id: "sub_def"
      }

      key = SessionKey.channel_peer(opts)

      assert key ==
               "agent:my_agent:chan_123:acc_456:dm:peer_789:thread:thread_abc:sub:sub_def"
    end

    test "generates channel peer session key with special characters in IDs" do
      opts = %{
        agent_id: "agent-123.test",
        channel_id: "channel_123",
        account_id: "account_456",
        peer_kind: :dm,
        peer_id: "peer-789_test"
      }

      key = SessionKey.channel_peer(opts)
      assert key == "agent:agent-123.test:channel_123:account_456:dm:peer-789_test"
    end
  end

  describe "parse/1" do
    test "parses main session key" do
      result = SessionKey.parse("agent:my_agent:main")

      assert result == %{
               agent_id: "my_agent",
               kind: :main,
               channel_id: nil,
               account_id: nil,
               peer_kind: nil,
               peer_id: nil,
               thread_id: nil,
               sub_id: nil
             }
    end

    test "parses main session key with sub_id" do
      result = SessionKey.parse("agent:my_agent:main:sub:cron_123")

      assert result == %{
               agent_id: "my_agent",
               kind: :main,
               channel_id: nil,
               account_id: nil,
               peer_kind: nil,
               peer_id: nil,
               thread_id: nil,
               sub_id: "cron_123"
             }
    end

    test "parses channel peer session key" do
      result = SessionKey.parse("agent:my_agent:chan_123:acc_456:dm:peer_789")

      assert result == %{
               agent_id: "my_agent",
               kind: :channel_peer,
               channel_id: "chan_123",
               account_id: "acc_456",
               peer_kind: :dm,
               peer_id: "peer_789",
               thread_id: nil,
               sub_id: nil
             }
    end

    test "parses channel peer session key with thread_id" do
      result = SessionKey.parse("agent:my_agent:chan_123:acc_456:dm:peer_789:thread:thread_abc")

      assert result == %{
               agent_id: "my_agent",
               kind: :channel_peer,
               channel_id: "chan_123",
               account_id: "acc_456",
               peer_kind: :dm,
               peer_id: "peer_789",
               thread_id: "thread_abc",
               sub_id: nil
             }
    end

    test "parses channel peer session key with sub_id" do
      result = SessionKey.parse("agent:my_agent:chan_123:acc_456:dm:peer_789:sub:sub_def")

      assert result == %{
               agent_id: "my_agent",
               kind: :channel_peer,
               channel_id: "chan_123",
               account_id: "acc_456",
               peer_kind: :dm,
               peer_id: "peer_789",
               thread_id: nil,
               sub_id: "sub_def"
             }
    end

    test "parses channel peer session key with both thread_id and sub_id" do
      result =
        SessionKey.parse(
          "agent:my_agent:chan_123:acc_456:dm:peer_789:thread:thread_abc:sub:sub_def"
        )

      assert result == %{
               agent_id: "my_agent",
               kind: :channel_peer,
               channel_id: "chan_123",
               account_id: "acc_456",
               peer_kind: :dm,
               peer_id: "peer_789",
               thread_id: "thread_abc",
               sub_id: "sub_def"
             }
    end

    test "parses all allowed peer kinds" do
      assert %{peer_kind: :dm} = SessionKey.parse("agent:a:c:acc:dm:p")
      assert %{peer_kind: :group} = SessionKey.parse("agent:a:c:acc:group:p")
      assert %{peer_kind: :channel} = SessionKey.parse("agent:a:c:acc:channel:p")
      assert %{peer_kind: :main} = SessionKey.parse("agent:a:c:acc:main:p")
      assert %{peer_kind: :unknown} = SessionKey.parse("agent:a:c:acc:unknown:p")
    end

    test "returns error for invalid peer kind" do
      result = SessionKey.parse("agent:my_agent:chan_123:acc_456:invalid_kind:peer_789")
      assert result == {:error, :invalid_peer_kind}
    end

    test "returns error for empty string" do
      assert SessionKey.parse("") == {:error, :invalid}
    end

    test "returns error for malformed keys" do
      assert SessionKey.parse("invalid") == {:error, :invalid}
      assert SessionKey.parse("agent") == {:error, :invalid}
      assert SessionKey.parse("agent:only_one") == {:error, :invalid}
      assert SessionKey.parse("agent:id:extra:more") == {:error, :invalid}
      assert SessionKey.parse("agent:id:main:sub") == {:error, :invalid}
    end

    test "returns error for keys with wrong prefix" do
      assert SessionKey.parse("user:my_agent:main") == {:error, :invalid}
      assert SessionKey.parse("bot:my_agent:main") == {:error, :invalid}
    end

    test "returns error for channel peer with missing components" do
      # Missing peer_id
      assert SessionKey.parse("agent:my_agent:chan_123:acc_456:dm") == {:error, :invalid}
      # Missing peer_kind and peer_id
      assert SessionKey.parse("agent:my_agent:chan_123:acc_456") == {:error, :invalid}
    end

    test "returns error for invalid extras format" do
      # Odd number of extra components
      assert SessionKey.parse("agent:a:c:acc:dm:p:thread") == {:error, :invalid}
      # Invalid extra key
      assert SessionKey.parse("agent:a:c:acc:dm:p:invalid:value") == {:error, :invalid}
      # Duplicate thread key
      assert SessionKey.parse("agent:a:c:acc:dm:p:thread:t1:thread:t2") == {:error, :invalid}
      # Duplicate sub key
      assert SessionKey.parse("agent:a:c:acc:dm:p:sub:s1:sub:s2") == {:error, :invalid}
    end

    test "round-trip: parse after generating main key" do
      key = SessionKey.main("test_agent")
      parsed = SessionKey.parse(key)

      assert parsed.agent_id == "test_agent"
      assert parsed.kind == :main
    end

    test "round-trip: parse after generating channel peer key" do
      opts = %{
        agent_id: "test_agent",
        channel_id: "chan_1",
        account_id: "acc_1",
        peer_kind: :dm,
        peer_id: "peer_1",
        thread_id: "thread_1",
        sub_id: "sub_1"
      }

      key = SessionKey.channel_peer(opts)
      parsed = SessionKey.parse(key)

      assert parsed.agent_id == "test_agent"
      assert parsed.kind == :channel_peer
      assert parsed.channel_id == "chan_1"
      assert parsed.account_id == "acc_1"
      assert parsed.peer_kind == :dm
      assert parsed.peer_id == "peer_1"
      assert parsed.thread_id == "thread_1"
      assert parsed.sub_id == "sub_1"
    end
  end

  describe "valid?/1" do
    test "returns true for valid main session key" do
      assert SessionKey.valid?("agent:my_agent:main") == true
      assert SessionKey.valid?("agent:my_agent:main:sub:cron_1") == true
    end

    test "returns true for valid channel peer session key" do
      assert SessionKey.valid?("agent:my_agent:chan_123:acc_456:dm:peer_789") == true
    end

    test "returns true for valid channel peer with extras" do
      assert SessionKey.valid?("agent:a:c:acc:dm:p:thread:t1:sub:s1") == true
    end

    test "returns false for invalid keys" do
      assert SessionKey.valid?("invalid") == false
      assert SessionKey.valid?("") == false
      assert SessionKey.valid?("agent:only") == false
    end

    test "returns false for invalid peer kind" do
      assert SessionKey.valid?("agent:a:c:acc:invalid:p") == false
    end
  end

  describe "allowed_peer_kinds/0" do
    test "returns list of allowed peer kind strings" do
      kinds = SessionKey.allowed_peer_kinds()

      assert is_list(kinds)
      assert "dm" in kinds
      assert "group" in kinds
      assert "channel" in kinds
      assert "main" in kinds
      assert "unknown" in kinds
      assert length(kinds) == 5
    end

    test "returns strings that can be used in session keys" do
      kinds = SessionKey.allowed_peer_kinds()

      for kind <- kinds do
        key = "agent:test:chan:acc:#{kind}:peer"
        assert SessionKey.valid?(key), "Expected #{kind} to be valid"
      end
    end
  end

  describe "agent_id/1" do
    test "extracts agent ID from main session key" do
      assert SessionKey.agent_id("agent:my_agent:main") == "my_agent"
    end

    test "extracts agent ID from channel peer session key" do
      assert SessionKey.agent_id("agent:my_agent:chan_123:acc_456:dm:peer_789") == "my_agent"
    end

    test "extracts agent ID from channel peer with extras" do
      assert SessionKey.agent_id("agent:my_agent:chan:acc:dm:peer:thread:t:sub:s") == "my_agent"
    end

    test "returns nil for invalid keys" do
      assert SessionKey.agent_id("invalid") == nil
      assert SessionKey.agent_id("") == nil
      assert SessionKey.agent_id("agent:only") == nil
    end

    test "returns nil for keys with invalid peer kind" do
      assert SessionKey.agent_id("agent:my_agent:chan:acc:invalid:peer") == nil
    end
  end

  describe "main?/1" do
    test "returns true for main session key" do
      assert SessionKey.main?("agent:my_agent:main") == true
      assert SessionKey.main?("agent:my_agent:main:sub:cron_1") == true
    end

    test "returns false for channel peer session key" do
      assert SessionKey.main?("agent:my_agent:chan_123:acc_456:dm:peer_789") == false
    end

    test "returns false for invalid keys" do
      assert SessionKey.main?("invalid") == false
      assert SessionKey.main?("") == false
    end

    test "returns false for keys with invalid peer kind" do
      assert SessionKey.main?("agent:my_agent:chan:acc:invalid:peer") == false
    end
  end

  describe "channel_peer?/1" do
    test "returns true for channel peer session key" do
      assert SessionKey.channel_peer?("agent:my_agent:chan_123:acc_456:dm:peer_789") == true
    end

    test "returns true for channel peer with extras" do
      assert SessionKey.channel_peer?("agent:a:c:acc:dm:p:thread:t:sub:s") == true
    end

    test "returns false for main session key" do
      assert SessionKey.channel_peer?("agent:my_agent:main") == false
    end

    test "returns false for invalid keys" do
      assert SessionKey.channel_peer?("invalid") == false
      assert SessionKey.channel_peer?("") == false
    end

    test "returns false for keys with invalid peer kind" do
      assert SessionKey.channel_peer?("agent:my_agent:chan:acc:invalid:peer") == false
    end
  end
end
