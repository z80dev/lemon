defmodule LemonRouter.PolicyTest do
  use ExUnit.Case, async: true

  alias CodingAgent.ToolPolicy
  alias LemonCore.PolicyStore
  alias LemonRouter.Policy

  test "session PolicyStore mode survives legacy and nested policy projections" do
    key = "approval-mode-#{System.unique_integer([:positive])}"
    on_exit(fn -> PolicyStore.delete_session(key) end)

    for row <- [%{approval_mode: :write}, %{"tool_policy" => %{"approval_mode" => "write"}}] do
      assert :ok = PolicyStore.put_session(key, row)
      assert {:ok, policy} = Policy.resolve_validated_for_run(%{session_key: key})
      assert policy.approval_mode == :write
      refute ToolPolicy.requires_approval?(policy, "write")
      assert ToolPolicy.requires_approval?(policy, "bash")
    end
  end

  describe "merge/2" do
    test "validates the other policy when one is absent" do
      policy = %{allow: ["read"], blocked_tools: ["bash"]}
      merged = Policy.merge(nil, policy)

      assert merged.allow == ["read"]
      assert merged.blocked_tools == ["bash"]
    end

    test "uses explicit full access when all policy layers are absent" do
      merged = Policy.merge(nil, nil)
      assert merged.allow == :all
      assert merged.blocked_tools == []
    end

    test "invalid policy fails closed" do
      merged = Policy.merge(%{allow: ["read"]}, %{allow: 42})

      assert merged.allow == []
      refute ToolPolicy.allowed?(merged, "read")
    end

    test "uses the stricter approval mode" do
      a = %{approvals: %{"bash" => :always}}
      b = %{approvals: %{"bash" => :never}}

      result = Policy.merge(a, b)
      assert result.approvals == %{"bash" => :always}
    end

    test "intersects allow lists" do
      a = %{allow: ["read", "write"]}
      b = %{allow: ["write", "exec"]}

      result = Policy.merge(a, b)
      assert result.allow == ["write"]
    end

    test "concatenates blocked lists with dedupe" do
      a = %{blocked_tools: ["read", "write"]}
      b = %{blocked_tools: ["write", "exec"]}

      result = Policy.merge(a, b)
      assert Enum.sort(result.blocked_tools) == ["exec", "read", "write"]
    end

    test "native allow and approval floors intersect string and atom keyed overrides" do
      floor = %{
        "allow" => ["read", "write"],
        "deny" => ["bash"],
        "require_approval" => ["write"],
        "approvals" => %{"write" => "always"}
      }

      result =
        Policy.merge(floor, %{
          allow: :all,
          deny: [],
          require_approval: [],
          approvals: %{"write" => :never}
        })

      assert result.allow == ["read", "write"]
      assert result.deny == ["bash"]
      assert result.require_approval == ["write"]
      assert result.approvals["write"] == :always
      assert Policy.merge(result, %{allow: []}).allow == []
    end
  end

  describe "resolve_for_run/1" do
    test "returns full access for basic params" do
      result =
        Policy.resolve_for_run(%{
          agent_id: "test",
          session_key: "agent:test:main",
          origin: :control_plane
        })

      assert result.allow == :all
      assert result.blocked_tools == []
    end

    test "returns empty map when no special policies are configured" do
      result =
        Policy.resolve_for_run(%{
          agent_id: "default-agent",
          session_key: "agent:default-agent:main",
          origin: :control_plane
        })

      assert result.allow == :all
      assert result.blocked_tools == []
    end

    test "returns full access for channel origin without channel context" do
      result =
        Policy.resolve_for_run(%{
          agent_id: "channel-agent",
          session_key: "agent:channel-agent:telegram:bot:dm:456",
          origin: :channel,
          channel_context: nil
        })

      assert result.allow == :all
      assert result.blocked_tools == []
    end
  end

  describe "persisted session policies" do
    test "preserves conflicting atom and string fields for canonical rejection" do
      session_key = "agent:policy-conflict:#{System.unique_integer([:positive])}"
      on_exit(fn -> PolicyStore.delete_session(session_key) end)

      assert :ok =
               PolicyStore.put_session(session_key, %{
                 tool_policy: %{"allow" => ["bash"], allow: ["read"]}
               })

      params = %{
        agent_id: "policy-conflict",
        session_key: session_key,
        origin: :control_plane
      }

      assert {:error, {:conflicting_policy_key, :allow}} =
               Policy.resolve_validated_for_run(params)

      refute ToolPolicy.allowed?(Policy.resolve_for_run(params), "read")
      refute ToolPolicy.allowed?(Policy.resolve_for_run(params), "bash")
    end

    test "treats a legacy stored empty command allowlist as deny-all" do
      session_key = "agent:empty-command-policy:#{System.unique_integer([:positive])}"
      on_exit(fn -> PolicyStore.delete_session(session_key) end)

      assert :ok =
               PolicyStore.put_session(session_key, %{
                 tool_policy: %{"allowed_commands" => []}
               })

      assert {:ok, policy} =
               Policy.resolve_validated_for_run(%{
                 agent_id: "empty-command-policy",
                 session_key: session_key,
                 origin: :control_plane
               })

      assert policy.allowed_commands == []
      refute Policy.command_allowed?(policy, "git status")
    end

    test "legacy and nested session policy floors intersect without routing fields" do
      session_key = "agent:layered-policy:#{System.unique_integer([:positive])}"
      on_exit(fn -> PolicyStore.delete_session(session_key) end)

      assert :ok =
               PolicyStore.put_session(session_key, %{
                 model: "retained-model",
                 thinking_level: "high",
                 allow: ["read", "write"],
                 approvals: %{"read" => :always},
                 tool_policy: %{
                   "allow" => ["read", "bash"],
                   "approvals" => %{"read" => "never"},
                   "deny" => ["write"]
                 }
               })

      assert {:ok, policy} =
               Policy.resolve_validated_for_run(%{
                 agent_id: "layered-policy",
                 session_key: session_key,
                 origin: :control_plane
               })

      assert policy.allow == ["read"]
      assert policy.approvals["read"] == :always
      assert policy.deny == ["write"]
      refute Map.has_key?(policy, :model)
      refute Map.has_key?(policy, :thinking_level)
    end

    test "malformed stored nested policy rejects admission" do
      session_key = "agent:malformed-policy:#{System.unique_integer([:positive])}"
      on_exit(fn -> PolicyStore.delete_session(session_key) end)
      assert :ok = PolicyStore.put_session(session_key, %{tool_policy: 42})

      assert {:error, :invalid_tool_policy} =
               Policy.resolve_validated_for_run(%{
                 agent_id: "malformed-policy",
                 session_key: session_key,
                 origin: :control_plane
               })
    end

    test "conflicting nested policy aliases reject admission" do
      session_key = "agent:nested-conflict:#{System.unique_integer([:positive])}"
      on_exit(fn -> PolicyStore.delete_session(session_key) end)

      assert :ok =
               PolicyStore.put_session(session_key, %{
                 "tool_policy" => %{"allow" => ["bash"]},
                 tool_policy: %{allow: ["read"]}
               })

      assert {:error, {:conflicting_session_policy_key, :tool_policy}} =
               Policy.resolve_validated_for_run(%{
                 agent_id: "nested-conflict",
                 session_key: session_key,
                 origin: :control_plane
               })
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
      assert ToolPolicy.requires_approval?(nil, "bash") == true
    end

    test "handles policy with empty require_approval list" do
      policy = %{require_approval: []}

      assert ToolPolicy.requires_approval?(policy, "bash") == false
      assert ToolPolicy.requires_approval?(policy, "write") == false
    end

    test "malformed nil require_approval fails closed" do
      policy = %{require_approval: nil}

      assert ToolPolicy.requires_approval?(policy, "bash") == true
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
      router_policy =
        Policy.resolve_for_run(%{
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
      router_policy =
        Policy.resolve_for_run(%{
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

    test "a sessions.patch tool policy reaches the run policy" do
      session_key = "agent:policy_patch_#{System.unique_integer([:positive])}:main"
      on_exit(fn -> LemonCore.PolicyStore.delete_session(session_key) end)

      # The row `sessions.patch` writes: routing settings beside a wire-shaped tool policy.
      :ok =
        LemonCore.PolicyStore.put_session(session_key, %{
          model: "openai:gpt-4o-mini",
          thinking_level: "low",
          tool_policy: %{"profile" => "full_access", "approvals" => %{"bash" => "always"}}
        })

      policy =
        Policy.resolve_for_run(%{
          agent_id: "test",
          session_key: session_key,
          origin: :control_plane
        })

      assert ToolPolicy.requires_approval?(policy, "bash") == true
      assert ToolPolicy.requires_approval?(policy, "read") == false
      refute Map.has_key?(policy, :model)
      refute Map.has_key?(policy, :thinking_level)
      refute Map.has_key?(policy, :tool_policy)
    end

    test "legacy session rows with top-level policy keys keep working" do
      session_key = "agent:policy_legacy_#{System.unique_integer([:positive])}:main"
      on_exit(fn -> LemonCore.PolicyStore.delete_session(session_key) end)
      :ok = LemonCore.PolicyStore.put_session(session_key, %{approvals: %{"write" => :always}})

      policy =
        Policy.resolve_for_run(%{
          agent_id: "test",
          session_key: session_key,
          origin: :control_plane
        })

      assert ToolPolicy.requires_approval?(policy, "write") == true
    end
  end
end
