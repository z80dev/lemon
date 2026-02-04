defmodule LemonRouter.ApprovalsBridgeTest do
  use ExUnit.Case, async: false

  alias LemonRouter.ApprovalsBridge

  # Helper to hash action like the ApprovalsBridge does
  defp hash_action(action) when is_map(action) do
    :crypto.hash(:sha256, :erlang.term_to_binary(action))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  # Start the required dependencies before tests
  setup do
    # Ensure LemonGateway.Store is running
    case Process.whereis(LemonGateway.Store) do
      nil ->
        {:ok, _} = LemonGateway.Store.start_link([])
      _pid ->
        :ok
    end

    # Clean up any pending approvals
    pending = LemonCore.Store.list(:exec_approvals_pending)
    for {key, _} <- pending do
      LemonCore.Store.delete(:exec_approvals_pending, key)
    end

    policies = LemonCore.Store.list(:exec_approvals_policy)
    for {key, _} <- policies do
      LemonCore.Store.delete(:exec_approvals_policy, key)
    end

    agent_policies = LemonCore.Store.list(:exec_approvals_policy_agent)
    for {key, _} <- agent_policies do
      LemonCore.Store.delete(:exec_approvals_policy_agent, key)
    end

    session_policies = LemonCore.Store.list(:exec_approvals_policy_session)
    for {key, _} <- session_policies do
      LemonCore.Store.delete(:exec_approvals_policy_session, key)
    end

    node_policies = LemonCore.Store.list(:exec_approvals_policy_node)
    for {key, _} <- node_policies do
      LemonCore.Store.delete(:exec_approvals_policy_node, key)
    end

    :ok
  end

  describe "request/1" do
    test "returns approved when global policy exists" do
      action = %{command: "ls"}
      action_hash = hash_action(action)

      # Pre-approve the tool globally (using hashed action)
      LemonCore.Store.put(:exec_approvals_policy, {"bash", action_hash}, %{
        approved: true,
        approved_at_ms: System.system_time(:millisecond)
      })

      result = ApprovalsBridge.request(%{
        run_id: "run-123",
        session_key: "agent:default:main",
        tool: "bash",
        action: action,
        rationale: "listing files"
      })

      assert {:ok, :approved, :global} = result
    end

    test "returns approved when agent policy exists" do
      agent_id = "test"
      session_key = "agent:#{agent_id}:main"
      action = %{path: "/tmp"}
      action_hash = hash_action(action)

      # Pre-approve the tool for this agent (keyed by agent_id)
      LemonCore.Store.put(:exec_approvals_policy_agent, {agent_id, "write", action_hash}, %{
        approved: true,
        approved_at_ms: System.system_time(:millisecond)
      })

      result = ApprovalsBridge.request(%{
        run_id: "run-456",
        session_key: session_key,
        tool: "write",
        action: action,
        rationale: "writing temp file"
      })

      assert {:ok, :approved, :agent} = result
    end

    test "returns timeout when no approval is given" do
      # Request with a very short timeout to test timeout behavior
      result = ApprovalsBridge.request(%{
        run_id: "run-789",
        session_key: "agent:timeout:main",
        tool: "dangerous_tool",
        action: %{},
        rationale: "testing timeout",
        expires_in_ms: 10
      })

      assert {:error, :timeout} = result
    end

    test "creates pending approval and waits for resolution" do
      session_key = "agent:pending:main"
      test_pid = self()

      # Spawn a task that will resolve the approval
      Task.start(fn ->
        # Wait a bit for the request to be stored
        Process.sleep(50)

        # Find the pending approval
        pending = LemonCore.Store.list(:exec_approvals_pending)

        case Enum.find(pending, fn {_id, p} -> p.session_key == session_key end) do
          {approval_id, _} ->
            ApprovalsBridge.resolve(approval_id, :approve_once)
            send(test_pid, :resolved)

          nil ->
            send(test_pid, :not_found)
        end
      end)

      result = ApprovalsBridge.request(%{
        run_id: "run-pending",
        session_key: session_key,
        tool: "bash",
        action: %{command: "echo test"},
        rationale: "test pending",
        expires_in_ms: 5000
      })

      assert {:ok, :approved, :approve_once} = result

      # Ensure the resolver ran
      assert_receive :resolved, 1000
    end
  end

  describe "resolve/2" do
    test "stores global approval when approve_global" do
      approval_id = LemonCore.Id.approval_id()
      action = %{command: "rm -rf"}
      action_hash = hash_action(action)

      pending = %{
        id: approval_id,
        run_id: "run-global",
        session_key: "agent:global:main",
        agent_id: "global",
        tool: "bash",
        action: action,
        rationale: "dangerous command",
        requested_at_ms: System.system_time(:millisecond),
        expires_at_ms: System.system_time(:millisecond) + 300_000
      }

      LemonCore.Store.put(:exec_approvals_pending, approval_id, pending)

      :ok = ApprovalsBridge.resolve(approval_id, :approve_global)

      # Verify the pending approval was removed
      assert LemonCore.Store.get(:exec_approvals_pending, approval_id) == nil

      # Verify global approval was stored (keyed by hashed action)
      policy = LemonCore.Store.get(:exec_approvals_policy, {"bash", action_hash})
      assert policy.approved == true
    end

    test "stores agent-level approval when approve_agent" do
      approval_id = LemonCore.Id.approval_id()
      agent_id = "agent-test"
      session_key = "agent:#{agent_id}:main"
      action = %{path: "/etc/hosts"}
      action_hash = hash_action(action)

      pending = %{
        id: approval_id,
        run_id: "run-agent",
        session_key: session_key,
        agent_id: agent_id,
        tool: "write",
        action: action,
        rationale: "write system file",
        requested_at_ms: System.system_time(:millisecond),
        expires_at_ms: System.system_time(:millisecond) + 300_000
      }

      LemonCore.Store.put(:exec_approvals_pending, approval_id, pending)

      :ok = ApprovalsBridge.resolve(approval_id, :approve_agent)

      # Verify agent-level approval was stored (keyed by agent_id and hashed action)
      policy = LemonCore.Store.get(:exec_approvals_policy_agent, {agent_id, "write", action_hash})
      assert policy.approved == true
    end

    test "does not store approval when denied" do
      approval_id = LemonCore.Id.approval_id()

      pending = %{
        id: approval_id,
        run_id: "run-deny",
        session_key: "agent:deny:main",
        tool: "bash",
        action: %{command: "bad_command"},
        rationale: "denied action",
        requested_at_ms: System.system_time(:millisecond),
        expires_at_ms: System.system_time(:millisecond) + 300_000
      }

      LemonCore.Store.put(:exec_approvals_pending, approval_id, pending)

      :ok = ApprovalsBridge.resolve(approval_id, :deny)

      # Verify the pending approval was removed
      assert LemonCore.Store.get(:exec_approvals_pending, approval_id) == nil

      # Verify no approval was stored
      assert LemonCore.Store.get(:exec_approvals_policy, {"bash", %{command: "bad_command"}}) == nil
    end

    test "handles non-existent approval_id gracefully" do
      result = ApprovalsBridge.resolve("non-existent-id", :approve_once)
      assert result == :ok
    end

    test "stores session-level approval when approve_session" do
      approval_id = LemonCore.Id.approval_id()
      session_key = "agent:session-test:main"

      pending = %{
        id: approval_id,
        run_id: "run-session",
        session_key: session_key,
        agent_id: "session-test",
        tool: "read",
        action: %{path: "/etc/passwd"},
        rationale: "read system file",
        requested_at_ms: System.system_time(:millisecond),
        expires_at_ms: System.system_time(:millisecond) + 300_000
      }

      LemonCore.Store.put(:exec_approvals_pending, approval_id, pending)

      :ok = ApprovalsBridge.resolve(approval_id, :approve_session)

      # Verify session-level approval was stored (parity requirement)
      policy = LemonCore.Store.get(
        :exec_approvals_policy_session,
        {session_key, "read", pending.action}
      )

      # The policy should exist with the action hash
      # May be stored with hash instead of raw action
      session_policies = LemonCore.Store.list(:exec_approvals_policy_session)
      session_policy = Enum.find(session_policies, fn {key, _v} ->
        case key do
          {^session_key, "read", _} -> true
          _ -> false
        end
      end)

      assert session_policy != nil
    end

    test "keys agent approvals by agent_id not session_key" do
      approval_id = LemonCore.Id.approval_id()
      agent_id = "my-agent"
      session_key = "agent:#{agent_id}:branch1"

      pending = %{
        id: approval_id,
        run_id: "run-agent-key",
        session_key: session_key,
        agent_id: agent_id,
        tool: "edit",
        action: %{path: "/src/main.ex"},
        rationale: "edit source file",
        requested_at_ms: System.system_time(:millisecond),
        expires_at_ms: System.system_time(:millisecond) + 300_000
      }

      LemonCore.Store.put(:exec_approvals_pending, approval_id, pending)

      :ok = ApprovalsBridge.resolve(approval_id, :approve_agent)

      # Verify approval is keyed by agent_id, not session_key
      agent_policies = LemonCore.Store.list(:exec_approvals_policy_agent)
      agent_policy = Enum.find(agent_policies, fn {key, _v} ->
        case key do
          {^agent_id, "edit", _} -> true
          _ -> false
        end
      end)

      assert agent_policy != nil, "Agent policy should be keyed by agent_id '#{agent_id}'"
    end
  end

  describe "node-level approval" do
    test "returns approved when node policy exists" do
      node_id = "node-123"
      action = %{command: "node-action"}
      action_hash = hash_action(action)

      # Pre-approve the tool for this node
      LemonCore.Store.put(:exec_approvals_policy_node, {node_id, "bash", action_hash}, %{
        approved: true,
        approved_at_ms: System.system_time(:millisecond)
      })

      result = ApprovalsBridge.request(%{
        run_id: "run-node",
        session_key: "agent:test:main",
        node_id: node_id,
        tool: "bash",
        action: action,
        rationale: "node-level approval test"
      })

      assert {:ok, :approved, :node} = result
    end

    test "node policy has lower precedence than global policy" do
      node_id = "node-456"
      action = %{command: "global-wins"}
      action_hash = hash_action(action)

      # Pre-approve globally
      LemonCore.Store.put(:exec_approvals_policy, {"bash", action_hash}, %{
        approved: true,
        approved_at_ms: System.system_time(:millisecond)
      })

      # Also pre-approve at node level
      LemonCore.Store.put(:exec_approvals_policy_node, {node_id, "bash", action_hash}, %{
        approved: true,
        approved_at_ms: System.system_time(:millisecond)
      })

      result = ApprovalsBridge.request(%{
        run_id: "run-precedence",
        session_key: "agent:test:main",
        node_id: node_id,
        tool: "bash",
        action: action,
        rationale: "precedence test"
      })

      # Global should win (checked first)
      assert {:ok, :approved, :global} = result
    end

    test "node policy has higher precedence than agent policy" do
      node_id = "node-789"
      agent_id = "agent-test"
      session_key = "agent:#{agent_id}:main"
      action = %{command: "node-wins"}
      action_hash = hash_action(action)

      # Pre-approve at agent level
      LemonCore.Store.put(:exec_approvals_policy_agent, {agent_id, "bash", action_hash}, %{
        approved: true,
        approved_at_ms: System.system_time(:millisecond)
      })

      # Also pre-approve at node level
      LemonCore.Store.put(:exec_approvals_policy_node, {node_id, "bash", action_hash}, %{
        approved: true,
        approved_at_ms: System.system_time(:millisecond)
      })

      result = ApprovalsBridge.request(%{
        run_id: "run-node-agent",
        session_key: session_key,
        node_id: node_id,
        tool: "bash",
        action: action,
        rationale: "node vs agent precedence"
      })

      # Node should win (checked before agent)
      assert {:ok, :approved, :node} = result
    end
  end

  describe "agent_id extraction" do
    test "extracts agent_id from session_key" do
      # Request should extract agent_id from session_key format
      session_key = "agent:my-extracted-agent:main"

      # Pre-approve for this agent
      agent_policies = LemonCore.Store.list(:exec_approvals_policy_agent)
      for {key, _} <- agent_policies do
        LemonCore.Store.delete(:exec_approvals_policy_agent, key)
      end

      # Simulate pre-approval keyed by extracted agent_id
      action = %{command: "test-cmd"}
      action_hash = :crypto.hash(:sha256, :erlang.term_to_binary(action))
                    |> Base.encode16(case: :lower)
                    |> String.slice(0, 16)

      LemonCore.Store.put(
        :exec_approvals_policy_agent,
        {"my-extracted-agent", "test-tool", action_hash},
        %{approved: true, approved_at_ms: System.system_time(:millisecond)}
      )

      result = ApprovalsBridge.request(%{
        run_id: "run-extract",
        session_key: session_key,
        # Note: not providing agent_id, should be extracted
        tool: "test-tool",
        action: action,
        rationale: "test extraction"
      })

      assert {:ok, :approved, :agent} = result
    end
  end

  describe "end-to-end approval resolution" do
    @moduledoc """
    Tests that verify exec.approval.resolve actually unblocks tool execution.
    This is critical for the approval flow - the control plane must be able to
    resolve pending approvals and have the tool execution continue.
    """

    test "exec.approval.resolve unblocks waiting request with approve_once" do
      session_key = "agent:e2e-test:main"
      test_pid = self()

      # Start the approval request in a separate task
      request_task = Task.async(fn ->
        ApprovalsBridge.request(%{
          run_id: "run-e2e-once",
          session_key: session_key,
          tool: "bash",
          action: %{command: "echo hello"},
          rationale: "e2e test",
          expires_in_ms: 5000
        })
      end)

      # Wait for the pending approval to be created
      Process.sleep(50)

      # Find the pending approval
      pending = LemonCore.Store.list(:exec_approvals_pending)
      {approval_id, pending_data} = Enum.find(pending, {nil, nil}, fn {_id, p} ->
        p.session_key == session_key and p.run_id == "run-e2e-once"
      end)

      assert approval_id != nil, "Pending approval should be created"
      assert pending_data.tool == "bash"

      # Resolve using the control-plane method (simulates exec.approval.resolve RPC)
      {:ok, resolve_result} = LemonControlPlane.Methods.ExecApprovalResolve.handle(
        %{"approvalId" => approval_id, "decision" => "approve_once"},
        %{}
      )

      assert resolve_result["resolved"] == true

      # The request should now return with approved status
      result = Task.await(request_task, 2000)
      assert {:ok, :approved, :approve_once} = result
    end

    test "exec.approval.resolve unblocks waiting request with approve_session" do
      session_key = "agent:e2e-session:main"

      request_task = Task.async(fn ->
        ApprovalsBridge.request(%{
          run_id: "run-e2e-session",
          session_key: session_key,
          tool: "write",
          action: %{path: "/tmp/test.txt"},
          rationale: "e2e session test",
          expires_in_ms: 5000
        })
      end)

      Process.sleep(50)

      pending = LemonCore.Store.list(:exec_approvals_pending)
      {approval_id, _} = Enum.find(pending, {nil, nil}, fn {_id, p} ->
        p.session_key == session_key and p.run_id == "run-e2e-session"
      end)

      assert approval_id != nil

      # Resolve with approve_session
      {:ok, _} = LemonControlPlane.Methods.ExecApprovalResolve.handle(
        %{"approvalId" => approval_id, "decision" => "approve_session"},
        %{}
      )

      result = Task.await(request_task, 2000)
      assert {:ok, :approved, :approve_session} = result

      # Verify the session approval was stored
      action_hash = hash_action(%{path: "/tmp/test.txt"})
      session_policies = LemonCore.Store.list(:exec_approvals_policy_session)
      found = Enum.find(session_policies, fn {key, _} ->
        case key do
          {^session_key, "write", ^action_hash} -> true
          _ -> false
        end
      end)

      assert found != nil, "Session approval should be stored after approve_session"
    end

    test "exec.approval.resolve unblocks waiting request with approve_global" do
      session_key = "agent:e2e-global:main"
      action = %{command: "npm test"}

      request_task = Task.async(fn ->
        ApprovalsBridge.request(%{
          run_id: "run-e2e-global",
          session_key: session_key,
          tool: "bash",
          action: action,
          rationale: "e2e global test",
          expires_in_ms: 5000
        })
      end)

      Process.sleep(50)

      pending = LemonCore.Store.list(:exec_approvals_pending)
      {approval_id, _} = Enum.find(pending, {nil, nil}, fn {_id, p} ->
        p.session_key == session_key and p.run_id == "run-e2e-global"
      end)

      assert approval_id != nil

      # Resolve with approve_global
      {:ok, _} = LemonControlPlane.Methods.ExecApprovalResolve.handle(
        %{"approvalId" => approval_id, "decision" => "approve_global"},
        %{}
      )

      result = Task.await(request_task, 2000)
      assert {:ok, :approved, :approve_global} = result

      # Verify the global approval was stored
      action_hash = hash_action(action)
      global_policy = LemonCore.Store.get(:exec_approvals_policy, {"bash", action_hash})
      assert global_policy != nil
      assert global_policy.approved == true
    end

    test "exec.approval.resolve unblocks waiting request with deny" do
      session_key = "agent:e2e-deny:main"

      request_task = Task.async(fn ->
        ApprovalsBridge.request(%{
          run_id: "run-e2e-deny",
          session_key: session_key,
          tool: "dangerous_tool",
          action: %{delete_all: true},
          rationale: "e2e deny test",
          expires_in_ms: 5000
        })
      end)

      Process.sleep(50)

      pending = LemonCore.Store.list(:exec_approvals_pending)
      {approval_id, _} = Enum.find(pending, {nil, nil}, fn {_id, p} ->
        p.session_key == session_key and p.run_id == "run-e2e-deny"
      end)

      assert approval_id != nil

      # Resolve with deny
      {:ok, resolve_result} = LemonControlPlane.Methods.ExecApprovalResolve.handle(
        %{"approvalId" => approval_id, "decision" => "deny"},
        %{}
      )

      assert resolve_result["decision"] == "deny"

      result = Task.await(request_task, 2000)
      assert {:ok, :denied} = result
    end

    test "subsequent requests for same action are auto-approved after approve_global" do
      session_key = "agent:e2e-repeat:main"
      action = %{command: "repeated_command"}
      action_hash = hash_action(action)

      # First, pre-approve globally for this action
      LemonCore.Store.put(:exec_approvals_policy, {"bash", action_hash}, %{
        approved: true,
        approved_at_ms: System.system_time(:millisecond)
      })

      # Request should return immediately without waiting
      result = ApprovalsBridge.request(%{
        run_id: "run-e2e-repeat",
        session_key: session_key,
        tool: "bash",
        action: action,
        rationale: "should be instant",
        expires_in_ms: 100  # Short timeout to prove we don't wait
      })

      assert {:ok, :approved, :global} = result
    end

    test "wildcard approval (any action) works for pre-approved tools" do
      session_key = "agent:e2e-wildcard:main"

      # Pre-approve with wildcard action hash
      LemonCore.Store.put(:exec_approvals_policy, {"read", :any}, %{
        approved: true,
        scope: :global,
        approved_at_ms: System.system_time(:millisecond)
      })

      # Any action for the "read" tool should be approved
      result1 = ApprovalsBridge.request(%{
        run_id: "run-wildcard-1",
        session_key: session_key,
        tool: "read",
        action: %{path: "/etc/passwd"},
        rationale: "wildcard test 1",
        expires_in_ms: 100
      })

      assert {:ok, :approved, :global} = result1

      result2 = ApprovalsBridge.request(%{
        run_id: "run-wildcard-2",
        session_key: session_key,
        tool: "read",
        action: %{path: "/etc/hosts", lines: 100},  # Different action
        rationale: "wildcard test 2",
        expires_in_ms: 100
      })

      assert {:ok, :approved, :global} = result2
    end
  end
end
