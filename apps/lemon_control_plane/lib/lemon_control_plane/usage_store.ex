defmodule LemonControlPlane.UsageStore do
  @moduledoc """
  Typed wrapper for control-plane usage records and summaries.
  """

  alias LemonCore.Store

  @record_table :usage_records
  @summary_table :usage_data
  @stats_table :usage_stats

  @spec get_record(binary()) :: map() | nil
  def get_record(date_key) when is_binary(date_key), do: Store.get(@record_table, date_key)

  @spec put_record(binary(), map()) :: :ok
  def put_record(date_key, record) when is_binary(date_key) and is_map(record),
    do: Store.put(@record_table, date_key, record)

  @spec get_summary(term()) :: map() | nil
  def get_summary(key), do: Store.get(@summary_table, key)

  @spec put_summary(term(), map()) :: :ok
  def put_summary(key, summary) when is_map(summary), do: Store.put(@summary_table, key, summary)

  @spec get_stats(term()) :: map() | nil
  def get_stats(key), do: Store.get(@stats_table, key)
end
