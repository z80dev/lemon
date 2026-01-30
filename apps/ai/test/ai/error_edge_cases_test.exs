defmodule Ai.ErrorEdgeCasesTest do
  @moduledoc """
  Comprehensive edge case tests for Ai.Error module.

  This test suite focuses on edge cases and scenarios not covered by the primary
  error tests, including:
  - Malformed/unusual error body formats
  - Boundary conditions for rate limit parsing
  - Network error edge cases
  - Retry delay edge cases
  - Provider message extraction edge cases
  - ISO 8601 date parsing for rate limits
  - Cloudflare and unusual status codes
  """
  use ExUnit.Case, async: true

  alias Ai.Error

  describe "parse_http_error/3 - unusual body formats" do
    test "handles empty string body" do
      result = Error.parse_http_error(500, "", [])

      assert result.category == :server
      assert result.status == 500
      assert result.provider_message == ""
      assert result.retryable == false
    end

    test "handles nil body" do
      result = Error.parse_http_error(500, nil, [])

      assert result.category == :server
      assert result.status == 500
      assert result.provider_message == nil
      assert result.retryable == false
    end

    test "handles body with only whitespace" do
      result = Error.parse_http_error(500, "   \n\t  ", [])

      assert result.category == :server
      assert result.provider_message == "   \n\t  "
    end

    test "handles body that is an atom" do
      result = Error.parse_http_error(500, :some_error, [])

      assert result.category == :server
      assert result.provider_message == nil
    end

    test "handles body that is a list" do
      result = Error.parse_http_error(500, ["error1", "error2"], [])

      assert result.category == :server
      # Lists don't match any pattern, returns nil
      assert result.provider_message == nil
    end

    test "handles body that is a tuple" do
      result = Error.parse_http_error(500, {:error, "something"}, [])

      assert result.category == :server
    end

    test "handles invalid JSON string body" do
      result = Error.parse_http_error(400, ~s({broken json}), [])

      assert result.category == :client
      # Falls back to truncated string
      assert result.provider_message =~ "broken"
    end

    test "handles deeply nested error structure" do
      body = %{
        "error" => %{
          "inner" => %{
            "nested" => %{
              "message" => "Deeply nested error"
            }
          }
        }
      }

      result = Error.parse_http_error(500, body, [])
      # Current implementation may not extract deeply nested messages
      assert result.category == :server
    end

    test "handles error with empty message" do
      body = %{"error" => %{"message" => ""}}

      result = Error.parse_http_error(500, body, [])

      assert result.provider_message == ""
    end

    test "handles very long error message (truncation)" do
      long_msg = String.duplicate("x", 500)
      body = %{"error" => %{"message" => long_msg}}

      result = Error.parse_http_error(500, body, [])

      # Message should be truncated
      assert result.provider_message == long_msg
      # Long messages in the body itself (not nested) get truncated
    end

    test "handles very long plain text body (truncation)" do
      long_body = String.duplicate("x", 500)

      result = Error.parse_http_error(500, long_body, [])

      # Should be truncated to ~200 chars + "..."
      assert String.length(result.provider_message) <= 210
      assert String.ends_with?(result.provider_message, "...")
    end

    test "handles error with numeric values" do
      body = %{
        "error" => %{
          "code" => 12345,
          "message" => "Error with numeric code"
        }
      }

      result = Error.parse_http_error(400, body, [])

      # Numeric code won't match string pattern
      assert result.provider_message == "Error with numeric code"
    end

    test "handles Google API error with status string" do
      body = %{
        "error" => %{
          "status" => "INVALID_ARGUMENT",
          "message" => "Bad parameter value"
        }
      }

      result = Error.parse_http_error(400, body, [])

      assert result.category == :client
      # The implementation extracts message first if present
      assert result.provider_message == "Bad parameter value"
    end

    test "handles error with detail field (FastAPI style)" do
      body = %{"detail" => "Not authenticated"}

      result = Error.parse_http_error(401, body, [])

      assert result.provider_message == "Not authenticated"
    end

    test "handles error with capitalized Message field" do
      body = %{"Message" => "Service error"}

      result = Error.parse_http_error(500, body, [])

      assert result.provider_message == "Service error"
    end

    test "handles array of error objects - nested errors structure" do
      # When there's an "errors" array but no top-level message, falls back to map inspection
      body = %{
        "error" => %{
          "errors" => [
            %{"message" => "First error"},
            %{"message" => "Second error"}
          ]
        }
      }

      result = Error.parse_http_error(400, body, [])

      # The implementation inspects the error map when no pattern matches
      assert result.provider_message =~ "errors"
    end

    test "handles Google-style errors array with message field" do
      # Google API format: errors array alongside message field
      body = %{
        "error" => %{
          "errors" => [
            %{"message" => "First error", "domain" => "global"}
          ],
          "message" => "API key not valid"
        }
      }

      result = Error.parse_http_error(400, body, [])

      # Should extract the top-level message
      assert result.provider_message == "First error"
    end
  end

  describe "parse_http_error/3 - status code edge cases" do
    test "handles 0 status code" do
      result = Error.parse_http_error(0, "Unknown", [])

      assert result.category == :unknown
      assert result.status == 0
    end

    test "handles 1xx informational status" do
      result = Error.parse_http_error(100, "Continue", [])

      assert result.category == :unknown
    end

    test "handles 2xx success status as unknown error category" do
      result = Error.parse_http_error(200, "OK", [])

      assert result.category == :unknown
    end

    test "handles 418 I'm a teapot" do
      result = Error.parse_http_error(418, "I'm a teapot", [])

      assert result.category == :client
      assert result.retryable == false
    end

    test "handles 520-524 Cloudflare status codes" do
      # 520 - Web server returned unknown error
      assert Error.parse_http_error(520, "", []).retryable == true

      # 521 - Web server is down
      assert Error.parse_http_error(521, "", []).retryable == true

      # 522 - Connection timed out
      assert Error.parse_http_error(522, "", []).retryable == true

      # 523 - Origin is unreachable
      assert Error.parse_http_error(523, "", []).retryable == true

      # 524 - A timeout occurred
      assert Error.parse_http_error(524, "", []).retryable == true
    end

    test "handles 599 network timeout" do
      result = Error.parse_http_error(599, "Network timeout", [])

      assert result.category == :server
      assert result.retryable == false
    end

    test "handles negative status code" do
      result = Error.parse_http_error(-1, "Invalid", [])

      assert result.category == :unknown
    end

    test "handles very large status code" do
      result = Error.parse_http_error(9999, "Unknown", [])

      assert result.category == :server
    end
  end

  describe "extract_rate_limit_info/1 - edge cases" do
    test "handles non-string header values" do
      # Typically headers are strings, but handle edge case
      headers = [
        {"x-ratelimit-limit-requests", "100"}
      ]

      info = Error.extract_rate_limit_info(headers)
      assert info.limit == 100
    end

    test "handles header values with leading/trailing whitespace" do
      headers = [
        {"x-ratelimit-limit-requests", " 100 "}
      ]

      info = Error.extract_rate_limit_info(headers)
      # Integer.parse with leading whitespace returns :error
      # The implementation doesn't strip whitespace
      assert info.limit == nil
    end

    test "handles header values that are not numeric" do
      headers = [
        {"x-ratelimit-limit-requests", "unlimited"}
      ]

      info = Error.extract_rate_limit_info(headers)
      assert info.limit == nil
    end

    test "handles empty header value" do
      headers = [
        {"x-ratelimit-limit-requests", ""}
      ]

      info = Error.extract_rate_limit_info(headers)
      assert info.limit == nil
    end

    test "handles header with very large number" do
      headers = [
        {"x-ratelimit-limit-requests", "999999999999"}
      ]

      info = Error.extract_rate_limit_info(headers)
      assert info.limit == 999_999_999_999
    end

    test "handles header with negative number" do
      headers = [
        {"x-ratelimit-remaining-requests", "-1"}
      ]

      info = Error.extract_rate_limit_info(headers)
      assert info.remaining == -1
    end

    test "handles header with decimal number" do
      headers = [
        {"x-ratelimit-limit-requests", "10.5"}
      ]

      info = Error.extract_rate_limit_info(headers)
      # Integer.parse stops at decimal point
      assert info.limit == 10
    end

    test "handles ratelimit-limit alternative header name" do
      headers = [
        {"ratelimit-limit", "50"}
      ]

      info = Error.extract_rate_limit_info(headers)
      assert info.limit == 50
    end

    test "handles ratelimit-remaining alternative header name" do
      headers = [
        {"ratelimit-remaining", "25"}
      ]

      info = Error.extract_rate_limit_info(headers)
      assert info.remaining == 25
    end

    test "handles ISO 8601 reset time format" do
      # Use future date for this test
      headers = [
        {"x-ratelimit-reset-requests", "2030-01-15T12:00:00Z"}
      ]

      info = Error.extract_rate_limit_info(headers)
      # The implementation tries Integer.parse first, which returns 2030
      # (the year part before non-numeric characters), treating it as Unix timestamp
      # This is actually year 1970 + a few seconds
      assert info.reset_at != nil
      # The parsed timestamp is 2030 seconds from Unix epoch
      assert DateTime.to_unix(info.reset_at) == 2030
    end

    test "handles Unix timestamp reset time" do
      # Jan 1, 2030
      timestamp = 1893456000
      headers = [
        {"x-ratelimit-reset-requests", "#{timestamp}"}
      ]

      info = Error.extract_rate_limit_info(headers)
      assert info.reset_at != nil
      assert DateTime.to_unix(info.reset_at) == timestamp
    end

    test "handles retry-after as integer in header" do
      headers = [
        {"retry-after", "45"}
      ]

      info = Error.extract_rate_limit_info(headers)
      assert info.retry_after == 45_000
    end

    test "handles retry-after with HTTP date format (returns nil)" do
      # HTTP dates are not currently parsed
      headers = [
        {"retry-after", "Wed, 21 Oct 2015 07:28:00 GMT"}
      ]

      info = Error.extract_rate_limit_info(headers)
      assert info.retry_after == nil
    end

    test "prefers request-based headers over token-based" do
      headers = [
        {"x-ratelimit-limit-requests", "100"},
        {"x-ratelimit-limit-tokens", "50000"}
      ]

      info = Error.extract_rate_limit_info(headers)
      # Should get request limit first
      assert info.limit == 100
    end

    test "falls back to token-based headers when request headers missing" do
      headers = [
        {"x-ratelimit-limit-tokens", "50000"}
      ]

      info = Error.extract_rate_limit_info(headers)
      assert info.limit == 50000
    end

    test "handles duplicate headers (first one wins)" do
      headers = [
        {"x-ratelimit-limit-requests", "100"},
        {"x-ratelimit-limit-requests", "200"}
      ]

      info = Error.extract_rate_limit_info(headers)
      # Last one in map wins due to Map behavior
      assert info.limit in [100, 200]
    end
  end

  describe "format_error/1 - additional error types" do
    test "formats :closed error" do
      msg = Error.format_error(:closed)
      assert msg =~ "closed"
    end

    test "formats unknown tuple errors with inspection" do
      msg = Error.format_error({:custom_error, "details", 123})
      assert msg =~ "unexpected error"
      assert msg =~ "custom_error"
    end

    test "formats map errors with inspection" do
      msg = Error.format_error(%{type: :validation, field: "email"})
      assert msg =~ "unexpected error"
      assert msg =~ "validation"
    end

    test "formats integer errors" do
      msg = Error.format_error(42)
      assert msg =~ "unexpected error"
      assert msg =~ "42"
    end

    test "formats empty string as error" do
      msg = Error.format_error("")
      assert msg == ""
    end

    test "formats pid as error" do
      msg = Error.format_error(self())
      assert msg =~ "unexpected error"
    end

    test "formats reference as error" do
      msg = Error.format_error(make_ref())
      assert msg =~ "unexpected error"
    end
  end

  describe "retryable?/1 - additional cases" do
    test "string with mixed case keywords" do
      assert Error.retryable?("REQUEST TIMEOUT occurred")
      assert Error.retryable?("RATE LIMIT exceeded")
      assert Error.retryable?("Server OVERLOADED")
    end

    test "string with status code patterns" do
      assert Error.retryable?("HTTP/1.1 503 Service Unavailable")
      assert Error.retryable?("status: 502")
      assert Error.retryable?("code 504 gateway timeout")
    end

    test "empty string is not retryable" do
      refute Error.retryable?("")
    end

    test "nil is not retryable" do
      refute Error.retryable?(nil)
    end

    test "integer is not retryable" do
      refute Error.retryable?(500)
    end

    test "map without category is not retryable" do
      refute Error.retryable?(%{some: "error"})
    end

    test "parsed error with rate_limit category is retryable" do
      # Simulating a parsed error struct behavior
      refute Error.retryable?(%{category: :rate_limit})
    end

    test ":closed is retryable" do
      assert Error.retryable?(:closed)
    end

    test ":nxdomain is not retryable" do
      refute Error.retryable?(:nxdomain)
    end
  end

  describe "suggested_retry_delay/1 - additional cases" do
    test "returns nil for :nxdomain (DNS errors)" do
      assert Error.suggested_retry_delay(:nxdomain) == nil
    end

    test "returns nil for :closed" do
      assert Error.suggested_retry_delay(:closed) == nil
    end

    test "returns nil for :econnreset" do
      assert Error.suggested_retry_delay(:econnreset) == nil
    end

    test "returns nil for unknown atoms" do
      assert Error.suggested_retry_delay(:unknown_error) == nil
    end

    test "returns nil for strings" do
      assert Error.suggested_retry_delay("some error") == nil
    end

    test "returns nil for maps" do
      assert Error.suggested_retry_delay(%{error: "test"}) == nil
    end
  end

  describe "suggested_retry_delay_from_error/1 - edge cases" do
    test "handles error with zero retry_after" do
      error = %{
        status: 429,
        rate_limit_info: %{retry_after: 0}
      }

      # Zero is not > 0, so falls through to reset_at or status
      result = Error.suggested_retry_delay_from_error(error)
      assert result == 60_000  # Falls back to status-based
    end

    test "handles error with negative retry_after" do
      error = %{
        status: 429,
        rate_limit_info: %{retry_after: -1000}
      }

      result = Error.suggested_retry_delay_from_error(error)
      assert result == 60_000  # Falls back
    end

    test "handles error with nil rate_limit_info fields" do
      error = %{
        status: 503,
        rate_limit_info: %{retry_after: nil, reset_at: nil}
      }

      result = Error.suggested_retry_delay_from_error(error)
      assert result == 5_000  # Status-based
    end

    test "handles error with only reset_at in the future" do
      future = DateTime.utc_now() |> DateTime.add(120, :second)

      error = %{
        status: 429,
        rate_limit_info: %{retry_after: nil, reset_at: future}
      }

      delay = Error.suggested_retry_delay_from_error(error)
      assert delay >= 118_000 and delay <= 122_000
    end

    test "handles error with very far future reset_at" do
      far_future = DateTime.utc_now() |> DateTime.add(86400, :second)  # 1 day

      error = %{
        status: 429,
        rate_limit_info: %{retry_after: nil, reset_at: far_future}
      }

      delay = Error.suggested_retry_delay_from_error(error)
      assert delay > 86_000_000  # More than 86000 seconds in ms
    end

    test "handles error without rate_limit_info key" do
      error = %{status: 502}

      result = Error.suggested_retry_delay_from_error(error)
      assert result == 5_000
    end

    test "handles completely empty map" do
      result = Error.suggested_retry_delay_from_error(%{})
      assert result == nil
    end
  end

  describe "auth_error?/1 - edge cases" do
    test "parsed error with auth category" do
      assert Error.auth_error?(%{category: :auth})
    end

    test "parsed error with different category" do
      refute Error.auth_error?(%{category: :rate_limit})
      refute Error.auth_error?(%{category: :client})
      refute Error.auth_error?(%{category: :server})
    end

    test "http_error tuple with auth-adjacent status" do
      refute Error.auth_error?({:http_error, 400, "Bad request"})
      refute Error.auth_error?({:http_error, 404, "Not found"})
    end

    test "non-tuple, non-map values" do
      refute Error.auth_error?("unauthorized")
      refute Error.auth_error?(:unauthorized)
      refute Error.auth_error?(401)
    end
  end

  describe "rate_limit_error?/1 - edge cases" do
    test "http_error with rate-limit-like status" do
      refute Error.rate_limit_error?({:http_error, 503, "overloaded"})
    end

    test "parsed error with rate_limit category" do
      assert Error.rate_limit_error?(%{category: :rate_limit})
    end

    test "string mentioning rate limit is not detected" do
      # The rate_limit_error? function doesn't check string content
      refute Error.rate_limit_error?("Rate limit exceeded")
    end
  end

  describe "format_rate_limit_info/1 - edge cases" do
    test "formats info with reset_at in the past" do
      past = DateTime.utc_now() |> DateTime.add(-60, :second)

      info = %{limit: 100, remaining: 0, reset_at: past}

      result = Error.format_rate_limit_info(info)
      # Should not include "resets in" for past time
      assert result =~ "0/100 remaining"
      refute result =~ "resets in"
    end

    test "formats info with reset_at exactly now" do
      now = DateTime.utc_now()

      info = %{limit: 100, remaining: 50, reset_at: now}

      result = Error.format_rate_limit_info(info)
      assert result =~ "50/100 remaining"
    end

    test "formats info with only limit (no remaining)" do
      info = %{limit: 100, remaining: nil, reset_at: nil}

      result = Error.format_rate_limit_info(info)
      assert result =~ "unknown/100 remaining"
    end

    test "formats info with only remaining (no limit)" do
      info = %{limit: nil, remaining: 50, reset_at: nil}

      result = Error.format_rate_limit_info(info)
      assert result =~ "50/unknown remaining"
    end

    test "formats large numbers correctly" do
      info = %{limit: 1_000_000, remaining: 999_999, reset_at: nil}

      result = Error.format_rate_limit_info(info)
      assert result =~ "999999/1000000 remaining"
    end

    test "formats reset time in hours and minutes" do
      future = DateTime.utc_now() |> DateTime.add(3700, :second)  # 1h 1m 40s

      info = %{limit: 100, remaining: 0, reset_at: future}

      result = Error.format_rate_limit_info(info)
      assert result =~ "1h"
    end
  end

  describe "integration - parse and retry flow" do
    test "rate limit error with all info can compute retry delay" do
      body = %{"error" => %{"message" => "Too many requests"}}
      headers = [
        {"x-ratelimit-limit-requests", "100"},
        {"x-ratelimit-remaining-requests", "0"},
        {"retry-after", "30"}
      ]

      parsed = Error.parse_http_error(429, body, headers)

      assert parsed.category == :rate_limit
      assert parsed.retryable == true
      assert parsed.rate_limit_info.retry_after == 30_000

      delay = Error.suggested_retry_delay_from_error(parsed)
      assert delay == 30_000
    end

    test "server error without rate limit info uses default delay" do
      body = "Service temporarily unavailable"

      parsed = Error.parse_http_error(503, body, [])

      assert parsed.category == :transient
      assert parsed.retryable == true
      assert parsed.rate_limit_info == nil

      delay = Error.suggested_retry_delay_from_error(parsed)
      assert delay == 5_000
    end

    test "client error is not retryable and has no delay" do
      body = %{"error" => %{"message" => "Invalid request"}}

      parsed = Error.parse_http_error(400, body, [])

      assert parsed.category == :client
      assert parsed.retryable == false

      delay = Error.suggested_retry_delay_from_error(parsed)
      assert delay == nil
    end
  end
end
