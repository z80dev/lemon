Code.require_file("../../../lemon_platform_test/test/support/crash_model.exs", __DIR__)

defmodule LemonChannels.OutboxCrashModelTest do
  use ExUnit.Case, async: true

  alias LemonChannels.OutboundPayload
  alias LemonChannels.Outbox.{Dedupe, QueueStore}
  alias LemonCore.Store
  alias LemonPlatformTest.Testing.CrashModel

  @moduletag :crash_model
  @moduletag :tmp_dir
  @store :outbox_crash_model_store
  @channel "outbox-crash-model"
  @seed 555_003

  test "OutboxKeys preserves admission, retry and confirmation identities across tears", %{
    tmp_dir: dir
  } do
    generator =
      StreamData.tuple({
        StreamData.list_of(
          StreamData.tuple({
            StreamData.member_of([:keyed, :unkeyed]),
            StreamData.member_of([:retry, :confirm]),
            StreamData.integer(0..3)
          }),
          max_length: 5
        ),
        StreamData.integer(0..1_000_000)
      })

    on_exit(fn ->
      :ets.match_delete(:lemon_channels_outbox_dedupe, {{@channel, :_}, :_})
    end)

    for {{operations, selector}, trial} <-
          Enum.with_index(CrashModel.samples(generator, @seed)) do
      path = Path.join(dir, "outbox-#{trial}.journal")
      store = CrashModel.start_store!(@store, path)
      # Both the explicit and private nil-key identities are mandatory witnesses.
      operations = [{:unkeyed, :retry, 0}, {:keyed, :confirm, 1} | operations]

      entries =
        operations
        |> Enum.with_index()
        |> Enum.map(fn {{key_kind, operation, attempts}, sequence} ->
          entry = entry(trial, sequence, key_kind)
          assert :ok = QueueStore.commit(@store, [QueueStore.pending_put(entry)], [])

          entry =
            Enum.reduce(1..(attempts + 1), entry, fn _, entry ->
              retried = %{entry | attempts: entry.attempts + 1}
              assert :ok = QueueStore.commit(@store, [QueueStore.pending_put(retried)], [])
              retried
            end)

          if operation == :confirm do
            receipt = QueueStore.receipt(entry)

            assert :ok =
                     QueueStore.commit(
                       @store,
                       [QueueStore.receipt_put(receipt)],
                       [QueueStore.pending_delete(entry)]
                     )
          end

          {entry, operation}
        end)

      # Crash between a terminal receipt put, pending deletion and their sync.
      # A surviving receipt must suppress the still-present recovered pending row.
      [{pending, :retry} | _] = entries
      {table, id, receipt} = QueueStore.receipt(pending) |> QueueStore.receipt_put()
      assert :ok = Store.put(@store, table, id, receipt)
      assert :ok = Store.delete(@store, QueueStore.pending_table(), pending.durable_id)
      assert :ok = Store.put(@store, :unrelated, :unsynced_suffix, String.duplicate("x", 64))
      CrashModel.crash_cut!(store, path, selector)
      reopened = CrashModel.start_store!(@store, path)
      assert {:ok, recovered, receipts, sequence} = QueueStore.load(@store, 100)
      receipt_map = Map.new(:queue.to_list(receipts))
      pending_map = Map.new(recovered, &{&1.durable_id, &1})

      assert Enum.map(recovered, & &1.sequence) == Enum.sort(Enum.map(recovered, & &1.sequence)),
             "OutboxKeys: FIFO changed on reopen"

      assert sequence == length(entries) - 1, "OutboxKeys: FIFO sequence regressed"

      for {original, operation} <- entries do
        expected_key = original.payload.idempotency_key || "outbox:#{original.durable_id}"
        pending = Map.get(pending_map, original.durable_id)
        receipt = Map.get(receipt_map, original.durable_id)
        assert pending != nil or receipt != nil, "OutboxKeys: acknowledged admission disappeared"

        if pending do
          assert QueueStore.delivery_key(pending) == expected_key, "OutboxKeys: retry key changed"
          assert pending.attempts == original.attempts, "OutboxKeys: retry budget reset"
          assert pending.payload == original.payload, "OutboxKeys: payload changed on replay"
        end

        if receipt do
          assert receipt.key == expected_key, "OutboxKeys: confirmation key changed"

          assert Dedupe.check(@channel, expected_key) == :duplicate,
                 "OutboxKeys: confirmed key became sendable"
        end

        if operation == :confirm do
          assert receipt != nil, "OutboxKeys: durable confirmation disappeared"
          assert pending == nil, "OutboxKeys: confirmed payload resurrected"
        end
      end

      CrashModel.crash!(reopened)
    end
  end

  defp entry(trial, sequence, key_kind) do
    id = "trial-#{trial}-item-#{sequence}"
    key = if key_kind == :keyed, do: "request:#{id}"

    %{
      durable_id: id,
      sequence: sequence,
      attempts: 0,
      available_at_ms: 0,
      expires_at_ms: 4_102_444_800_000,
      payload:
        OutboundPayload.text(@channel, "model", %{kind: :dm, id: "peer"}, "item #{sequence}",
          idempotency_key: key
        )
    }
  end
end
