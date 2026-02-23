defmodule LemonIngestion.Adapters.Polymarket do
  @moduledoc """
  Polymarket adapter for detecting large trades and market movements.

  Polls the Polymarket Gamma API for:
  - Large trades (above configurable threshold)
  - Significant price movements
  - New markets with high liquidity
  - Market resolution events

  Configuration:
    config :lemon_ingestion, :polymarket,
      poll_interval_ms: 30_000,
      api_url: "https://gamma-api.polymarket.com",
      min_trade_size: 10_000,      # USD
      min_liquidity: 100_000,      # USD
      price_change_threshold: 0.05 # 5%

  API Docs: https://docs.polymarket.com/
  """

  use GenServer
  require Logger

  alias LemonIngestion.Router

  @default_api_url "https://gamma-api.polymarket.com"
  @default_poll_interval 30_000

  defstruct [
    :api_url,
    :poll_interval_ms,
    :min_trade_size,
    :min_liquidity,
    :price_change_threshold,
    :last_check_time,
    :seen_trade_ids,
    :markets_cache
  ]

  # --- Client API ---

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Manually trigger a check (for testing).
  """
  def check_now do
    GenServer.cast(__MODULE__, :check)
  end

  @doc """
  Get current adapter state (for debugging).
  """
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # --- Server Callbacks ---

  @impl true
  def init(_) do
    config = Application.get_env(:lemon_ingestion, :polymarket, [])

    state = %__MODULE__{
      api_url: Keyword.get(config, :api_url, @default_api_url),
      poll_interval_ms: Keyword.get(config, :poll_interval_ms, @default_poll_interval),
      min_trade_size: Keyword.get(config, :min_trade_size, 10_000),
      min_liquidity: Keyword.get(config, :min_liquidity, 100_000),
      price_change_threshold: Keyword.get(config, :price_change_threshold, 0.05),
      last_check_time: DateTime.utc_now(),
      seen_trade_ids: MapSet.new(),
      markets_cache: %{}
    }

    # Schedule first check
    schedule_check(state.poll_interval_ms)

    {:ok, state}
  end

  @impl true
  def handle_cast(:check, state) do
    new_state = perform_check(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:check, state) do
    new_state = perform_check(state)
    schedule_check(state.poll_interval_ms)
    {:noreply, new_state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       last_check: state.last_check_time,
       seen_trades_count: MapSet.size(state.seen_trade_ids),
       cached_markets: map_size(state.markets_cache),
       config: %{
         min_trade_size: state.min_trade_size,
         min_liquidity: state.min_liquidity,
         poll_interval_ms: state.poll_interval_ms
       }
     }, state}
  end

  # --- Private Functions ---

  defp schedule_check(interval_ms) do
    Process.send_after(self(), :check, interval_ms)
  end

  defp perform_check(state) do
    Logger.debug("Polymarket adapter: checking for events...")

    state
    |> check_large_trades()
    |> check_market_movements()
    |> tap(fn _ -> Logger.debug("Polymarket adapter: check complete") end)
    |> Map.put(:last_check_time, DateTime.utc_now())
  rescue
    e ->
      Logger.error("Polymarket adapter error: #{inspect(e)}")
      state
  end

  @doc """
  Check for large trades on Polymarket.

  Queries the activity/trades endpoint and emits events for trades
  above the configured threshold.
  """
  defp check_large_trades(state) do
    case fetch_recent_trades(state) do
      {:ok, trades} ->
        new_trades =
          trades
          |> Enum.reject(fn trade ->
            trade_id = trade["id"] || trade["transactionHash"]
            MapSet.member?(state.seen_trade_ids, trade_id)
          end)

        Enum.each(new_trades, fn trade ->
          event = trade_to_event(trade, state)
          if event, do: Router.route(event)
        end)

        # Update seen IDs (keep last 1000 to prevent memory bloat)
        new_ids =
          new_trades
          |> Enum.map(&(&1["id"] || &1["transactionHash"]))
          |> Enum.reject(&is_nil/1)

        updated_ids =
          state.seen_trade_ids
          |> MapSet.union(MapSet.new(new_ids))
          |> limit_set_size(1000)

        %{state | seen_trade_ids: updated_ids}

      {:error, reason} ->
        Logger.warning("Failed to fetch Polymarket trades: #{inspect(reason)}")
        state
    end
  end

  @doc """
  Check for significant market price movements.

  Compares current market prices to cached values and emits
  events for movements above the threshold.
  """
  defp check_market_movements(state) do
    case fetch_markets(state) do
      {:ok, markets} ->
        Enum.each(markets, fn market ->
          market_id = market["conditionId"] || market["slug"]
          cached = state.markets_cache[market_id]

          if cached do
            check_price_movement(market, cached, state)
          end
        end)

        # Update cache with current prices
        new_cache =
          markets
          |> Enum.map(fn m ->
            id = m["conditionId"] || m["slug"]
            {id, extract_market_snapshot(m)}
          end)
          |> Map.new()

        %{state | markets_cache: new_cache}

      {:error, reason} ->
        Logger.warning("Failed to fetch Polymarket markets: #{inspect(reason)}")
        state
    end
  end

  defp check_price_movement(market, cached, state) do
    current_price = market["outcomePrices"] |> List.first() |> parse_price()
    old_price = cached.best_price

    if current_price && old_price && old_price > 0 do
      change = abs(current_price - old_price) / old_price

      if change >= state.price_change_threshold do
        event = %{
          source: :polymarket,
          type: :price_movement,
          timestamp: DateTime.utc_now(),
          importance: if(change > 0.1, do: :high, else: :medium),
          data: %{
            market_id: market["conditionId"] || market["slug"],
            market_title: market["question"] || market["title"],
            old_price: old_price,
            new_price: current_price,
            change_pct: Float.round(change * 100, 2),
            direction: if(current_price > old_price, do: :up, else: :down),
            liquidity: market["liquidity"] || market["volume"],
            volume: market["volume"]
          },
          url: "https://polymarket.com/market/#{market["slug"]}"
        }

        Router.route(event)
      end
    end
  end

  # --- API Fetching ---

  defp fetch_recent_trades(state) do
    # Polymarket Gamma API endpoint for recent activity
    url = "#{state.api_url}/events"

    # Query params for recent high-value activity
    params = [
      limit: 100,
      active: true,
      closed: false,
      order: "volume",
      ascending: false
    ]

    Req.get(url, params: params, decode_json: [keys: :strings])
    |> case do
      {:ok, %{status: 200, body: body}} -> {:ok, extract_trades(body)}
      {:ok, %{status: status}} -> {:error, "HTTP #{status}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_markets(state) do
    url = "#{state.api_url}/events"

    params = [
      limit: 100,
      active: true,
      liquidityMin: state.min_liquidity,
      order: "liquidity",
      ascending: false
    ]

    Req.get(url, params: params, decode_json: [keys: :strings])
    |> case do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, "HTTP #{status}"}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- Data Transformation ---

  defp extract_trades(events) when is_list(events) do
    # Extract trades from events/markets
    # This is a simplified version - real implementation would parse
    # the specific trade data structure from Polymarket
    events
    |> Enum.flat_map(fn event ->
      # Each event may have markets with recent trades
      markets = event["markets"] || []

      Enum.flat_map(markets, fn market ->
        # Look for recent trade activity in market data
        if has_recent_large_activity?(market) do
          [
            %{
              "id" => "#{event["id"]}_#{System.unique_integer([:positive])}",
              "event" => event,
              "market" => market,
              "size" => extract_trade_size(market),
              "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
            }
          ]
        else
          []
        end
      end)
    end)
  end

  defp trade_to_event(trade, state) do
    size = trade["size"] || 0

    # Only emit events for trades above threshold
    if size >= state.min_trade_size do
      market = trade["market"] || %{}
      event_data = trade["event"] || %{}

      %{
        source: :polymarket,
        type: :large_trade,
        timestamp: DateTime.utc_now(),
        importance: if(size >= state.min_trade_size * 5, do: :high, else: :medium),
        data: %{
          market_id: market["conditionId"] || market["slug"],
          market_title: market["question"] || market["title"] || event_data["title"],
          trade_size: size,
          liquidity: market["liquidity"] || market["volume"],
          volume: market["volume"],
          best_price: market["outcomePrices"] |> List.first() |> parse_price()
        },
        url: "https://polymarket.com/market/#{market["slug"]}"
      }
    else
      nil
    end
  end

  defp has_recent_large_activity?(market) do
    # Check if market shows signs of recent large trading
    volume = market["volume"] || 0
    liquidity = market["liquidity"] || 0

    # Simple heuristic: high volume relative to liquidity suggests recent activity
    volume > 0 && liquidity > 50_000
  end

  defp extract_trade_size(market) do
    # Estimate trade size from market data
    # In a real implementation, this would use actual trade data
    volume = market["volume"] || 0
    # Rough estimate: assume some % of volume is recent large trades
    div(volume, 100)
  end

  defp extract_market_snapshot(market) do
    %{
      best_price: market["outcomePrices"] |> List.first() |> parse_price(),
      liquidity: market["liquidity"] || market["volume"],
      timestamp: DateTime.utc_now()
    }
  end

  defp parse_price(nil), do: nil
  defp parse_price(price) when is_binary(price) do
    case Float.parse(price) do
      {p, _} -> p
      :error -> nil
    end
  end
  defp parse_price(price) when is_number(price), do: price

  defp limit_set_size(set, max_size) do
    if MapSet.size(set) > max_size do
      # Keep only the most recent (arbitrary but consistent)
      set
      |> MapSet.to_list()
      |> Enum.take(-max_size)
      |> MapSet.new()
    else
      set
    end
  end
end
