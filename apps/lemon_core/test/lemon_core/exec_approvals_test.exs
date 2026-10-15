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

  # Waits for a request running in another process to create its pending approval.
  defp await_pending_approvals do
    LemonCore.Testing.AsyncHelpers.assert_eventually(
      fn -> ExecApprovalStore.list_pending() != [] end,
      timeout: 5_000
    )

    ExecApprovalStore.list_pending()
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

      # Wait for the request to create the pending approval
      pending_list = await_pending_approvals()

      # Verify pending approval was created
      assert length(pending_list) == 1

      {_key, pending} = hd(pending_list)
      assert pending.tool == "bash"
      assert pending.run_id == "run_123"
      assert pending.action == action

      # Resolve the approval
      ExecApprovals.resolve(pending.id, :approve_once)

      # Wait for the result
      assert {:ok, :approved, :approve_once} = Task.await(task, 5_000)
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

      # Get the pending approval once the request created it
      pending_list = await_pending_approvals()
      {_key, pending} = hd(pending_list)

      # Deny the approval
      ExecApprovals.resolve(pending.id, :deny)

      assert {:ok, :denied} = Task.await(task, 5_000)
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

      {_key, pending} = hd(await_pending_approvals())
      {:ok, %{decision: :deny, outcome: :denied}} = ExecApprovals.resolve(pending.id, :deny)

      assert {:ok, :denied} = Task.await(task, 5_000)

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

      {:ok, %{decision: :approve_session, outcome: :approved}} =
        ExecApprovals.resolve(pending.id, :approve_session)

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

      {:ok, %{decision: :approve_agent, outcome: :approved}} =
        ExecApprovals.resolve(pending.id, :approve_agent)

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

      {:ok, %{decision: :approve_global, outcome: :approved}} =
        ExecApprovals.resolve(pending.id, :approve_global)

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

      {:ok, %{decision: :approve_once, outcome: :approved}} =
        ExecApprovals.resolve(pending.id, :approve_once)

      # Verify no approval was stored
      action_hash = hash_action(pending.action)
      assert Store.get(:exec_approvals_policy, {"bash", action_hash}) == nil
      assert Store.get(:exec_approvals_policy_agent, {"test", "bash", action_hash}) == nil

      assert Store.get(:exec_approvals_policy_session, {"agent:test:main", "bash", action_hash}) ==
               nil
    end

    test "removes completed approval from pending accessors" do
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

      {:ok, %{decision: :approve_once, outcome: :approved}} =
        ExecApprovals.resolve(pending.id, :approve_once)

      assert ExecApprovalStore.get_pending(pending.id) == nil
    end

    test "reports :not_found for an unknown approval" do
      assert {:error, :not_found} = ExecApprovals.resolve("non_existent_id", :approve_once)
    end
  end

  describe "private invocation-context standing grants" do
    test "session and agent grants authorize only the exact team context" do
      LemonCore.Bus.subscribe("exec_approvals")

      for {decision, scope} <- [{:approve_session, :session}, {:approve_agent, :agent}] do
        run_id = "team_context_A_#{scope}"

        params = %{
          run_id: run_id,
          session_key: "agent:team-bot:shared",
          agent_id: "team-bot",
          invocation_context_key: "principal-A:policy-v1:#{scope}",
          tool: "bash",
          action: %{command: "team-context-action-#{scope}"},
          expires_in_ms: 5_000
        }

        task = Task.async(fn -> ExecApprovals.request(params) end)

        assert_receive %LemonCore.Event{
                         type: :approval_requested,
                         payload: %{pending: %{run_id: ^run_id} = pending}
                       },
                       1_000

        assert pending.session_key == params.session_key
        assert pending.agent_id == params.agent_id
        assert pending.invocation_context_key == params.invocation_context_key
        assert {:ok, ^pending} = ExecApprovalStore.fetch_pending(pending.id)
        encoded = Jason.encode!(pending)
        refute encoded =~ params.invocation_context_key
        refute encoded =~ "invocation_context_key"

        assert {:ok, receipt} =
                 ExecApprovals.resolve(pending.id, decision,
                   expected_session_key: params.session_key,
                   expected_run_id: run_id
                 )

        assert receipt.decision == decision
        refute inspect(receipt) =~ params.invocation_context_key
        assert Task.await(task) == {:ok, :approved, decision}

        # Another run with the same trusted principal/policy context retains
        # the standing grant; changing context on the same public team key does not.
        assert ExecApprovals.request(%{params | run_id: "same_A_#{scope}"}) ==
                 {:ok, :approved, scope}

        other_run = "team_context_B_#{scope}"

        other_params = %{
          params
          | run_id: other_run,
            invocation_context_key: "principal-B:policy-v1:#{scope}"
        }

        other_task = Task.async(fn -> ExecApprovals.request(other_params) end)

        assert_receive %LemonCore.Event{
                         type: :approval_requested,
                         payload: %{pending: %{run_id: ^other_run} = other_pending}
                       },
                       1_000

        assert other_pending.session_key == params.session_key
        assert other_pending.agent_id == params.agent_id
        assert {:ok, %{outcome: :denied}} = ExecApprovals.resolve(other_pending.id, :deny)
        assert Task.await(other_task) == {:ok, :denied}

        # Legacy-native grants remain usable only in the legacy namespace.
        legacy_run = "legacy_context_#{scope}"
        legacy_params = %{params | run_id: legacy_run, invocation_context_key: nil}
        legacy_task = Task.async(fn -> ExecApprovals.request(legacy_params) end)

        assert_receive %LemonCore.Event{
                         type: :approval_requested,
                         payload: %{pending: %{run_id: ^legacy_run} = legacy_pending}
                       },
                       1_000

        assert {:ok, %{outcome: :approved}} =
                 ExecApprovals.resolve(legacy_pending.id, decision)

        assert Task.await(legacy_task) == {:ok, :approved, decision}

        assert ExecApprovals.request(%{legacy_params | run_id: "same_legacy_#{scope}"}) ==
                 {:ok, :approved, scope}

        changed_run = "changed_policy_#{scope}"

        changed_params = %{
          params
          | run_id: changed_run,
            invocation_context_key: "principal-A:policy-v2:#{scope}"
        }

        changed_task = Task.async(fn -> ExecApprovals.request(changed_params) end)

        assert_receive %LemonCore.Event{
                         type: :approval_requested,
                         payload: %{pending: %{run_id: ^changed_run} = changed_pending}
                       },
                       1_000

        assert {:ok, %{outcome: :denied}} = ExecApprovals.resolve(changed_pending.id, :deny)
        assert Task.await(changed_task) == {:ok, :denied}
      end
    end

    test "explicit global and node administrator grants remain distinct" do
      for {scope, tool} <- [{:global, "global_tool"}, {:node, "node_tool"}] do
        action = %{command: "admin-scoped-action"}
        approval = %{approved: true, scope: scope}

        case scope do
          :global ->
            ExecApprovalStore.put_global_policy(tool, hash_action(action), approval)

          :node ->
            ExecApprovalStore.put_node_policy("admin-node", tool, hash_action(action), approval)
        end

        for context <- ["principal-A", "principal-B"] do
          assert ExecApprovals.request(%{
                   run_id: "admin_#{scope}_#{context}",
                   session_key: "agent:team-bot:shared",
                   agent_id: "team-bot",
                   invocation_context_key: context,
                   node_id: "admin-node",
                   tool: tool,
                   action: action
                 }) == {:ok, :approved, scope}
        end
      end
    end
  end

  describe "verified bound resolutions" do
    test "foreign session and run bindings never consume or authorize the live request" do
      LemonCore.Bus.subscribe("exec_approvals")

      task =
        Task.async(fn ->
          ExecApprovals.request(%{
            approval_id: "approval_bound",
            run_id: "run_bound",
            session_key: "agent:test:bound",
            tool: "bash",
            action: %{command: "bound command"},
            expires_in_ms: 5_000
          })
        end)

      assert_receive %LemonCore.Event{
                       type: :approval_requested,
                       payload: %{pending: pending}
                     },
                     1_000

      assert {:error, :mismatch} =
               ExecApprovals.resolve(pending.id, :approve_global,
                 expected_session_key: "agent:other:bound",
                 expected_run_id: pending.run_id
               )

      assert {:error, :mismatch} =
               ExecApprovals.resolve(pending.id, :approve_session,
                 expected_session_key: pending.session_key,
                 expected_run_id: "run_other"
               )

      assert ExecApprovalStore.get_pending(pending.id) == pending
      assert ExecApprovalStore.get_global_policy("bash", hash_action(pending.action)) == nil

      assert ExecApprovalStore.get_session_policy(
               pending.session_key,
               "bash",
               hash_action(pending.action)
             ) == nil

      refute_receive %LemonCore.Event{type: :approval_resolved}

      assert {:ok, %{outcome: :denied, decision: :deny, replayed: false}} =
               ExecApprovals.resolve(pending.id, :deny,
                 expected_session_key: pending.session_key,
                 expected_run_id: pending.run_id
               )

      assert {:ok, :denied} = Task.await(task)
    end

    test "same-decision replay requires both identities and retained completed owner state" do
      pending = %{
        id: "approval_replay",
        run_id: "run_replay",
        session_key: "agent:test:replay",
        agent_id: "test",
        tool: "bash",
        action: %{command: "private command"},
        rationale: "private rationale"
      }

      :ok = ExecApprovalStore.put_pending_new(pending.id, pending)
      LemonCore.Bus.subscribe("exec_approvals")
      opts = [expected_session_key: pending.session_key, expected_run_id: pending.run_id]

      assert {:ok, receipt} = ExecApprovals.resolve(pending.id, :approve_session, opts)
      assert receipt.decision == :approve_session
      assert receipt.outcome == :approved
      assert receipt.replayed == false
      assert_receive %LemonCore.Event{type: :approval_resolved}

      policy =
        ExecApprovalStore.get_session_policy(
          pending.session_key,
          pending.tool,
          hash_action(pending.action)
        )

      assert {:ok, replay} = ExecApprovals.resolve(pending.id, :approve_session, opts)
      assert replay == %{receipt | replayed: true}

      assert ExecApprovalStore.get_session_policy(
               pending.session_key,
               pending.tool,
               hash_action(pending.action)
             ) == policy

      refute_receive %LemonCore.Event{type: :approval_resolved}
      assert ExecApprovalStore.get_pending(pending.id) == nil

      assert {:error, :already_resolved} = ExecApprovals.resolve(pending.id, :approve_session)

      assert {:error, :already_resolved} =
               ExecApprovals.resolve(pending.id, :approve_session,
                 expected_session_key: pending.session_key
               )

      assert {:error, :mismatch} =
               ExecApprovals.resolve(pending.id, :approve_session,
                 expected_session_key: pending.session_key,
                 expected_run_id: "other_run"
               )

      assert {:error, :mismatch} =
               ExecApprovals.resolve(pending.id, :approve_session,
                 expected_session_key: "agent:other:replay",
                 expected_run_id: pending.run_id
               )

      assert {:error, :conflict} = ExecApprovals.resolve(pending.id, :deny, opts)

      assert {:error, :exists} =
               ExecApprovalStore.put_pending_new(pending.id, %{pending | run_id: "other_run"})

      assert {:ok, stored} = ExecApprovalStore.fetch_record(pending.id)
      refute inspect(stored) =~ "private command"
      refute inspect(stored) =~ "private rationale"

      :ok = ExecApprovalStore.delete_pending(pending.id)
      assert {:error, :not_found} = ExecApprovals.resolve(pending.id, :approve_session, opts)
    end

    test "competing bound decisions report the winner without duplicate grants or events" do
      LemonCore.Bus.subscribe("exec_approvals")

      task =
        Task.async(fn ->
          ExecApprovals.request(%{
            approval_id: "approval_winner",
            run_id: "run_winner",
            session_key: "agent:test:winner",
            tool: "bash",
            action: %{command: "winner"},
            expires_in_ms: 5_000
          })
        end)

      assert_receive %LemonCore.Event{
                       type: :approval_requested,
                       payload: %{pending: pending}
                     },
                     1_000

      opts = [expected_session_key: pending.session_key, expected_run_id: pending.run_id]

      callers =
        for i <- 1..12 do
          Task.async(fn ->
            decision = if rem(i, 2) == 0, do: :approve_session, else: :deny
            ExecApprovals.resolve(pending.id, decision, opts)
          end)
        end

      results = Task.await_many(callers)
      assert Enum.count(results, &match?({:ok, %{replayed: false}}, &1)) == 1
      {:ok, winner} = Enum.find(results, &match?({:ok, %{replayed: false}}, &1))

      assert Enum.all?(results, fn
               {:ok, receipt} ->
                 receipt.decision == winner.decision and receipt.outcome == winner.outcome

               {:error, reason} ->
                 reason in [:conflict, :resolution_in_progress]
             end)

      assert_receive %LemonCore.Event{
        type: :approval_resolved,
        payload: %{decision: decision}
      }

      assert decision == winner.decision
      refute_receive %LemonCore.Event{type: :approval_resolved}

      expected =
        if winner.outcome == :approved,
          do: {:ok, :approved, :approve_session},
          else: {:ok, :denied}

      assert Task.await(task) == expected
      assert {:ok, replay} = ExecApprovals.resolve(pending.id, winner.decision, opts)
      assert replay.replayed == true
      loser = if winner.decision == :deny, do: :approve_session, else: :deny
      assert {:error, :conflict} = ExecApprovals.resolve(pending.id, loser, opts)
    end
  end

  describe "exact approval previews" do
    test "changed preview and invalid decisions leave the live request pending" do
      pending = %{
        id: "approval_preview",
        run_id: "run_preview",
        session_key: "agent:test:main",
        agent_id: "test",
        tool: "bash",
        action: %{command: "first"},
        expires_at_ms: nil
      }

      :ok = ExecApprovalStore.put_pending(pending.id, pending)
      changed = %{pending | action: %{command: "second"}}
      :ok = ExecApprovalStore.put_pending(pending.id, changed)

      assert {:error, :mismatch} =
               ExecApprovals.resolve(pending.id, :approve_once, expected_pending: pending)

      assert {:error, :invalid_decision} = ExecApprovals.resolve(pending.id, :yes)
      assert {:ok, ^changed} = ExecApprovalStore.fetch_pending(pending.id)

      assert {:ok, %{decision: :approve_once}} =
               ExecApprovals.resolve(pending.id, :approve_once, expected_pending: changed)

      assert {:error, :already_resolved} =
               ExecApprovals.resolve(pending.id, :approve_once, expected_pending: changed)
    end

    test "an expired preview cannot install policy and wakes the waiter as timed out" do
      LemonCore.Bus.subscribe("exec_approvals")

      pending = %{
        id: "approval_expired",
        run_id: "run_expired",
        session_key: "agent:test:main",
        agent_id: "test",
        tool: "bash",
        action: %{command: "expired"},
        expires_at_ms: LemonCore.Clock.now_ms() - 1
      }

      :ok = ExecApprovalStore.put_pending(pending.id, pending)

      assert {:error, :expired} =
               ExecApprovals.resolve(pending.id, :approve_global, expected_pending: pending)

      assert {:ok, nil} = ExecApprovalStore.fetch_pending(pending.id)
      assert ExecApprovalStore.get_global_policy("bash", hash_action(pending.action)) == nil

      assert_receive %LemonCore.Event{
        type: :approval_resolved,
        payload: %{approval_id: "approval_expired", decision: :timeout}
      }
    end

    test "a second request cannot replace an existing exact approval ID" do
      pending = %{
        id: "approval_duplicate",
        run_id: "run_original",
        session_key: "agent:test:main",
        agent_id: "test",
        tool: "bash",
        action: %{command: "original"}
      }

      :ok = ExecApprovalStore.put_pending(pending.id, pending)

      assert {:error, :already_pending} =
               ExecApprovals.request(%{
                 approval_id: pending.id,
                 run_id: "run_replacement",
                 session_key: "agent:test:main",
                 tool: "bash",
                 action: %{command: "replacement"},
                 expires_in_ms: 10
               })

      assert {:ok, ^pending} = ExecApprovalStore.fetch_pending(pending.id)
    end
  end

  describe "atomic cancel/resolve transition" do
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
      assert {:error, :cancelled} = ExecApprovals.resolve(pending.id, :approve_global)

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

      assert {:ok, %{decision: :approve_session}} =
               ExecApprovals.resolve(pending.id, :approve_session)

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

      # Exactly one transition won. Losing resolvers report retained state;
      # cancellations never overwrite that state or install grants.
      assert Enum.count(results, &(match?({:ok, %{replayed: false}}, &1) or &1 == :ok)) == 1
      assert Enum.count(results, &match?({:error, _}, &1)) == 15
      assert ExecApprovalStore.get_pending(pending.id) == nil

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

      # The timeout's retained receipt rejects late resolution without grants.
      assert {:error, :expired} = ExecApprovals.resolve(approval_id, :approve_global)

      assert Store.get(:exec_approvals_policy, {"bash", hash_action(%{command: "ls"})}) == nil
      assert ExecApprovalStore.get_pending(approval_id) == nil

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

      # The request event is the registration barrier for the exact snapshot.
      assert_receive %LemonCore.Event{
                       type: :approval_requested,
                       payload: %{approval_id: ^approval_id}
                     },
                     1_000

      on_exit(fn -> safe_resume(store) end)
      :ok = :sys.suspend(store)

      resolve_task =
        try do
          # Hold Store until the exact-record timeout claim is queued, then
          # queue the resolver's owner read behind it. Only timeout may win.
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
      assert {:error, :expired} = Task.await(resolve_task, 1_000)
      assert ExecApprovalStore.get_pending(approval_id) == nil

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
      when operation in [:generic_get, :generic_fetch, :generic_take] ->
        true

      {:"$gen_call", _from,
       {:generic_compare_and_swap, :exec_approvals_pending, ^approval_id, _, _}} ->
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
