defmodule LemonControlPlane.Methods.ExecApprovalsTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.ExecApprovalsSet
  alias LemonControlPlane.Methods.ExecApprovalsNodeSet
  alias LemonControlPlane.Methods.ExecApprovalsGet
  alias LemonControlPlane.Methods.ExecApprovalsNodeGet
  alias LemonControlPlane.Methods.ExecApprovalResolve
  alias LemonRouter.ApprovalsBridge

  setup do
    # Ensure LemonGateway.Store is running
    case Process.whereis(LemonCore.Store) do
      nil ->
        {:ok, _} = LemonGateway.Store.start_link([])

      _pid ->
        :ok
    end

    # Clean up policies
    clean_policies()

    on_exit(fn -> clean_policies() end)

    :ok
  end

  defp clean_policies do
    for table <- [
          :exec_approvals_policy,
          :exec_approvals_policy_node,
          :exec_approvals_policy_agent,
          :exec_approvals_policy_session,
          :exec_approvals_policy_map,
          :exec_approvals_policy_node_map,
          :exec_approvals_pending
        ] do
      try do
        for {key, _} <- LemonCore.Store.list(table) do
          LemonCore.Store.delete(table, key)
        end
      rescue
        _ -> :ok
      end
    end
  end

  describe "ExecApprovalsSet" do
    test "method name is correct" do
      assert ExecApprovalsSet.name() == "exec.approvals.set"
    end

    test "requires policy or approvals parameter" do
      result = ExecApprovalsSet.handle(%{}, %{})
      assert {:error, {:invalid_request, message, _}} = result
      assert message =~ "required"
    end

    test "sets global policy map with allow disposition" do
      policy = %{"bash" => "allow", "write" => "require"}

      {:ok, result} = ExecApprovalsSet.handle(%{"policy" => policy}, %{})

      assert result["success"] == true

      # Verify the policy map was stored
      stored_map = LemonCore.Store.get(:exec_approvals_policy_map, :global)
      assert stored_map == policy

      # Verify bash is pre-approved (any action)
      bash_approval = LemonCore.Store.get(:exec_approvals_policy, {"bash", :any})
      assert bash_approval != nil
      assert bash_approval.approved == true
    end

    test "pre-approves specific tool+action combinations" do
      approvals = [
        %{"tool" => "bash", "action" => %{"command" => "npm test"}},
        %{"tool" => "bash", "action" => %{"command" => "npm build"}}
      ]

      {:ok, result} = ExecApprovalsSet.handle(%{"approvals" => approvals}, %{})

      assert result["success"] == true
      assert result["approvals_set"] == 2

      # Verify the approvals were stored with correct action hashes
      action1 = %{"command" => "npm test"}
      hash1 = hash_action(action1)
      approval1 = LemonCore.Store.get(:exec_approvals_policy, {"bash", hash1})
      assert approval1 != nil
      assert approval1.approved == true
    end

    test "pre-approved tools are automatically approved by ApprovalsBridge" do
      # Pre-approve bash for any action
      {:ok, _} = ExecApprovalsSet.handle(%{"policy" => %{"bash" => "allow"}}, %{})

      # Request approval - should return immediately
      result = ApprovalsBridge.request(%{
        run_id: "test-run",
        session_key: "agent:test:main",
        tool: "bash",
        action: %{command: "echo hello"},
        rationale: "test",
        expires_in_ms: 100
      })

      assert {:ok, :approved, :global} = result
    end

    test "specific action pre-approval works with ApprovalsBridge" do
      action = %{"command" => "npm test"}

      {:ok, _} =
        ExecApprovalsSet.handle(
          %{"approvals" => [%{"tool" => "bash", "action" => action}]},
          %{}
        )

      # Request with the same action should be approved
      result = ApprovalsBridge.request(%{
        run_id: "test-run",
        session_key: "agent:test:main",
        tool: "bash",
        action: action,
        rationale: "test",
        expires_in_ms: 100
      })

      assert {:ok, :approved, :global} = result
    end
  end

  describe "ExecApprovalsNodeSet" do
    test "method name is correct" do
      assert ExecApprovalsNodeSet.name() == "exec.approvals.node.set"
    end

    test "requires nodeId parameter" do
      result = ExecApprovalsNodeSet.handle(%{"policy" => %{}}, %{})
      assert {:error, {:invalid_request, message, _}} = result
      assert message =~ "nodeId"
    end

    test "requires policy or approvals parameter" do
      result = ExecApprovalsNodeSet.handle(%{"nodeId" => "node-1"}, %{})
      assert {:error, {:invalid_request, message, _}} = result
      assert message =~ "required"
    end

    test "sets node-level policy with allow disposition" do
      node_id = "node-123"
      policy = %{"bash" => "allow", "write" => "require"}

      {:ok, result} =
        ExecApprovalsNodeSet.handle(%{"nodeId" => node_id, "policy" => policy}, %{})

      assert result["success"] == true
      assert result["nodeId"] == node_id

      # Verify bash is pre-approved for this node
      bash_approval = LemonCore.Store.get(:exec_approvals_policy_node, {node_id, "bash", :any})
      assert bash_approval != nil
      assert bash_approval.approved == true
      assert bash_approval.node_id == node_id
    end

    test "pre-approves specific tool+action combinations for node" do
      node_id = "node-456"
      approvals = [
        %{"tool" => "bash", "action" => %{"command" => "make build"}}
      ]

      {:ok, result} =
        ExecApprovalsNodeSet.handle(
          %{"nodeId" => node_id, "approvals" => approvals},
          %{}
        )

      assert result["success"] == true
      assert result["approvals_set"] == 1

      # Verify the approval was stored with correct action hash
      action = %{"command" => "make build"}
      hash = hash_action(action)
      approval = LemonCore.Store.get(:exec_approvals_policy_node, {node_id, "bash", hash})
      assert approval != nil
      assert approval.approved == true
      assert approval.node_id == node_id
    end

    test "node pre-approval works with ApprovalsBridge" do
      node_id = "node-bridge-test"

      {:ok, _} =
        ExecApprovalsNodeSet.handle(
          %{"nodeId" => node_id, "policy" => %{"bash" => "allow"}},
          %{}
        )

      # Request with node_id should be approved
      result = ApprovalsBridge.request(%{
        run_id: "test-run",
        session_key: "agent:test:main",
        node_id: node_id,
        tool: "bash",
        action: %{command: "echo node"},
        rationale: "test",
        expires_in_ms: 100
      })

      assert {:ok, :approved, :node} = result
    end
  end

  describe "ExecApprovalResolve" do
    test "method name is correct" do
      assert ExecApprovalResolve.name() == "exec.approval.resolve"
    end

    test "requires approvalId parameter" do
      result = ExecApprovalResolve.handle(%{"decision" => "approve_once"}, %{})
      assert {:error, {:invalid_request, message, _}} = result
      assert message =~ "approvalId"
    end

    test "requires decision parameter" do
      result = ExecApprovalResolve.handle(%{"approvalId" => "approval-1"}, %{})
      assert {:error, {:invalid_request, message, _}} = result
      assert message =~ "decision"
    end

    test "validates decision values" do
      result = ExecApprovalResolve.handle(
        %{"approvalId" => "approval-1", "decision" => "invalid_decision"},
        %{}
      )

      assert {:error, {:invalid_request, message, _}} = result
      assert message =~ "Invalid decision"
    end

    test "accepts camelCase decision values" do
      # Create a pending approval
      approval_id = LemonCore.Id.approval_id()
      pending = %{
        id: approval_id,
        run_id: "run-camel",
        session_key: "agent:test:main",
        agent_id: "test",
        tool: "bash",
        action: %{command: "test"},
        rationale: "test",
        requested_at_ms: System.system_time(:millisecond),
        expires_at_ms: System.system_time(:millisecond) + 300_000
      }

      LemonCore.Store.put(:exec_approvals_pending, approval_id, pending)

      {:ok, result} = ExecApprovalResolve.handle(
        %{"approvalId" => approval_id, "decision" => "approveOnce"},
        %{}
      )

      assert result["resolved"] == true
    end

    test "accepts snake_case decision values" do
      approval_id = LemonCore.Id.approval_id()
      pending = %{
        id: approval_id,
        run_id: "run-snake",
        session_key: "agent:test:main",
        agent_id: "test",
        tool: "write",
        action: %{path: "/tmp/test"},
        rationale: "test",
        requested_at_ms: System.system_time(:millisecond),
        expires_at_ms: System.system_time(:millisecond) + 300_000
      }

      LemonCore.Store.put(:exec_approvals_pending, approval_id, pending)

      {:ok, result} = ExecApprovalResolve.handle(
        %{"approvalId" => approval_id, "decision" => "approve_session"},
        %{}
      )

      assert result["resolved"] == true
    end

    test "resolves pending approval and removes from pending" do
      approval_id = LemonCore.Id.approval_id()
      pending = %{
        id: approval_id,
        run_id: "run-remove",
        session_key: "agent:test:main",
        agent_id: "test",
        tool: "bash",
        action: %{command: "echo"},
        rationale: "test",
        requested_at_ms: System.system_time(:millisecond),
        expires_at_ms: System.system_time(:millisecond) + 300_000
      }

      LemonCore.Store.put(:exec_approvals_pending, approval_id, pending)

      {:ok, _} = ExecApprovalResolve.handle(
        %{"approvalId" => approval_id, "decision" => "deny"},
        %{}
      )

      # Pending approval should be removed
      assert LemonCore.Store.get(:exec_approvals_pending, approval_id) == nil
    end
  end

  describe "ExecApprovalsGet" do
    test "method name is correct" do
      assert ExecApprovalsGet.name() == "exec.approvals.get"
    end

    test "returns global policy map when set" do
      policy = %{"bash" => "allow", "write" => "require"}
      {:ok, _} = ExecApprovalsSet.handle(%{"policy" => policy}, %{})

      {:ok, result} = ExecApprovalsGet.handle(%{}, %{})

      assert result["policy"] == policy
    end
  end

  describe "ExecApprovalsNodeGet" do
    test "method name is correct" do
      assert ExecApprovalsNodeGet.name() == "exec.approvals.node.get"
    end

    test "requires nodeId parameter" do
      result = ExecApprovalsNodeGet.handle(%{}, %{})
      assert {:error, {:invalid_request, message, _}} = result
      assert message =~ "nodeId"
    end

    test "returns node policy map when set" do
      node_id = "node-get-test"
      policy = %{"bash" => "allow"}
      {:ok, _} = ExecApprovalsNodeSet.handle(%{"nodeId" => node_id, "policy" => policy}, %{})

      {:ok, result} = ExecApprovalsNodeGet.handle(%{"nodeId" => node_id}, %{})

      assert result["nodeId"] == node_id
      assert result["policy"] == policy
    end
  end

  # Helper to hash action the same way as the methods
  defp hash_action(action) when is_map(action) and map_size(action) == 0, do: :any

  defp hash_action(action) when is_map(action) do
    :crypto.hash(:sha256, :erlang.term_to_binary(action))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end
end
