defmodule LemonGateway.Store.EtsBackend do
  @moduledoc """
  In-memory ETS-based storage backend.

  This is the default backend providing fast, ephemeral storage.
  Data is lost when the process terminates.
  """

  @behaviour LemonGateway.Store.Backend

  @impl true
  def init(_opts) do
    tables = %{
      chat: :ets.new(:lemon_gateway_chat, [:set, :protected]),
      progress: :ets.new(:lemon_gateway_progress, [:set, :protected]),
      runs: :ets.new(:lemon_gateway_runs, [:set, :protected]),
      run_history: :ets.new(:lemon_gateway_run_history, [:ordered_set, :protected])
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
      ets_table = :ets.new(:"lemon_gateway_#{table}", [:set, :protected])
      Map.put(state, table, ets_table)
    end
  end
end
