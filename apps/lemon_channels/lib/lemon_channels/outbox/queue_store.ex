defmodule LemonChannels.Outbox.QueueStore do
  @moduledoc """
  Channels-owned durable outbox records over `LemonCore.Store`.

  Pending records include the original payload, FIFO sequence and wall-clock
  retry/expiry times. A missing payload key stays nil; the durable record ID
  supplies its private per-chunk dedupe identity. Confirmation replaces content with a
  bounded, content-free receipt in a separate table. A successful mutation always
  crosses the Store durability barrier. The configured Store backend determines
  crash durability; the in-memory ETS backend remains explicitly ephemeral.
  """

  alias LemonChannels.Outbox.Dedupe
  alias LemonCore.Store

  @pending_table :channels_outbox_pending
  @receipts_table :channels_outbox_receipts

  def pending_table, do: @pending_table
  def receipts_table, do: @receipts_table

  def load(store, receipt_limit) do
    with {:ok, pending} <- Store.fetch_all(store, @pending_table),
         {:ok, receipts} <- Store.fetch_all(store, @receipts_table) do
      now = System.system_time(:millisecond)

      {expired_pending, pending} =
        Enum.split_with(pending, fn {_id, entry} -> entry.expires_at_ms <= now end)

      {expired_receipts, receipts} =
        Enum.split_with(receipts, fn {_id, receipt} -> receipt.expires_at_ms < now end)

      receipts =
        Enum.sort_by(receipts, fn {_id, receipt} -> {receipt.expires_at_ms, receipt.sequence} end)

      {evicted_receipts, receipts} =
        Enum.split(receipts, max(length(receipts) - receipt_limit, 0))

      deletes =
        Enum.map(expired_pending, fn {id, _} -> {@pending_table, id} end) ++
          Enum.map(expired_receipts ++ evicted_receipts, fn {id, _} -> {@receipts_table, id} end)

      with :ok <- commit(store, [], deletes) do
        Enum.each(receipts, fn {_id, receipt} ->
          Dedupe.restore(receipt.channel_id, receipt.key, receipt.expires_at_ms - now)
        end)

        sequence =
          Enum.reduce(pending ++ receipts, 0, fn {_id, value}, acc -> max(value.sequence, acc) end)

        entries =
          pending
          |> Enum.map(fn {_id, entry} -> Map.put(entry, :recovered, true) end)
          |> Enum.sort_by(& &1.sequence)

        {:ok, entries, :queue.from_list(receipts), sequence}
      end
    else
      _ -> {:error, :outbox_store_unavailable}
    end
  end

  def commit(_store, [], []), do: :ok

  def commit(store, puts, deletes) do
    with :ok <- write_all(store, puts),
         :ok <- delete_all(store, deletes),
         :ok <- Store.confirm_durable(store) do
      :ok
    else
      _ -> {:error, :outbox_persistence_failed}
    end
  end

  def pending_put(entry),
    do: {@pending_table, entry.durable_id, Map.drop(entry, [:recovered, :worker_pid])}

  def pending_delete(entry), do: {@pending_table, entry.durable_id}

  @doc false
  def delivery_key(entry), do: entry.payload.idempotency_key || "outbox:#{entry.durable_id}"

  def receipt(entry) do
    value = %{
      channel_id: entry.payload.channel_id,
      key: delivery_key(entry),
      expires_at_ms: System.system_time(:millisecond) + Dedupe.ttl_ms(),
      sequence: entry.sequence
    }

    {entry.durable_id, value}
  end

  def receipt_put({id, receipt}), do: {@receipts_table, id, receipt}
  def receipt_delete({id, _receipt}), do: {@receipts_table, id}

  defp write_all(store, puts) do
    Enum.reduce_while(puts, :ok, fn {table, key, value}, :ok ->
      case Store.put(store, table, key, value, durable: true) do
        :ok -> {:cont, :ok}
        _ -> {:halt, {:error, :outbox_persistence_failed}}
      end
    end)
  end

  defp delete_all(store, deletes) do
    Enum.reduce_while(deletes, :ok, fn {table, key}, :ok ->
      case Store.delete(store, table, key, durable: true) do
        :ok -> {:cont, :ok}
        _ -> {:halt, {:error, :outbox_persistence_failed}}
      end
    end)
  end
end
