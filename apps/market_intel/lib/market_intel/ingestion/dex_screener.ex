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

  alias MarketIntel.Ingestion.HttpClient
  alias MarketIntel.Errors

  @api_base "https://api.dexscreener.com/latest"
  @source_name "DEX Screener"
  @fetch_interval :timer.minutes(2)

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Manually trigger a fetch"
  def fetch do
    GenServer.cast(__MODULE__, :fetch)
  end

  @doc "Get latest tracked token data from cache"
  def get_tracked_token_data do
    MarketIntel.Cache.get(MarketIntel.Config.tracked_token_price_cache_key())
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    send(self(), :fetch)
    {:ok, %{last_fetch: nil}}
  end

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

  # Private Functions

  defp do_fetch do
    HttpClient.log_info(@source_name, "fetching data...")

    tracked_token_address = MarketIntel.Config.tracked_token_address()
    tracked_token_signal_key = MarketIntel.Config.tracked_token_signal_key()
    eth_address = MarketIntel.Config.eth_address()

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

      {:error, _} = error ->
        HttpClient.log_error(@source_name, Errors.format_for_log(error))
    end)

    # Check for significant price movements
    check_price_signals(results)
  end

  defp maybe_fetch_token_task(nil, _key), do: nil
  defp maybe_fetch_token_task("", _key), do: nil

  defp maybe_fetch_token_task(address, key) do
    Task.async(fn -> fetch_token(address, key) end)
  end

  defp fetch_token(address, key) do
    url = "#{@api_base}/dex/tokens/#{address}"
    headers = build_auth_headers()

    with {:ok, data} <- HttpClient.get(url, headers, source: @source_name),
         {:ok, parsed} <- parse_token_data(data) do
      {:ok, key, parsed}
    end
  end

  defp build_auth_headers do
    case MarketIntel.Secrets.get(:dexscreener_key) do
      {:ok, key} -> [{"Authorization", "Bearer #{key}"}]
      _ -> []
    end
  end

  defp fetch_base_ecosystem do
    url = "#{@api_base}/dex/search?q=base"

    with {:ok, data} <- HttpClient.get(url, [], source: @source_name),
         {:ok, parsed} <- parse_ecosystem_data(data) do
      {:ok, :base_ecosystem, parsed}
    end
  end

  defp parse_token_data(%{"pairs" => pairs}) when is_list(pairs) and length(pairs) > 0 do
    # Get the highest liquidity pair
    best_pair = Enum.max_by(pairs, &get_in(&1, ["liquidity", "usd"]) || 0)

    {:ok,
     %{
       price_usd: best_pair["priceUsd"],
       price_change_24h: get_in(best_pair, ["priceChange", "h24"]),
       volume_24h: get_in(best_pair, ["volume", "h24"]),
       liquidity_usd: get_in(best_pair, ["liquidity", "usd"]),
       market_cap: best_pair["marketCap"],
       fdv: best_pair["fdv"],
       dex: best_pair["dexId"],
       pair_address: best_pair["pairAddress"],
       fetched_at: DateTime.utc_now()
     }}
  end

  defp parse_token_data(%{"pairs" => []}) do
    Errors.parse_error("no trading pairs found")
  end

  defp parse_token_data(_) do
    Errors.parse_error("unexpected response format")
  end

  defp parse_ecosystem_data(%{"pairs" => pairs}) when is_list(pairs) do
    # Top 10 Base tokens by volume
    tokens =
      pairs
      |> Enum.filter(&(&1["chainId"] == "base"))
      |> Enum.sort_by(&get_in(&1, ["volume", "h24"]) || 0, :desc)
      |> Enum.take(10)
      |> Enum.map(fn p ->
        %{
          symbol: get_in(p, ["baseToken", "symbol"]),
          price: p["priceUsd"],
          volume_24h: get_in(p, ["volume", "h24"]),
          change_24h: get_in(p, ["priceChange", "h24"])
        }
      end)

    {:ok, tokens}
  end

  defp parse_ecosystem_data(_) do
    Errors.parse_error("unexpected ecosystem response format")
  end

  defp persist_to_db(_key, _data) do
    # Store in SQLite for historical analysis
    # Implementation in schema module
    :ok
  end

  defp check_price_signals(results) do
    token_key = MarketIntel.Config.tracked_token_signal_key()
    threshold = MarketIntel.Config.tracked_token_price_change_signal_threshold_pct()

    case find_result(results, token_key) do
      {:ok, %{price_change_24h: change}} when is_number(change) and abs(change) > threshold ->
        MarketIntel.Commentary.Pipeline.trigger(:price_spike, %{
          token: token_key,
          change: change
        })

      _ ->
        :ok
    end
  end

  defp find_result(results, key) do
    case List.keyfind(results, key, 1) do
      {:ok, ^key, data} -> {:ok, data}
      _ -> {:error, :not_found}
    end
  end

  defp schedule_next_fetch do
    HttpClient.schedule_next_fetch(self(), :fetch, @fetch_interval)
  end
end
