defmodule LemonRouter.AgentMessageStore do
  @moduledoc false

  alias LemonCore.Store

  @table :agent_message_receipts

  def fetch(message_id) do
    with {:ok, row} <- Store.fetch(@table, message_id),
         :ok <- Store.confirm_durable() do
      {:ok, row}
    end
  end

  def all do
    with {:ok, rows} <- Store.fetch_all(@table),
         :ok <- Store.confirm_durable() do
      {:ok, Enum.map(rows, &elem(&1, 1))}
    end
  end

  def reserve(row) do
    case Store.put_new(Store, @table, row.message_id, row, durable: true) do
      :ok -> {:ok, row}
      {:error, :exists} -> {:error, :exists}
      {:error, _} -> {:error, :outcome_unknown}
    end
  end

  def replace(current, replacement) do
    case Store.compare_and_swap(Store, @table, current.message_id, current, replacement,
           durable: true
         ) do
      :ok -> {:ok, replacement}
      {:error, :mismatch} -> {:error, :receipt_conflict}
      {:error, _} -> {:error, :outcome_unknown}
    end
  end

  def public(row) do
    Map.take(row, [:message_id, :source_id, :target_id, :status, :run_id, :response, :error])
  end
end
