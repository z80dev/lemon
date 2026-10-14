defmodule LemonCore.ToolPolicyTest do
  use ExUnit.Case, async: true

  alias LemonCore.ToolPolicy

  test "native presets remain ceilings even when explicit grants claim full access" do
    policy =
      ToolPolicy.intersect(
        %{"profile" => "read_only", "allow" => "all"},
        %{profile: :full_access, allow: :all, deny: [], require_approval: []}
      )

    assert "read" in policy.allow
    refute "bash" in policy.allow
    assert ToolPolicy.intersect(policy, %{allow: []}).allow == []
  end

  test "denials and approval gates compose restrictively across JSON and native maps" do
    floor = %{
      "allow" => ["read", "write"],
      "deny" => ["bash"],
      "blocked_tools" => ["cron"],
      "require_approval" => ["write"],
      "approvals" => %{"read" => "always", "write" => "always"}
    }

    caller = %{
      allow: ["bash", "read"],
      deny: [],
      blocked_tools: [],
      require_approval: [],
      approvals: %{"read" => :never, "write" => :never}
    }

    policy = ToolPolicy.intersect(floor, caller)
    assert policy.allow == ["read"]
    assert policy.deny == ["bash"]
    assert policy.blocked_tools == ["cron"]
    assert policy.require_approval == ["write"]
    assert policy.approvals == %{"read" => :always, "write" => :always}
    assert ToolPolicy.expand(%{}) == %{}
  end

  test "normalization rejects non-JSON policy values and unrecognized native fields" do
    for policy <- [
          nil,
          [],
          %{allow: fn -> :all end},
          %{profile: :unknown},
          %{approvals: %{"bash" => :dangerous}},
          %{deny: ["bad\0tool"]},
          %{files: true},
          %{allow: [1]}
        ] do
      assert {:error, {:invalid_field, :tool_policy}} = ToolPolicy.normalize(policy)
    end

    assert {:ok, %{"allow" => "all", "profile" => "custom"}} =
             ToolPolicy.normalize(%{allow: :all, profile: :custom})
  end
end
