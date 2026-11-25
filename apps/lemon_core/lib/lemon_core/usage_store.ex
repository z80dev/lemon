defmodule LemonCore.UsageStore do
  @moduledoc """
  Typed wrapper for shared usage records, summaries, and quota counters.
  """

  alias LemonCore.Store

  @record_table :usage_records
  @summary_table :usage_data
  @stats_table :usage_stats
  @occurrence_table :usage_occurrences
  @projection_table :usage_projections

  @doc "Durably inserts one native run/usage occurrence; replay cannot bill twice."
  def put_occurrence(server \\ Store, record),
    do: Store.put_new(server, @occurrence_table, record.id, record)

  @doc "Strict reads for the canonical ledger, never unavailable-as-empty."
  def fetch_occurrences(server \\ Store), do: Store.fetch_all(server, @occurrence_table)
  def fetch_daily_records(server \\ Store), do: Store.fetch_all(server, @record_table)

  @doc "Strict indexed read of daily coverage plus any rows with malformed date keys."
  def fetch_daily_records_between(server, from_ms, to_ms),
    do: Store.fetch_range(server, @record_table, from_ms, to_ms, include_untimed: true)

  @doc """
  Strict read of the occurrences timed in `[from_ms, to_ms)` plus those with no
  time, which no window can exclude. Reads only that window on SQLite.
  """
  @spec fetch_occurrences_between(Store.server(), integer(), integer()) ::
          {:ok, [{binary(), map()}]} | {:error, :store_unavailable}
  def fetch_occurrences_between(server \\ Store, from_ms, to_ms),
    do: Store.fetch_range(server, @occurrence_table, from_ms, to_ms, include_untimed: true)

  @doc "Returns a filter-bound, half-open page of canonical usage records."
  def records(params, opts \\ []), do: LemonCore.UsageRecords.query(params, opts)

  @doc "Display read of one day's projection; `nil` also when the Store cannot answer."
  @spec get_record(binary()) :: map() | nil
  def get_record(server \\ Store, date_key) when is_binary(date_key),
    do: Store.get(server, @record_table, date_key)

  @doc "Strict read of one day's projection, for read-modify-write."
  @spec fetch_record(Store.server(), binary()) ::
          {:ok, map() | nil} | {:error, :store_unavailable}
  def fetch_record(server \\ Store, date_key) when is_binary(date_key),
    do: Store.fetch(server, @record_table, date_key)

  @doc "Replaces one day's projection only when it still equals `expected`."
  @spec compare_and_swap_record(Store.server(), binary(), map() | nil, map()) ::
          :ok | {:error, :mismatch | term()}
  def compare_and_swap_record(server \\ Store, date_key, expected, record)
      when is_binary(date_key) and is_map(record),
      do: Store.compare_and_swap(server, @record_table, date_key, expected, record)

  @spec put_record(binary(), map()) :: :ok | {:error, term()}
  def put_record(server \\ Store, date_key, record) when is_binary(date_key) and is_map(record),
    do: Store.put(server, @record_table, date_key, record)

  @doc """
  Projection markers record whether an occurrence's daily projection is
  `:pending` or `:done`, so a replay repairs a missing projection without
  counting a completed one twice.
  """
  def put_projection_new(server \\ Store, occurrence_id, marker),
    do: Store.put_new(server, @projection_table, occurrence_id, marker)

  def fetch_projection(server \\ Store, occurrence_id),
    do: Store.fetch(server, @projection_table, occurrence_id)

  @doc "Every projection marker, strictly; used to reconcile pre-marker days."
  def fetch_projections(server \\ Store), do: Store.fetch_all(server, @projection_table)

  def compare_and_swap_projection(server \\ Store, occurrence_id, expected, marker),
    do: Store.compare_and_swap(server, @projection_table, occurrence_id, expected, marker)

  @spec get_summary(term()) :: map() | nil
  def get_summary(server \\ Store, key), do: Store.get(server, @summary_table, key)

  @spec put_summary(term(), map()) :: :ok | {:error, term()}
  def put_summary(server \\ Store, key, summary) when is_map(summary),
    do: Store.put(server, @summary_table, key, summary)

  @spec get_stats(term()) :: map() | nil
  def get_stats(key), do: Store.get(@stats_table, key)
end
