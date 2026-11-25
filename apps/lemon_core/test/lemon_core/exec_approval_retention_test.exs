defmodule LemonCore.ExecApprovalRetentionTest do
  @moduledoc """
  Owner-indexed expiry and terminal receipt retention (#694).
  """
  use ExUnit.Case, async: false

  alias LemonCore.{ExecApprovals, ExecApprovalStore, Store}

  @pending :exec_approvals_pending
  @index :exec_approval_owner_index

  setup do
    LemonCore.Bus.subscribe("exec_approvals")
    clear()

    on_exit(fn ->
      Application.delete_env(:lemon_core, :exec_approval_receipt_retention_ms)
      clear()
    end)

    :ok
  end

  test "run end reads only that run's approvals, not 10k unrelated terminal rows" do
    for i <- 1..10_000 do
      id = "unrelated-#{i}"

      :ok =
        Store.put(
          @pending,
          id,
          ExecApprovalStore.terminal_record(%{
            approval_id: id,
            session_key: "agent:test:other",
            run_id: "run-other-#{i}",
            decision: :deny,
            outcome: :denied,
            resolved_at_ms: 1,
            pending_hash: "digest"
          })
        )
    end

    {task, id} = request("owner-indexed", "run-owner-indexed", "session-owner-indexed")

    calls =
      store_calls(fn ->
        assert {:ok, 1} = ExecApprovals.expire_owner({:run, "run-owner-indexed"})
      end)

    refute Enum.any?(
             calls,
             &match?({op, _table} when op in [:generic_list, :generic_fetch_all], &1)
           )

    # Index read, record read, expiry CAS, index cleanup: independent of table size.
    assert Enum.count(calls, &match?({_op, table} when table in [@pending, @index], &1)) <= 8
    assert {:ok, :denied} = Task.await(task)
    assert {:error, :expired} = ExecApprovals.resolve(id, :approve_once)
    assert {:ok, []} = ExecApprovalStore.fetch_owner_index({:run, "run-owner-indexed"})

    # The session index no longer lists the expired approval either way.
    assert {:ok, 0} = ExecApprovals.expire_owner({:session, "session-owner-indexed"})
    assert {:ok, []} = ExecApprovalStore.fetch_owner_index({:session, "session-owner-indexed"})
  end

  test "terminal receipts are swept after retention and the tables stay bounded across a run loop" do
    Application.put_env(:lemon_core, :exec_approval_receipt_retention_ms, 1)
    before = length(Store.list(@pending))

    ids =
      for i <- 1..25 do
        {task, id} = request("loop-#{i}", "run-loop", "session-loop")
        assert {:ok, %{outcome: :denied}} = ExecApprovals.resolve(id, :deny)
        assert {:ok, :denied} = Task.await(task)
        id
      end

    # Resolution already removed the IDs from both owner indexes.
    assert {:ok, []} = ExecApprovalStore.fetch_owner_index({:run, "run-loop"})
    assert {:ok, []} = ExecApprovalStore.fetch_owner_index({:session, "session-loop"})
    assert length(Store.list(@pending)) == before + 25

    Process.sleep(5)
    send(Process.whereis(Store), :sweep_expired)
    assert :ok = Store.ping()

    assert length(Store.list(@pending)) == before
    assert Store.list(@index) == []

    for id <- ids do
      assert {:ok, nil} = ExecApprovalStore.fetch_record(id)
      assert {:error, :not_found} = ExecApprovals.resolve(id, :deny)
    end
  end

  test "pending requests are never swept" do
    Application.put_env(:lemon_core, :exec_approval_receipt_retention_ms, 1)
    {task, id} = request("unswept", "run-unswept", nil)

    Process.sleep(5)
    send(Process.whereis(Store), :sweep_expired)
    assert :ok = Store.ping()

    assert %{id: ^id} = ExecApprovalStore.get_pending(id)
    assert {:ok, 1} = ExecApprovals.expire_owner({:run, "run-unswept"})
    assert {:ok, :denied} = Task.await(task)
  end

  test "recovery stamps legacy terminal records so the sweep can remove them" do
    receipt = %{approval_id: "legacy-terminal", outcome: :denied, decision: :deny}
    :ok = Store.put(@pending, "legacy-terminal", %{resolution: receipt})

    assert {:ok, _count} = ExecApprovals.reconcile_runtime()

    assert {:ok, %{resolution: ^receipt, expires_at: stamp}} =
             ExecApprovalStore.fetch_record("legacy-terminal")

    assert is_integer(stamp)
  end

  defp request(suffix, run_id, session_id) do
    id = "approval-#{suffix}-#{System.unique_integer([:positive])}"

    task =
      Task.async(fn ->
        ExecApprovals.request(%{
          approval_id: id,
          run_id: run_id,
          session_id: session_id,
          session_key: "agent:test:#{suffix}",
          agent_id: "test",
          tool: "bash",
          action: %{command: "ls"},
          expires_in_ms: :infinity
        })
      end)

    assert_receive %LemonCore.Event{type: :approval_requested, payload: %{approval_id: ^id}},
                   2_000

    {task, id}
  end

  # {operation, table} of every Store call `fun` makes.
  defp store_calls(fun) do
    store = Process.whereis(Store)
    :erlang.trace(store, true, [:receive])

    try do
      fun.()
      Store.ping()
    after
      :erlang.trace(store, false, [:receive])
    end

    collect([])
  end

  defp collect(acc) do
    receive do
      {:trace, _pid, :receive, {:"$gen_call", _from, request}} when is_tuple(request) ->
        collect([{elem(request, 0), elem(request, 1)} | acc])

      {:trace, _pid, :receive, _other} ->
        collect(acc)
    after
      50 -> Enum.reverse(acc)
    end
  end

  defp clear do
    for table <- [@pending, @index, :exec_approval_session_owners],
        {key, _value} <- Store.list(table),
        do: Store.delete(table, key)
  end
end
