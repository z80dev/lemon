defmodule LemonCore.ToolPolicyTest do
  use ExUnit.Case, async: true

  alias LemonCore.ToolPolicy

  describe "parse/1" do
    test "accepts equivalent atom- and string-keyed policies" do
      atom_policy = %{
        allow: [:read, "grep"],
        deny: [:write],
        blocked_tools: ["bash"],
        require_approval: [:edit],
        approvals: %{patch: :always, read: :never}
      }

      string_policy = %{
        "allow" => ["read", "grep"],
        "deny" => ["write"],
        "blocked_tools" => ["bash"],
        "require_approval" => ["edit"],
        "approvals" => %{"patch" => "always", "read" => "never"}
      }

      assert {:ok, left} = ToolPolicy.parse(atom_policy)
      assert {:ok, right} = ToolPolicy.parse(string_policy)
      assert ToolPolicy.to_map(left) == ToolPolicy.to_map(right)
    end

    test "distinguishes absent from malformed supplied policy" do
      assert {:error, :policy_absent} = ToolPolicy.parse(nil)
      assert {:error, :invalid_tool_policy} = ToolPolicy.parse(["read"])

      assert {:error, {:invalid_policy_field, :allow}} =
               ToolPolicy.parse(%{"allow" => 123})
    end

    test "rejects unknown profiles and conflicting key forms" do
      assert {:error, {:unknown_policy_profile, "root"}} =
               ToolPolicy.parse(%{"profile" => "root"})

      assert {:error, {:conflicting_policy_key, :allow}} =
               ToolPolicy.parse(%{"allow" => ["write"], allow: ["read"]})
    end

    test "unknown profile constructors deny instead of granting full access" do
      policy = ToolPolicy.from_profile(:unknown)
      refute ToolPolicy.allowed?(policy, "read")
      refute ToolPolicy.allowed?(policy, "bash")
    end

    test "invalid input fails closed in authorization helpers" do
      refute ToolPolicy.allowed?(%{"allow" => 1}, "bash")
      assert ToolPolicy.requires_approval?(%{"approvals" => []}, "bash")
      assert ToolPolicy.denial_reason(%{"allow" => 1}, "bash") == "Tool policy is invalid"
    end

    test "a profile-only policy receives the profile's actual restrictions" do
      assert {:ok, policy} = ToolPolicy.parse(%{"profile" => "read_only"})
      assert ToolPolicy.allowed?(policy, "read")
      refute ToolPolicy.allowed?(policy, "write")
    end
  end

  describe "restrict/2" do
    test "cannot remove parent denials or approval requirements" do
      parent =
        ToolPolicy.custom(
          allow: ["read", "write", "bash"],
          deny: ["bash"],
          require_approval: ["write"],
          approvals: %{"read" => :always}
        )

      requested =
        ToolPolicy.custom(
          allow: :all,
          deny: [],
          require_approval: [],
          approvals: %{"read" => :never}
        )

      assert {:ok, child} = ToolPolicy.restrict(parent, requested)
      assert ToolPolicy.allowed?(child, "read")
      assert ToolPolicy.allowed?(child, "write")
      refute ToolPolicy.allowed?(child, "bash")
      assert ToolPolicy.requires_approval?(child, "read")
      assert ToolPolicy.requires_approval?(child, "write")
    end

    test "malformed child input is rejected, not treated as an empty override" do
      parent = ToolPolicy.from_profile(:read_only)

      assert {:error, {:invalid_policy_field, :allow}} =
               ToolPolicy.restrict(parent, %{"allow" => %{"unexpected" => true}})
    end
  end
end
