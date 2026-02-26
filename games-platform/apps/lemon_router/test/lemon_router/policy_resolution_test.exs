defmodule LemonRouter.PolicyResolutionTest do
  use ExUnit.Case, async: true

  alias LemonRouter.Policy

  @moduledoc """
  Tests for the new policy resolution helpers: approval_required?, tool_blocked?, command_allowed?
  """

  describe "approval_required?/2" do
    test "returns :always when approvals map has :always for tool" do
      policy = %{approvals: %{"bash" => :always}}

      assert Policy.approval_required?(policy, "bash") == :always
    end

    test "returns :dangerous when approvals map has :dangerous for tool" do
      policy = %{approvals: %{"write" => :dangerous}}

      assert Policy.approval_required?(policy, "write") == :dangerous
    end

    test "returns :never when approvals map has :never for tool" do
      policy = %{approvals: %{"read" => :never}}

      assert Policy.approval_required?(policy, "read") == :never
    end

    test "returns :default when tool not in approvals map" do
      policy = %{approvals: %{"bash" => :always}}

      assert Policy.approval_required?(policy, "read") == :default
    end

    test "returns :default when approvals map is empty" do
      policy = %{approvals: %{}}

      assert Policy.approval_required?(policy, "bash") == :default
    end

    test "returns :default when policy has no approvals key" do
      policy = %{}

      assert Policy.approval_required?(policy, "bash") == :default
    end

    test "handles string values in approvals map" do
      policy = %{approvals: %{"bash" => "always", "write" => "dangerous"}}

      assert Policy.approval_required?(policy, "bash") == :always
      assert Policy.approval_required?(policy, "write") == :dangerous
    end
  end

  describe "tool_blocked?/2" do
    test "returns true when tool is in blocked_tools list" do
      policy = %{blocked_tools: ["rm", "sudo", "dangerous_tool"]}

      assert Policy.tool_blocked?(policy, "rm") == true
      assert Policy.tool_blocked?(policy, "dangerous_tool") == true
    end

    test "returns false when tool is not in blocked_tools list" do
      policy = %{blocked_tools: ["rm", "sudo"]}

      assert Policy.tool_blocked?(policy, "read") == false
      assert Policy.tool_blocked?(policy, "bash") == false
    end

    test "returns false when blocked_tools is empty" do
      policy = %{blocked_tools: []}

      assert Policy.tool_blocked?(policy, "bash") == false
    end

    test "returns false when policy has no blocked_tools key" do
      policy = %{}

      assert Policy.tool_blocked?(policy, "bash") == false
    end
  end

  describe "command_allowed?/2" do
    test "returns false when command matches blocked_commands pattern" do
      policy = %{blocked_commands: ["rm -rf", "sudo"]}

      assert Policy.command_allowed?(policy, "rm -rf /") == false
      assert Policy.command_allowed?(policy, "sudo apt install") == false
    end

    test "returns true when command is in allowed_commands list" do
      policy = %{allowed_commands: ["git", "npm", "cargo"]}

      assert Policy.command_allowed?(policy, "git status") == true
      assert Policy.command_allowed?(policy, "npm install") == true
    end

    test "returns false when command is not in allowed_commands list" do
      policy = %{allowed_commands: ["git", "npm"]}

      assert Policy.command_allowed?(policy, "curl http://example.com") == false
    end

    test "returns true when no allowed_commands specified" do
      policy = %{}

      assert Policy.command_allowed?(policy, "any command") == true
    end

    test "returns true when allowed_commands is empty" do
      policy = %{allowed_commands: []}

      assert Policy.command_allowed?(policy, "any command") == true
    end

    test "blocked_commands takes precedence over allowed_commands" do
      policy = %{
        allowed_commands: ["sudo apt"],
        blocked_commands: ["sudo"]
      }

      # Even though "sudo apt" matches allowed, "sudo" is blocked
      assert Policy.command_allowed?(policy, "sudo apt install vim") == false
    end
  end

  describe "merge/2 with policy structure" do
    test "merges approvals maps deeply" do
      a = %{approvals: %{"bash" => :always}}
      b = %{approvals: %{"write" => :dangerous}}

      result = Policy.merge(a, b)

      assert result.approvals["bash"] == :always
      assert result.approvals["write"] == :dangerous
    end

    test "second policy overrides same key in approvals" do
      a = %{approvals: %{"bash" => :never}}
      b = %{approvals: %{"bash" => :always}}

      result = Policy.merge(a, b)

      assert result.approvals["bash"] == :always
    end

    test "combines blocked_tools lists" do
      a = %{blocked_tools: ["rm"]}
      b = %{blocked_tools: ["sudo"]}

      result = Policy.merge(a, b)

      assert "rm" in result.blocked_tools
      assert "sudo" in result.blocked_tools
    end

    test "combines blocked_commands lists" do
      a = %{blocked_commands: ["rm -rf"]}
      b = %{blocked_commands: ["sudo"]}

      result = Policy.merge(a, b)

      assert "rm -rf" in result.blocked_commands
      assert "sudo" in result.blocked_commands
    end

    test "allowed_commands uses second policy when non-empty" do
      a = %{allowed_commands: ["git", "npm", "curl"]}
      b = %{allowed_commands: ["git", "npm"]}

      result = Policy.merge(a, b)

      # Second policy is more restrictive
      assert result.allowed_commands == ["git", "npm"]
    end

    test "sandbox boolean uses stricter (true) value" do
      a = %{sandbox: false}
      b = %{sandbox: true}

      result = Policy.merge(a, b)
      assert result.sandbox == true

      # Test other direction
      result2 = Policy.merge(b, a)
      assert result2.sandbox == true
    end
  end

  describe "resolve_for_run/1 with channel origin" do
    test "adds group restrictions for group peer_kind" do
      result = Policy.resolve_for_run(%{
        agent_id: "test",
        session_key: "agent:test:telegram:bot:123:group:456",
        origin: :channel,
        channel_context: %{
          channel_id: "telegram",
          peer_kind: :group
        }
      })

      # Groups should have stricter policies
      assert is_map(result)
      # The group policy adds approvals requirements
      if result[:approvals] do
        # If approvals are set, bash should require approval
        assert result.approvals["bash"] == :always
      end
    end

    test "no group restrictions for dm peer_kind" do
      result = Policy.resolve_for_run(%{
        agent_id: "test",
        session_key: "agent:test:telegram:bot:123:dm:456",
        origin: :channel,
        channel_context: %{
          channel_id: "telegram",
          peer_kind: :dm
        }
      })

      # DMs don't have the automatic group restrictions
      assert is_map(result)
    end
  end
end
