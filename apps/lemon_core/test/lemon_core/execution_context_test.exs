defmodule LemonCore.ExecutionContextTest do
  use ExUnit.Case, async: true

  alias LemonCore.{ExecutionContext, ToolPolicy}

  @tag :tmp_dir
  test "child authority is the intersection of parent and request", %{tmp_dir: tmp_dir} do
    assert {:ok, parent} =
             ExecutionContext.new(
               run_id: "parent",
               agent_id: "operator",
               cwd: tmp_dir,
               tool_policy:
                 ToolPolicy.custom(
                   allow: ["read", "write", "bash"],
                   deny: ["bash"],
                   require_approval: ["write"]
                 ),
               capabilities: ["read", "write", "bash"],
               limits: %{max_steps: 10, max_tokens: 1_000}
             )

    child_dir = Path.join(tmp_dir, "child")

    assert {:ok, child} =
             ExecutionContext.child(parent,
               run_id: "child",
               cwd: child_dir,
               tool_policy: ToolPolicy.from_profile(:full_access),
               capabilities: ["read", "bash"],
               limits: %{max_steps: 20, max_tokens: 500}
             )

    assert child.parent_run_id == "parent"
    assert child.workspace_scope.root == child_dir
    assert child.capabilities == ["read", "bash"]
    assert ToolPolicy.allowed?(child.tool_policy, "read")
    refute ToolPolicy.allowed?(child.tool_policy, "write")
    refute ToolPolicy.allowed?(child.tool_policy, "bash")
    assert child.limits == %{max_steps: 10, max_tokens: 500}
    assert ExecutionContext.subset?(child, parent)
  end

  @tag :tmp_dir
  test "child workspace cannot escape its parent", %{tmp_dir: tmp_dir} do
    assert {:ok, parent} = ExecutionContext.new(run_id: "parent", cwd: tmp_dir)

    assert {:error, :workspace_scope_escalation} =
             ExecutionContext.child(parent,
               run_id: "child",
               cwd: Path.join(Path.dirname(tmp_dir), "sibling")
             )
  end

  @tag :tmp_dir
  test "read-only workspace mode rejects every classified direct mutation tool", %{
    tmp_dir: tmp_dir
  } do
    assert ExecutionContext.direct_workspace_mutation_tools() == [
             "write",
             "edit",
             "patch",
             "ast_grep",
             "checkpoint",
             "bash",
             "eval",
             "debug",
             "lsp",
             "lsp_diagnostics"
           ]

    for tool <- ExecutionContext.direct_workspace_mutation_tools() do
      assert {:error, :read_only_workspace_policy_mismatch} =
               ExecutionContext.new(
                 run_id: "read-only-#{tool}",
                 workspace_scope: %{root: tmp_dir, mode: :read_only},
                 tool_policy: ToolPolicy.custom(allow: [tool])
               )
    end

    assert {:ok, context} =
             ExecutionContext.new(
               run_id: "read-only-reader",
               workspace_scope: %{root: tmp_dir, mode: :read_only},
               tool_policy: ToolPolicy.custom(allow: ["read"])
             )

    assert context.workspace_scope.mode == :read_only
  end

  @tag :tmp_dir
  test "destination capability restriction preserves identity and cannot widen authority", %{
    tmp_dir: tmp_dir
  } do
    assert {:ok, context} =
             ExecutionContext.new(
               run_id: "remote-run",
               attempt_id: "remote-attempt",
               cwd: tmp_dir,
               tool_policy: ToolPolicy.custom(allow: ["read", "write"]),
               capabilities: ["read", "write"]
             )

    assert {:ok, restricted} =
             ExecutionContext.restrict_capabilities(context, ["read", "bash"])

    assert restricted.run_id == context.run_id
    assert restricted.attempt_id == context.attempt_id
    assert restricted.capabilities == ["read"]
    assert ToolPolicy.allowed?(restricted.tool_policy, "read")
    refute ToolPolicy.allowed?(restricted.tool_policy, "write")
    refute ToolPolicy.allowed?(restricted.tool_policy, "bash")
    assert ExecutionContext.subset?(restricted, context)

    assert {:error, :invalid_capabilities} =
             ExecutionContext.restrict_capabilities(context, %{"read" => true})
  end

  @tag :tmp_dir
  test "versioned named-node representation round trips and rejects tampering", %{
    tmp_dir: tmp_dir
  } do
    assert {:ok, context} =
             ExecutionContext.new(
               run_id: "remote-run",
               attempt_id: "remote-attempt",
               parent_run_id: "parent-run",
               principal: %{type: "agent", id: "research"},
               provenance: %{origin: "delegated", delegated_by: %{run_id: "parent-run"}},
               cwd: tmp_dir,
               tool_policy: ToolPolicy.from_profile(:leaf_worker),
               capabilities: ["read", "write"],
               limits: %{max_steps: 5}
             )

    assert {:ok, remote} = ExecutionContext.for_remote(context, nil)
    assert {:ok, encoded} = ExecutionContext.encode(remote)
    assert encoded["version"] == ExecutionContext.version()
    assert encoded["workspaceScope"]["root"] == nil
    assert {:ok, decoded} = ExecutionContext.decode(encoded)
    assert decoded.run_id == context.run_id
    assert decoded.tool_policy == context.tool_policy
    assert decoded.capabilities == context.capabilities

    assert {:error, {:unsupported_execution_context_version, 999}} =
             encoded |> Map.put("version", 999) |> ExecutionContext.decode()

    assert {:error, {:invalid_policy_field, :allow}} =
             encoded
             |> put_in(["toolPolicy", "allow"], %{"bad" => true})
             |> ExecutionContext.decode()
  end

  @tag :tmp_dir
  test "read-only children inherit mode and omitted workspace fields", %{tmp_dir: tmp_dir} do
    assert {:ok, parent} =
             ExecutionContext.new(
               run_id: "read-only",
               workspace_scope: %{root: tmp_dir, mode: :read_only},
               tool_policy: ToolPolicy.from_profile(:read_only),
               capabilities: ["read", "grep"],
               limits: %{max_steps: 4, deadline_ms: 2_000}
             )

    assert {:ok, child} = ExecutionContext.child(parent, run_id: "child")
    assert child.workspace_scope == parent.workspace_scope
    assert child.limits == parent.limits
    assert ExecutionContext.subset?(child, parent)

    assert {:ok, narrowed} =
             ExecutionContext.child(parent, %{
               "runId" => "narrowed",
               "workspaceScope" => %{"root" => Path.join(tmp_dir, "child")},
               "toolPolicy" => %{"allow" => "all"},
               "capabilities" => ["read", "bash"],
               "limits" => %{"max_steps" => 10}
             })

    assert narrowed.workspace_scope.mode == :read_only
    assert narrowed.capabilities == ["read"]
    assert narrowed.limits == parent.limits
    assert ExecutionContext.subset?(narrowed, parent)
  end

  @tag :tmp_dir
  test "trusted owned worktree binding changes only the workspace root", %{tmp_dir: tmp_dir} do
    assert {:ok, context} =
             ExecutionContext.new(
               run_id: "owned",
               cwd: Path.join(tmp_dir, "source"),
               tool_policy: ToolPolicy.from_profile(:safe_mode),
               limits: %{max_tokens: 200}
             )

    worktree = Path.join(tmp_dir, "worktree")
    assert {:ok, owned} = ExecutionContext.for_owned_worktree(context, worktree)
    assert owned.workspace_scope == %{context.workspace_scope | root: worktree}
    assert Map.delete(owned, :workspace_scope) == Map.delete(context, :workspace_scope)

    assert {:error, :invalid_workspace_root} =
             ExecutionContext.for_owned_worktree(context, "relative/worktree")

    assert {:error, :workspace_scope_mismatch} =
             ExecutionContext.bind_workspace(context, worktree)
  end

  test "malformed supplied authority never becomes default authority" do
    for attrs <- [
          [tool_policy: false],
          [tool_policy: %{allow: 1}],
          [capabilities: false],
          [capabilities: ["bad tool"]],
          [capabilities: [String.duplicate("x", 257)]],
          [capabilities: [nil]],
          [limits: false],
          [workspace_scope: false],
          [run_id: false],
          [principal: false],
          [provenance: false],
          [workspace_scope: %{mode: false}],
          [limits: %{"max_steps" => 10, max_steps: 1}],
          %{"toolPolicy" => %{}, tool_policy: %{allow: []}}
        ] do
      assert {:error, _reason} = ExecutionContext.new(attrs)
    end

    assert {:error, :invalid_execution_context} = ExecutionContext.new(["not a keyword"])
    assert {:ok, context} = ExecutionContext.new(run_id: "validated")

    for key <-
          ~w(run_id attempt_id principal provenance tool_policy workspace_scope capabilities limits)a do
      assert {:error, _reason} = ExecutionContext.validate(Map.put(context, key, nil))
      assert {:error, _reason} = ExecutionContext.child(context, %{key => false})
    end

    assert {:error, _reason} = ExecutionContext.validate(Map.delete(context, :run_id))
    assert {:error, _reason} = ExecutionContext.validate(%{context | version: 99})
    assert {:error, _reason} = ExecutionContext.child(context, ["not a keyword"])
  end

  test "named-node decode requires complete authority rather than constructing defaults" do
    assert {:ok, context} = ExecutionContext.new(run_id: "wire")
    assert {:ok, encoded} = ExecutionContext.encode(context)

    for key <-
          ~w(runId attemptId principal provenance toolPolicy workspaceScope capabilities limits) do
      assert {:error, _reason} = encoded |> Map.delete(key) |> ExecutionContext.decode()
      assert {:error, _reason} = encoded |> Map.put(key, nil) |> ExecutionContext.decode()
      assert {:error, _reason} = encoded |> Map.put(key, false) |> ExecutionContext.decode()
    end
  end

  test "reidentification preserves every authority dimension" do
    assert {:ok, context} =
             ExecutionContext.new(
               run_id: "before",
               parent_run_id: "parent",
               tool_policy: ToolPolicy.from_profile(:read_only),
               limits: %{max_file_size: 100}
             )

    assert {:ok, rebound} = ExecutionContext.reidentify(context, "accepted")
    assert rebound.run_id == "accepted"
    assert rebound.attempt_id == "accepted:attempt:1"
    assert Map.drop(rebound, [:run_id, :attempt_id]) == Map.drop(context, [:run_id, :attempt_id])
  end
end
