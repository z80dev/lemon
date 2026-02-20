defmodule MarketIntel.Ingestion.DexScreener do
  @moduledoc """
  Ingests token price and market data from DEX Screener API.

  Tracks:
  - configured tracked token price, volume, mcap
  - ETH price for context
  - Base ecosystem tokens
  - AI agent sector performance
  """

  use GenServer
  require Logger

  @api_base "https://api.dexscreener.com/latest"

  # GenServer setup

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Initial fetch
    send(self(), :fetch)

    {:ok, %{last_fetch: nil}}
  end

  # Public API

  @doc "Manually trigger a fetch"
  def fetch do
    GenServer.cast(__MODULE__, :fetch)
  end

  @doc "Get latest tracked token data from cache"
  def get_tracked_token_data do
    MarketIntel.Cache.get(MarketIntel.Config.tracked_token_price_cache_key())
  end

  # GenServer callbacks

  @impl true
  def handle_cast(:fetch, state) do
    do_fetch()
    {:noreply, %{state | last_fetch: DateTime.utc_now()}}
  end

  @impl true
  def handle_info(:fetch, state) do
    do_fetch()
    schedule_next_fetch()
    {:noreply, %{state | last_fetch: DateTime.utc_now()}}
  end

  # Private functions

  defp do_fetch do
    Logger.info("[MarketIntel] Fetching DEX Screener data...")

    tracked_token_address = MarketIntel.Config.tracked_token_address()
    tracked_token_signal_key = MarketIntel.Config.tracked_token_signal_key()
    eth_address = MarketIntel.Config.eth_address()

    # Fetch concurrently
    tasks =
      [
        maybe_fetch_token_task(tracked_token_address, tracked_token_signal_key),
        maybe_fetch_token_task(eth_address, :eth),
        Task.async(fn -> fetch_base_ecosystem() end)
      ]
      |> Enum.reject(&is_nil/1)

    results = Task.await_many(tasks, 30_000)

    # Store results
    Enum.each(results, fn
      {:ok, key, data} ->
        MarketIntel.Cache.put(key, data)
        persist_to_db(key, data)

      {:error, reason} ->
        Logger.warning("[MarketIntel] Fetch failed: #{inspect(reason)}")
    end)

    # Check for significant price movements
    check_price_signals(results)
  end

  defp maybe_fetch_token_task(nil, _key), do: nil
  defp maybe_fetch_token_task("", _key), do: nil
  defp maybe_fetch_token_task(address, key), do: Task.async(fn -> fetch_token(address, key) end)

  defp fetch_token(address, key) do
    url = "#{@api_base}/dex/tokens/#{address}"
    headers = maybe_add_api_key([])

    case HTTPoison.get(url, headers, timeout: 10_000) do
      {:ok, %{status_code: 200, body: body}} ->
        data = Jason.decode!(body)
        {:ok, key, parse_token_data(data)}

      {:ok, %{status_code: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_add_api_key(headers) do
    case MarketIntel.Secrets.get(:dexscreener_key) do
      {:ok, key} -> [{"Authorization", "Bearer #{key}"} | headers]
      _ -> headers
    end
  end

  defp fetch_base_ecosystem do
    # Fetch top Base tokens for context
    url = "#{@api_base}/dex/search?q=base"

    case HTTPoison.get(url, [], timeout: 10_000) do
      {:ok, %{status_code: 200, body: body}} ->
        data = Jason.decode!(body)
        {:ok, :base_ecosystem, parse_ecosystem_data(data)}

      _ ->
        {:error, :fetch_failed}
    end
  end

  defp parse_token_data(%{"pairs" => pairs}) when is_list(pairs) do
    # Get the highest liquidity pair
    best_pair = Enum.max_by(pairs, & &1["liquidity"]["usd"])

    %{
      price_usd: best_pair["priceUsd"],
      price_change_24h: best_pair["priceChange"]["h24"],
      volume_24h: best_pair["volume"]["h24"],
      liquidity_usd: best_pair["liquidity"]["usd"],
      market_cap: best_pair["marketCap"],
      fdv: best_pair["fdv"],
      dex: best_pair["dexId"],
      pair_address: best_pair["pairAddress"],
      fetched_at: DateTime.utc_now()
    }
  end

  defp parse_ecosystem_data(%{"pairs" => pairs}) do
    # Top 10 Base tokens by volume
    pairs
    |> Enum.filter(&(&1["chainId"] == "base"))
    |> Enum.sort_by(& &1["volume"]["h24"], :desc)
    |> Enum.take(10)
    |> Enum.map(fn p ->
      %{
        symbol: p["baseToken"]["symbol"],
        price: p["priceUsd"],
        volume_24h: p["volume"]["h24"],
        change_24h: p["priceChange"]["h24"]
      }
    end)
  end

  defp persist_to_db(_key, _data) do
    # Store in SQLite for historical analysis
    # Implementation in schema module
    :ok
  end

  defp check_price_signals(results) do
    token_key = MarketIntel.Config.tracked_token_signal_key()
    threshold = MarketIntel.Config.tracked_token_price_change_signal_threshold_pct()

    case List.keyfind(results, token_key, 1) do
      {:ok, ^token_key, %{price_change_24h: change}} when is_number(change) ->
        if abs(change) > threshold do
          MarketIntel.Commentary.Pipeline.trigger(:price_spike, %{
            token: token_key,
            change: change
          })
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  defp schedule_next_fetch do
    # Fetch every 2 minutes
    Process.send_after(self(), :fetch, :timer.minutes(2))
  end
end
