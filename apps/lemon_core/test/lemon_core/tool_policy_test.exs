defmodule LemonCore.ToolPolicyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

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
    assert {:ok, parsed} = ToolPolicy.parse(%{profile: :safe_mode, deny: []})
    refute ToolPolicy.allowed?(parsed, "eval")
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
    assert ToolPolicy.intersect(nil, nil) == %{}
  end

  test "normalization rejects malformed policies without an alternate permissive path" do
    for policy <- [
          nil,
          [],
          %{allow: fn -> :all end},
          %{profile: :unknown},
          %{approvals: %{"bash" => :unsupported}},
          %{deny: ["bad\0tool"]},
          %{deny: ["bad tool"]},
          %{deny: [nil]},
          %{deny: "bash"},
          %{files: true},
          %{allow: [1]},
          %{"allow" => :all, allow: []},
          %{approvals: %{"read" => :always, read: :never}},
          %{sandbox: "false"},
          %{max_file_size: 0}
        ] do
      assert {:error, {:invalid_field, :tool_policy}} = ToolPolicy.normalize(policy)

      unless is_nil(policy),
        do: refute(ToolPolicy.allowed?(ToolPolicy.intersect(%{}, policy), "read"))
    end

    assert {:ok, %{"allow" => "all", "profile" => "custom"}} =
             ToolPolicy.normalize(%{allow: :all, profile: :custom})

    assert {:ok, %{"approvals" => %{"bash" => "dangerous"}}} =
             ToolPolicy.normalize(%{approvals: %{"bash" => :dangerous}})
  end

  test "native admission projections retain sparse shape and profile metadata" do
    original = %{"profile" => "full_access", "allow" => "all", "deny" => ["bash"]}
    assert {:ok, ^original} = ToolPolicy.normalize(original)
    assert {:ok, expanded} = original |> ToolPolicy.expand() |> ToolPolicy.normalize()
    assert {:ok, ^expanded} = original |> ToolPolicy.intersect(nil) |> ToolPolicy.normalize()
    assert {:ok, %{}} = ToolPolicy.normalize(%{})
  end

  test "current presets retain dangerous kernels, language tooling and delegation floors" do
    for profile <- [:safe_mode, :subagent_restricted],
        tool <- ~w(eval debug lsp lsp_diagnostics ast_grep remember task agent goal kanban cron) do
      refute ToolPolicy.allowed?(%{profile: profile, deny: []}, tool)
    end

    for tool <- ~w(task agent goal kanban cron) do
      refute ToolPolicy.allowed?(ToolPolicy.from_profile(:leaf_worker), tool)
    end

    assert ToolPolicy.allowed?(ToolPolicy.from_profile(:read_only), "recall")
    assert ToolPolicy.allowed?(ToolPolicy.from_profile(:minimal_core), "eval")
  end

  test "command patterns, sandbox and file limits intersect without tool-name coercion" do
    parent =
      ToolPolicy.custom(
        allowed_commands: ["git status", "mix test"],
        blocked_commands: ["rm -rf"],
        max_file_size: 10,
        sandbox: true,
        approvals: %{"bash" => :dangerous}
      )

    requested =
      ToolPolicy.custom(
        allowed_commands: ["git status", "sudo apt"],
        blocked_commands: ["sudo apt"],
        max_file_size: 20,
        sandbox: false,
        approvals: %{"bash" => :never}
      )

    assert {:ok, restricted} = ToolPolicy.restrict(parent, requested)
    assert restricted.allowed_commands == ["git status"]
    assert restricted.blocked_commands == ["rm -rf", "sudo apt"]
    assert restricted.max_file_size == 10
    assert restricted.sandbox
    assert ToolPolicy.approval_mode(restricted, "bash") == :dangerous
    assert ToolPolicy.subset?(restricted, parent)
    assert ToolPolicy.subset?(restricted, requested)
    refute ToolPolicy.subset?(requested, parent)
    assert {:ok, ^restricted} = restricted |> ToolPolicy.to_map() |> ToolPolicy.parse()
    assert {:error, _} = ToolPolicy.parse(%{blocked_commands: ["rm\n-rf"]})
  end

  test "validation cannot trust malformed defaults or forged structs" do
    invalid = %{ToolPolicy.from_profile(:full_access) | allow: nil}
    assert {:error, _} = ToolPolicy.validate(invalid)
    assert {:error, _} = ToolPolicy.resolve(nil, invalid)
    assert {:error, _} = ToolPolicy.resolve(%{}, invalid)
    assert {:error, _} = ToolPolicy.validate(Map.delete(invalid, :allow))
    assert {:error, _} = ToolPolicy.parse(%{{:unexpected, :key} => true})
    assert {:error, _} = ToolPolicy.parse(%{allow: [<<255>>]})
    refute ToolPolicy.subset?(invalid, ToolPolicy.from_profile(:full_access))
  end

  test "configured malformed policy denies instead of becoming an absent default" do
    assert LemonCore.Config.parse_tool_policy(nil) == nil

    for policy <- [%{allow: 1}, false, %{profile: :unknown}, []] do
      refute policy |> LemonCore.Config.parse_tool_policy() |> ToolPolicy.allowed?("read")
    end

    assert LemonCore.RunRequest.new(tool_policy: false).tool_policy == false
    assert LemonCore.RunRequest.new(execution_context: false).execution_context == false
  end

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

  property "restriction never authorizes a tool denied by either input" do
    tools = ["read", "write", "bash", "task", "agent", "webfetch"]
    allow_gen = one_of([constant(:all), list_of(member_of(tools), uniq: true)])
    deny_gen = list_of(member_of(tools), uniq: true)

    check all(
            parent_allow <- allow_gen,
            parent_deny <- deny_gen,
            requested_allow <- allow_gen,
            requested_deny <- deny_gen
          ) do
      parent = ToolPolicy.custom(allow: parent_allow, deny: parent_deny)
      requested = ToolPolicy.custom(allow: requested_allow, deny: requested_deny)
      assert {:ok, restricted} = ToolPolicy.restrict(parent, requested)

      for tool <- tools, ToolPolicy.allowed?(restricted, tool) do
        assert ToolPolicy.allowed?(parent, tool)
        assert ToolPolicy.allowed?(requested, tool)
      end
    end
  end
end
