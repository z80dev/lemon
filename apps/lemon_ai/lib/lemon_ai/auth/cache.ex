defmodule LemonAi.Auth.Cache do
  @moduledoc """
  Application-owned ETS cache for expiring tokens and discovered fingerprints.

  Only this supervised process creates the table. Callers access ETS directly;
  token refresh locking and expiry checks remain in the auth adapter. Entries
  survive requesting-process exits but are discarded when this owner restarts.

  Before application startup or during an owner restart, reads miss and writes
  are skipped. Auth adapters can still resolve credentials or build fingerprints
  without creating a table owned by a transient caller.
  """

  use GenServer

  @table :lemon_ai_auth_cache

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns a cached value, or nil on a miss or while the owner is unavailable."
  @spec get(term()) :: term()
  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Caches a value if the supervised table is available."
  @spec put(term(), term()) :: :ok
  def put(key, value) do
    :ets.insert(@table, {key, value})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Removes a cached value if the supervised table is available."
  @spec delete(term()) :: :ok
  def delete(key) do
    :ets.delete(@table, key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def init(_opts) do
    _ = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end
end
