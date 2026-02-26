defmodule LemonCore.ExecApprovalsTest do
  @moduledoc """
  Tests for the ExecApprovals module.
  """
  use LemonCore.Testing.Case, async: false
  @moduletag with_store: true

  alias LemonCore.ExecApprovals
  alias LemonCore.Store

  setup do
    if Process.whereis(LemonCore.PubSub) == nil do
      start_supervised!({Phoenix.PubSub, name: LemonCore.PubSub})
    end

    # Clear approval-related tables before each test
    clear_approval_tables()

    on_exit(fn ->
      clear_approval_tables()
    end)

    :ok
  end

  defp clear_approval_tables do
    [
      :exec_approvals_pending,
      :exec_approvals_policy,
      :exec_approvals_policy_agent,
      :exec_approvals_policy_session,
      :exec_approvals_policy_node
    ]
    |> Enum.each(fn table ->
      Store.list(table)
      |> Enum.each(fn {key, _value} ->
        Store.delete(table, key)
      end)
    end)
  end

  describe "request/1" do
    test "returns approved immediately when global approval exists" do
      # Pre-store a global approval
      action = %{command: "ls -la"}
      action_hash = hash_action(action)

      Store.put(:exec_approvals_policy, {"bash", action_hash}, %{
        tool: "bash",
        action_hash: action_hash,
        scope: :global,
        approved: true,
        approved_at_ms: System.system_time(:millisecond)
      })

      result =
        ExecApprovals.request(%{
          run_id: "run_123",
          session_key: "agent:test:main",
          tool: "bash",
          action: action
        })

      assert {:ok, :approved, :global} = result
    end

    test "returns approved immediately when session approval exists" do
      action = %{command: "ls -la"}
      action_hash = hash_action(action)
      session_key = "agent:test:main"

      Store.put(:exec_approvals_policy_session, {session_key, "bash", action_hash}, %{
        tool: "bash",
        action_hash: action_hash,
        scope: :session,
        approved: true,
        approved_at_ms: System.system_time(:millisecond)
      })

      result =
        ExecApprovals.request(%{
          run_id: "run_123",
          session_key: session_key,
          tool: "bash",
          action: action
        })

      assert {:ok, :approved, :session} = result
    end

    test "returns approved immediately when agent approval exists" do
      action = %{command: "ls -la"}
      action_hash = hash_action(action)

      Store.put(:exec_approvals_policy_agent, {"test", "bash", action_hash}, %{
        tool: "bash",
        action_hash: action_hash,
        scope: :agent,
        approved: true,
        approved_at_ms: System.system_time(:millisecond)
      })

      result =
        ExecApprovals.request(%{
          run_id: "run_123",
          session_key: "agent:test:main",
          agent_id: "test",
          tool: "bash",
          action: action
        })

      assert {:ok, :approved, :agent} = result
    end

    test "creates pending approval when no existing approval" do
      action = %{command: "rm -rf /"}

      # Run request in a task so we can resolve it
      task =
        Task.async(fn ->
          ExecApprovals.request(%{
            run_id: "run_123",
            session_key: "agent:test:main",
            tool: "bash",
            action: action,
            expires_in_ms: 5000
          })
        end)

      # Give the request time to create the pending approval
      Process.sleep(100)

      # Verify pending approval was created
      pending_list = Store.list(:exec_approvals_pending)
      assert length(pending_list) == 1

      {_key, pending} = hd(pending_list)
      assert pending.tool == "bash"
      assert pending.run_id == "run_123"
      assert pending.action == action

      # Resolve the approval
      ExecApprovals.resolve(pending.id, :approve_once)

      # Wait for the result
      assert {:ok, :approved, :approve_once} = Task.await(task, 1000)
    end

    test "returns denied when approval is denied" do
      action = %{command: "rm -rf /"}

      task =
        Task.async(fn ->
          ExecApprovals.request(%{
            run_id: "run_123",
            session_key: "agent:test:main",
            tool: "bash",
            action: action,
            expires_in_ms: 5000
          })
        end)

      Process.sleep(100)

      # Get the pending approval
      pending_list = Store.list(:exec_approvals_pending)
      {_key, pending} = hd(pending_list)

      # Deny the approval
      ExecApprovals.resolve(pending.id, :deny)

      assert {:ok, :denied} = Task.await(task, 1000)
    end

    test "returns timeout when approval times out" do
      action = %{command: "ls"}

      result =
        ExecApprovals.request(%{
          run_id: "run_123",
          session_key: "agent:test:main",
          tool: "bash",
          action: action,
          expires_in_ms: 50
        })

      assert {:error, :timeout} = result
    end
  end

  describe "resolve/2" do
    test "stores session approval when resolved with :approve_session" do
      pending = %{
        id: "approval_123",
        run_id: "run_123",
        session_key: "agent:test:main",
        agent_id: "test",
        tool: "bash",
        action: %{command: "ls"},
        requested_at_ms: System.system_time(:millisecond)
      }

      Store.put(:exec_approvals_pending, pending.id, pending)

      :ok = ExecApprovals.resolve(pending.id, :approve_session)

      # Verify the approval was stored at session scope
      action_hash = hash_action(pending.action)
      stored = Store.get(:exec_approvals_policy_session, {"agent:test:main", "bash", action_hash})

      assert stored != nil
      assert stored.approved == true
      assert stored.scope == :session
    end

    test "stores agent approval when resolved with :approve_agent" do
      pending = %{
        id: "approval_123",
        run_id: "run_123",
        session_key: "agent:test:main",
        agent_id: "test_agent",
        tool: "bash",
        action: %{command: "ls"},
        requested_at_ms: System.system_time(:millisecond)
      }

      Store.put(:exec_approvals_pending, pending.id, pending)

      :ok = ExecApprovals.resolve(pending.id, :approve_agent)

      action_hash = hash_action(pending.action)
      stored = Store.get(:exec_approvals_policy_agent, {"test_agent", "bash", action_hash})

      assert stored != nil
      assert stored.approved == true
      assert stored.scope == :agent
    end

    test "stores global approval when resolved with :approve_global" do
      pending = %{
        id: "approval_123",
        run_id: "run_123",
        session_key: "agent:test:main",
        agent_id: "test",
        tool: "bash",
        action: %{command: "ls"},
        requested_at_ms: System.system_time(:millisecond)
      }

      Store.put(:exec_approvals_pending, pending.id, pending)

      :ok = ExecApprovals.resolve(pending.id, :approve_global)

      action_hash = hash_action(pending.action)
      stored = Store.get(:exec_approvals_policy, {"bash", action_hash})

      assert stored != nil
      assert stored.approved == true
      assert stored.scope == :global
    end

    test "does not store approval when resolved with :approve_once" do
      pending = %{
        id: "approval_123",
        run_id: "run_123",
        session_key: "agent:test:main",
        agent_id: "test",
        tool: "bash",
        action: %{command: "ls"},
        requested_at_ms: System.system_time(:millisecond)
      }

      Store.put(:exec_approvals_pending, pending.id, pending)

      :ok = ExecApprovals.resolve(pending.id, :approve_once)

      # Verify no approval was stored
      action_hash = hash_action(pending.action)
      assert Store.get(:exec_approvals_policy, {"bash", action_hash}) == nil
      assert Store.get(:exec_approvals_policy_agent, {"test", "bash", action_hash}) == nil
      assert Store.get(:exec_approvals_policy_session, {"agent:test:main", "bash", action_hash}) == nil
    end

    test "deletes pending approval after resolution" do
      pending = %{
        id: "approval_123",
        run_id: "run_123",
        session_key: "agent:test:main",
        agent_id: "test",
        tool: "bash",
        action: %{command: "ls"},
        requested_at_ms: System.system_time(:millisecond)
      }

      Store.put(:exec_approvals_pending, pending.id, pending)

      :ok = ExecApprovals.resolve(pending.id, :approve_once)

      assert Store.get(:exec_approvals_pending, pending.id) == nil
    end

    test "returns :ok for non-existent approval" do
      assert :ok = ExecApprovals.resolve("non_existent_id", :approve_once)
    end
  end

  describe "approval scope hierarchy" do
    test "global approval takes precedence over agent and session" do
      action = %{command: "ls"}
      action_hash = hash_action(action)

      # Store approvals at all scopes
      Store.put(:exec_approvals_policy, {"bash", action_hash}, %{
        tool: "bash",
        action_hash: action_hash,
        scope: :global,
        approved: true,
        approved_at_ms: System.system_time(:millisecond)
      })

      Store.put(:exec_approvals_policy_agent, {"test", "bash", action_hash}, %{
        tool: "bash",
        action_hash: action_hash,
        scope: :agent,
        approved: true,
        approved_at_ms: System.system_time(:millisecond)
      })

      result =
        ExecApprovals.request(%{
          run_id: "run_123",
          session_key: "agent:test:main",
          agent_id: "test",
          tool: "bash",
          action: action
        })

      assert {:ok, :approved, :global} = result
    end

    test "agent approval takes precedence over session" do
      action = %{command: "ls"}
      action_hash = hash_action(action)

      Store.put(:exec_approvals_policy_agent, {"test", "bash", action_hash}, %{
        tool: "bash",
        action_hash: action_hash,
        scope: :agent,
        approved: true,
        approved_at_ms: System.system_time(:millisecond)
      })

      Store.put(:exec_approvals_policy_session, {"agent:test:main", "bash", action_hash}, %{
        tool: "bash",
        action_hash: action_hash,
        scope: :session,
        approved: true,
        approved_at_ms: System.system_time(:millisecond)
      })

      result =
        ExecApprovals.request(%{
          run_id: "run_123",
          session_key: "agent:test:main",
          agent_id: "test",
          tool: "bash",
          action: action
        })

      assert {:ok, :approved, :agent} = result
    end
  end

  describe "action hashing" do
    test "same actions produce same hash" do
      action1 = %{command: "ls -la", directory: "/tmp"}
      action2 = %{command: "ls -la", directory: "/tmp"}

      hash1 = hash_action(action1)
      hash2 = hash_action(action2)

      assert hash1 == hash2
    end

    test "different actions produce different hashes" do
      action1 = %{command: "ls -la"}
      action2 = %{command: "ls -l"}

      hash1 = hash_action(action1)
      hash2 = hash_action(action2)

      assert hash1 != hash2
    end
  end

  describe "wildcard approvals" do
    test "wildcard :any action hash matches any action" do
      Store.put(:exec_approvals_policy, {"bash", :any}, %{
        tool: "bash",
        action_hash: :any,
        scope: :global,
        approved: true,
        approved_at_ms: System.system_time(:millisecond)
      })

      result =
        ExecApprovals.request(%{
          run_id: "run_123",
          session_key: "agent:test:main",
          tool: "bash",
          action: %{command: "any command here"}
        })

      assert {:ok, :approved, :global} = result
    end
  end

  # Helper function to match the module's hashing
  defp hash_action(action) when is_map(action) do
    :crypto.hash(:sha256, :erlang.term_to_binary(action))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end
end
