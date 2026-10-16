defmodule LemonControlPlane.Methods.ExecApprovalResolveTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.ExecApprovalResolve
  alias LemonControlPlane.Protocol.{Errors, Schemas}
  alias LemonCore.{Bus, ExecApprovalStore, ExecApprovals, Store}

  setup do
    if Process.whereis(Store) == nil do
      start_supervised!({Store, []})
    end

    if Process.whereis(LemonCore.PubSub) == nil do
      start_supervised!({Phoenix.PubSub, name: LemonCore.PubSub})
    end

    id = "approval_rpc_#{System.unique_integer([:positive])}"
    :ok = Bus.subscribe("exec_approvals")
    on_exit(fn -> ExecApprovalStore.delete_pending(id) end)
    {:ok, id: id}
  end

  test "foreign run/session bindings reject without consuming or granting approval", %{id: id} do
    {task, pending} = request(id)
    params = params(pending, "approve_global")
    assert :ok = Schemas.validate("exec.approval.resolve", params)

    for foreign <- [
          Map.put(params, "expectedRunId", "another_run"),
          Map.put(params, "expectedSessionKey", "agent:other:main")
        ] do
      assert {:error, {:conflict, _, %{"reason" => "mismatch"}}} =
               ExecApprovalResolve.handle(foreign, %{})

      assert ExecApprovalStore.get_pending(id) == pending
    end

    refute_receive %LemonCore.Event{type: :approval_resolved}
    assert {:ok, result} = ExecApprovalResolve.handle(params(pending, "deny"), %{})
    assert result["outcome"] == "denied"
    assert result["approved"] == false
    assert Task.await(task) == {:ok, :denied}
  end

  test "receipt reports the actual canonical outcome and exact same-decision replay", %{id: id} do
    {task, pending} = request(id)
    params = params(pending, "approveOnce")
    assert {:ok, result} = ExecApprovalResolve.handle(params, %{})
    assert result["resolved"] == true
    assert result["approvalId"] == id
    assert result["sessionKey"] == pending.session_key
    assert result["runId"] == pending.run_id
    assert result["decision"] == "approve_once"
    assert result["outcome"] == "approved"
    assert result["approved"] == true
    assert result["replayed"] == false
    assert is_integer(result["resolvedAtMs"])
    refute inspect(result) =~ "private action"
    refute inspect(result) =~ "private rationale"
    assert Task.await(task) == {:ok, :approved, :approve_once}
    assert_receive %LemonCore.Event{type: :approval_resolved}

    assert {:ok, replay} = ExecApprovalResolve.handle(params, %{})
    assert replay == Map.put(result, "replayed", true)
    refute_receive %LemonCore.Event{type: :approval_resolved}

    assert {:error, {:conflict, _, %{"reason" => "conflict"}}} =
             ExecApprovalResolve.handle(params(pending, "deny"), %{})

    assert {:error, {:conflict, _, %{"reason" => "already_resolved"}}} =
             ExecApprovalResolve.handle(%{"approvalId" => id, "decision" => "approve_once"}, %{})

    assert {:error, {:conflict, _, %{"reason" => "mismatch"}}} =
             ExecApprovalResolve.handle(Map.put(params, "expectedRunId", "another_run"), %{})

    assert {:error, {:conflict, _, %{"reason" => "mismatch"}}} =
             ExecApprovalResolve.handle(
               Map.put(params, "expectedSessionKey", "agent:other:main"),
               %{}
             )

    :ok = ExecApprovalStore.delete_pending(id)

    assert {:error, {:not_found, _, %{"reason" => "not_found"}}} =
             ExecApprovalResolve.handle(params, %{})
  end

  test "a denied winner cannot be acknowledged as approval", %{id: id} do
    {task, pending} = request(id)
    assert {:ok, denied} = ExecApprovalResolve.handle(params(pending, "deny"), %{})
    assert denied["resolved"] == true
    assert denied["decision"] == "deny"
    assert denied["outcome"] == "denied"
    assert denied["approved"] == false
    assert Task.await(task) == {:ok, :denied}

    assert {:error, {:conflict, _, %{"reason" => "conflict"}}} =
             ExecApprovalResolve.handle(params(pending, "approve_once"), %{})

    assert {:ok, replay} = ExecApprovalResolve.handle(params(pending, "deny"), %{})
    assert replay["replayed"] == true
    assert replay["approved"] == false
  end

  test "owner cancellation is an explicit error, never resolved true", %{id: id} do
    {task, pending} = request(id)
    assert :ok = ExecApprovals.cancel(id, "invocation ended")
    assert Task.await(task) == {:ok, :denied}

    assert {:error, error} = ExecApprovalResolve.handle(params(pending, "approve_once"), %{})

    assert %{"code" => "CONFLICT", "details" => %{"approvalId" => ^id, "reason" => "cancelled"}} =
             Errors.to_payload(error)
  end

  test "an ended run expires the approval: waiter denied, wire event, later resolve is expired",
       %{id: id} do
    {task, pending} = request(id, :infinity)
    assert pending.expires_at_ms == nil

    assert {:ok, 1} = ExecApprovals.expire_owner({:run, pending.run_id})
    assert Task.await(task) == {:ok, :denied}

    assert_receive %LemonCore.Event{
                     type: :approval_resolved,
                     payload: %{approval_id: ^id, decision: :expired} = payload
                   },
                   1_000

    assert {"exec.approval.resolved", projected} =
             LemonControlPlane.EventBridge.project(
               LemonCore.Event.new(:approval_resolved, payload, %{})
             )

    assert projected["decision"] == "expired"
    assert projected["approvalId"] == id
    assert :ok = Schemas.validate_event("exec.approval.resolved", projected)

    for decision <- ["approve_once", "approve_session", "approve_global", "deny"] do
      assert {:error, error} = ExecApprovalResolve.handle(params(pending, decision), %{})

      assert %{
               "code" => "CONFLICT",
               "message" => "Approval expired",
               "details" => %{"approvalId" => ^id, "reason" => "expired"}
             } = Errors.to_payload(error)
    end

    assert ExecApprovalStore.get_pending(id) == nil
  end

  test "expired owner state and unknown IDs return distinct errors", %{id: id} do
    {task, pending} = request(id, 25)
    assert Task.await(task, 1_000) == {:error, :timeout}

    assert {:error, {:conflict, _, %{"reason" => "expired"}}} =
             ExecApprovalResolve.handle(params(pending, "approve_global"), %{})

    assert {:error, error} =
             ExecApprovalResolve.handle(
               %{"approvalId" => "missing_#{id}", "decision" => "deny"},
               %{}
             )

    assert %{"code" => "NOT_FOUND", "details" => %{"reason" => "not_found"}} =
             Errors.to_payload(error)
  end

  test "malformed bindings and IDs cannot consume a live approval", %{id: id} do
    {task, pending} = request(id)

    for value <- [nil, "", 123, String.duplicate("x", 1025)],
        field <- ["approvalId", "expectedSessionKey", "expectedRunId"] do
      assert {:error, {:invalid_request, _, _}} =
               ExecApprovalResolve.handle(
                 Map.put(params(pending, "approve_once"), field, value),
                 %{}
               )

      assert ExecApprovalStore.get_pending(id) == pending
    end

    assert {:ok, _} = ExecApprovalResolve.handle(params(pending, "deny"), %{})
    assert Task.await(task) == {:ok, :denied}
  end

  test "private team invocation context is absent from wire events, pending lists and receipts",
       %{id: id} do
    private_context = "principal-policy-epoch:private:#{id}"
    {task, pending} = request(id, 5_000, private_context)
    assert pending.invocation_context_key == private_context
    payload = LemonCore.Events.ApprovalRequested.new(%{approval_id: id, pending: pending})
    event = LemonCore.Event.new(:approval_requested, payload, %{})

    assert {"exec.approval.requested", projected} =
             LemonControlPlane.EventBridge.project(event)

    assert projected["approvalId"] == id
    assert projected["sessionKey"] == pending.session_key
    assert {:ok, listed} = LemonControlPlane.Methods.ExecApprovalsGet.handle(%{}, %{})
    assert Enum.any?(listed["pending"], &(&1["id"] == id))
    assert {:ok, receipt} = ExecApprovalResolve.handle(params(pending, "approve_once"), %{})
    assert Task.await(task) == {:ok, :approved, :approve_once}

    for exposed <- [payload, projected, listed, receipt] do
      encoded = Jason.encode!(exposed)
      refute encoded =~ private_context
      refute encoded =~ "invocation_context_key"
      refute encoded =~ "invocationContextKey"
    end
  end

  defp request(id, expires_in_ms \\ 5_000, invocation_context_key \\ nil) do
    task =
      Task.async(fn ->
        ExecApprovals.request(%{
          approval_id: id,
          run_id: "run_#{id}",
          session_key: "agent:test:#{id}",
          invocation_context_key: invocation_context_key,
          tool: "bash",
          action: %{command: "private action #{id}"},
          rationale: "private rationale",
          expires_in_ms: expires_in_ms
        })
      end)

    assert_receive %LemonCore.Event{
                     type: :approval_requested,
                     payload: %{pending: %{id: ^id} = pending}
                   },
                   1_000

    {task, pending}
  end

  defp params(pending, decision) do
    %{
      "approvalId" => pending.id,
      "decision" => decision,
      "expectedSessionKey" => pending.session_key,
      "expectedRunId" => pending.run_id
    }
  end
end
