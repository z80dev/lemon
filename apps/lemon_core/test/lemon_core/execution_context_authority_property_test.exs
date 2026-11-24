defmodule LemonCore.ExecutionContextAuthorityPropertyTest do
  @moduledoc """
  Delegated and named-node authority invariants of the canonical execution
  context (#73): a child is never broader than its parent intersected with its
  request, and transport or a destination ceiling never widens authority.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias LemonCore.{ExecutionContext, ToolPolicy}

  @tools ~w(read grep find write edit bash eval task agent webfetch zz_unclassified_tool)
  @limit_keys [:max_steps, :max_tokens, :deadline_ms, :max_file_size]

  @tag :tmp_dir
  property "children are within parent ∩ request on every authority dimension", %{
    tmp_dir: tmp_dir
  } do
    check all(
            parent_attrs <- context_attrs(tmp_dir),
            request <- child_request(tmp_dir)
          ) do
      {:ok, parent} = ExecutionContext.new(parent_attrs)

      case ExecutionContext.child(parent, request) do
        {:ok, child} ->
          assert_within(child, parent)
          assert child.parent_run_id == parent.run_id
          assert child.provenance.delegated_by == ExecutionContext.identity(parent)

          requested_policy = request[:tool_policy] || parent.tool_policy

          for tool <- @tools, ToolPolicy.allowed?(child.tool_policy, tool) do
            assert ToolPolicy.allowed?(requested_policy, tool)
            assert capability?(request[:capabilities], tool)
          end

          for {key, value} <- request[:limits] || %{} do
            assert child.limits[key] <= value
          end

          # Delegation is transitive: a grandchild stays within the root.
          case ExecutionContext.child(child, request) do
            {:ok, grandchild} -> assert_within(grandchild, parent)
            {:error, _reason} -> :ok
          end

        {:error, reason} ->
          # Only an escalating workspace request or a read-only workspace that
          # the narrowed policy still could mutate is refused.
          assert reason in [:workspace_scope_escalation, :read_only_workspace_policy_mismatch]
      end
    end
  end

  @tag :tmp_dir
  property "named-node transport and destination ceilings never widen authority", %{
    tmp_dir: tmp_dir
  } do
    check all(
            attrs <- context_attrs(tmp_dir),
            ceiling <- capabilities()
          ) do
      {:ok, context} = ExecutionContext.new(attrs)
      {:ok, remote} = ExecutionContext.for_remote(context, nil)
      {:ok, encoded} = ExecutionContext.encode(remote)
      wire = encoded |> Jason.encode!() |> Jason.decode!()

      assert {:ok, decoded} = ExecutionContext.decode(wire)
      assert decoded == remote
      assert decoded.workspace_scope.root == nil
      assert_within(%{decoded | workspace_scope: context.workspace_scope}, context)

      assert {:ok, restricted} = ExecutionContext.restrict_capabilities(decoded, ceiling)
      assert restricted.run_id == context.run_id
      assert restricted.attempt_id == context.attempt_id
      assert ExecutionContext.subset?(restricted, decoded)

      for tool <- @tools, ToolPolicy.allowed?(restricted.tool_policy, tool) do
        assert capability?(ceiling, tool)
        assert ToolPolicy.allowed?(context.tool_policy, tool)
      end

      # A destination binds the unbound scope to its own root.
      assert {:ok, bound} = ExecutionContext.bind_workspace(restricted, tmp_dir)
      assert bound.workspace_scope.root == Path.expand(tmp_dir)
      assert Map.delete(bound, :workspace_scope) == Map.delete(restricted, :workspace_scope)
    end
  end

  @tag :tmp_dir
  test "a requested child cannot widen a read-only workspace or escape its root", %{
    tmp_dir: tmp_dir
  } do
    {:ok, parent} =
      ExecutionContext.new(
        run_id: "read-only-parent",
        workspace_scope: %{root: tmp_dir, mode: :read_only},
        tool_policy: ToolPolicy.from_profile(:read_only)
      )

    for request <- [
          %{workspace_scope: %{root: tmp_dir, mode: :read_write}},
          %{"workspaceScope" => %{"mode" => "read_write"}},
          %{cwd: Path.dirname(tmp_dir)},
          %{cwd: "/"}
        ] do
      assert {:error, :workspace_scope_escalation} = ExecutionContext.child(parent, request)
    end

    assert {:ok, child} =
             ExecutionContext.child(parent, %{tool_policy: :full_access, capabilities: :all})

    assert child.workspace_scope.mode == :read_only

    for tool <- ExecutionContext.direct_workspace_mutation_tools() do
      refute ToolPolicy.allowed?(child.tool_policy, tool)
    end
  end

  test "transported authority is revalidated rather than trusted at the destination" do
    {:ok, context} =
      ExecutionContext.new(
        run_id: "wire",
        tool_policy: ToolPolicy.custom(allow: ["read"]),
        capabilities: ["read"]
      )

    {:ok, encoded} = ExecutionContext.encode(context)

    for tampered <- [
          put_in(encoded, ["toolPolicy", "profile"], "root"),
          put_in(encoded, ["toolPolicy", "allow"], 1),
          put_in(encoded, ["toolPolicy", "unknown"], true),
          put_in(encoded, ["capabilities"], ["bad tool"]),
          put_in(encoded, ["capabilities"], %{"read" => true}),
          put_in(encoded, ["limits"], %{"max_steps" => 0}),
          put_in(encoded, ["limits"], %{"unbounded" => 1}),
          put_in(encoded, ["workspaceScope", "mode"], "admin"),
          put_in(encoded, ["principal"], %{"type" => "agent"}),
          Map.put(encoded, "run_id", "conflicting-alias"),
          Map.put(encoded, "version", 2)
        ] do
      assert {:error, _reason} = ExecutionContext.decode(tampered)
    end

    # A wire capability set never re-grants a tool its own policy denies.
    widened = put_in(encoded, ["capabilities"], "all")
    assert {:ok, decoded} = ExecutionContext.decode(widened)
    refute ToolPolicy.allowed?(decoded.tool_policy, "bash")
  end

  defp assert_within(child, parent) do
    assert ExecutionContext.subset?(child, parent)
    assert capability_subset?(child.capabilities, parent.capabilities)
    refute child.workspace_scope.mode == :read_write and parent.workspace_scope.mode == :read_only

    for tool <- @tools, ToolPolicy.allowed?(child.tool_policy, tool) do
      assert ToolPolicy.allowed?(parent.tool_policy, tool)
      assert capability?(parent.capabilities, tool)

      if ToolPolicy.requires_approval?(parent.tool_policy, tool),
        do: assert(ToolPolicy.requires_approval?(child.tool_policy, tool))
    end

    for {key, value} <- parent.limits do
      assert Map.fetch!(child.limits, key) <= value
    end
  end

  defp capability?(nil, _tool), do: true
  defp capability?(:all, _tool), do: true
  defp capability?("all", _tool), do: true
  defp capability?(capabilities, tool), do: tool in capabilities

  defp capability_subset?(_child, :all), do: true
  defp capability_subset?(:all, _parent), do: false
  defp capability_subset?(child, parent), do: Enum.all?(child, &(&1 in parent))

  defp context_attrs(tmp_dir) do
    gen all(
          run_id <- string(:alphanumeric, min_length: 1, max_length: 12),
          policy <- policy(),
          capabilities <- one_of([constant(nil), capabilities()]),
          limits <- limits(),
          read_only? <- boolean()
        ) do
      scope_mode = if read_only?, do: :read_only, else: :read_write

      policy =
        if read_only?,
          do:
            ToolPolicy.restrict(policy, %{
              deny: ExecutionContext.direct_workspace_mutation_tools()
            })
            |> elem(1),
          else: policy

      [
        run_id: "parent-" <> run_id,
        tool_policy: policy,
        workspace_scope: %{root: tmp_dir, mode: scope_mode},
        limits: limits
      ]
      |> then(&if(capabilities, do: Keyword.put(&1, :capabilities, capabilities), else: &1))
    end
  end

  defp child_request(tmp_dir) do
    gen all(
          run_id <- string(:alphanumeric, min_length: 1, max_length: 12),
          policy <- one_of([constant(nil), policy()]),
          capabilities <- one_of([constant(nil), capabilities()]),
          limits <- one_of([constant(nil), limits()]),
          cwd <-
            member_of([nil, tmp_dir, Path.join(tmp_dir, "child"), Path.dirname(tmp_dir), "/"]),
          mode <- member_of([nil, :read_only, :read_write])
        ) do
      %{run_id: "child-" <> run_id}
      |> put_present(:tool_policy, policy)
      |> put_present(:capabilities, capabilities)
      |> put_present(:limits, limits)
      |> put_present(:cwd, cwd)
      |> put_present(:workspace_scope, mode && %{mode: mode})
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp policy do
    gen all(
          allow <- one_of([constant(:all), tool_set(6)]),
          deny <- tool_set(3),
          require_approval <- tool_set(3),
          never <- tool_set(2),
          approval_mode <- member_of([nil, :ask, :write, :yolo]),
          max_file_size <- one_of([constant(nil), positive_integer()])
        ) do
      ToolPolicy.custom(
        allow: allow,
        deny: deny,
        require_approval: require_approval,
        approvals: Map.new(never, &{&1, :never}),
        approval_mode: approval_mode,
        max_file_size: max_file_size
      )
    end
  end

  defp capabilities, do: one_of([constant(:all), tool_set(6)])

  defp tool_set(max), do: map(list_of(member_of(@tools), max_length: max), &Enum.uniq/1)

  defp limits, do: optional_map(Map.new(@limit_keys, &{&1, positive_integer()}))
end
