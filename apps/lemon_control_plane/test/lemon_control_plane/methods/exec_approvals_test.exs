defmodule LemonControlPlane.Methods.ExecApprovalsTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.ExecApprovalsGet
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
      assert LemonCore.ExecApprovalStore.get_pending(approval_id) == nil
    end
  end

  describe "ExecApprovalsGet" do
    test "method name is correct" do
      assert ExecApprovalsGet.name() == "exec.approvals.get"
    end

    test "returns global policy map when set" do
      policy = %{"bash" => "allow", "write" => "require"}
      :ok = LemonCore.ExecApprovalStore.put_global_policy_map(policy)

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

    test "retains usable OAuth URLs without exposing action credentials" do
      safe_url =
        "https://provider.example/authorize?client_id=lemon&response_type=code" <>
          "&redirect_uri=http%3A%2F%2F127.0.0.1%3A4000%2Fcallback" <>
          "&scope=read%20write&state=approval-state&code_challenge=challenge"

      unsafe_urls = [
        "https://user:url-password@provider.example/authorize",
        "https://provider.example/authorize?access_token=query-credential",
        "https://provider.example/authorize?api%5Fkey=encoded-credential",
        "https://provider.example/authorize#token=fragment-credential",
        "https://provider.example/sk-urlcredential123/authorize"
      ]

      for {url, index} <- Enum.with_index([safe_url | unsafe_urls]) do
        approval_id = LemonCore.Id.approval_id()

        LemonCore.Store.put(:exec_approvals_pending, approval_id, %{
          id: approval_id,
          action: %{
            "authorization_url" => url,
            "authorization_url_token" => "lookalike-credential",
            "nested" => [
              %{"Authorization" => "Bearer header-credential"},
              %{"message" => "continue token=text-credential"}
            ]
          },
          expires_at_ms: nil
        })

        {:ok, result} = ExecApprovalsGet.handle(%{}, %{})
        pending = Enum.find(result["pending"], &(&1["id"] == approval_id))

        if index == 0 do
          assert pending["action"]["authorization_url"] == safe_url
        else
          assert pending["action"]["authorization_url"] == %{
                   "redacted" => true,
                   "kind" => "secret"
                 }
        end

        assert pending["action"]["authorization_url_token"] == %{
                 "redacted" => true,
                 "kind" => "secret"
               }

        for credential <- [
              "url-password",
              "query-credential",
              "encoded-credential",
              "fragment-credential",
              "sk-urlcredential123",
              "lookalike-credential",
              "header-credential",
              "text-credential"
            ] do
          refute inspect(result) =~ credential
        end
      end
    end
  end
end
