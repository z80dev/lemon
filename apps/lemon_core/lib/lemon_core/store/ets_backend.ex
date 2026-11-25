defmodule LemonCore.Store.EtsBackend do
  @moduledoc """
  In-memory ETS-based storage backend.

  This is the default backend providing fast, ephemeral storage.
  Data is lost when the process terminates.

  Tables are `:protected`: the Store process writes them, and `reader/1`
  lets any process read them (through a directory of table references) while
  the Store keeps writing.
  """

  @behaviour LemonCore.Store.Backend

  # Non-atom state key, so it can never collide with a caller's table name.
  @directory {__MODULE__, :directory}

  @impl true
  def init(_opts) do
    tables = %{
      chat: :ets.new(:lemon_core_chat, [:set, :protected]),
      progress: :ets.new(:lemon_core_progress, [:set, :protected]),
      runs: :ets.new(:lemon_core_runs, [:set, :protected]),
      run_history: :ets.new(:lemon_core_run_history, [:ordered_set, :protected])
    }

    directory = :ets.new(:lemon_core_directory, [:set, :protected])
    true = :ets.insert(directory, Map.to_list(tables))
    {:ok, Map.put(tables, @directory, directory)}
  end

  @impl true
  def put(state, table, key, value) do
    state = ensure_table(state, table)
    :ets.insert(state[table], {key, value})
    {:ok, state}
  end

  @impl true
  def put_new(state, table, key, value) do
    state = ensure_table(state, table)

    if :ets.insert_new(state[table], {key, value}) do
      {:ok, state}
    else
      {:exists, state}
    end
  end

  @impl true
  def get(state, table, key) do
    state = ensure_table(state, table)

    value =
      case :ets.lookup(state[table], key) do
        [{^key, val}] -> val
        _ -> nil
      end

    {:ok, value, state}
  end

  @impl true
  def delete(state, table, key) do
    state = ensure_table(state, table)
    :ets.delete(state[table], key)
    {:ok, state}
  end

  @impl true
  def sweep(state, table, {field, cutoff}) do
    state = ensure_table(state, table)
    count = :ets.select_delete(state[table], sweep_match_spec(field, cutoff))
    {:ok, count, state}
  end

  @doc """
  Returns the retention match specification for `{key, value}` ETS rows.

  Read-cache eviction and SQLite's ephemeral tables use the same predicates.
  Ordered clauses preserve field precedence even when the preferred timestamp
  is too recent to delete.
  """
  @spec sweep_match_spec(LemonCore.Store.Backend.sweep_field(), integer()) :: list()
  def sweep_match_spec(:expires_at, cutoff) do
    [{{:_, %{expires_at: :"$1"}}, [{:is_integer, :"$1"}], [{:<, :"$1", cutoff}]}]
  end

  def sweep_match_spec(:inserted_at_ms, cutoff) do
    [{{:_, %{"inserted_at_ms" => :"$1"}}, [{:is_integer, :"$1"}], [{:<, :"$1", cutoff}]}]
  end

  def sweep_match_spec(:started_at_ms, cutoff) do
    [
      {{:_, %{started_at_ms: :"$1"}}, [{:is_integer, :"$1"}], [{:<, :"$1", cutoff}]},
      {{:_, %{"started_at_ms" => :"$1"}}, [{:is_integer, :"$1"}], [{:<, :"$1", cutoff}]}
    ]
  end

  def sweep_match_spec(:introspection_timestamp, cutoff) do
    [
      {{{:"$1", :_}, :_}, [{:is_integer, :"$1"}], [{:<, :"$1", cutoff}]},
      {{:_, %{ts_ms: :"$1"}}, [{:"=/=", :"$1", nil}, {:"=/=", :"$1", false}],
       [{:andalso, {:is_integer, :"$1"}, {:<, :"$1", cutoff}}]},
      {{:_, %{"ts_ms" => :"$1"}}, [{:is_integer, :"$1"}], [{:<, :"$1", cutoff}]}
    ]
  end

  # Ephemeral by design: nothing outlives the process, so there is nothing to
  # flush and no crash in which flushed data would survive.
  @impl true
  def sync(state), do: {:ok, state}

  @impl true
  def compare_and_delete_many(state, entries) do
    state =
      Enum.reduce(entries, state, fn {table, _key, _expected}, acc -> ensure_table(acc, table) end)

    if Enum.all?(entries, fn {table, key, expected} ->
         :ets.lookup(state[table], key) == [{key, expected}]
       end) do
      Enum.each(entries, fn {table, key, _expected} -> :ets.delete(state[table], key) end)
      {:ok, state}
    else
      {:error, :mismatch, state}
    end
  end

  @impl true
  def list(state, table) do
    state = ensure_table(state, table)
    items = :ets.tab2list(state[table])
    {:ok, items, state}
  end

  @doc "The table directory; `read_list/2` and `read_range/5` take it."
  @impl true
  def reader(state), do: Map.fetch!(state, @directory)

  @impl true
  def read_list(directory, table) do
    case :ets.lookup(directory, table) do
      [{^table, tid}] -> {:ok, :ets.tab2list(tid)}
      [] -> {:ok, []}
    end
  end

  @impl true
  def read_keys(directory, table) do
    case :ets.lookup(directory, table) do
      [{^table, tid}] -> {:ok, :ets.select(tid, [{{:"$1", :_}, [], [:"$1"]}])}
      [] -> {:ok, []}
    end
  end

  @impl true
  def read_range(directory, table, from_ms, to_ms, include_untimed) do
    case :ets.lookup(directory, table) do
      [{^table, tid}] -> {:ok, select_range(tid, table, from_ms, to_ms, include_untimed)}
      [] -> {:ok, []}
    end
  end

  defp select_range(tid, :usage_records = table, from_ms, to_ms, include_untimed) do
    :ets.foldl(
      fn row, acc ->
        if in_range?(row, table, from_ms, to_ms, include_untimed), do: [row | acc], else: acc
      end,
      [],
      tid
    )
  end

  defp select_range(tid, _table, from_ms, to_ms, include_untimed) do
    time = {:map_get, :at_ms, :"$1"}

    timed? =
      {:andalso, {:is_map, :"$1"}, {:andalso, {:is_map_key, :at_ms, :"$1"}, {:is_integer, time}}}

    in_range? = {:andalso, timed?, {:andalso, {:>=, time, from_ms}, {:<, time, to_ms}}}
    predicate = if include_untimed, do: {:orelse, {:not, timed?}, in_range?}, else: in_range?
    :ets.select(tid, [{{:_, :"$1"}, [predicate], [:"$_"]}])
  end

  @doc false
  def filter_range(rows, table, from_ms, to_ms, include_untimed) do
    Enum.filter(rows, &in_range?(&1, table, from_ms, to_ms, include_untimed))
  end

  defp in_range?({key, value}, table, from_ms, to_ms, include_untimed) do
    case LemonCore.Store.Backend.range_timestamp(table, key, value) do
      nil -> include_untimed
      ms -> ms >= from_ms and ms < to_ms
    end
  end

  # Ensure a table exists, creating it dynamically if needed
  defp ensure_table(state, table) do
    if Map.has_key?(state, table) do
      state
    else
      ets_table = :ets.new(:"lemon_core_#{table}", [:set, :protected])

      case Map.fetch(state, @directory) do
        {:ok, directory} -> true = :ets.insert(directory, {table, ets_table})
        :error -> :ok
      end

      Map.put(state, table, ets_table)
    end
  end
end
