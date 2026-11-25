defmodule LemonCore.ExecApprovalsGrantOrderTest do
  @moduledoc """
  Grant installation is ordered after the approval's completion CAS, and a
  store mutation whose call timed out reports `:outcome_unknown`.

  The real `LemonCore.Store` process is stalled on one exact request with a
  `:sys` debug hook, so each test interleaves at the real store boundary.
  """
  use LemonCore.Testing.Case, async: false
  @moduletag with_store: true

  alias LemonCore.ExecApprovals
  alias LemonCore.ExecApprovalStore
  alias LemonCore.Store

  @session_key "agent:test:main"
  @policy_tables [
    :exec_approvals_policy,
    :exec_approvals_policy_agent,
    :exec_approvals_policy_session,
    :exec_approvals_timeout_scratch
  ]

  setup do
    if Process.whereis(LemonCore.PubSub) == nil do
      start_supervised!({Phoenix.PubSub, name: LemonCore.PubSub})
    end

    clear_tables()
    on_exit(&clear_tables/0)
    :ok
  end

  test "a losing completion CAS installs no grant and leaves the command unapproved" do
    action = %{command: "rm -rf /tmp/lost-cas-#{System.unique_integer([:positive])}"}
    pending = pending_record(action)
    :ok = ExecApprovalStore.put_pending(pending.id, pending)
    LemonCore.Bus.subscribe("exec_approvals")

    store = Process.whereis(Store)

    competing = %{
      resolution: %{
        approval_id: pending.id,
        session_key: pending.session_key,
        run_id: pending.run_id,
        decision: :expired,
        outcome: :expired,
        resolved_at_ms: LemonCore.Clock.now_ms(),
        pending_hash: :crypto.hash(:sha256, :erlang.term_to_binary(pending))
      }
    }

    # Stall the store on the resolver's claim, queue a competing owner write
    # behind it, then let both run: the claim wins, the competitor replaces it,
    # and the resolver's completion CAS loses.
    stall = stall_on(store, &claim_cas?(&1, pending))
    resolver = Task.async(fn -> ExecApprovals.resolve(pending.id, :approve_session) end)
    stalled = await_stall(stall)

    competitor = Task.async(fn -> Store.put(:exec_approvals_pending, pending.id, competing) end)
    await_queued(store, &match?({:generic_put, :exec_approvals_pending, _, ^competing}, &1))
    release(stall, stalled)

    assert :ok = Task.await(competitor, 5_000)
    assert {:error, _} = Task.await(resolver, 10_000)

    assert {:ok, ^competing} = ExecApprovalStore.fetch_record(pending.id)
    assert policy_rows() == []

    refute_receive %LemonCore.Event{
      type: :approval_resolved,
      payload: %{approval_id: _, decision: :approve_session}
    }

    assert_not_auto_approved(action)
  end

  test "a grant write that times out after completion surfaces :outcome_unknown, never cancelled" do
    action = %{command: "deploy-#{System.unique_integer([:positive])}"}
    approval_id = "grant_timeout_#{System.unique_integer([:positive])}"
    LemonCore.Bus.subscribe("exec_approvals")

    request =
      Task.async(fn ->
        ExecApprovals.request(%{
          run_id: "run_#{approval_id}",
          session_key: @session_key,
          agent_id: "test",
          tool: "bash",
          action: action,
          approval_id: approval_id
        })
      end)

    assert_receive %LemonCore.Event{
                     type: :approval_requested,
                     payload: %{approval_id: ^approval_id}
                   },
                   1_000

    store = Process.whereis(Store)
    stall = stall_on(store, &grant_put?/1)
    resolver = Task.async(fn -> ExecApprovals.resolve(approval_id, :approve_session) end)
    stalled = await_stall(stall)

    # Hold the grant write past the store call timeout, then let it apply late.
    Process.sleep(5_300)
    release(stall, stalled)

    assert {:error, :outcome_unknown} = Task.await(resolver, 10_000)
    assert {:error, :outcome_unknown} = Task.await(request, 10_000)

    assert_receive %LemonCore.Event{
                     type: :approval_resolved,
                     payload: %{approval_id: ^approval_id, decision: :outcome_unknown}
                   },
                   1_000

    # Exactly one resolution event: never a cancelled/denied/approved one.
    refute_receive %LemonCore.Event{
      type: :approval_resolved,
      payload: %{approval_id: ^approval_id}
    }

    # A late-applied grant is only ever backed by a completed approval receipt.
    assert {:ok, %{resolution: %{outcome: :approved, decision: :approve_session}}} =
             ExecApprovalStore.fetch_record(approval_id)
  end

  test "killing the resolver between receipt and grant writes leaves no executable grant" do
    action = %{command: "chaos-#{System.unique_integer([:positive])}"}
    pending = pending_record(action)
    :ok = ExecApprovalStore.put_pending(pending.id, pending)

    store = Process.whereis(Store)

    # Stall on the first write after the claim, kill the resolver there, then
    # let only that one queued write apply.
    stall = stall_on(store, fn request -> grant_put?(request) or completion_cas?(request) end)
    resolver = spawn(fn -> ExecApprovals.resolve(pending.id, :approve_global) end)
    stalled = await_stall(stall)
    Process.exit(resolver, :kill)
    release(stall, stalled)

    _ = :sys.get_state(store)

    assert policy_rows() == []
    assert {:ok, %{resolution: %{approval_id: id}}} = ExecApprovalStore.fetch_record(pending.id)
    assert id == pending.id
    assert_not_auto_approved(action)
  end

  test "every non-durable mutation that times out reports :outcome_unknown" do
    store = Process.whereis(Store)
    table = :exec_approvals_timeout_scratch
    key = fn name -> {"timeout-node", name, "hash"} end
    :ok = Store.put(table, key.("cas"), :old)
    :ok = Store.put(table, key.("delete"), :old)
    :ok = Store.put(table, key.("take"), :old)

    stall = stall_on(store, &match?({:generic_put, ^table, {"timeout-node", "put", _}, _}, &1))

    calls = [
      fn -> Store.put(table, key.("put"), :new) end,
      fn -> Store.put_new(table, key.("put_new"), :new) end,
      fn -> Store.compare_and_swap(table, key.("cas"), :old, :new) end,
      fn -> Store.delete(table, key.("delete")) end,
      fn -> Store.take(table, key.("take")) end
    ]

    [first | rest] = calls
    first = Task.async(first)
    stalled = await_stall(stall)
    tasks = [first | Enum.map(rest, &Task.async/1)]
    Process.sleep(5_300)
    release(stall, stalled)

    for task <- tasks do
      assert {:error, :outcome_unknown} = Task.await(task, 10_000)
    end
  end

  describe "run-end fence" do
    test "a run finalized before the claim, with expiry not yet processed, installs no grant" do
      action = %{command: "fence-#{System.unique_integer([:positive])}"}
      pending = pending_record(action)
      :ok = ExecApprovalStore.put_pending(pending.id, pending)
      LemonCore.Bus.subscribe("exec_approvals")

      # Hold the expiry worker on this run's expiry notification while still
      # answering readiness probes, so the finalizer's async scan is delayed.
      expiry = Process.whereis(LemonCore.ExecApprovalExpiry)
      run_id = pending.run_id
      test = self()
      ref = make_ref()

      hold = fn hold ->
        receive do
          {^ref, :release} ->
            :done

          {:"$gen_call", from, :ready} ->
            GenServer.reply(from, :ok)
            hold.(hold)
        after
          15_000 -> :done
        end
      end

      hook = fn
        :armed, {:in, {:"$gen_cast", {:expire, {:run, ^run_id}}}}, _proc ->
          send(test, {ref, :stalled, self()})
          hold.(hold)

        state, _event, _proc ->
          state
      end

      :ok = :sys.install(expiry, {hook, :armed})

      on_exit(fn ->
        try do
          :sys.remove(expiry, hook, 20_000)
        catch
          :exit, _ -> :ok
        end
      end)

      assert :ok = finalize(run_id)
      assert_receive {^ref, :stalled, ^expiry}, 5_000
      assert {:ok, %{id: _}} = ExecApprovalStore.fetch_pending(pending.id)

      assert {:error, :expired} = ExecApprovals.resolve(pending.id, :approve_session)
      send(expiry, {ref, :release})
      assert policy_rows() == []

      assert {:ok, %{resolution: %{outcome: :expired, decision: :expired}}} =
               ExecApprovalStore.fetch_record(pending.id)

      assert_receive %LemonCore.Event{
        type: :approval_resolved,
        payload: %{approval_id: id, decision: :expired}
      }

      assert id == pending.id
      refute_receive %LemonCore.Event{type: :approval_resolved}
      assert_not_auto_approved(action)
    end
  end

  describe "outcome_unknown through every approval mutation" do
    test "a claim timeout settles the waiter as unknown" do
      {waiter, pending} = start_waiter()

      assert {:error, :outcome_unknown} =
               timed_out(&claim_cas?(&1, pending), fn ->
                 ExecApprovals.resolve(pending.id, :approve_session)
               end)

      assert_settled_unknown(waiter, pending)
    end

    test "a denial whose completion times out is unknown, not denied" do
      {waiter, pending} = start_waiter()

      assert {:error, :outcome_unknown} =
               timed_out(&completion_cas?/1, fn -> ExecApprovals.resolve(pending.id, :deny) end)

      assert_settled_unknown(waiter, pending)
    end

    test "an expiry whose completion times out is unknown, not timed out" do
      pending =
        Map.put(pending_record(%{command: "late"}), :expires_at_ms, LemonCore.Clock.now_ms() - 1)

      :ok = ExecApprovalStore.put_pending(pending.id, pending)
      LemonCore.Bus.subscribe("exec_approvals")

      assert {:error, :outcome_unknown} =
               timed_out(&completion_cas?/1, fn ->
                 ExecApprovals.resolve(pending.id, :approve_once)
               end)

      id = pending.id

      assert_receive %LemonCore.Event{
        type: :approval_resolved,
        payload: %{approval_id: ^id, decision: :outcome_unknown}
      }

      refute_receive %LemonCore.Event{type: :approval_resolved, payload: %{approval_id: ^id}}
      assert policy_rows() == []
    end

    test "an owner-expiry write that times out is unknown, not expired" do
      {waiter, pending} = start_waiter()

      assert {:error, :outcome_unknown} =
               timed_out(&claim_cas?(&1, pending), fn ->
                 ExecApprovals.expire_owner({:run, pending.run_id})
               end)

      assert_settled_unknown(waiter, pending)
    end

    test "a cancellation timeout settles the waiter as unknown" do
      {waiter, pending} = start_waiter()

      assert {:error, :outcome_unknown} =
               timed_out(&claim_cas?(&1, pending), fn -> ExecApprovals.cancel(pending.id) end)

      assert_settled_unknown(waiter, pending)
    end

    test "a pending-creation timeout is unknown, not unavailable" do
      assert {:error, :outcome_unknown} =
               timed_out(&match?({:generic_put_new, :exec_approvals_pending, _, _}, &1), fn ->
                 ExecApprovals.request(request_params("create"))
               end)
    end

    test "a waiter-timeout write that times out is unknown, not a confirmed timeout" do
      params = Map.put(request_params("wait"), :expires_in_ms, 200)
      id = params.approval_id
      LemonCore.Bus.subscribe("exec_approvals")

      predicate = fn
        {:generic_compare_and_swap, :exec_approvals_pending, ^id, expected, _} ->
          not Map.has_key?(expected, :resolution)

        _ ->
          false
      end

      assert {:error, :outcome_unknown} =
               timed_out(predicate, fn -> ExecApprovals.request(params) end)

      assert_receive %LemonCore.Event{
        type: :approval_resolved,
        payload: %{approval_id: ^id, decision: :outcome_unknown}
      }

      refute_receive %LemonCore.Event{
        type: :approval_resolved,
        payload: %{approval_id: ^id, decision: :timeout}
      }
    end

    test "settle_unknown wakes the waiter as unknown and later resolution never replays" do
      {waiter, pending} = start_waiter()

      assert :ok =
               ExecApprovals.settle_unknown(pending.id,
                 expected_run_id: pending.run_id,
                 expected_session_key: pending.session_key
               )

      assert_settled_unknown(waiter, pending)
      assert {:error, :outcome_unknown} = ExecApprovals.resolve(pending.id, :approve_session)
      assert policy_rows() == []
    end
  end

  defp request_params(tag) do
    id = "unknown_#{tag}_#{System.unique_integer([:positive])}"

    %{
      run_id: "run_#{id}",
      session_key: @session_key,
      agent_id: "test",
      tool: "bash",
      action: %{command: id},
      approval_id: id
    }
  end

  defp start_waiter do
    params = request_params("waiter")
    id = params.approval_id
    LemonCore.Bus.subscribe("exec_approvals")
    waiter = Task.async(fn -> ExecApprovals.request(params) end)

    assert_receive %LemonCore.Event{
                     type: :approval_requested,
                     payload: %{approval_id: ^id, pending: pending}
                   },
                   1_000

    {waiter, pending}
  end

  defp assert_settled_unknown(waiter, pending) do
    id = pending.id
    assert {:error, :outcome_unknown} = Task.await(waiter, 5_000)

    assert_receive %LemonCore.Event{
      type: :approval_resolved,
      payload: %{approval_id: ^id, decision: :outcome_unknown}
    }

    refute_receive %LemonCore.Event{type: :approval_resolved, payload: %{approval_id: ^id}}
    assert policy_rows() == []
  end

  # Runs `fun` while the real store is held on the first matching call past the
  # client call timeout, then lets that call apply late.
  defp timed_out(predicate, fun) do
    stall = stall_on(Process.whereis(Store), predicate)
    task = Task.async(fun)
    stalled = await_stall(stall)
    Process.sleep(5_300)
    release(stall, stalled)
    Task.await(task, 10_000)
  end

  defp finalize(run_id) do
    Store.finalize_run(run_id, %{ok: true, session_key: @session_key})
  end

  defp pending_record(action) do
    id = "grant_order_#{System.unique_integer([:positive])}"

    %{
      id: id,
      run_id: "run_#{id}",
      session_key: @session_key,
      agent_id: "test",
      tool: "bash",
      action: action,
      requested_at_ms: LemonCore.Clock.now_ms()
    }
  end

  defp assert_not_auto_approved(action) do
    assert {:error, :timeout} =
             ExecApprovals.request(%{
               run_id: "run_probe_#{System.unique_integer([:positive])}",
               session_key: @session_key,
               agent_id: "test",
               tool: "bash",
               action: action,
               expires_in_ms: 100
             })
  end

  defp claim_cas?(
         {:generic_compare_and_swap, :exec_approvals_pending, _id, expected, _},
         pending
       ),
       do: expected == pending

  defp claim_cas?(_, _), do: false

  defp completion_cas?(
         {:generic_compare_and_swap, :exec_approvals_pending, _id,
          %{resolution: %{outcome: :resolving}}, _}
       ),
       do: true

  defp completion_cas?(_), do: false

  defp grant_put?({:generic_put, table, _key, %{approved: true}}), do: table in @policy_tables
  defp grant_put?(_), do: false

  defp policy_rows do
    Enum.flat_map(@policy_tables, &Store.list/1)
  end

  # Blocks the store process inside its own debug hook when the first matching
  # call arrives, until `release/2`.
  defp stall_on(store, predicate) do
    test = self()
    ref = make_ref()

    hook = fn
      :done, _event, _proc ->
        :done

      :armed, {:in, {:"$gen_call", _from, request}}, _proc ->
        if predicate.(request) do
          send(test, {ref, :stalled, self()})

          receive do
            {^ref, :release} -> :done
          after
            15_000 -> :done
          end
        else
          :armed
        end

      state, _event, _proc ->
        state
    end

    :ok = :sys.install(store, {hook, :armed})

    on_exit(fn ->
      try do
        :sys.remove(store, hook, 20_000)
      catch
        :exit, _ -> :ok
      end
    end)

    {store, ref}
  end

  defp await_stall({_store, ref}) do
    assert_receive {^ref, :stalled, pid}, 5_000
    pid
  end

  defp release({_store, ref}, pid), do: send(pid, {ref, :release})

  defp await_queued(store, predicate) do
    LemonCore.Testing.AsyncHelpers.assert_eventually(
      fn ->
        {:messages, messages} = Process.info(store, :messages)

        Enum.any?(messages, fn
          {:"$gen_call", _from, request} -> predicate.(request)
          _ -> false
        end)
      end,
      timeout: 2_000,
      interval: 1
    )
  end

  defp clear_tables do
    Enum.each([:exec_approvals_pending | @policy_tables], fn table ->
      Enum.each(Store.list(table), fn {key, _} -> Store.delete(table, key) end)
    end)
  end
end
