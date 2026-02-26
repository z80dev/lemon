defmodule Ai.ErrorExtendedTest do
  @moduledoc """
  Extended tests for AI error handling functionality.

  Tests cover:
  - Provider-specific error format parsing
  - Rate limit header extraction
  - Retry delay calculation with rate limit info
  - Error classification helpers
  """
  use ExUnit.Case, async: true

  alias Ai.Error

  describe "parse_http_error/3 with various provider formats" do
    test "parses Anthropic error format" do
      body = %{
        "error" => %{
          "type" => "rate_limit_error",
          "message" => "Rate limit exceeded. Please try again later."
        }
      }

      result = Error.parse_http_error(429, body, [])
      assert result.category == :rate_limit
      assert result.status == 429
      assert result.message =~ "Rate limit exceeded"
      # Implementation extracts message only when type+message are both present
      assert result.provider_message == "Rate limit exceeded. Please try again later."
      assert result.retryable == true
    end

    test "parses OpenAI error format with code" do
      body = %{
        "error" => %{
          "code" => "insufficient_quota",
          "message" => "You exceeded your current quota"
        }
      }

      result = Error.parse_http_error(429, body, [])
      assert result.category == :rate_limit
      # Implementation extracts message only, not code
      assert result.provider_message == "You exceeded your current quota"
    end

    test "parses Google API error format" do
      body = %{
        "error" => %{
          "errors" => [
            %{"message" => "API key not valid", "domain" => "global", "reason" => "badRequest"}
          ],
          "code" => 400,
          "message" => "API key not valid"
        }
      }

      result = Error.parse_http_error(400, body, [])
      assert result.category == :client
      assert result.provider_message == "API key not valid"
    end

    test "parses AWS/Bedrock error format" do
      body = %{
        "__type" => "ThrottlingException",
        "message" => "Rate exceeded"
      }

      result = Error.parse_http_error(429, body, [])
      assert result.category == :rate_limit
      # Implementation extracts message from __type + message format
      assert result.provider_message == "Rate exceeded"
    end

    test "parses error with nested error map containing param" do
      body = %{
        "error" => %{
          "type" => "invalid_request_error",
          "code" => "invalid_api_key",
          "message" => "Invalid API key provided",
          "param" => "api_key"
        }
      }

      result = Error.parse_http_error(401, body, [])
      assert result.category == :auth
      # Implementation extracts the message directly
      assert result.provider_message == "Invalid API key provided"
    end

    test "handles plain text error body" do
      body = "Internal Server Error"

      result = Error.parse_http_error(500, body, [])
      assert result.category == :server
      assert result.provider_message == "Internal Server Error"
    end

    test "handles JSON string error body" do
      body = ~s({"error": {"message": "Bad request"}})

      result = Error.parse_http_error(400, body, [])
      assert result.category == :client
      assert result.provider_message == "Bad request"
    end
  end

  describe "extract_rate_limit_info/1" do
    test "extracts standard rate limit headers" do
      headers = [
        {"x-ratelimit-limit-requests", "100"},
        {"x-ratelimit-remaining-requests", "50"},
        {"x-ratelimit-reset-requests", "1640000000"},
        {"retry-after", "60"}
      ]

      result = Error.extract_rate_limit_info(headers)
      assert result.limit == 100
      assert result.remaining == 50
      assert result.reset_at == DateTime.from_unix!(1_640_000_000)
      assert result.retry_after == 60_000
    end

    test "extracts token-based rate limit headers" do
      headers = [
        {"x-ratelimit-limit-tokens", "100000"},
        {"x-ratelimit-remaining-tokens", "50000"},
        {"x-ratelimit-reset-tokens", "1640000000"}
      ]

      result = Error.extract_rate_limit_info(headers)
      assert result.limit == 100_000
      assert result.remaining == 50_000
      assert result.reset_at == DateTime.from_unix!(1_640_000_000)
    end

    test "handles mixed case headers" do
      headers = [
        {"X-RateLimit-Limit-Requests", "100"},
        {"X-RATELIMIT-REMAINING-REQUESTS", "50"}
      ]

      result = Error.extract_rate_limit_info(headers)
      assert result.limit == 100
      assert result.remaining == 50
    end

    test "returns nil for missing headers" do
      headers = []
      result = Error.extract_rate_limit_info(headers)
      assert result.limit == nil
      assert result.remaining == nil
      assert result.reset_at == nil
      assert result.retry_after == nil
    end

    test "handles ratelimit-reset as seconds timestamp" do
      headers = [
        {"ratelimit-reset", "1640000000"}
      ]

      result = Error.extract_rate_limit_info(headers)
      assert result.reset_at == DateTime.from_unix!(1_640_000_000)
    end

    test "handles retry-after as integer" do
      result = Error.extract_rate_limit_info([{"retry-after", "120"}])
      assert result.retry_after == 120_000
    end
  end

  describe "suggested_retry_delay_from_error/1" do
    test "uses retry_after from rate limit info" do
      error = %{
        status: 429,
        rate_limit_info: %{retry_after: 30_000}
      }

      assert Error.suggested_retry_delay_from_error(error) == 30_000
    end

    test "calculates delay from reset_at timestamp" do
      future = DateTime.utc_now() |> DateTime.add(45, :second)

      error = %{
        status: 429,
        rate_limit_info: %{reset_at: future, retry_after: nil}
      }

      delay = Error.suggested_retry_delay_from_error(error)
      # Allow for some time passing during test
      assert delay >= 44_000 and delay <= 46_000
    end

    test "falls back to status-based delay when no rate limit info" do
      error = %{status: 503, rate_limit_info: nil}
      assert Error.suggested_retry_delay_from_error(error) == 5_000
    end

    test "returns nil for unknown errors" do
      assert Error.suggested_retry_delay_from_error(%{}) == nil
    end

    test "returns nil when reset_at is in the past" do
      past = DateTime.utc_now() |> DateTime.add(-10, :second)

      error = %{
        status: 429,
        rate_limit_info: %{reset_at: past, retry_after: nil}
      }

      # When reset_at is in the past and no status fallback provided, returns nil
      assert Error.suggested_retry_delay_from_error(error) == nil
    end
  end

  describe "auth_error?/1" do
    test "returns true for 401 status" do
      assert Error.auth_error?({:http_error, 401, "Unauthorized"}) == true
    end

    test "returns true for 403 status" do
      assert Error.auth_error?({:http_error, 403, "Forbidden"}) == true
    end

    test "returns true for auth category" do
      assert Error.auth_error?(%{category: :auth}) == true
    end

    test "returns false for other errors" do
      assert Error.auth_error?({:http_error, 500, "Server Error"}) == false
      assert Error.auth_error?(%{category: :server}) == false
      assert Error.auth_error?(:timeout) == false
    end
  end

  describe "rate_limit_error?/1" do
    test "returns true for 429 status" do
      assert Error.rate_limit_error?({:http_error, 429, "Rate limited"}) == true
    end

    test "returns true for :rate_limited atom" do
      assert Error.rate_limit_error?(:rate_limited) == true
    end

    test "returns true for rate_limit category" do
      assert Error.rate_limit_error?(%{category: :rate_limit}) == true
    end

    test "returns false for other errors" do
      assert Error.rate_limit_error?({:http_error, 500, "Server Error"}) == false
      assert Error.rate_limit_error?(%{category: :server}) == false
      assert Error.rate_limit_error?(:timeout) == false
    end
  end

  describe "format_rate_limit_info/1" do
    test "formats basic rate limit info" do
      info = %{limit: 100, remaining: 50, reset_at: nil}
      assert Error.format_rate_limit_info(info) == "Rate limit: 50/100 remaining"
    end

    test "includes reset time when available" do
      future = DateTime.utc_now() |> DateTime.add(65, :second)
      info = %{limit: 100, remaining: 50, reset_at: future}

      result = Error.format_rate_limit_info(info)
      assert result =~ "50/100 remaining"
      assert result =~ "resets in"
    end

    test "formats seconds for short resets" do
      future = DateTime.utc_now() |> DateTime.add(30, :second)
      info = %{limit: 100, remaining: 50, reset_at: future}

      result = Error.format_rate_limit_info(info)
      # Allow for slight timing differences (29-30s)
      assert result =~ ~r/resets in (29|30)s/
    end

    test "formats minutes for medium resets" do
      future = DateTime.utc_now() |> DateTime.add(125, :second)
      info = %{limit: 100, remaining: 50, reset_at: future}

      result = Error.format_rate_limit_info(info)
      assert result =~ "2m"
    end

    test "formats hours for long resets" do
      future = DateTime.utc_now() |> DateTime.add(3665, :second)
      info = %{limit: 100, remaining: 50, reset_at: future}

      result = Error.format_rate_limit_info(info)
      assert result =~ "1h"
    end

    test "handles nil values gracefully" do
      assert Error.format_rate_limit_info(nil) == "Rate limit information unavailable"

      info = %{limit: nil, remaining: nil, reset_at: nil}
      assert Error.format_rate_limit_info(info) == "Rate limit: unknown/unknown remaining"
    end
  end

  describe "retryable?/1 edge cases" do
    test "detects retryable status codes" do
      assert Error.retryable?({:http_error, 429, ""}) == true
      assert Error.retryable?({:http_error, 502, ""}) == true
      assert Error.retryable?({:http_error, 503, ""}) == true
      assert Error.retryable?({:http_error, 504, ""}) == true
    end

    test "detects non-retryable status codes" do
      assert Error.retryable?({:http_error, 400, ""}) == false
      assert Error.retryable?({:http_error, 401, ""}) == false
      assert Error.retryable?({:http_error, 404, ""}) == false
    end

    test "handles string error messages" do
      assert Error.retryable?("Request timeout") == true
      assert Error.retryable?("Rate limit exceeded") == true
      assert Error.retryable?("Service overloaded") == true
      assert Error.retryable?("Error 503") == true
      assert Error.retryable?("Something else") == false
    end
  end

  describe "format_error/1 edge cases" do
    test "formats connection errors" do
      assert Error.format_error(:econnrefused) =~ "Connection refused"
      assert Error.format_error(:econnreset) =~ "Connection reset"
      assert Error.format_error(:nxdomain) =~ "DNS lookup failed"
    end

    test "formats binary errors" do
      assert Error.format_error("custom error message") == "custom error message"
    end

    test "formats unknown errors" do
      result = Error.format_error({:unknown, "something"})
      assert result =~ "unexpected error"
      assert result =~ "something"
    end
  end
end
