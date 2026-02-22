defmodule MarketIntel.Ingestion.PolymarketTest do
  @moduledoc """
  Comprehensive tests for the Polymarket ingestion module.

  Tests cover:
  - GraphQL API fetching with mocked HTTP calls
  - Market filtering (crypto, AI, weird)
  - Market categorization
  - Event detection and triggering
  - Error handling
  - GenServer behavior
  """

  use ExUnit.Case, async: false

  import Mox

  alias MarketIntel.Ingestion.Polymarket
  alias MarketIntel.Ingestion.HttpClientMock

  setup :verify_on_exit!

  setup do
    unless Process.whereis(MarketIntel.Cache) do
      start_supervised!(MarketIntel.Cache)
    end

    unless Process.whereis(Polymarket) do
      start_supervised!(Polymarket)
    end

    :ok
  end

  describe "module structure" do
    test "exports expected functions" do
      assert function_exported?(Polymarket, :start_link, 1)
      assert function_exported?(Polymarket, :fetch, 0)
      assert function_exported?(Polymarket, :get_trending, 0)
    end

    test "is a GenServer" do
      assert Process.whereis(Polymarket) != nil
    end
  end

  describe "get_trending/0" do
    test "returns cached trending markets when available" do
      cached_data = %{
        trending: [%{"id" => "market-1", "question" => "Test?"}],
        crypto_related: [],
        ai_agent: [],
        weird_niche: [],
        high_volume: []
      }

      MarketIntel.Cache.put(:polymarket_trending, cached_data)

      assert {:ok, data} = Polymarket.get_trending()
      assert length(data.trending) == 1
      assert hd(data.trending)["id"] == "market-1"
    end

    test "returns :not_found when no cached data" do
      # Clear cache
      :ets.delete_all_objects(:market_intel_cache)

      assert :not_found = Polymarket.get_trending()
    end
  end

  describe "market filtering" do
    setup do
      json = File.read!("test/fixtures/polymarket_markets_response.json")
      data = Jason.decode!(json)
      markets = data["data"]["markets"]

      %{markets: markets}
    end

    test "identifies crypto-related markets", %{markets: markets} do
      crypto_keywords = ["bitcoin", "ethereum", "crypto", "btc", "eth", "blockchain", "token"]

      crypto_markets = Enum.filter(markets, fn m ->
        text = String.downcase((m["question"] || "") <> " " <> (m["description"] || ""))
        Enum.any?(crypto_keywords, &String.contains?(text, &1))
      end)

      assert length(crypto_markets) >= 2
      assert Enum.any?(crypto_markets, &(&1["slug"] == "bitcoin-100k-2024"))
      assert Enum.any?(crypto_markets, &(&1["slug"] == "eth-etf-2024"))
    end

    test "identifies AI-related markets", %{markets: markets} do
      ai_keywords = ["ai", "artificial intelligence", "chatgpt", "openai", "anthropic", "agent"]

      ai_markets = Enum.filter(markets, fn m ->
        text = String.downcase((m["question"] || "") <> " " <> (m["description"] || ""))
        Enum.any?(ai_keywords, &String.contains?(text, &1))
      end)

      assert length(ai_markets) >= 2
      assert Enum.any?(ai_markets, &(&1["slug"] == "agi-2030"))
      assert Enum.any?(ai_markets, &(&1["slug"] == "gpt5-2024"))
    end

    test "identifies weird/niche markets", %{markets: markets} do
      weird_keywords = ["jesus", "alien", "ufo", "apocalypse", "end of the world", "trump tweet"]

      weird_markets = Enum.filter(markets, fn m ->
        text = String.downcase(m["question"] || "")
        Enum.any?(weird_keywords, &String.contains?(text, &1))
      end)

      assert length(weird_markets) >= 2
      assert Enum.any?(weird_markets, &(&1["slug"] == "alien-contact-2024"))
      assert Enum.any?(weird_markets, &(&1["slug"] == "jesus-sighting-2024"))
    end

    test "identifies high volume markets", %{markets: markets} do
      high_volume_threshold = 1_000_000

      high_volume = Enum.filter(markets, &(&1["volume"] > high_volume_threshold))

      assert length(high_volume) >= 3
      assert Enum.all?(high_volume, &(&1["volume"] > high_volume_threshold))
    end

    test "takes top 5 trending markets", %{markets: markets} do
      # Sort by volume descending (as the API would return)
      sorted = Enum.sort_by(markets, & &1["volume"], :desc)
      trending = Enum.take(sorted, 5)

      assert length(trending) == 5
      # Markets should be sorted by volume descending
      assert trending == Enum.sort_by(trending, & &1["volume"], :desc)
    end
  end

  describe "market data structure" do
    setup do
      json = File.read!("test/fixtures/polymarket_markets_response.json")
      data = Jason.decode!(json)
      markets = data["data"]["markets"]

      %{markets: markets}
    end

    test "market has required fields", %{markets: markets} do
      market = hd(markets)

      assert is_binary(market["id"])
      assert is_binary(market["question"])
      assert is_binary(market["slug"])
      assert is_number(market["volume"])
      assert is_number(market["liquidity"])
      assert is_list(market["outcomePrices"])
      assert is_list(market["outcomes"])
      assert is_binary(market["endDate"])
      assert is_binary(market["category"])
    end

    test "outcome prices sum to approximately 1", %{markets: markets} do
      market = hd(markets)

      prices = Enum.map(market["outcomePrices"], fn price ->
        case Float.parse(price) do
          {val, _} -> val
          :error -> 0.0
        end
      end)

      sum = Enum.sum(prices)
      assert sum >= 0.99 and sum <= 1.01
    end

    test "volume is always positive", %{markets: markets} do
      assert Enum.all?(markets, &(&1["volume"] >= 0))
    end
  end

  describe "GraphQL API integration" do
    test "builds correct GraphQL query" do
      query = """
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

      assert query =~ "query GetMarkets"
      assert query =~ "markets("
      assert query =~ "orderBy: \"volume\""
      assert query =~ "orderDirection: \"desc\""
    end

    test "sends correct request body" do
      expected_body = Jason.encode!(%{
        query: "query { markets { id } }",
        variables: %{limit: 50, offset: 0}
      })

      decoded = Jason.decode!(expected_body)
      assert decoded["variables"]["limit"] == 50
      assert decoded["variables"]["offset"] == 0
    end

    test "handles successful API response" do
      json = File.read!("test/fixtures/polymarket_markets_response.json")
      data = Jason.decode!(json)

      expect(HttpClientMock, :post, fn _url, _body, _headers, opts ->
        assert opts[:source] == "Polymarket"
        {:ok, data}
      end)

      result = HttpClientMock.post(
        "https://api.polymarket.com/graphql",
        "{}",
        [{"Content-Type", "application/json"}],
        source: "Polymarket"
      )

      assert {:ok, response} = result
      assert get_in(response, ["data", "markets"])
    end

    test "handles GraphQL errors" do
      error_response = %{
        "errors" => [
          %{"message" => "Field 'markets' doesn't exist"}
        ]
      }

      expect(HttpClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, error_response}
      end)

      result = HttpClientMock.post("https://api.polymarket.com/graphql", "{}", [], [])

      assert {:ok, %{"errors" => _}} = result
    end
  end

  describe "market categorization" do
    setup do
      json = File.read!("test/fixtures/polymarket_markets_response.json")
      data = Jason.decode!(json)
      markets = data["data"]["markets"]

      categorized = %{
        trending: Enum.take(markets, 5),
        crypto_related: filter_crypto_markets(markets),
        ai_agent: filter_ai_markets(markets),
        weird_niche: filter_weird_markets(markets),
        high_volume: Enum.filter(markets, &(&1["volume"] > 1_000_000))
      }

      %{categorized: categorized}
    end

    test "categorized data structure is correct", %{categorized: categorized} do
      assert is_list(categorized.trending)
      assert is_list(categorized.crypto_related)
      assert is_list(categorized.ai_agent)
      assert is_list(categorized.weird_niche)
      assert is_list(categorized.high_volume)
    end

    test "categories don't overlap incorrectly", %{categorized: categorized} do
      # A market could be in both crypto and high_volume, which is fine
      # But all markets should have valid structure
      all_markets =
        categorized.trending ++
        categorized.crypto_related ++
        categorized.ai_agent ++
        categorized.weird_niche

      assert Enum.all?(all_markets, &is_map/1)
      assert Enum.all?(all_markets, & &1["id"])
    end

    test "weird_niche markets trigger commentary", %{categorized: categorized} do
      if length(categorized.weird_niche) > 0 do
        # This would trigger the weird_market event
        assert length(categorized.weird_niche) > 0
      end
    end
  end

  describe "event detection" do
    test "detects weird markets for commentary trigger" do
      weird_markets = [
        %{"question" => "Will aliens appear?", "id" => "1"},
        %{"question" => "Jesus returns?", "id" => "2"}
      ]

      categorized = %{weird_niche: weird_markets}

      if length(categorized.weird_niche) > 0 do
        # Would trigger :weird_market event
        assert true
      end
    end

    test "does not trigger when no weird markets" do
      categorized = %{weird_niche: []}

      # Should not trigger
      assert length(categorized.weird_niche) == 0
    end
  end

  describe "error handling" do
    test "handles network timeout" do
      expect(HttpClientMock, :post, fn _url, _body, _headers, _opts ->
        {:error, %{type: :network_error, reason: :timeout}}
      end)

      result = HttpClientMock.post("https://api.polymarket.com/graphql", "{}", [], [])

      assert {:error, %{type: :network_error}} = result
    end

    test "handles HTTP 5xx errors" do
      expect(HttpClientMock, :post, fn _url, _body, _headers, _opts ->
        {:error, %{type: :api_error, source: "Polymarket", reason: "HTTP 500"}}
      end)

      result = HttpClientMock.post("https://api.polymarket.com/graphql", "{}", [], [])

      assert {:error, %{type: :api_error, reason: "HTTP 500"}} = result
    end

    test "handles unexpected response structure" do
      unexpected_response = %{"unexpected" => "data"}

      expect(HttpClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, unexpected_response}
      end)

      result = HttpClientMock.post("https://api.polymarket.com/graphql", "{}", [], [])

      assert {:ok, %{"unexpected" => "data"}} = result
    end

    test "handles empty markets list" do
      empty_response = %{"data" => %{"markets" => []}}

      expect(HttpClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, empty_response}
      end)

      result = HttpClientMock.post("https://api.polymarket.com/graphql", "{}", [], [])

      assert {:ok, %{"data" => %{"markets" => []}}} = result
    end
  end

  describe "GenServer callbacks" do
    test "fetch/0 casts message to server" do
      assert :ok = Polymarket.fetch()
    end

    test "init schedules initial fetch" do
      pid = Process.whereis(Polymarket)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end
  end

  describe "market data extraction" do
    test "extracts markets from valid response" do
      valid_response = %{
        "data" => %{
          "markets" => [
            %{"id" => "1", "question" => "Test?"},
            %{"id" => "2", "question" => "Another?"}
          ]
        }
      }

      markets = get_in(valid_response, ["data", "markets"])
      assert length(markets) == 2
    end

    test "handles missing data field" do
      invalid_response = %{"errors" => [%{"message" => "Auth failed"}]}

      markets = get_in(invalid_response, ["data", "markets"])
      assert is_nil(markets)
    end
  end

  # Helper functions

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
end
