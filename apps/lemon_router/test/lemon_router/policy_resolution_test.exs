defmodule LemonRouter.PolicyResolutionTest do
  use ExUnit.Case, async: true

  alias LemonRouter.Policy

  @moduledoc """
  Tests for the new policy resolution helpers: approval_required?, tool_blocked?
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

  describe "merge/2 with policy structure" do
    test "merges approvals maps deeply" do
      a = %{approvals: %{"bash" => :always}}
      b = %{approvals: %{"write" => :dangerous}}

      result = Policy.merge(a, b)

      assert result.approvals["bash"] == :always
      assert result.approvals["write"] == :dangerous
    end

    test "approval requirements cannot be weakened in either order" do
      a = %{approvals: %{"bash" => :never}}
      b = %{approvals: %{"bash" => :always}}

      result = Policy.merge(a, b)

      assert result.approvals["bash"] == :always
      assert Policy.merge(b, a).approvals["bash"] == :always
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

    test "allowed_commands intersect rather than taking the second policy" do
      a = %{allowed_commands: ["git", "npm", "curl"]}
      b = %{allowed_commands: ["git", "npm", "cargo"]}

      result = Policy.merge(a, b)

      assert result.allowed_commands == ["git", "npm"]
      assert Policy.merge(b, a).allowed_commands == ["git", "npm"]
      assert Policy.merge(a, %{allowed_commands: []}).allowed_commands == []
    end

    test "removed sandbox input does not alter merged authority" do
      a = %{allow: ["read"], sandbox: false}
      b = %{deny: ["bash"], sandbox: true}

      assert Policy.merge(a, b) == Policy.merge(%{allow: ["read"]}, %{deny: ["bash"]})
      refute Map.has_key?(Policy.merge(a, b), :sandbox)
    end
  end

  describe "resolve_for_run/1 with channel origin" do
    test "requires approval for every mutating tool in groups" do
      result =
        Policy.resolve_for_run(%{
          agent_id: "test",
          session_key: "agent:test:telegram:bot:123:group:456",
          origin: :channel,
          channel_context: %{
            channel_id: "telegram",
            peer_kind: :group
          }
        })

      for tool <- ~w(bash write edit patch hashline_edit) do
        assert Policy.approval_required?(result, tool) == :always
      end

      assert Policy.approval_required?(result, "read") == :default
    end

    test "no group restrictions for dm peer_kind" do
      result =
        Policy.resolve_for_run(%{
          agent_id: "test",
          session_key: "agent:test:telegram:bot:123:dm:456",
          origin: :channel,
          channel_context: %{
            channel_id: "telegram",
            peer_kind: :dm
          }
        })

      assert Policy.approval_required?(result, "bash") == :default
    end
  end
end
