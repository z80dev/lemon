defmodule LemonTcg.MarketData.Cache do
  @moduledoc """
  TTL cache for market data responses, backed by a public ETS table.

  Quotes go stale in seconds, not milliseconds — a short TTL keeps an agent
  loop from hammering rate-limited marketplace APIs when several tools read
  the same floor in one decision turn.
  """

  use GenServer

  @table :lemon_tcg_market_cache
  @default_ttl_ms 30_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Fetch `key` from cache or compute it with `fun`, caching :ok results."
  @spec get_or_run(term(), (-> {:ok, term()} | {:error, term()}), keyword()) ::
          {:ok, term()} | {:error, term()}
  def get_or_run(key, fun, opts \\ []) do
    ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)

    if Keyword.get(opts, :fresh?, false) do
      run_and_store(key, fun, ttl_ms)
    else
      case lookup(key) do
        {:ok, value} -> {:ok, value}
        :miss -> run_and_store(key, fun, ttl_ms)
      end
    end
  end

  @spec lookup(term()) :: {:ok, term()} | :miss
  def lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, expires_at_ms, value}] ->
        if System.monotonic_time(:millisecond) < expires_at_ms, do: {:ok, value}, else: :miss

      [] ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  def clear do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp run_and_store(key, fun, ttl_ms) do
    case fun.() do
      {:ok, value} = ok ->
        expires_at_ms = System.monotonic_time(:millisecond) + ttl_ms
        :ets.insert(@table, {key, expires_at_ms, value})
        ok

      other ->
        other
    end
  rescue
    ArgumentError -> fun.()
  end

  @impl true
  def init(_opts) do
    _ = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end
end
