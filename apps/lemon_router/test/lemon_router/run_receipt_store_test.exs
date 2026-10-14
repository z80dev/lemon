defmodule LemonRouter.RunReceiptStoreTest do
  use ExUnit.Case, async: false

  alias LemonCore.Store
  alias LemonRouter.RunReceiptStore

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    name = :"run_receipt_store_#{System.unique_integer([:positive])}"

    opts = [
      name: name,
      backend: LemonCore.Store.SqliteBackend,
      backend_opts: [path: Path.join(dir, "receipts.sqlite3"), ephemeral_tables: []]
    ]

    start_supervised!({Store, opts})
    %{store: name, opts: opts}
  end

  test "receipts retain only disposition and private digest across store restart", %{
    store: store,
    opts: opts
  } do
    identity = String.duplicate("a", 64)
    receipt = Map.put(receipt("run"), :request_identity, identity)

    assert :ok =
             RunReceiptStore.put(
               store,
               Map.merge(receipt, %{prompt: "private", error: {:secret, "raw"}})
             )

    assert {:ok, ^receipt} = RunReceiptStore.fetch(store, "run")

    stop_supervised!(Store)
    start_supervised!({Store, opts})
    assert {:ok, ^receipt} = RunReceiptStore.fetch(store, "run")
  end

  test "initial admission is immutable and conflicting writes fail", %{store: store} do
    receipt = receipt("run")
    assert :ok = RunReceiptStore.put(store, receipt)
    assert :ok = RunReceiptStore.put(store, receipt)

    assert {:error, :receipt_conflict} =
             RunReceiptStore.put(store, %{receipt | target_run_id: "different"})

    assert {:ok, ^receipt} = RunReceiptStore.fetch(store, "run")
  end

  test "CAS updates change mode and target but preserve fixed identity", %{store: store} do
    identity = String.duplicate("b", 64)
    receipt = Map.put(receipt("run"), :request_identity, identity)
    assert :ok = RunReceiptStore.put(store, receipt)

    assert :ok =
             RunReceiptStore.update(store, "run", %{
               effective_mode: :merged,
               target_run_id: "survivor",
               run_id: "forged",
               session_key: "forged",
               request_identity: "forged",
               prompt: "private"
             })

    assert {:ok, updated} = RunReceiptStore.fetch(store, "run")
    assert updated == %{receipt | effective_mode: :merged, target_run_id: "survivor"}
    assert {:ok, nil} = RunReceiptStore.fetch(store, "forged")
  end

  test "update and uncertainty fencing never manufacture missing receipts", %{store: store} do
    assert {:ok, nil} = RunReceiptStore.fetch(store, "missing")

    assert :ok =
             RunReceiptStore.update(store, "missing", %{
               effective_mode: :steer,
               target_run_id: "active"
             })

    assert :ok = RunReceiptStore.mark_unknown(store, "missing")
    assert {:ok, nil} = RunReceiptStore.fetch(store, "missing")
  end

  test "durable unknown fence survives restart until actual disposition is written", %{
    store: store,
    opts: opts
  } do
    identity = String.duplicate("c", 64)
    receipt = Map.put(receipt("follower"), :request_identity, identity)
    assert :ok = RunReceiptStore.put(store, receipt)
    assert :ok = RunReceiptStore.mark_unknown(store, "follower")
    stop_supervised!(Store)
    start_supervised!({Store, opts})

    assert {:ok,
            %{
              state: :outcome_unknown,
              effective_mode: nil,
              target_run_id: nil,
              request_identity: ^identity
            }} = RunReceiptStore.fetch(store, "follower")

    assert :ok =
             RunReceiptStore.update(store, "follower", %{
               effective_mode: :merged,
               target_run_id: "survivor"
             })

    assert {:ok,
            %{
              state: :accepted,
              effective_mode: :merged,
              target_run_id: "survivor",
              request_identity: ^identity
            }} = RunReceiptStore.fetch(store, "follower")

    stop_supervised!(Store)
    start_supervised!({Store, opts})

    assert {:ok,
            %{
              state: :accepted,
              effective_mode: :merged,
              target_run_id: "survivor",
              request_identity: ^identity
            }} = RunReceiptStore.fetch(store, "follower")
  end

  test "terminal scope evidence survives run-history pruning and storage restart", %{
    store: store,
    opts: opts
  } do
    id = "completed"
    scope = %{profile_id: "executed-profile", agent_id: "actual-agent", session_key: "arbitrary"}

    :ok =
      Store.put(store, LemonRouter.RunOrchestrator.admission_table(), id, %{
        state: "accepted",
        identity: "fixed",
        scope: scope
      })

    :ok = Store.put(store, :runs, id, %{summary: %{completed: %{ok: true}}})
    :ok = RunReceiptStore.put(store, Map.merge(receipt(id), scope))

    assert {:ok, %{terminal: true, profile_id: "executed-profile"}} =
             RunReceiptStore.fetch(store, id)

    assert {:ok, %{terminal: true, scope: ^scope}} =
             Store.fetch(store, LemonRouter.RunOrchestrator.admission_table(), id)

    :ok = Store.delete(store, :runs, id)
    stop_supervised!(Store)
    start_supervised!({Store, opts})
    assert {:ok, nil} = Store.fetch(store, :runs, id)
    assert {:ok, %{terminal: true, agent_id: "actual-agent"}} = RunReceiptStore.fetch(store, id)

    assert {:ok, %{terminal: true, scope: ^scope}} =
             Store.fetch(store, LemonRouter.RunOrchestrator.admission_table(), id)
  end

  test "failed reads are unavailable, never successful absence", %{store: store} do
    pid = Process.whereis(store)
    stop_supervised!(Store)
    assert {:error, :store_unavailable} = RunReceiptStore.fetch(pid, "run")
    assert {:error, :store_unavailable} = RunReceiptStore.put(pid, receipt("run"))

    assert {:error, :store_unavailable} =
             RunReceiptStore.update(pid, "run", %{effective_mode: :queued})
  end

  test "invalid receipts cannot be stored as accepted", %{store: store} do
    assert {:error, :invalid_receipt} =
             RunReceiptStore.put(store, %{receipt("run") | target_run_id: nil})

    assert {:error, :invalid_receipt} =
             RunReceiptStore.put(store, %{receipt("run") | effective_mode: :requested})

    assert {:error, :invalid_receipt} = RunReceiptStore.put(store, nil)
    assert {:ok, nil} = RunReceiptStore.fetch(store, "run")
  end

  defp receipt(id) do
    %{
      run_id: id,
      session_key: "agent:test:main",
      state: :accepted,
      effective_mode: :queued,
      target_run_id: id
    }
  end
end
