defmodule LemonControlPlane.Methods.ExecApprovalsTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.ExecApprovalsSet
  alias LemonControlPlane.Methods.ExecApprovalsNodeSet
  alias LemonControlPlane.Methods.ExecApprovalsGet
  alias LemonControlPlane.Methods.ExecApprovalsNodeGet
  alias LemonControlPlane.Methods.ExecApprovalRequest
  alias LemonControlPlane.Methods.ExecApprovalResolve

  setup do
    # Ensure LemonCore.Store is running
    case Process.whereis(LemonCore.Store) do
      nil ->
        {:ok, _} = LemonCore.Store.start_link([])

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

  describe "ExecApprovalRequest" do
    test "returns bounded approval request summary" do
      {:ok, result} =
        ExecApprovalRequest.handle(
          %{
            "runId" => "run-summary",
            "sessionKey" => "agent:test:main",
            "tool" => "bash",
            "action" => %{"command" => "echo secret", "token" => "should-not-leak"},
            "rationale" => "needs shell"
          },
          %{}
        )

      assert is_binary(result["approvalId"])
      assert result["summary"]["approvalId"] == result["approvalId"]
      assert result["summary"]["tool"] == "bash"
      assert result["summary"]["hasRunId"] == true
      assert result["summary"]["hasSessionKey"] == true
      assert result["summary"]["actionKeyCount"] == 2
      assert result["summary"]["cleanup"]["includesAction"] == false
      assert result["summary"]["cleanup"]["includesRationale"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
      refute inspect(result) =~ "should-not-leak"
      refute inspect(result) =~ "needs shell"
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
      assert result["summary"]["mode"] == "policy"
      assert result["summary"]["policyToolCount"] == 2
      assert result["summary"]["cleanup"]["includesActions"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false

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
      assert result["summary"]["mode"] == "approvals"
      assert result["summary"]["approvalsSet"] == 2
      assert result["summary"]["requestedApprovalCount"] == 2
      assert result["summary"]["cleanup"]["includesActions"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
      refute inspect(result) =~ "npm test"
      refute inspect(result) =~ "npm build"

      # Verify the approvals were stored with correct action hashes
      action1 = %{"command" => "npm test"}
      hash1 = hash_action(action1)
      approval1 = LemonCore.Store.get(:exec_approvals_policy, {"bash", hash1})
      assert approval1 != nil
      assert approval1.approved == true
    end

    test "pre-approved tools are automatically approved by ExecApprovals" do
      # Pre-approve bash for any action
      {:ok, _} = ExecApprovalsSet.handle(%{"policy" => %{"bash" => "allow"}}, %{})

      # Request approval - should return immediately
      result =
        LemonCore.ExecApprovals.request(%{
          run_id: "test-run",
          session_key: "agent:test:main",
          tool: "bash",
          action: %{command: "echo hello"},
          rationale: "test",
          expires_in_ms: 100
        })

      assert {:ok, :approved, :global} = result
    end

    test "specific action pre-approval works with ExecApprovals" do
      action = %{"command" => "npm test"}

      {:ok, _} =
        ExecApprovalsSet.handle(
          %{"approvals" => [%{"tool" => "bash", "action" => action}]},
          %{}
        )

      # Request with the same action should be approved
      result =
        LemonCore.ExecApprovals.request(%{
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
      assert result["summary"]["nodeId"] == node_id
      assert result["summary"]["mode"] == "policy"
      assert result["summary"]["policyToolCount"] == 2
      assert result["summary"]["cleanup"]["includesActions"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false

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
      assert result["summary"]["nodeId"] == node_id
      assert result["summary"]["mode"] == "approvals"
      assert result["summary"]["approvalsSet"] == 1
      assert result["summary"]["requestedApprovalCount"] == 1
      assert result["summary"]["cleanup"]["includesActions"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
      refute inspect(result) =~ "make build"

      # Verify the approval was stored with correct action hash
      action = %{"command" => "make build"}
      hash = hash_action(action)
      approval = LemonCore.Store.get(:exec_approvals_policy_node, {node_id, "bash", hash})
      assert approval != nil
      assert approval.approved == true
      assert approval.node_id == node_id
    end

    test "node pre-approval works with ExecApprovals" do
      node_id = "node-bridge-test"

      {:ok, _} =
        ExecApprovalsNodeSet.handle(
          %{"nodeId" => node_id, "policy" => %{"bash" => "allow"}},
          %{}
        )

      # Request with node_id should be approved
      result =
        LemonCore.ExecApprovals.request(%{
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
      result =
        ExecApprovalResolve.handle(
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

      {:ok, result} =
        ExecApprovalResolve.handle(
          %{"approvalId" => approval_id, "decision" => "approveOnce"},
          %{}
        )

      assert result["resolved"] == true
      assert result["summary"]["approvalId"] == approval_id
      assert result["summary"]["resolved"] == true
      assert result["summary"]["decision"] == "approve_once"
      assert result["summary"]["cleanup"]["includesAction"] == false
      assert result["summary"]["cleanup"]["includesRationale"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
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

      {:ok, result} =
        ExecApprovalResolve.handle(
          %{"approvalId" => approval_id, "decision" => "approve_session"},
          %{}
        )

      assert result["resolved"] == true
      assert result["summary"]["decision"] == "approve_session"
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

      {:ok, _} =
        ExecApprovalResolve.handle(
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

    test "returns active pending approvals with structured action metadata" do
      active_id = LemonCore.Id.approval_id()
      expired_id = LemonCore.Id.approval_id()
      now_ms = LemonCore.Clock.now_ms()

      LemonCore.Store.put(:exec_approvals_pending, active_id, %{
        id: active_id,
        run_id: "run-oauth",
        session_key: "agent:oauth:main",
        agent_id: "oauth",
        tool: "mcp_mcp_oauth",
        action: %{
          type: "mcp_oauth_authorization",
          authorization_url: "http://127.0.0.1:4000/oauth",
          nested: %{state_hash: "abc123", api_key: "should-not-leak"}
        },
        rationale: "MCP OAuth authorization required",
        requested_at_ms: now_ms,
        expires_at_ms: nil
      })

      LemonCore.Store.put(:exec_approvals_pending, expired_id, %{
        "id" => expired_id,
        "run_id" => "run-expired",
        "session_key" => "agent:expired:main",
        "tool" => "bash",
        "action" => %{"cmd" => "echo stale"},
        "rationale" => "expired",
        "requested_at_ms" => now_ms - 10_000,
        "expires_at_ms" => now_ms - 1
      })

      {:ok, result} = ExecApprovalsGet.handle(%{}, %{})

      assert [pending] = result["pending"]
      assert pending["id"] == active_id
      assert pending["runId"] == "run-oauth"
      assert pending["sessionKey"] == "agent:oauth:main"
      assert pending["agentId"] == "oauth"
      assert pending["tool"] == "mcp_mcp_oauth"
      assert pending["expiresAtMs"] == nil
      assert pending["action"]["type"] == "mcp_oauth_authorization"
      assert pending["action"]["authorization_url"] == "http://127.0.0.1:4000/oauth"
      assert pending["action"]["nested"]["state_hash"] == "abc123"
      assert pending["action"]["nested"]["api_key"] == %{"redacted" => true, "kind" => "secret"}
      refute inspect(result) =~ "should-not-leak"
      assert result["summary"]["policyCount"] == 0
      assert result["summary"]["approvalCount"] == 0
      assert result["summary"]["pendingCount"] == 1
      assert result["summary"]["pendingToolCounts"]["mcp_mcp_oauth"] == 1
      assert result["summary"]["pendingAgentCounts"]["oauth"] == 1
      assert result["summary"]["expiredPendingOmitted"] == true
      assert result["summary"]["cleanup"]["includesPendingActions"] == true
      assert result["summary"]["cleanup"]["redactsPendingActionSecretKeys"] == true
      assert result["summary"]["cleanup"]["includesRationales"] == true
      assert result["summary"]["cleanup"]["includesCredentials"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
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
      assert result["summary"]["nodeId"] == node_id
      assert result["summary"]["policyCount"] == 1
      assert result["summary"]["approvalCount"] == 1
      assert result["summary"]["approvalToolCounts"]["bash"] == 1
      assert result["summary"]["cleanup"]["includesPolicy"] == true
      assert result["summary"]["cleanup"]["includesApprovalHashes"] == true
      assert result["summary"]["cleanup"]["includesActionBodies"] == false
      assert result["summary"]["cleanup"]["includesCredentials"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
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
