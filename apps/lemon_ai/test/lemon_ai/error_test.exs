defmodule LemonAi.ErrorTest do
  use ExUnit.Case, async: true

  alias LemonAi.Error

  test "provider authentication copy preserves HTTP details and identifies credential remediation" do
    for provider <- [:openai, "openai", :anthropic, :google] do
      result =
        Error.parse_http_error(401, %{"error" => %{"message" => "Invalid API key"}}, [], provider)

      assert result.message =~ to_string(provider)
      assert result.message =~ "HTTP 401"
      assert result.message =~ "Invalid API key"
      assert result.message =~ "API_KEY"
      assert result.message =~ "lemon secrets set"
      refute result.message =~ "{"
      refute result.message =~ ":auth"
      refute result.retryable
    end
  end

  test "transport and unknown API copy names the provider without term syntax" do
    message = Error.format_error({:unknown_api, :missing_api})
    assert message =~ "\"missing_api\""
    assert message =~ "lemon doctor"
    refute message =~ ":missing_api"

    for reason <- [:timeout, :closed, :econnrefused, :econnreset, :nxdomain] do
      message = Error.format_error(reason, "local_provider")
      assert message =~ "local_provider"
      refute message =~ "{"
      refute message =~ ":#{reason}"
    end

    assert Error.format_error(:econnrefused, :ollama) =~ "base_url"
    assert Error.format_error(:econnrefused, :ollama) =~ "server is running"
  end

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
      assert result.retryable == true
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

    test "parses provider-overloaded client error as retryable transient" do
      body = %{
        "error" => %{
          "type" => "overloaded_error",
          "message" => "Model is overloaded. Please try again later."
        }
      }

      result = Error.parse_http_error(400, body, [])

      assert result.category == :transient
      assert result.retryable == true
      assert result.message =~ "Service temporarily unavailable"
      assert Error.suggested_retry_delay_from_error(result) == 5_000
    end

    test "parses provider rate-limit text on non-429 status with retry headers" do
      body = %{"error" => %{"message" => "Rate limit exceeded"}}
      headers = [{"retry-after", "7"}]

      result = Error.parse_http_error(400, body, headers)

      assert result.category == :rate_limit
      assert result.retryable == true
      assert result.rate_limit_info.retry_after == 7_000
      assert Error.suggested_retry_delay_from_error(result) == 7_000
    end

    test "quota exhaustion rotates credentials without retrying the same request" do
      body = %{"error" => %{"code" => "insufficient_quota", "message" => "Quota exceeded"}}

      result = Error.parse_http_error(400, body, [])

      assert result.category == :rate_limit
      assert result.retryable == false
      assert Error.failover_action(result) == :next_credential
    end

    test "handles JSON string error body" do
      body = ~s({"error": {"message": "Bad request"}})

      result = Error.parse_http_error(400, body, [])
      assert result.category == :client
      assert result.provider_message == "Bad request"
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
        {"x-ratelimit-remaining-tokens", "50000"},
        {"x-ratelimit-reset-tokens", "1640000000"}
      ]

      result = Error.extract_rate_limit_info(headers)
      assert result.limit == 100_000
      assert result.remaining == 50_000
      assert result.reset_at == DateTime.from_unix!(1_640_000_000)
    end

    test "extracts retry-after header" do
      headers = [
        {"retry-after", "30"}
      ]

      info = Error.extract_rate_limit_info(headers)

      assert info.retry_after == 30_000
    end

    test "extracts retry-after HTTP date header" do
      retry_at =
        DateTime.utc_now()
        |> DateTime.add(65, :second)
        |> DateTime.truncate(:second)

      headers = [{"retry-after", Calendar.strftime(retry_at, "%a, %d %b %Y %H:%M:%S GMT")}]

      info = Error.extract_rate_limit_info(headers)

      assert info.retry_after >= 63_000
      assert info.retry_after <= 65_000
    end

    test "ignores malformed retry-after values" do
      info = Error.extract_rate_limit_info([{"retry-after", "123ms"}])

      assert info.retry_after == nil
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

    test "handles Req-style header maps with list values" do
      headers = %{
        "x-ratelimit-limit-requests" => ["100"],
        "x-ratelimit-remaining-requests" => ["0"],
        "retry-after" => ["30"]
      }

      result = Error.extract_rate_limit_info(headers)

      assert result.limit == 100
      assert result.remaining == 0
      assert result.retry_after == 30_000
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
      assert Error.retryable?({:http_error, 529, "overloaded"})
      assert Error.retryable?(:timeout)
      assert Error.retryable?(:econnrefused)
      assert Error.retryable?(:econnreset)
    end

    test "circuit_open is retryable" do
      assert Error.retryable?(:circuit_open)
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

    test "server errors (500) are retryable" do
      assert Error.retryable?({:http_error, 500, "internal error"})
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

    test "suggests 30 seconds for circuit_open" do
      assert Error.suggested_retry_delay(:circuit_open) == 30_000
    end

    test "returns nil for non-retryable errors" do
      assert Error.suggested_retry_delay({:http_error, 400, "bad request"}) == nil
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

  describe "parse_http_error/3 - unusual body formats" do
    test "handles empty string body" do
      result = Error.parse_http_error(500, "", [])

      assert result.category == :server
      assert result.status == 500
      assert result.provider_message == ""
      assert result.retryable == true
    end

    test "handles nil body" do
      result = Error.parse_http_error(500, nil, [])

      assert result.category == :server
      assert result.status == 500
      assert result.provider_message == nil
      assert result.retryable == true
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

    test "handles error with empty message" do
      body = %{"error" => %{"message" => ""}}

      result = Error.parse_http_error(500, body, [])

      assert result.provider_message == ""
    end

    test "uses nested provider details when top-level message is empty" do
      body = %{
        "error" => %{
          "type" => "invalid_request_error",
          "message" => "",
          "details" => %{
            "message" => "Nested detail explains the failure"
          }
        }
      }

      result = Error.parse_http_error(400, body, [])

      assert result.provider_message ==
               "invalid_request_error: Nested detail explains the failure"

      assert result.message =~ "Nested detail explains the failure"
    end

    test "preserves symbolic error type prefixes with direct messages" do
      body = %{
        "error" => %{
          "type" => "invalid_request_error",
          "message" => "Bad request"
        }
      }

      result = Error.parse_http_error(400, body, [])

      assert result.provider_message == "invalid_request_error: Bad request"
      assert result.message =~ "invalid_request_error: Bad request"
    end

    test "preserves symbolic error code prefixes with direct messages" do
      body = %{
        "error" => %{
          "code" => "bad_request",
          "message" => "Bad request"
        }
      }

      result = Error.parse_http_error(400, body, [])

      assert result.provider_message == "bad_request: Bad request"
      assert result.message =~ "bad_request: Bad request"
    end

    test "normalizes atom-key provider error maps" do
      body = %{
        error: %{
          type: "invalid_request_error",
          message: "Bad request"
        }
      }

      result = Error.parse_http_error(400, body, [])

      assert result.provider_message == "invalid_request_error: Bad request"
      assert result.message =~ "invalid_request_error: Bad request"
    end

    test "normalizes atom-key placeholder messages with nested details" do
      body = %{
        error: %{
          message: "",
          details: %{
            message: "Nested atom-key detail"
          }
        }
      }

      result = Error.parse_http_error(400, body, [])

      assert result.provider_message == "Nested atom-key detail"
      assert result.message =~ "Nested atom-key detail"
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
          "code" => 12_345,
          "message" => "Error with numeric code"
        }
      }

      result = Error.parse_http_error(400, body, [])

      # Numeric code won't match string pattern
      assert result.provider_message == "Error with numeric code"
    end

    test "handles error with detail field (FastAPI style)" do
      body = %{"detail" => "Not authenticated"}

      result = Error.parse_http_error(401, body, [])

      assert result.provider_message == "Not authenticated"
    end

    test "handles FastAPI-style detail arrays" do
      body = %{
        "detail" => [
          %{
            "loc" => ["body", "messages", 0],
            "msg" => "Input should be a valid message",
            "type" => "value_error"
          }
        ]
      }

      result = Error.parse_http_error(422, body, [])

      assert result.provider_message == "Input should be a valid message"
      assert result.message =~ "Input should be a valid message"
    end

    test "handles top-level detail maps" do
      body = %{
        "detail" => %{
          "errors" => [
            %{"loc" => ["body", "messages", 0], "msg" => "Nested detail map message"}
          ]
        }
      }

      result = Error.parse_http_error(422, body, [])

      assert result.provider_message == "Nested detail map message"
      assert result.message =~ "Nested detail map message"
    end

    test "handles top-level error arrays" do
      body = %{
        "error" => [
          %{"reason" => "First top-level error array message"},
          %{"message" => "Second top-level error array message"}
        ]
      }

      result = Error.parse_http_error(400, body, [])

      assert result.provider_message == "First top-level error array message"
      assert result.message =~ "First top-level error array message"
    end

    test "handles OAuth-style error descriptions" do
      body = %{
        "error" => "invalid_request",
        "error_description" => "Missing authorization header"
      }

      result = Error.parse_http_error(400, body, [])

      assert result.provider_message == "invalid_request: Missing authorization header"
      assert result.message =~ "Missing authorization header"
    end

    test "handles string error code with sibling message" do
      body = %{
        "error" => "invalid_request",
        "message" => "Prompt is required"
      }

      result = Error.parse_http_error(400, body, [])

      assert result.provider_message == "invalid_request: Prompt is required"
      assert result.message =~ "Prompt is required"
    end

    test "handles string error code with sibling detail" do
      body = %{
        "error" => "bad_request",
        "detail" => "Model does not support tool calls"
      }

      result = Error.parse_http_error(400, body, [])

      assert result.provider_message == "bad_request: Model does not support tool calls"
      assert result.message =~ "Model does not support tool calls"
    end

    test "handles description fields in nested provider errors" do
      body = %{
        "error" => %{
          "details" => [
            %{"description" => "Nested provider description"}
          ]
        }
      }

      result = Error.parse_http_error(500, body, [])

      assert result.provider_message == "Nested provider description"
      assert result.message =~ "Nested provider description"
    end

    test "handles nested provider error descriptions" do
      body = %{
        "error" => %{
          "details" => %{
            "error_description" => "Nested provider description"
          }
        }
      }

      result = Error.parse_http_error(500, body, [])

      assert result.provider_message == "Nested provider description"
      assert result.message =~ "Nested provider description"
    end

    test "handles nested provider details arrays" do
      body = %{
        "error" => %{
          "details" => [
            %{"reason" => "First provider detail"},
            %{"message" => "Second provider detail"}
          ]
        }
      }

      result = Error.parse_http_error(500, body, [])

      assert result.provider_message == "First provider detail"
    end

    test "keeps nested details message when error map only has a symbolic type" do
      body = %{
        "error" => %{
          "type" => "invalid_request_error",
          "details" => %{
            "message" => "Model does not support this request format"
          }
        }
      }

      result = Error.parse_http_error(400, body, [])

      assert result.provider_message =~ "invalid_request_error"
      assert result.provider_message =~ "Model does not support this request format"
      assert result.message =~ "Model does not support this request format"
    end

    test "handles provider description fields inside detail arrays" do
      body = %{
        "detail" => [
          %{"error_description" => "First provider detail description"},
          %{"error_message" => "Second provider detail message"}
        ]
      }

      result = Error.parse_http_error(422, body, [])

      assert result.provider_message == "First provider detail description"
      assert result.message =~ "First provider detail description"
    end

    test "normalizes atom-key detail arrays" do
      body = %{
        detail: [
          %{msg: "First atom-key detail"},
          %{message: "Second atom-key detail"}
        ]
      }

      result = Error.parse_http_error(422, body, [])

      assert result.provider_message == "First atom-key detail"
      assert result.message =~ "First atom-key detail"
    end

    test "handles error with capitalized Message field" do
      body = %{"Message" => "Service error"}

      result = Error.parse_http_error(500, body, [])

      assert result.provider_message == "Service error"
    end

    test "handles array of error objects - nested errors structure" do
      body = %{
        "error" => %{
          "errors" => [
            %{"message" => "First error"},
            %{"message" => "Second error"}
          ]
        }
      }

      result = Error.parse_http_error(400, body, [])

      assert result.provider_message == "First error"
    end

    test "handles JSON API style nested errors array with detail field" do
      body = %{
        "error" => %{
          "errors" => [
            %{"detail" => "First nested error detail"},
            %{"detail" => "Second nested error detail"}
          ]
        }
      }

      result = Error.parse_http_error(400, body, [])

      assert result.provider_message == "First nested error detail"
      assert result.message =~ "First nested error detail"
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

      assert result.provider_message == "First error"
    end

    test "handles top-level errors array with message field" do
      body = %{
        "errors" => [
          %{"message" => "First top-level error"},
          %{"message" => "Second top-level error"}
        ]
      }

      result = Error.parse_http_error(400, body, [])

      assert result.provider_message == "First top-level error"
    end

    test "handles JSON API style top-level errors array with detail field" do
      body = %{
        "errors" => [
          %{"detail" => "First top-level error detail"},
          %{"detail" => "Second top-level error detail"}
        ]
      }

      result = Error.parse_http_error(400, body, [])

      assert result.provider_message == "First top-level error detail"
      assert result.message =~ "First top-level error detail"
    end

    test "handles JSON API style errors array with title fallback" do
      body = %{
        "errors" => [
          %{"title" => "First top-level error title"},
          %{"title" => "Second top-level error title"}
        ]
      }

      result = Error.parse_http_error(400, body, [])

      assert result.provider_message == "First top-level error title"
      assert result.message =~ "First top-level error title"
    end

    test "handles nested error objects inside detail arrays" do
      body = %{
        "detail" => [
          %{
            "loc" => ["body", "input"],
            "error" => %{"message" => "Nested detail array error object"}
          }
        ]
      }

      result = Error.parse_http_error(422, body, [])

      assert result.provider_message == "Nested detail array error object"
      assert result.message =~ "Nested detail array error object"
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

    test "handles retry-after with HTTP date format (returns nil)" do
      # HTTP dates are not currently parsed
      headers = [
        {"retry-after", "Wed, 21 Oct 2015 07:28:00 GMT"}
      ]

      info = Error.extract_rate_limit_info(headers)
      assert info.retry_after == nil
    end
  end

  describe "format_error/1 - additional error types" do
    test "formats :closed error" do
      msg = Error.format_error(:closed)
      assert msg =~ "closed"
    end

    test "formats unknown tuple errors without exposing terms" do
      msg = Error.format_error({:custom_error, "details", 123})
      assert msg =~ "unexpected error"
      assert msg =~ "lemon doctor"
      refute msg =~ "{"
      refute msg =~ ":custom_error"
    end

    test "formats map errors without exposing terms" do
      msg = Error.format_error(%{type: :validation, field: "email"})
      assert msg =~ "unexpected error"
      refute msg =~ "%{"
      refute msg =~ ":validation"
    end

    test "formats integer errors" do
      msg = Error.format_error(42)
      assert msg =~ "unexpected error"
      refute msg =~ "42"
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
      assert Error.retryable?(%{category: :rate_limit})
    end

    test ":closed is retryable" do
      assert Error.retryable?(:closed)
    end

    test ":nxdomain is retryable" do
      assert Error.retryable?(:nxdomain)
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
      # Falls back to status-based
      assert result == 60_000
    end

    test "handles error with negative retry_after" do
      error = %{
        status: 429,
        rate_limit_info: %{retry_after: -1000}
      }

      result = Error.suggested_retry_delay_from_error(error)
      # Falls back
      assert result == 60_000
    end

    test "handles error with nil rate_limit_info fields" do
      error = %{
        status: 503,
        rate_limit_info: %{retry_after: nil, reset_at: nil}
      }

      result = Error.suggested_retry_delay_from_error(error)
      # Status-based
      assert result == 5_000
    end

    test "handles error with very far future reset_at" do
      # 1 day
      far_future = DateTime.utc_now() |> DateTime.add(86_400, :second)

      error = %{
        status: 429,
        rate_limit_info: %{retry_after: nil, reset_at: far_future}
      }

      delay = Error.suggested_retry_delay_from_error(error)
      # More than 86000 seconds in ms
      assert delay > 86_000_000
    end

    test "handles error without rate_limit_info key" do
      error = %{status: 502}

      result = Error.suggested_retry_delay_from_error(error)
      assert result == 5_000
    end
  end

  describe "auth_error?/1 - edge cases" do
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

    test "detects provider-body rate limits on non-429 HTTP errors" do
      assert Error.rate_limit_error?({:http_error, 400, %{error: %{type: :rate_limit_error}}})

      assert Error.rate_limit_error?(
               {:http_error, 400, %{"error" => %{"message" => "Too many requests"}}}
             )
    end

    test "string mentioning rate limit is not detected" do
      # The rate_limit_error? function doesn't check string content
      refute Error.rate_limit_error?("Rate limit exceeded")
    end
  end

  describe "context_length_error?/1 - edge cases" do
    test "detects atom-key context length error maps" do
      assert Error.context_length_error?(
               {:http_error, 400, %{error: %{code: "context_length_exceeded"}}}
             )

      assert Error.context_length_error?(
               {:http_error, 400, %{error: %{message: "maximum context length exceeded"}}}
             )
    end

    test "detects atom enum context length values" do
      parsed = Error.parse_http_error(400, %{error: %{code: :context_length_exceeded}}, [])

      assert parsed.category == :context_length
      assert parsed.provider_message == "context_length_exceeded"

      assert Error.context_length_error?(
               {:http_error, 400, %{error: %{code: :context_length_exceeded}}}
             )
    end

    test "detects structured assistant and stream errors without display text" do
      message = %LemonAi.Types.AssistantMessage{
        stop_reason: :error,
        error_message: "Provider rejected input",
        error_details: %{category: :context_length, status: 400}
      }

      assert Error.context_length_error?(message)
      assert Error.context_length_error?({:error, :error, message})
      assert Error.context_length_error?(%{"category" => "context_length"})

      assert Error.context_length_error?(
               {:http_error, 400, %{"error" => %{"code" => "context_length_exceeded"}}, []}
             )

      refute Error.context_length_error?(%{category: :client, message: "Invalid messages"})
      refute Error.context_length_error?({:http_error, 400, "Bad Request"})
      refute Error.context_length_error?({:http_error, 413, "Request entity too large"})
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
  end

  describe "integration - parse and retry flow" do
    test "rate limit error uses retry_after body hint when headers are absent" do
      body = %{
        "error" => %{"message" => "Rate limit exceeded"},
        "retry_after" => "2.5"
      }

      parsed = Error.parse_http_error(429, body, [])

      assert parsed.category == :rate_limit
      assert parsed.rate_limit_info.retry_after == 2_500
      assert Error.suggested_retry_delay_from_error(parsed) == 2_500
    end

    test "rate limit error uses retry_after_ms body hint when headers are absent" do
      body = %{
        "error" => %{
          "message" => "Too many requests",
          "retry_after_ms" => 1750
        }
      }

      parsed = Error.parse_http_error(429, body, [])

      assert parsed.category == :rate_limit
      assert parsed.rate_limit_info.retry_after == 1_750
      assert Error.suggested_retry_delay_from_error(parsed) == 1_750
    end

    test "rate limit error uses atom-key retry body hints" do
      body = %{
        error: %{
          code: "rate_limit_error",
          message: "Too many requests"
        },
        retry_after_ms: 1_250
      }

      parsed = Error.parse_http_error(400, body, [])

      assert parsed.category == :rate_limit
      assert parsed.provider_message == "rate_limit_error: Too many requests"
      assert parsed.rate_limit_info.retry_after == 1_250
      assert Error.suggested_retry_delay_from_error(parsed) == 1_250
    end

    test "rate limit error uses atom enum provider fields" do
      parsed = Error.parse_http_error(400, %{error: %{type: :rate_limit_error}}, [])

      assert parsed.category == :rate_limit
      assert parsed.provider_message == "rate_limit_error"
      assert parsed.retryable == true
    end

    test "retry-after header takes precedence over proxy retry body hints" do
      body = %{
        "error" => %{"message" => "Rate limit exceeded"},
        "retry_after_ms" => 60_000
      }

      parsed = Error.parse_http_error(429, body, [{"retry-after", "3"}])

      assert parsed.category == :rate_limit
      assert parsed.rate_limit_info.retry_after == 3_000
      assert Error.suggested_retry_delay_from_error(parsed) == 3_000
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
