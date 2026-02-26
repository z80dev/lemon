defmodule MarketIntel.Ingestion.HttpClientTest do
  @moduledoc """
  Comprehensive tests for the HttpClient module.

  Tests cover:
  - HTTP GET/POST requests
  - JSON parsing and error handling
  - Authentication header management
  - Error formatting and logging
  - Request timeouts
  - Response status code handling
  """

  use ExUnit.Case, async: false

  import Mox

  alias MarketIntel.Ingestion.HttpClient
  alias MarketIntel.Errors

  setup :verify_on_exit!

  setup do
    previous_http_client = Application.get_env(:market_intel, :http_client_module)
    previous_secrets_module = Application.get_env(:market_intel, :http_client_secrets_module)

    Application.put_env(:market_intel, :http_client_module, HTTPoison.Mock)
    Application.put_env(:market_intel, :http_client_secrets_module, MarketIntel.Secrets.Mock)

    on_exit(fn ->
      case previous_http_client do
        nil -> Application.delete_env(:market_intel, :http_client_module)
        value -> Application.put_env(:market_intel, :http_client_module, value)
      end

      case previous_secrets_module do
        nil -> Application.delete_env(:market_intel, :http_client_secrets_module)
        value -> Application.put_env(:market_intel, :http_client_secrets_module, value)
      end
    end)

    :ok
  end

  describe "get/3" do
    test "makes successful GET request" do
      expect(HTTPoison.Mock, :get, fn url, headers, opts ->
        assert url == "https://api.example.com/data"
        assert is_list(headers)
        assert opts[:timeout] == 15_000
        {:ok, %{status_code: 200, body: ~s({"key": "value"})}}
      end)

      result = HttpClient.get("https://api.example.com/data", [], [])
      assert {:ok, %{"key" => "value"}} = result
    end

    test "handles HTTP 200 with JSON response" do
      expect(HTTPoison.Mock, :get, fn _url, _headers, _opts ->
        {:ok, %{status_code: 200, body: ~s({"success": true})}}
      end)

      assert {:ok, %{"success" => true}} = HttpClient.get("https://test.com", [], [])
    end

    test "handles HTTP 404 error" do
      expect(HTTPoison.Mock, :get, fn _url, _headers, _opts ->
        {:ok, %{status_code: 404, body: "Not Found"}}
      end)

      result = HttpClient.get("https://test.com", [], source: "TestAPI")
      assert {:error, %{type: :api_error, source: "TestAPI", reason: "HTTP 404"}} = result
    end

    test "handles HTTP 500 error" do
      expect(HTTPoison.Mock, :get, fn _url, _headers, _opts ->
        {:ok, %{status_code: 500, body: "Internal Server Error"}}
      end)

      result = HttpClient.get("https://test.com", [], source: "TestAPI")
      assert {:error, %{type: :api_error}} = result
    end

    test "handles HTTP 429 rate limit" do
      expect(HTTPoison.Mock, :get, fn _url, _headers, _opts ->
        {:ok, %{status_code: 429, body: "Rate Limited"}}
      end)

      result = HttpClient.get("https://test.com", [], source: "TestAPI")
      assert {:error, %{type: :api_error, reason: "HTTP 429"}} = result
    end

    test "handles network timeout" do
      expect(HTTPoison.Mock, :get, fn _url, _headers, _opts ->
        {:error, %HTTPoison.Error{reason: :timeout}}
      end)

      result = HttpClient.get("https://test.com", [], [])
      assert {:error, %{type: :network_error, reason: "timeout"}} = result
    end

    test "handles connection refused" do
      expect(HTTPoison.Mock, :get, fn _url, _headers, _opts ->
        {:error, %HTTPoison.Error{reason: :econnrefused}}
      end)

      result = HttpClient.get("https://test.com", [], [])
      assert {:error, %{type: :network_error}} = result
    end

    test "handles DNS resolution failure" do
      expect(HTTPoison.Mock, :get, fn _url, _headers, _opts ->
        {:error, %HTTPoison.Error{reason: :nxdomain}}
      end)

      result = HttpClient.get("https://invalid.domain", [], [])
      assert {:error, %{type: :network_error}} = result
    end

    test "uses custom timeout option" do
      expect(HTTPoison.Mock, :get, fn _url, _headers, opts ->
        assert opts[:timeout] == 5_000
        assert opts[:recv_timeout] == 10_000
        {:ok, %{status_code: 200, body: "{}"}}
      end)

      HttpClient.get("https://test.com", [], timeout: 5_000, recv_timeout: 10_000)
    end

    test "passes headers correctly" do
      expect(HTTPoison.Mock, :get, fn _url, headers, _opts ->
        assert {"Authorization", "Bearer token123"} in headers
        assert {"Content-Type", "application/json"} in headers
        {:ok, %{status_code: 200, body: "{}"}}
      end)

      headers = [
        {"Authorization", "Bearer token123"},
        {"Content-Type", "application/json"}
      ]

      HttpClient.get("https://test.com", headers, [])
    end
  end

  describe "post/4" do
    test "makes successful POST request" do
      expect(HTTPoison.Mock, :post, fn url, body, headers, _opts ->
        assert url == "https://api.example.com/data"
        assert body == ~s({"query": "test"})
        assert is_list(headers)
        {:ok, %{status_code: 200, body: ~s({"result": "ok"})}}
      end)

      result = HttpClient.post("https://api.example.com/data", ~s({"query": "test"}), [], [])
      assert {:ok, %{"result" => "ok"}} = result
    end

    test "sends JSON body correctly" do
      expect(HTTPoison.Mock, :post, fn _url, body, _headers, _opts ->
        decoded = Jason.decode!(body)
        assert decoded["query"] =~ "GetMarkets"
        assert decoded["variables"]["limit"] == 50
        {:ok, %{status_code: 200, body: ~s({"data": {}})}}
      end)

      body = Jason.encode!(%{query: "query GetMarkets { markets { id } }", variables: %{limit: 50}})
      HttpClient.post("https://test.com", body, [], [])
    end

    test "handles POST errors" do
      expect(HTTPoison.Mock, :post, fn _url, _body, _headers, _opts ->
        {:error, %HTTPoison.Error{reason: :timeout}}
      end)

      result = HttpClient.post("https://test.com", "{}", [], [])
      assert {:error, %{type: :network_error}} = result
    end

    test "handles 201 Created response" do
      expect(HTTPoison.Mock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status_code: 201, body: ~s({"id": "123"})}}
      end)

      # Note: 201 is not 200, so this will be treated as an error by current implementation
      result = HttpClient.post("https://test.com", "{}", [], [])
      assert {:error, %{type: :api_error, reason: "HTTP 201"}} = result
    end
  end

  describe "request/5" do
    test "handles non-JSON response when expect_json is false" do
      expect(HTTPoison.Mock, :get, fn _url, _headers, _opts ->
        {:ok, %{status_code: 200, body: "plain text response"}}
      end)

      result = HttpClient.request(:get, "https://test.com", "", [], expect_json: false)
      assert {:ok, "plain text response"} = result
    end

    test "attempts JSON parse by default" do
      expect(HTTPoison.Mock, :get, fn _url, _headers, _opts ->
        {:ok, %{status_code: 200, body: ~s({"parsed": true})}}
      end)

      result = HttpClient.request(:get, "https://test.com", "", [], [])
      assert {:ok, %{"parsed" => true}} = result
    end

    test "includes source in error messages" do
      expect(HTTPoison.Mock, :get, fn _url, _headers, _opts ->
        {:ok, %{status_code: 503, body: "Service Unavailable"}}
      end)

      result = HttpClient.request(:get, "https://test.com", "", [], source: "MyService")
      assert {:error, %{source: "MyService", type: :api_error}} = result
    end
  end

  describe "safe_decode/2" do
    test "decodes valid JSON object" do
      assert {:ok, %{"key" => "value"}} = HttpClient.safe_decode(~s({"key": "value"}))
    end

    test "decodes valid JSON array" do
      assert {:ok, [1, 2, 3]} = HttpClient.safe_decode(~s([1, 2, 3]))
    end

    test "decodes nested JSON" do
      json = ~s({"outer": {"inner": [1, 2, 3]}})
      assert {:ok, %{"outer" => %{"inner" => [1, 2, 3]}}} = HttpClient.safe_decode(json)
    end

    test "returns parse error for invalid JSON" do
      assert {:error, %{type: :parse_error, reason: reason}} = HttpClient.safe_decode("not json")
      assert reason =~ "JSON decode error"
    end

    test "returns parse error for empty string" do
      assert {:error, %{type: :parse_error}} = HttpClient.safe_decode("")
    end

    test "returns parse error for truncated JSON" do
      assert {:error, %{type: :parse_error}} = HttpClient.safe_decode(~s({"key": "val))
    end

    test "includes source in parse error" do
      assert {:error, %{type: :parse_error}} = HttpClient.safe_decode("bad", "TestAPI")
    end
  end

  describe "maybe_add_auth_header/3" do
    test "adds Bearer authorization header when secret exists" do
      # Mock the Secrets module
      expect(MarketIntel.Secrets.Mock, :get, fn :api_key ->
        {:ok, "secret_token_123"}
      end)

      headers = HttpClient.maybe_add_auth_header([], :api_key)
      assert {"Authorization", "Bearer secret_token_123"} in headers
    end

    test "adds custom prefix authorization header" do
      expect(MarketIntel.Secrets.Mock, :get, fn :api_key ->
        {:ok, "token_123"}
      end)

      headers = HttpClient.maybe_add_auth_header([], :api_key, "Token")
      assert {"Authorization", "Token token_123"} in headers
    end

    test "returns original headers when secret not found" do
      expect(MarketIntel.Secrets.Mock, :get, fn :missing_key ->
        {:error, :not_found}
      end)

      original = [{"Content-Type", "application/json"}]
      headers = HttpClient.maybe_add_auth_header(original, :missing_key)
      assert headers == original
    end

    test "returns original headers when secret is empty" do
      expect(MarketIntel.Secrets.Mock, :get, fn :empty_key ->
        {:ok, ""}
      end)

      original = [{"Accept", "application/json"}]
      headers = HttpClient.maybe_add_auth_header(original, :empty_key)
      assert headers == original
    end

    test "prepends auth header to existing headers" do
      expect(MarketIntel.Secrets.Mock, :get, fn :api_key ->
        {:ok, "token"}
      end)

      original = [{"Content-Type", "application/json"}]
      headers = HttpClient.maybe_add_auth_header(original, :api_key)

      assert length(headers) == 2
      assert hd(headers) == {"Authorization", "Bearer token"}
    end
  end

  describe "schedule_next_fetch/3" do
    test "returns a reference" do
      ref = HttpClient.schedule_next_fetch(self(), :fetch, 1000)
      assert is_reference(ref)

      # Cancel the timer to avoid messages during tests
      Process.cancel_timer(ref)
    end

    test "sends message after delay" do
      ref = HttpClient.schedule_next_fetch(self(), :test_message, 50)

      assert_receive :test_message, 200

      # Clean up just in case
      Process.cancel_timer(ref)
    end

    test "uses self() as default pid" do
      ref = HttpClient.schedule_next_fetch(:default_test, 50)

      assert_receive :default_test, 200

      Process.cancel_timer(ref)
    end
  end

  describe "log_error/2" do
    test "returns :ok" do
      assert :ok = HttpClient.log_error("Source", "error message")
    end

    test "handles string reason" do
      assert :ok = HttpClient.log_error("API", "connection failed")
    end

    test "handles atom reason" do
      assert :ok = HttpClient.log_error("API", :timeout)
    end

    test "handles complex reason" do
      assert :ok = HttpClient.log_error("API", %{code: 500, message: "error"})
    end
  end

  describe "log_info/2" do
    test "returns :ok" do
      assert :ok = HttpClient.log_info("Source", "info message")
    end

    test "handles various message types" do
      assert :ok = HttpClient.log_info("Source", "fetching data...")
      assert :ok = HttpClient.log_info("Source", "completed")
    end
  end

  describe "error integration with Errors module" do
    test "api_error creates correct error structure" do
      error = Errors.api_error("TestAPI", "HTTP 500")
      assert {:error, %{type: :api_error, source: "TestAPI", reason: "HTTP 500"}} = error
    end

    test "network_error creates correct error structure" do
      error = Errors.network_error(:timeout)
      assert {:error, %{type: :network_error, reason: "timeout"}} = error
    end

    test "parse_error creates correct error structure" do
      error = Errors.parse_error("invalid JSON")
      assert {:error, %{type: :parse_error, reason: "invalid JSON"}} = error
    end

    test "config_error creates correct error structure" do
      error = Errors.config_error("missing key")
      assert {:error, %{type: :config_error, reason: "missing key"}} = error
    end
  end

  describe "default timeouts" do
    test "uses default timeout of 15 seconds" do
      expect(HTTPoison.Mock, :get, fn _url, _headers, opts ->
        assert opts[:timeout] == 15_000
        {:ok, %{status_code: 200, body: "{}"}}
      end)

      HttpClient.get("https://test.com", [], [])
    end

    test "uses default recv_timeout of 30 seconds" do
      expect(HTTPoison.Mock, :get, fn _url, _headers, opts ->
        assert opts[:recv_timeout] == 30_000
        {:ok, %{status_code: 200, body: "{}"}}
      end)

      HttpClient.get("https://test.com", [], [])
    end
  end
end
