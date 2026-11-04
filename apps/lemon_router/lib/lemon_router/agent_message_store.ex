defmodule LemonRouter.AgentMessageStore do
  @moduledoc false

  alias LemonCore.Store

  @table :agent_message_receipts

  def fetch(message_id) do
    with {:ok, row} <- Store.fetch(@table, message_id),
         :ok <- Store.sync() do
      {:ok, row}
    end
  end

  def all do
    with {:ok, rows} <- Store.fetch_all(@table),
         :ok <- Store.sync() do
      {:ok, Enum.map(rows, &elem(&1, 1))}
    end
  end

  def reserve(row) do
    case Store.put_new(@table, row.message_id, row) do
      :ok -> durable(row)
      {:error, :exists} -> {:error, :exists}
      {:error, _} -> {:error, :unavailable}
    end
  end

  def replace(current, replacement) do
    case Store.compare_and_swap(@table, current.message_id, current, replacement) do
      :ok -> durable(replacement)
      {:error, :mismatch} -> {:error, :receipt_conflict}
      {:error, _} -> {:error, :outcome_unknown}
    end
  end

  def public(row) do
    Map.take(row, [:message_id, :source_id, :target_id, :status, :run_id, :response, :error])
  end

  defp durable(row) do
    case Store.sync() do
      :ok -> {:ok, row}
      _ -> {:error, :outcome_unknown}
    end
  end
end
