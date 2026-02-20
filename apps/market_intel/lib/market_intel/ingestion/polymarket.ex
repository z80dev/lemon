defmodule MarketIntel.Ingestion.Polymarket do
  @moduledoc """
  Ingests prediction market data from Polymarket.
  
  Tracks:
  - Trending markets
  - Crypto-related predictions
  - AI/agent market sentiment
  - Unusual volume patterns
  """
  
  use GenServer
  require Logger
  
  @graphql_endpoint "https://api.polymarket.com/graphql"
  
  # Markets query
  @markets_query """
  query GetMarkets($limit: Int!, $offset: Int!) {
    markets(
      limit: $limit
      offset: $offset
      active: true
      orderBy: "volume"
      orderDirection: "desc"
    ) {
      id
      question
      slug
      volume
      liquidity
      outcomePrices
      outcomes
      endDate
      category
      description
      createdAt
    }
  }
  """
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  @impl true
  def init(_opts) do
    send(self(), :fetch)
    {:ok, %{last_fetch: nil}}
  end
  
  # Public API
  
  def fetch, do: GenServer.cast(__MODULE__, :fetch)
  
  def get_trending do
    MarketIntel.Cache.get(:polymarket_trending)
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
    schedule_next()
    {:noreply, %{state | last_fetch: DateTime.utc_now()}}
  end
  
  # Private
  
  defp do_fetch do
    Logger.info("[MarketIntel] Fetching Polymarket data...")
    
    case fetch_markets() do
      {:ok, markets} ->
        # Categorize markets
        categorized = %{
          trending: Enum.take(markets, 5),
          crypto_related: filter_crypto_markets(markets),
          ai_agent: filter_ai_markets(markets),
          weird_niche: filter_weird_markets(markets),
          high_volume: Enum.filter(markets, & &1["volume"] > 1_000_000)
        }
        
        MarketIntel.Cache.put(:polymarket_trending, categorized)
        
        # Check for interesting market events
        check_market_events(categorized)
        
      {:error, reason} ->
        Logger.warning("[MarketIntel] Polymarket fetch failed: #{inspect(reason)}")
    end
  end
  
  defp fetch_markets do
    body = Jason.encode!(%{
      query: @markets_query,
      variables: %{limit: 50, offset: 0}
    })
    
    headers = [
      {"Content-Type", "application/json"}
    ]
    
    case HTTPoison.post(@graphql_endpoint, body, headers, timeout: 15_000) do
      {:ok, %{status_code: 200, body: response}} ->
        case Jason.decode(response) do
          {:ok, %{"data" => %{"markets" => markets}}} ->
            {:ok, markets}
          _ ->
            {:error, :invalid_response}
        end
        
      {:ok, %{status_code: status}} ->
        {:error, "HTTP #{status}"}
        
      {:error, reason} ->
        {:error, reason}
    end
  end
  
  defp filter_crypto_markets(markets) do
    keywords = ["bitcoin", "ethereum", "crypto", "btc", "eth", "blockchain", "token"]
    
    Enum.filter(markets, fn m ->
      text = String.downcase(m["question"] <> " " <> (m["description"] || ""))
      Enum.any?(keywords, &String.contains?(text, &1))
    end)
  end
  
  defp filter_ai_markets(markets) do
    keywords = ["ai", "artificial intelligence", "chatgpt", "openai", "anthropic", "agent"]
    
    Enum.filter(markets, fn m ->
      text = String.downcase(m["question"] <> " " <> (m["description"] || ""))
      Enum.any?(keywords, &String.contains?(text, &1))
    end)
  end
  
  defp filter_weird_markets(markets) do
    # Markets with unusual questions (for fun commentary)
    weird_keywords = ["jesus", "alien", "ufo", "apocalypse", "end of the world", "trump tweet"]
    
    Enum.filter(markets, fn m ->
      text = String.downcase(m["question"])
      Enum.any?(weird_keywords, &String.contains?(text, &1))
    end)
  end
  
  defp check_market_events(categorized) do
    # Check if any interesting markets are trending
    if length(categorized.weird_niche) > 0 do
      MarketIntel.Commentary.Pipeline.trigger(:weird_market, %{
        markets: categorized.weird_niche
      })
    end
  end
  
  defp schedule_next do
    Process.send_after(self(), :fetch, :timer.minutes(5))
  end
end
