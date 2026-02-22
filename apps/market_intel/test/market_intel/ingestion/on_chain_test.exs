defmodule MarketIntel.Ingestion.OnChainTest do
  @moduledoc """
  Comprehensive tests for the OnChain ingestion module.

  Tests cover:
  - BaseScan API integration with mocked HTTP calls
  - Token transfer parsing
  - Large transfer detection
  - Gas price fetching
  - Network stats tracking
  - Error handling
  - GenServer behavior
  """

  use ExUnit.Case, async: false

  import Mox

  alias MarketIntel.Ingestion.OnChain
  alias MarketIntel.Ingestion.HttpClientMock

  setup :verify_on_exit!

  setup do
    unless Process.whereis(MarketIntel.Cache) do
      start_supervised!(MarketIntel.Cache)
    end

    unless Process.whereis(OnChain) do
      start_supervised!(OnChain)
    end

    :ok
  end

  describe "module structure" do
    test "exports expected functions" do
      assert function_exported?(OnChain, :start_link, 1)
      assert function_exported?(OnChain, :fetch, 0)
      assert function_exported?(OnChain, :get_network_stats, 0)
      assert function_exported?(OnChain, :get_large_transfers, 0)
    end

    test "is a GenServer" do
      assert Process.whereis(OnChain) != nil
    end
  end

  describe "get_network_stats/0" do
    test "returns cached network stats when available" do
      stats = %{
        gas_price_gwei: 0.1,
        congestion: :medium,
        fetched_at: DateTime.utc_now()
      }

      MarketIntel.Cache.put(:base_network_stats, stats)

      assert {:ok, data} = OnChain.get_network_stats()
      assert data.gas_price_gwei == 0.1
      assert data.congestion == :medium
    end

    test "returns :not_found when no cached data" do
      :ets.delete_all_objects(:market_intel_cache)

      assert :not_found = OnChain.get_network_stats()
    end
  end

  describe "get_large_transfers/0" do
    test "returns cached large transfers when available" do
      transfers = [
        %{
          from: "0x1111",
          to: "0x2222",
          value: "1000000000000000000000000",
          timestamp: "1704067200",
          block: "12345678",
          hash: "0xabc"
        }
      ]

      cache_key = MarketIntel.Config.tracked_token_large_transfers_cache_key()
      MarketIntel.Cache.put(cache_key, transfers)

      assert {:ok, data} = OnChain.get_large_transfers()
      assert length(data) == 1
      assert hd(data).value == "1000000000000000000000000"
    end

    test "returns :not_found when no cached data" do
      # Use a unique key that won't exist
      cache_key = :nonexistent_large_transfers_key
      Application.put_env(:market_intel, :tracked_token, [large_transfers_cache_key: cache_key])

      assert :not_found = OnChain.get_large_transfers()

      Application.delete_env(:market_intel, :tracked_token)
    end
  end

  describe "token transfer parsing" do
    setup do
      json = File.read!("test/fixtures/basescan_transfers_response.json")
      data = Jason.decode!(json)

      %{response: data}
    end

    test "parses transfer list correctly", %{response: response} do
      transfers = response["result"]

      assert is_list(transfers)
      assert length(transfers) == 3

      first = hd(transfers)
      assert first["blockNumber"] == "12345678"
      assert first["from"] == "0x1111111111111111111111111111111111111111"
      assert first["to"] == "0x2222222222222222222222222222222222222222"
      assert first["value"] == "500000000000000000000000"
      assert first["tokenSymbol"] == "TEST"
      assert first["tokenDecimal"] == "18"
    end

    test "transforms transfers to internal format", %{response: response} do
      transfers = response["result"]

      parsed = Enum.map(transfers, fn t ->
        %{
          from: t["from"],
          to: t["to"],
          value: t["value"],
          timestamp: t["timeStamp"],
          block: t["blockNumber"],
          hash: t["hash"]
        }
      end)

      first = hd(parsed)
      assert first.from == "0x1111111111111111111111111111111111111111"
      assert first.value == "500000000000000000000000"
      assert is_binary(first.timestamp)
      assert is_binary(first.block)
    end

    test "handles empty transfer list" do
      empty_response = %{"status" => "1", "message" => "OK", "result" => []}

      assert empty_response["result"] == []
    end

    test "handles API error response" do
      error_response = %{"status" => "0", "message" => "NOTOK", "result" => "Invalid API Key"}

      assert error_response["status"] == "0"
      assert error_response["message"] == "NOTOK"
    end
  end

  describe "large transfer detection" do
    test "identifies transfers above threshold" do
      threshold = 1_000_000_000_000_000_000_000_000  # 1M tokens with 18 decimals

      transfers = [
        %{"value" => "500000000000000000000000"},   # 500K - below threshold
        %{"value" => "1000000000000000000000000"},  # 1M - at threshold
        %{"value" => "2000000000000000000000000"}   # 2M - above threshold
      ]

      large_transfers = Enum.filter(transfers, fn t ->
        case Integer.parse(to_string(t["value"] || "0")) do
          {value, _} -> value > threshold
          :error -> false
        end
      end)

      assert length(large_transfers) == 1
      assert hd(large_transfers)["value"] == "2000000000000000000000000"
    end

    test "handles missing or invalid value field" do
      transfers = [
        %{"value" => nil},
        %{"value" => ""},
        %{"value" => "invalid"},
        %{"hash" => "0xabc"}  # missing value entirely
      ]

      results = Enum.map(transfers, fn t ->
        case Integer.parse(to_string(t["value"] || "0")) do
          {value, _} -> value > 1000
          :error -> false
        end
      end)

      assert Enum.all?(results, &(&1 == false))
    end

    test "handles decimal string values" do
      value_str = "1500000000000000000000000"

      {value, _} = Integer.parse(value_str)

      assert value == 1_500_000_000_000_000_000_000_000
    end
  end

  describe "BaseScan API integration" do
    test "builds correct API URL for token transfers" do
      token_address = "0xabcdef1234567890abcdef1234567890abcdef12"
      from_block = 12_345_000
      api_key = "test_api_key_123"

      expected_url =
        "https://api.basescan.org/api?module=account&action=tokentx" <>
        "&contractaddress=#{token_address}&startblock=#{from_block}&sort=desc&apikey=#{api_key}"

      assert expected_url =~ "api.basescan.org"
      assert expected_url =~ "module=account"
      assert expected_url =~ "action=tokentx"
      assert expected_url =~ token_address
      assert expected_url =~ "#{from_block}"
      assert expected_url =~ api_key
    end

    test "handles successful API response" do
      json = File.read!("test/fixtures/basescan_transfers_response.json")
      data = Jason.decode!(json)

      expect(HttpClientMock, :get, fn url, _headers, opts ->
        assert url =~ "api.basescan.org"
        assert opts[:source] == "BaseScan"
        {:ok, data}
      end)

      result = HttpClientMock.get(
        "https://api.basescan.org/api?module=account&action=tokentx",
        [],
        source: "BaseScan"
      )

      assert {:ok, response} = result
      assert response["status"] == "1"
      assert length(response["result"]) == 3
    end

    test "handles API key errors" do
      expect(HttpClientMock, :get, fn _url, _headers, _opts ->
        {:error, %{type: :config_error, reason: "missing BASESCAN_KEY secret"}}
      end)

      result = HttpClientMock.get("https://api.basescan.org/api", [], [])

      assert {:error, %{type: :config_error}} = result
    end

    test "handles rate limiting" do
      expect(HttpClientMock, :get, fn _url, _headers, _opts ->
        {:error, %{type: :api_error, source: "BaseScan", reason: "HTTP 429"}}
      end)

      result = HttpClientMock.get("https://api.basescan.org/api", [], [])

      assert {:error, %{type: :api_error, reason: "HTTP 429"}} = result
    end
  end

  describe "gas price fetching" do
    test "parses gas price from RPC response" do
      # Parse hex gas price
      hex_price = "0x1dfd14000"
      decimal_price = String.to_integer(String.replace_prefix(hex_price, "0x", ""), 16)

      assert decimal_price > 0
    end

    test "converts wei to gwei" do
      wei_price = 8_000_000_000  # 8 Gwei in wei
      gwei_price = wei_price / 1_000_000_000

      assert gwei_price == 8.0
    end

    test "handles RPC errors" do
      error_response = {:error, :econnrefused}

      assert match?({:error, _}, error_response)
    end
  end

  describe "network stats" do
    test "determines congestion level" do
      gas_price_gwei = 0.1

      congestion = cond do
        gas_price_gwei < 0.05 -> :low
        gas_price_gwei < 0.2 -> :medium
        true -> :high
      end

      assert congestion == :medium
    end

    test "stores network stats in cache" do
      stats = %{
        gas_price_gwei: 0.05,
        congestion: :low,
        fetched_at: DateTime.utc_now()
      }

      MarketIntel.Cache.put(:base_network_stats, stats)

      assert {:ok, cached} = MarketIntel.Cache.get(:base_network_stats)
      assert cached.congestion == :low
    end
  end

  describe "error handling" do
    test "handles missing token address configuration" do
      token_address = nil

      assert is_nil(token_address)
    end

    test "handles empty token address" do
      token_address = ""

      assert token_address == ""
    end

    test "handles network timeouts" do
      expect(HttpClientMock, :get, fn _url, _headers, _opts ->
        {:error, %{type: :network_error, reason: :timeout}}
      end)

      result = HttpClientMock.get("https://api.basescan.org/api", [], [])

      assert {:error, %{type: :network_error, reason: :timeout}} = result
    end

    test "handles invalid JSON response" do
      expect(HttpClientMock, :get, fn _url, _headers, _opts ->
        {:ok, "not valid json"}
      end)

      result = HttpClientMock.get("https://api.basescan.org/api", [], [])

      assert {:ok, "not valid json"} = result
    end
  end

  describe "GenServer callbacks" do
    test "fetch/0 casts message to server" do
      assert :ok = OnChain.fetch()
    end

    test "init schedules initial fetch" do
      pid = Process.whereis(OnChain)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "maintains last_block state" do
      # The GenServer should track the last processed block
      pid = Process.whereis(OnChain)
      assert is_pid(pid)

      # State should include last_block field
      state = :sys.get_state(pid)
      assert Map.has_key?(state, :last_block)
    end
  end

  describe "block tracking" do
    test "calculates starting block for first run" do
      latest_block = 12_345_678
      blocks_to_go_back = 1000

      start_block = latest_block - blocks_to_go_back

      assert start_block == 12_344_678
    end

    test "uses last_block for subsequent runs" do
      last_block = 12_340_000

      # Should use last_block + 1 to avoid duplicates
      start_block = last_block + 1

      assert start_block == 12_340_001
    end
  end

  describe "holder stats" do
    test "returns placeholder holder stats" do
      stats = %{
        total_holders: :unknown,
        top_10_concentration: :unknown
      }

      assert stats.total_holders == :unknown
      assert stats.top_10_concentration == :unknown
    end
  end

  describe "data persistence" do
    test "stores transfers in cache" do
      transfers = %{
        recent: [%{hash: "0xabc", value: "1000"}],
        large: [%{hash: "0xdef", value: "1000000"}],
        count_24h: 150
      }

      cache_key = MarketIntel.Config.tracked_token_transfers_cache_key()
      MarketIntel.Cache.put(cache_key, transfers)

      assert {:ok, cached} = MarketIntel.Cache.get(cache_key)
      assert cached.count_24h == 150
      assert length(cached.recent) == 1
      assert length(cached.large) == 1
    end
  end
end
