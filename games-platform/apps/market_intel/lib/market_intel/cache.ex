defmodule MarketIntel.Cache do
  @moduledoc """
  ETS-based cache for real-time market data.

  Stores:
  - Latest token prices
  - 24h volume/mcap
  - Trending markets
  - Recent mentions/sentiment

  All data expires after configured TTL to ensure freshness.
  """

  use GenServer

  @table :market_intel_cache
  @default_ttl :timer.minutes(5)

  # Public API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Store data with optional TTL (ms)"
  def put(key, value, ttl \\ @default_ttl) do
    expires_at = System.monotonic_time(:millisecond) + ttl
    :ets.insert(@table, {key, value, expires_at})
    :ok
  end

  @doc "Get data if not expired"
  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, value, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at do
          {:ok, value}
        else
          :expired
        end

      [] ->
        :not_found
    end
  end

  @doc "Get latest market snapshot for commentary generation"
  def get_snapshot do
    token_cache_key = MarketIntel.Config.tracked_token_price_cache_key()

    %{
      token: get(token_cache_key),
      eth: get(:eth_price),
      base: get(:base_activity),
      polymarket: get(:polymarket_trending),
      mentions: get(:recent_mentions),
      timestamp: DateTime.utc_now()
    }
  end

  # GenServer callbacks

  @impl true
  def init(_) do
    :ets.new(@table, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    # Start cleanup timer
    schedule_cleanup()

    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.monotonic_time(:millisecond)

    # Delete expired entries
    :ets.select_delete(@table, [
      {{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}
    ])

    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, :timer.minutes(1))
  end
end
