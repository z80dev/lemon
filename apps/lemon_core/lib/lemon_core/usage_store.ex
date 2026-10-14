defmodule LemonCore.UsageStore do
  @moduledoc """
  Typed wrapper for shared usage records, summaries, and quota counters.
  """

  alias LemonCore.Store

  @record_table :usage_records
  @summary_table :usage_data
  @stats_table :usage_stats
  @occurrence_table :usage_occurrences

  @doc "Durably inserts one native run/usage occurrence; replay cannot bill twice."
  def put_occurrence(server \\ Store, record),
    do: Store.put_new(server, @occurrence_table, record.id, record)

  @doc "Strict reads for the canonical ledger, never unavailable-as-empty."
  def fetch_occurrences(server \\ Store), do: Store.fetch_all(server, @occurrence_table)
  def fetch_runs(server \\ Store), do: Store.fetch_all(server, :runs)
  def fetch_daily_records(server \\ Store), do: Store.fetch_all(server, @record_table)

  @doc "Returns a filter-bound, half-open page of canonical usage records."
  def records(params, opts \\ []), do: LemonCore.UsageRecords.query(params, opts)

  @spec get_record(binary()) :: map() | nil
  def get_record(server \\ Store, date_key) when is_binary(date_key),
    do: Store.get(server, @record_table, date_key)

  @spec put_record(binary(), map()) :: :ok | {:error, term()}
  def put_record(server \\ Store, date_key, record) when is_binary(date_key) and is_map(record),
    do: Store.put(server, @record_table, date_key, record)

  @spec get_summary(term()) :: map() | nil
  def get_summary(server \\ Store, key), do: Store.get(server, @summary_table, key)

  @spec put_summary(term(), map()) :: :ok | {:error, term()}
  def put_summary(server \\ Store, key, summary) when is_map(summary),
    do: Store.put(server, @summary_table, key, summary)

  @spec get_stats(term()) :: map() | nil
  def get_stats(key), do: Store.get(@stats_table, key)
end
