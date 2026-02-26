defmodule LemonRouter.PolicyTest do
  use ExUnit.Case, async: true

  alias LemonRouter.Policy
  alias CodingAgent.ToolPolicy

  describe "merge/2" do
    test "returns other policy when one is nil" do
      policy = %{foo: "bar"}
      assert Policy.merge(nil, policy) == policy
      assert Policy.merge(policy, nil) == policy
    end

    test "returns empty map when both are nil" do
      assert Policy.merge(nil, nil) == %{}
    end

    test "second policy takes precedence for simple values" do
      a = %{key: "value_a", other: "stays"}
      b = %{key: "value_b"}

      result = Policy.merge(a, b)
      assert result[:key] == "value_b"
      assert result[:other] == "stays"
    end

    test "deep merges nested maps" do
      a = %{nested: %{a: 1, b: 2}}
      b = %{nested: %{b: 3, c: 4}}

      result = Policy.merge(a, b)
      assert result[:nested] == %{a: 1, b: 3, c: 4}
    end

    test "uses more restrictive allowed lists when both present" do
      a = %{allowed: ["read", "write"]}
      b = %{allowed: ["exec"]}

      result = Policy.merge(a, b)
      assert Enum.sort(result[:allowed]) == ["exec"]
    end

    test "concatenates blocked lists with dedupe" do
      a = %{blocked_tools: ["read", "write"]}
      b = %{blocked_tools: ["write", "exec"]}

      result = Policy.merge(a, b)
      assert Enum.sort(result[:blocked_tools]) == ["exec", "read", "write"]
    end
  end

  describe "resolve_for_run/1" do
    test "returns empty map for basic params" do
      result = Policy.resolve_for_run(%{
        agent_id: "test",
        session_key: "agent:test:main",
        origin: :control_plane
      })

      assert is_map(result)
    end

    test "returns empty map when no special policies are configured" do
      result = Policy.resolve_for_run(%{
        agent_id: "default-agent",
        session_key: "agent:default-agent:main",
        origin: :control_plane
      })

      # Should return an empty map, not nil
      assert result == %{}
    end

    test "returns empty map for channel origin without channel context" do
      result = Policy.resolve_for_run(%{
        agent_id: "channel-agent",
        session_key: "agent:channel-agent:telegram:bot:dm:456",
        origin: :channel,
        channel_context: nil
      })

      assert is_map(result)
    end
  end

  describe "ToolPolicy.requires_approval?/2 with router default policies" do
    # Tests that ToolPolicy.requires_approval?/2 handles empty policies from
    # LemonRouter.Policy.resolve_for_run/1 without crashing.

    test "handles empty policy map without crashing" do
      # This is what resolve_for_run returns by default
      empty_policy = %{}

      # Should return false, not crash
      assert ToolPolicy.requires_approval?(empty_policy, "bash") == false
      assert ToolPolicy.requires_approval?(empty_policy, "write") == false
      assert ToolPolicy.requires_approval?(empty_policy, "edit") == false
    end

    test "handles nil policy without crashing" do
      assert ToolPolicy.requires_approval?(nil, "bash") == false
    end

    test "handles policy with empty require_approval list" do
      policy = %{require_approval: []}

      assert ToolPolicy.requires_approval?(policy, "bash") == false
      assert ToolPolicy.requires_approval?(policy, "write") == false
    end

    test "handles policy with nil require_approval" do
      policy = %{require_approval: nil}

      assert ToolPolicy.requires_approval?(policy, "bash") == false
    end

    test "handles policy with other keys but no require_approval" do
      policy = %{allow: :all, deny: []}

      assert ToolPolicy.requires_approval?(policy, "bash") == false
    end

    test "properly detects tools in require_approval list" do
      policy = %{require_approval: ["bash", "write"]}

      assert ToolPolicy.requires_approval?(policy, "bash") == true
      assert ToolPolicy.requires_approval?(policy, "write") == true
      assert ToolPolicy.requires_approval?(policy, "read") == false
    end
  end

  describe "integration: router policy to tool wrapping" do
    # Tests the full flow from router policy resolution to tool approval wrapping.

    test "empty router policy does not wrap any tools" do
      # Simulate what happens in ToolRegistry
      router_policy = Policy.resolve_for_run(%{
        agent_id: "test",
        session_key: "agent:test:main",
        origin: :control_plane
      })

      # Empty policy means no tools require approval
      assert ToolPolicy.requires_approval?(router_policy, "bash") == false
      assert ToolPolicy.requires_approval?(router_policy, "write") == false
      assert ToolPolicy.requires_approval?(router_policy, "edit") == false
      assert ToolPolicy.requires_approval?(router_policy, "read") == false
    end

    test "router policy can be merged with a restrictive policy" do
      router_policy = Policy.resolve_for_run(%{
        agent_id: "test",
        session_key: "agent:test:main",
        origin: :control_plane
      })

      restrictive_policy = %{require_approval: ["bash", "write"]}

      merged = Policy.merge(router_policy, restrictive_policy)

      assert ToolPolicy.requires_approval?(merged, "bash") == true
      assert ToolPolicy.requires_approval?(merged, "write") == true
      assert ToolPolicy.requires_approval?(merged, "read") == false
    end
  end
end
