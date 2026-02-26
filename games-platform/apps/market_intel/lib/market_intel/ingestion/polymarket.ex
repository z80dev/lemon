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

  alias MarketIntel.Ingestion.HttpClient
  alias MarketIntel.Errors

  @graphql_endpoint "https://api.polymarket.com/graphql"
  @source_name "Polymarket"
  @fetch_interval :timer.minutes(5)

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

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def fetch, do: GenServer.cast(__MODULE__, :fetch)

  def get_trending do
    MarketIntel.Cache.get(:polymarket_trending)
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
    schedule_next()
    {:noreply, %{state | last_fetch: DateTime.utc_now()}}
  end

  # Private Functions

  defp do_fetch do
    HttpClient.log_info(@source_name, "fetching data...")

    case fetch_markets() do
      {:ok, markets} ->
        process_markets(markets)

      {:error, reason} = error ->
        HttpClient.log_error(@source_name, Errors.format_for_log(error))
        {:error, reason}
    end
  end

  defp process_markets(markets) do
    categorized = %{
      trending: Enum.take(markets, 5),
      crypto_related: filter_crypto_markets(markets),
      ai_agent: filter_ai_markets(markets),
      weird_niche: filter_weird_markets(markets),
      high_volume: Enum.filter(markets, &(&1["volume"] > 1_000_000))
    }

    MarketIntel.Cache.put(:polymarket_trending, categorized)
    check_market_events(categorized)

    {:ok, categorized}
  end

  defp fetch_markets do
    body =
      Jason.encode!(%{
        query: @markets_query,
        variables: %{limit: 50, offset: 0}
      })

    headers = [{"Content-Type", "application/json"}]

    with {:ok, data} <- HttpClient.post(@graphql_endpoint, body, headers, source: @source_name),
         {:ok, markets} <- extract_markets(data) do
      {:ok, markets}
    end
  end

  defp extract_markets(%{"data" => %{"markets" => markets}}) when is_list(markets) do
    {:ok, markets}
  end

  defp extract_markets(data) do
    Errors.parse_error("unexpected response structure: #{inspect(String.slice(inspect(data), 0, 100))}")
  end

  defp filter_crypto_markets(markets) do
    keywords = ["bitcoin", "ethereum", "crypto", "btc", "eth", "blockchain", "token"]
    filter_by_keywords(markets, keywords)
  end

  defp filter_ai_markets(markets) do
    keywords = ["ai", "artificial intelligence", "chatgpt", "openai", "anthropic", "agent"]
    filter_by_keywords(markets, keywords)
  end

  defp filter_weird_markets(markets) do
    keywords = ["jesus", "alien", "ufo", "apocalypse", "end of the world", "trump tweet"]

    Enum.filter(markets, fn m ->
      text = String.downcase(m["question"] || "")
      Enum.any?(keywords, &String.contains?(text, &1))
    end)
  end

  defp filter_by_keywords(markets, keywords) do
    Enum.filter(markets, fn m ->
      text = String.downcase((m["question"] || "") <> " " <> (m["description"] || ""))
      Enum.any?(keywords, &String.contains?(text, &1))
    end)
  end

  defp check_market_events(%{weird_niche: weird}) when length(weird) > 0 do
    MarketIntel.Commentary.Pipeline.trigger(:weird_market, %{
      markets: weird
    })
  end

  defp check_market_events(_), do: :ok

  defp schedule_next do
    HttpClient.schedule_next_fetch(self(), :fetch, @fetch_interval)
  end
end
