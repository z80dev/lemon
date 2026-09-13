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
             "hashline_edit",
             "patch",
             "bash",
             "execute_code"
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
end
