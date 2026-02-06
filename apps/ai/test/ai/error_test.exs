defmodule Ai.ErrorTest do
  use ExUnit.Case, async: true

  alias Ai.Error

  describe "parse_http_error/3" do
    test "parses rate limit error with headers" do
      headers = [
        {"x-ratelimit-limit-requests", "1000"},
        {"x-ratelimit-remaining-requests", "0"},
        {"retry-after", "60"}
      ]

      result =
        Error.parse_http_error(429, %{"error" => %{"message" => "Rate limit exceeded"}}, headers)

      assert result.category == :rate_limit
      assert result.status == 429
      assert result.message =~ "Rate limit exceeded"
      assert result.provider_message == "Rate limit exceeded"
      assert result.retryable == true
      assert result.rate_limit_info.limit == 1000
      assert result.rate_limit_info.remaining == 0
      assert result.rate_limit_info.retry_after == 60_000
    end

    test "parses server error" do
      result = Error.parse_http_error(500, "Internal Server Error", [])

      assert result.category == :server
      assert result.status == 500
      assert result.message =~ "Server error"
      assert result.retryable == false
    end

    test "parses auth error" do
      result = Error.parse_http_error(401, %{"error" => "Invalid API key"}, [])

      assert result.category == :auth
      assert result.status == 401
      assert result.message =~ "Authentication failed"
      assert result.retryable == false
    end

    test "parses client error" do
      result =
        Error.parse_http_error(400, %{"error" => %{"message" => "Invalid request body"}}, [])

      assert result.category == :client
      assert result.status == 400
      assert result.message =~ "Invalid request"
      assert result.retryable == false
    end

    test "parses transient error (503)" do
      result = Error.parse_http_error(503, "Service Unavailable", [])

      assert result.category == :transient
      assert result.status == 503
      assert result.message =~ "Service temporarily unavailable"
      assert result.retryable == true
    end

    test "parses transient error (502)" do
      result = Error.parse_http_error(502, "Bad Gateway", [])

      assert result.category == :transient
      assert result.retryable == true
    end

    test "parses transient error (504)" do
      result = Error.parse_http_error(504, "Gateway Timeout", [])

      assert result.category == :transient
      assert result.retryable == true
    end
  end

  describe "extract_rate_limit_info/1" do
    test "extracts OpenAI-style rate limit headers" do
      headers = [
        {"x-ratelimit-limit-requests", "1000"},
        {"x-ratelimit-remaining-requests", "999"},
        {"x-ratelimit-reset-requests", "1704067200"}
      ]

      info = Error.extract_rate_limit_info(headers)

      assert info.limit == 1000
      assert info.remaining == 999
      assert info.reset_at != nil
    end

    test "extracts token-based rate limit headers" do
      headers = [
        {"x-ratelimit-limit-tokens", "100000"},
        {"x-ratelimit-remaining-tokens", "50000"}
      ]

      info = Error.extract_rate_limit_info(headers)

      assert info.limit == 100_000
      assert info.remaining == 50_000
    end

    test "extracts retry-after header" do
      headers = [
        {"retry-after", "30"}
      ]

      info = Error.extract_rate_limit_info(headers)

      assert info.retry_after == 30_000
    end

    test "handles missing headers" do
      info = Error.extract_rate_limit_info([])

      assert info.limit == nil
      assert info.remaining == nil
      assert info.reset_at == nil
      assert info.retry_after == nil
    end

    test "handles case-insensitive headers" do
      headers = [
        {"X-RateLimit-Limit-Requests", "500"},
        {"X-RateLimit-Remaining-Requests", "100"}
      ]

      info = Error.extract_rate_limit_info(headers)

      assert info.limit == 500
      assert info.remaining == 100
    end
  end

  describe "format_error/1" do
    test "formats HTTP errors" do
      assert Error.format_error(
               {:http_error, 429, %{"error" => %{"message" => "Rate limit exceeded"}}}
             ) =~
               "Rate limit exceeded"
    end

    test "formats rate_limited atom" do
      assert Error.format_error(:rate_limited) =~ "rate limited"
    end

    test "formats circuit_open" do
      assert Error.format_error(:circuit_open) =~ "circuit breaker"
    end

    test "formats max_concurrency" do
      assert Error.format_error(:max_concurrency) =~ "concurrent requests"
    end

    test "formats timeout" do
      assert Error.format_error(:timeout) =~ "timed out"
    end

    test "formats connection errors" do
      assert Error.format_error(:econnrefused) =~ "refused"
      assert Error.format_error(:econnreset) =~ "reset"
      assert Error.format_error(:nxdomain) =~ "DNS"
    end

    test "formats unknown_api" do
      assert Error.format_error({:unknown_api, :some_api}) =~ "Unknown API type"
    end

    test "passes through string errors" do
      assert Error.format_error("Custom error message") == "Custom error message"
    end

    test "handles unknown errors" do
      assert Error.format_error(%{some: :error}) =~ "unexpected error"
    end
  end

  describe "retryable?/1" do
    test "rate limit errors are retryable" do
      assert Error.retryable?({:http_error, 429, "rate limited"})
      assert Error.retryable?(:rate_limited)
    end

    test "transient errors are retryable" do
      assert Error.retryable?({:http_error, 502, "bad gateway"})
      assert Error.retryable?({:http_error, 503, "unavailable"})
      assert Error.retryable?({:http_error, 504, "timeout"})
      assert Error.retryable?(:timeout)
      assert Error.retryable?(:econnrefused)
      assert Error.retryable?(:econnreset)
    end

    test "circuit_open is not retryable" do
      refute Error.retryable?(:circuit_open)
    end

    test "max_concurrency is retryable" do
      assert Error.retryable?(:max_concurrency)
    end

    test "unknown_api is not retryable" do
      refute Error.retryable?({:unknown_api, :some_api})
    end

    test "client errors (4xx except 429) are not retryable" do
      refute Error.retryable?({:http_error, 400, "bad request"})
      refute Error.retryable?({:http_error, 401, "unauthorized"})
      refute Error.retryable?({:http_error, 403, "forbidden"})
      refute Error.retryable?({:http_error, 404, "not found"})
    end

    test "server errors (500) are not retryable" do
      refute Error.retryable?({:http_error, 500, "internal error"})
    end

    test "string errors with retryable keywords are retryable" do
      assert Error.retryable?("Connection timeout")
      assert Error.retryable?("Rate limit exceeded")
      assert Error.retryable?("Server temporarily unavailable")
      assert Error.retryable?("HTTP 503")
      assert Error.retryable?("Service overloaded")
    end

    test "string errors without retryable keywords are not retryable" do
      refute Error.retryable?("Invalid API key")
      refute Error.retryable?("Bad request format")
    end
  end

  describe "suggested_retry_delay/1" do
    test "suggests 60 seconds for rate limit" do
      assert Error.suggested_retry_delay({:http_error, 429, "rate limited"}) == 60_000
      assert Error.suggested_retry_delay(:rate_limited) == 60_000
    end

    test "suggests shorter delay for transient errors" do
      assert Error.suggested_retry_delay({:http_error, 503, "unavailable"}) == 5_000
      assert Error.suggested_retry_delay({:http_error, 502, "bad gateway"}) == 5_000
      assert Error.suggested_retry_delay(:timeout) == 5_000
    end

    test "suggests 10 seconds for gateway timeout and connection refused" do
      assert Error.suggested_retry_delay({:http_error, 504, "timeout"}) == 10_000
      assert Error.suggested_retry_delay(:econnrefused) == 10_000
    end

    test "returns nil for non-retryable errors" do
      assert Error.suggested_retry_delay({:http_error, 400, "bad request"}) == nil
      assert Error.suggested_retry_delay(:circuit_open) == nil
    end
  end
end
