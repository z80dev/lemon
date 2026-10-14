defmodule LemonControlPlane.Methods.RunReceiptsTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.RunsReceiptGet
  alias LemonRouter.{RunOrchestrator, RunReceiptStore}

  setup do
    previous = Application.get_env(:lemon_core, :router_bridge)

    :ok =
      LemonCore.RouterBridge.configure(
        run_orchestrator: RunOrchestrator,
        router: previous && previous[:router]
      )

    run_id = "run_wire_receipt_#{System.unique_integer([:positive, :monotonic])}"

    on_exit(fn ->
      if previous,
        do: Application.put_env(:lemon_core, :router_bridge, previous),
        else: Application.delete_env(:lemon_core, :router_bridge)

      LemonCore.Store.delete(:run_receipts, run_id)
      LemonCore.Store.delete(RunOrchestrator.admission_table(), run_id)
      LemonCore.Store.delete(:runs, run_id)
    end)

    %{run_id: run_id}
  end

  test "readback preserves actual steering target and excludes private identity", %{run_id: id} do
    :ok =
      RunReceiptStore.put(%{
        run_id: id,
        session_key: "agent:receipt:main",
        state: :accepted,
        effective_mode: :steer_pending,
        target_run_id: "run_active",
        request_identity: "private_hash"
      })

    assert {:ok, %{"receipt" => receipt}} = RunsReceiptGet.handle(%{"runId" => id}, %{})

    assert receipt == %{
             "runId" => id,
             "sessionKey" => "agent:receipt:main",
             "state" => "accepted",
             "effectiveMode" => "steer_pending",
             "targetRunId" => "run_active",
             "retrySafe" => false
           }

    :ok = RunReceiptStore.update(id, %{effective_mode: :steer, target_run_id: "run_active"})

    assert {:ok, %{"receipt" => %{"effectiveMode" => "steer", "targetRunId" => "run_active"}}} =
             RunsReceiptGet.handle(%{"runId" => id}, %{})
  end

  test "an ambiguous admission fence is not a missing or retryable run", %{run_id: id} do
    :ok =
      LemonCore.Store.put(RunOrchestrator.admission_table(), id, %{
        state: "submitting",
        identity: "private_request_hash"
      })

    assert {:ok, %{"receipt" => receipt}} = RunsReceiptGet.handle(%{"runId" => id}, %{})
    assert receipt["runId"] == id
    assert receipt["state"] == "outcome_unknown"
    assert receipt["effectiveMode"] == nil
    assert receipt["targetRunId"] == nil
    assert receipt["retrySafe"] == false
    refute inspect(receipt) =~ "private_request_hash"
  end

  test "status-only receipt readback never transfers the completed private answer", %{run_id: id} do
    :ok =
      RunReceiptStore.put(%{
        run_id: id,
        session_key: "agent:receipt:main",
        state: :accepted,
        effective_mode: :new_run,
        target_run_id: id
      })

    :ok =
      LemonCore.Store.put(:runs, id, %{
        summary: %{
          answer: "other-principal-private-answer",
          meta: %{
            memory_context_key: "private-audience",
            invocation_context_key: "private-principal"
          }
        }
      })

    for flag <- [false, true] do
      assert {:ok, response} =
               RunsReceiptGet.handle(%{"runId" => id, "includeAnswer" => flag}, %{})

      assert response["receipt"]["runId"] == id
      encoded = Jason.encode!(response)
      refute encoded =~ "other-principal-private-answer"
      refute encoded =~ "private-audience"
      refute encoded =~ "private-principal"
      refute Map.has_key?(response, "answer")
    end

    for flag <- [nil, "false", 0, %{}] do
      assert {:error, {:invalid_request, _}} =
               RunsReceiptGet.handle(%{"runId" => id, "includeAnswer" => flag}, %{})
    end
  end

  test "a missing receipt remains missing and invalid IDs never generate a replacement", %{
    run_id: id
  } do
    assert {:error, {:not_found, _}} = RunsReceiptGet.handle(%{"runId" => id}, %{})
    assert {:error, {:invalid_request, _}} = RunsReceiptGet.handle(%{}, %{})
    assert {:error, {:invalid_request, _, nil}} = RunsReceiptGet.handle(%{"runId" => ""}, %{})
  end
end
