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
    :ets.insert(state[table], {key, value})
    {:ok, state}
  end

  @impl true
  def get(state, table, key) do
    value =
      case :ets.lookup(state[table], key) do
        [{^key, val}] -> val
        _ -> nil
      end

    {:ok, value, state}
  end

  @impl true
  def delete(state, table, key) do
    :ets.delete(state[table], key)
    {:ok, state}
  end

  @impl true
  def list(state, table) do
    items = :ets.tab2list(state[table])
    {:ok, items, state}
  end
end
