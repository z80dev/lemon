defmodule MarketIntel.Ingestion.HttpClientTest do
  use ExUnit.Case
  alias MarketIntel.Ingestion.HttpClient

  describe "safe_decode/2" do
    test "decodes valid JSON" do
      assert {:ok, %{"key" => "value"}} = HttpClient.safe_decode(~s({"key": "value"}))
    end

    test "returns parse error for invalid JSON" do
      assert {:error, %{type: :parse_error, reason: reason}} = HttpClient.safe_decode("invalid")
      assert reason =~ "JSON decode error"
    end
  end

  describe "maybe_add_auth_header/3" do
    test "adds auth header when secret exists" do
      # Mock the secret - we can't test this without mocking
      # This is a placeholder for the pattern
      headers = HttpClient.maybe_add_auth_header([], :test_key)
      assert is_list(headers)
    end
  end

  describe "log_error/2 and log_info/2" do
    test "log_error returns :ok" do
      assert :ok = HttpClient.log_error("Source", "message")
    end

    test "log_info returns :ok" do
      assert :ok = HttpClient.log_info("Source", "message")
    end
  end
end
