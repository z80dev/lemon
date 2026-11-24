defmodule LemonRouter.ReceiptDurabilityTest do
  use ExUnit.Case, async: false

  alias LemonCore.Store
  alias LemonCore.Store.SqliteBackend
  alias LemonRouter.{RunOrchestrator, RunReceiptStore}

  test "receipt writes use durable commits; receipt and presence reads never checkpoint" do
    path =
      Path.join(
        System.tmp_dir!(),
        "receipt_durable_#{System.unique_integer([:positive, :monotonic])}.db"
      )

    original = :sys.get_state(Store)
    owner = self()
    store_pid = Process.whereis(Store)
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach_many(
        handler,
        [[:lemon, :store, :sqlite, :durable_write], [:lemon, :store, :sqlite, :checkpoint]],
        fn event, _, _, _ ->
          if self() == store_pid, do: send(owner, {:sqlite_event, List.last(event)})
        end,
        nil
      )

    try do
      :sys.replace_state(Store, fn state ->
        {:ok, backend_state} = SqliteBackend.init(path: path, ephemeral_tables: [])
        %{state | backend: SqliteBackend, backend_state: backend_state}
      end)

      receipt = %{
        run_id: "run_receipt_durable",
        session_key: "agent:receipt:durable",
        state: :accepted,
        effective_mode: :new_run,
        target_run_id: "run_receipt_durable"
      }

      assert :ok = RunReceiptStore.put(receipt)
      assert_received {:sqlite_event, :durable_write}
      refute_received {:sqlite_event, :checkpoint}

      for _ <- 1..10 do
        assert {:ok, %{run_id: "run_receipt_durable"}} = RunReceiptStore.fetch(receipt.run_id)

        assert {:ok, %{admissions: _, receipts: %{"run_receipt_durable" => _}}} =
                 RunOrchestrator.presence_snapshot()

        refute_received {:sqlite_event, :checkpoint}
        refute_received {:sqlite_event, :durable_write}
      end

      assert :ok = Store.sync()
      assert_received {:sqlite_event, :checkpoint}
    after
      :sys.replace_state(Store, fn state ->
        SqliteBackend.close(state.backend_state)
        original
      end)

      :telemetry.detach(handler)
      Enum.each([path, path <> "-wal", path <> "-shm"], &File.rm/1)
    end
  end
end
