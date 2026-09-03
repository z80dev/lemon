defmodule LemonCore.ExecApprovalsTest do
  @moduledoc """
  Tests for the ExecApprovals module.
  """
  use LemonCore.Testing.Case, async: false
  @moduletag with_store: true

  alias LemonCore.ExecApprovals
  alias LemonCore.ExecApprovalStore
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
      :exec_approvals_policy_node,
      :introspection_log
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

    test "records redacted approval lifecycle introspection events" do
      action = %{type: "mcp_sampling", prompt: "secret prompt"}
      run_id = "run_approval_introspection"

      task =
        Task.async(fn ->
          ExecApprovals.request(%{
            run_id: run_id,
            session_key: "agent:test:main",
            agent_id: "test",
            tool: "mcp_elixir_sampling",
            action: action,
            rationale: "needs review",
            expires_in_ms: 5000
          })
        end)

      Process.sleep(100)

      {_key, pending} = hd(Store.list(:exec_approvals_pending))
      :ok = ExecApprovals.resolve(pending.id, :deny)

      assert {:ok, :denied} = Task.await(task, 1000)

      events = LemonCore.Introspection.list(run_id: run_id, limit: 10)
      requested = Enum.find(events, &(&1.event_type == :approval_requested))
      resolved = Enum.find(events, &(&1.event_type == :approval_resolved))

      assert requested.payload.approval_id == pending.id
      assert requested.payload.tool == "mcp_elixir_sampling"
      assert requested.payload.action_type == "mcp_sampling"
      assert is_binary(requested.payload.action_hash)
      assert Map.fetch!(requested.payload, :rationale_present?) == true

      assert resolved.payload.approval_id == pending.id
      assert resolved.payload.decision == "deny"
      assert resolved.payload.scope == "deny"
      assert Map.fetch!(resolved.payload, :approved?) == false

      refute inspect(events) =~ "secret prompt"
    end

    test "returns timeout when approval times out" do
      action = %{command: "ls"}
      LemonCore.Bus.subscribe("exec_approvals")

      task =
        Task.async(fn ->
          ExecApprovals.request(%{
            run_id: "run_123",
            session_key: "agent:test:main",
            tool: "bash",
            action: action,
            expires_in_ms: 50
          })
        end)

      assert_receive %LemonCore.Event{
                       type: :approval_requested,
                       payload: %{pending: %{tool: "bash"}}
                     },
                     1_000

      assert_receive %LemonCore.Event{
                       type: :approval_resolved,
                       payload: %{decision: :timeout, pending: %{tool: "bash"}}
                     },
                     1_000

      assert {:error, :timeout} = Task.await(task, 1_000)

      event =
        LemonCore.Introspection.list(run_id: "run_123", event_type: :approval_timed_out, limit: 1)
        |> List.first()

      assert event.payload.tool == "bash"
      assert is_binary(event.payload.action_hash)
    end

    test "broadcasts approval timeout with pending metadata" do
      LemonCore.Bus.subscribe("exec_approvals")

      task =
        Task.async(fn ->
          ExecApprovals.request(%{
            run_id: "run_timeout_broadcast",
            session_key: "agent:test:timeout",
            agent_id: "test",
            tool: "bash",
            action: %{command: "sleep"},
            expires_in_ms: 50
          })
        end)

      assert_receive %LemonCore.Event{
                       type: :approval_requested,
                       payload: %{pending: %{id: approval_id}}
                     },
                     1_000

      assert_receive %LemonCore.Event{
                       type: :approval_resolved,
                       payload: %{
                         approval_id: ^approval_id,
                         decision: :timeout,
                         pending: %{
                           run_id: "run_timeout_broadcast",
                           session_key: "agent:test:timeout",
                           agent_id: "test",
                           tool: "bash"
                         }
                       },
                       meta: %{run_id: "run_timeout_broadcast", session_key: "agent:test:timeout"}
                     },
                     1_000

      assert {:error, :timeout} = Task.await(task, 1_000)
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

      assert Store.get(:exec_approvals_policy_session, {"agent:test:main", "bash", action_hash}) ==
               nil
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

    test "reports :not_pending for an approval that is not pending" do
      assert {:error, :not_pending} = ExecApprovals.resolve("non_existent_id", :approve_once)
    end
  end

  describe "atomic cancel/resolve transition" do
    test "take_pending hands the record to exactly one taker" do
      pending = %{id: "approval_take", tool: "bash", run_id: "run_123"}
      Store.put(:exec_approvals_pending, pending.id, pending)

      assert {%{id: "approval_take"}, nil} =
               {ExecApprovalStore.take_pending(pending.id),
                ExecApprovalStore.take_pending(pending.id)}

      assert Store.get(:exec_approvals_pending, pending.id) == nil
    end

    test "resolve after cancel loses and installs no policy" do
      pending = %{
        id: "approval_c1",
        run_id: "run_123",
        session_key: "agent:test:main",
        agent_id: "test",
        tool: "bash",
        action: %{command: "ls"}
      }

      Store.put(:exec_approvals_pending, pending.id, pending)

      assert :ok = ExecApprovals.cancel(pending.id, "dispatch ended")
      assert {:error, :not_pending} = ExecApprovals.resolve(pending.id, :approve_global)

      assert Store.get(:exec_approvals_policy, {"bash", hash_action(pending.action)}) == nil
    end

    test "cancel after resolve loses and leaves the decision standing" do
      pending = %{
        id: "approval_c2",
        run_id: "run_123",
        session_key: "agent:test:main",
        agent_id: "test",
        tool: "bash",
        action: %{command: "ls"}
      }

      Store.put(:exec_approvals_pending, pending.id, pending)

      assert :ok = ExecApprovals.resolve(pending.id, :approve_session)
      assert {:error, :not_pending} = ExecApprovals.cancel(pending.id, "dispatch ended")

      assert Store.get(
               :exec_approvals_policy_session,
               {"agent:test:main", "bash", hash_action(pending.action)}
             ).approved ==
               true
    end

    test "a concurrent cancel-vs-resolve storm has exactly one winner" do
      pending = %{
        id: "approval_storm",
        run_id: "run_123",
        session_key: "agent:test:main",
        agent_id: "test",
        tool: "bash",
        action: %{command: "ls"}
      }

      Store.put(:exec_approvals_pending, pending.id, pending)

      callers =
        for i <- 1..16 do
          Task.async(fn ->
            if rem(i, 2) == 0,
              do: ExecApprovals.resolve(pending.id, :approve_global),
              else: ExecApprovals.cancel(pending.id, "dispatch ended")
          end)
        end

      results = Task.await_many(callers, 5_000)

      # Exactly one caller won the atomic transition; every loser reported
      # :not_pending with no side effects.
      assert Enum.count(results, &(&1 == :ok)) == 1
      assert Enum.count(results, &(&1 == {:error, :not_pending})) == 15
      assert Store.get(:exec_approvals_pending, pending.id) == nil

      global = Store.get(:exec_approvals_policy, {"bash", hash_action(pending.action)})
      assert global == nil or global.approved == true
    end

    test "a timeout that wins the atomic take leaves nothing for a late resolve" do
      run_id = "run_timeout_take_#{System.unique_integer([:positive])}"
      approval_id = "timeout_take_#{System.unique_integer([:positive])}"

      task =
        Task.async(fn ->
          ExecApprovals.request(%{
            run_id: run_id,
            session_key: "agent:test:main",
            tool: "bash",
            action: %{command: "ls"},
            approval_id: approval_id,
            expires_in_ms: 25
          })
        end)

      assert {:error, :timeout} = Task.await(task, 1_000)

      # The timeout won `take_pending`: the decision and its events belong
      # to the timeout alone, and a late resolve loses without side effects.
      assert {:error, :not_pending} = ExecApprovals.resolve(approval_id, :approve_global)

      assert Store.get(:exec_approvals_policy, {"bash", hash_action(%{command: "ls"})}) == nil
      assert Store.get(:exec_approvals_pending, approval_id) == nil

      assert LemonCore.Introspection.list(
               run_id: run_id,
               event_type: :approval_timed_out,
               limit: 1
             )
             |> List.first()
             |> Map.get(:payload)
             |> Map.get(:approval_id) == approval_id
    end

    test "timeout and resolve queued together have one winner with no double side effects" do
      action = %{command: "ls"}
      action_hash = hash_action(action)
      approval_id = "timeout_race_#{System.unique_integer([:positive])}"
      store = Process.whereis(Store)

      assert is_pid(store)
      LemonCore.Bus.subscribe("exec_approvals")

      request_task =
        Task.async(fn ->
          ExecApprovals.request(%{
            run_id: "run_123",
            session_key: "agent:test:main",
            tool: "bash",
            action: action,
            approval_id: approval_id,
            expires_in_ms: 1_000
          })
        end)

      # The request event is the registration barrier: put_pending/2 happens
      # before this broadcast, so the race below cannot accidentally resolve
      # an id that has not been registered yet.
      assert_receive %LemonCore.Event{
                       type: :approval_requested,
                       payload: %{approval_id: ^approval_id}
                     },
                     1_000

      on_exit(fn -> safe_resume(store) end)
      :ok = :sys.suspend(store)

      resolve_task =
        try do
          # Hold the Store until the waiter's deadline transition is queued,
          # then queue resolve's take behind it. With the old get+delete
          # timeout path both callers could receive the same pending record;
          # the single take path hands it only to the timeout.
          assert :ok =
                   LemonCore.Testing.AsyncHelpers.assert_eventually(
                     fn -> queued_pending_transitions(store, approval_id) == 1 end,
                     timeout: 2_000,
                     interval: 1,
                     message: "timeout transition was never queued"
                   )

          task =
            Task.async(fn ->
              ExecApprovals.resolve(approval_id, :approve_session)
            end)

          assert :ok =
                   LemonCore.Testing.AsyncHelpers.assert_eventually(
                     fn -> queued_pending_transitions(store, approval_id) == 2 end,
                     timeout: 1_000,
                     interval: 1,
                     message: "resolve transition was never queued"
                   )

          task
        after
          safe_resume(store)
        end

      assert {:error, :timeout} = Task.await(request_task, 1_000)
      assert {:error, :not_pending} = Task.await(resolve_task, 1_000)
      assert Store.get(:exec_approvals_pending, approval_id) == nil

      assert Store.get(:exec_approvals_policy_session, {
               "agent:test:main",
               "bash",
               action_hash
             }) == nil

      assert_receive %LemonCore.Event{
                       type: :approval_resolved,
                       payload: %{approval_id: ^approval_id, decision: :timeout}
                     },
                     1_000

      refute_receive %LemonCore.Event{
        type: :approval_resolved,
        payload: %{approval_id: ^approval_id}
      }
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

  defp queued_pending_transitions(store, approval_id) do
    {:messages, messages} = Process.info(store, :messages)

    Enum.count(messages, fn
      {:"$gen_call", _from, {operation, :exec_approvals_pending, ^approval_id}}
      when operation in [:generic_get, :generic_take] ->
        true

      _other ->
        false
    end)
  end

  defp safe_resume(store) do
    if Process.alive?(store) do
      try do
        _ = :sys.resume(store)
        :ok
      catch
        :exit, _reason -> :ok
      end
    else
      :ok
    end
  end

  # Helper function to match the module's hashing
  defp hash_action(action) when is_map(action) do
    :crypto.hash(:sha256, :erlang.term_to_binary(action))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end
end
