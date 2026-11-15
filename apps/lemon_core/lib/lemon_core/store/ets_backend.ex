defmodule LemonCore.Store.EtsBackend do
  @moduledoc """
  In-memory ETS-based storage backend.

  This is the default backend providing fast, ephemeral storage.
  Data is lost when the process terminates.
  """

  @behaviour LemonCore.Store.Backend

  @impl true
  def init(_opts) do
    tables = %{
      chat: :ets.new(:lemon_core_chat, [:set, :protected]),
      progress: :ets.new(:lemon_core_progress, [:set, :protected]),
      runs: :ets.new(:lemon_core_runs, [:set, :protected]),
      run_history: :ets.new(:lemon_core_run_history, [:ordered_set, :protected])
    }

    {:ok, tables}
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

  # Ensure a table exists, creating it dynamically if needed
  defp ensure_table(state, table) do
    if Map.has_key?(state, table) do
      state
    else
      ets_table = :ets.new(:"lemon_core_#{table}", [:set, :protected])
      Map.put(state, table, ets_table)
    end
  end
end
