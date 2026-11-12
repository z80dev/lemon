defmodule LemonAi.ErrorProviderTest do
  use ExUnit.Case, async: true

  alias LemonAi.Error

  # ============================================================================
  # Provider-Specific Error Response Parsing
  # ============================================================================

  describe "Anthropic error format parsing" do
    test "parses Anthropic overloaded error" do
      body = %{
        "error" => %{
          "type" => "overloaded_error",
          "message" => "Overloaded"
        }
      }

      result = Error.parse_http_error(529, body, [])

      assert result.category == :transient
      assert result.provider_message == "overloaded_error: Overloaded"
      assert result.retryable == true
    end
  end

  describe "OpenAI error format parsing" do
    test "parses OpenAI context_length_exceeded error" do
      body = %{
        "error" => %{
          "message" =>
            "This model's maximum context length is 8192 tokens. However, you requested 10000 tokens.",
          "type" => "invalid_request_error",
          "param" => "messages",
          "code" => "context_length_exceeded"
        }
      }

      result = Error.parse_http_error(400, body, [])

      assert result.category == :context_length
      assert result.provider_message =~ "maximum context length"
      assert result.message =~ "Context length exceeded"
      assert Error.context_length_error?(result)
    end
  end

  describe "AWS Bedrock error format parsing" do
    test "parses Bedrock ThrottlingException" do
      body = %{
        "__type" => "ThrottlingException",
        "message" => "Too many requests, please wait before trying again."
      }

      result = Error.parse_http_error(429, body, [])

      assert result.category == :rate_limit
      assert result.provider_message =~ "Too many requests"
    end
  end

  # ============================================================================
  # Rate Limit Header Extraction - All Provider Variants
  # ============================================================================

  describe "rate limit header extraction - OpenAI format" do
    test "extracts OpenAI request-based rate limits" do
      before = DateTime.utc_now()

      headers = [
        {"x-ratelimit-limit-requests", "10000"},
        {"x-ratelimit-remaining-requests", "9999"},
        {"x-ratelimit-reset-requests", "1ms"}
      ]

      info = Error.extract_rate_limit_info(headers)

      assert info.limit == 10_000
      assert info.remaining == 9999
      assert DateTime.diff(info.reset_at, before, :millisecond) >= 0
    end

    test "extracts OpenAI token-based rate limits" do
      before = DateTime.utc_now()

      headers = [
        {"x-ratelimit-limit-tokens", "1000000"},
        {"x-ratelimit-remaining-tokens", "999500"},
        {"x-ratelimit-reset-tokens", "6m0s"}
      ]

      info = Error.extract_rate_limit_info(headers)

      assert info.limit == 1_000_000
      assert info.remaining == 999_500
      assert DateTime.diff(info.reset_at, before, :millisecond) in 359_000..361_000
    end

    test "request limits take precedence over token limits" do
      headers = [
        {"x-ratelimit-limit-requests", "100"},
        {"x-ratelimit-limit-tokens", "50000"},
        {"x-ratelimit-remaining-requests", "50"},
        {"x-ratelimit-remaining-tokens", "25000"}
      ]

      info = Error.extract_rate_limit_info(headers)

      assert info.limit == 100
      assert info.remaining == 50
    end
  end

  describe "rate limit header extraction - standard ratelimit format" do
    test "extracts standard ratelimit-limit header" do
      headers = [
        {"ratelimit-limit", "500"},
        {"ratelimit-remaining", "400"},
        {"ratelimit-reset", "1640000000"}
      ]

      info = Error.extract_rate_limit_info(headers)

      assert info.limit == 500
      assert info.remaining == 400
      assert info.reset_at == DateTime.from_unix!(1_640_000_000)
    end
  end

  describe "rate limit header extraction - Azure format" do
    test "extracts Azure rate limit headers" do
      headers = [
        {"x-ratelimit-remaining-requests", "100"},
        {"x-ratelimit-remaining-tokens", "50000"},
        {"retry-after-ms", "1000"}
      ]

      info = Error.extract_rate_limit_info(headers)

      assert info.remaining == 100
      assert info.retry_after == 1000
    end

    test "extracts Azure x-ms retry-after header" do
      headers = [
        {"x-ms-retry-after-ms", "2500"}
      ]

      info = Error.extract_rate_limit_info(headers)

      assert info.retry_after == 2500
    end
  end

  # ============================================================================
  # DateTime Parsing from Rate-Limit Headers
  # ============================================================================

  describe "DateTime parsing from rate-limit headers" do
    test "parses Unix timestamp (seconds)" do
      # 2024-01-01 00:00:00 UTC
      timestamp = 1_704_067_200

      headers = [
        {"x-ratelimit-reset-requests", "#{timestamp}"}
      ]

      info = Error.extract_rate_limit_info(headers)

      assert info.reset_at == DateTime.from_unix!(timestamp)
    end

    test "parses Unix timestamp in milliseconds" do
      timestamp_ms = 1_704_067_200_000

      headers = [
        {"x-ratelimit-reset-requests", "#{timestamp_ms}"}
      ]

      info = Error.extract_rate_limit_info(headers)

      assert info.reset_at == DateTime.from_unix!(timestamp_ms, :millisecond)
    end

    test "parses ISO 8601 datetime" do
      headers = [
        {"x-ratelimit-reset-requests", "2024-01-15T12:00:00Z"}
      ]

      info = Error.extract_rate_limit_info(headers)

      assert info.reset_at == ~U[2024-01-15 12:00:00Z]
    end

    test "returns nil for non-parseable reset time" do
      headers = [
        {"x-ratelimit-reset-requests", "invalid"}
      ]

      info = Error.extract_rate_limit_info(headers)

      assert info.reset_at == nil
    end

    test "prioritizes request reset over token reset" do
      headers = [
        {"x-ratelimit-reset-requests", "1704067200"},
        {"x-ratelimit-reset-tokens", "1704070800"}
      ]

      info = Error.extract_rate_limit_info(headers)

      assert info.reset_at == DateTime.from_unix!(1_704_067_200)
    end

    test "retry-after preserves fractional seconds as milliseconds" do
      headers = [
        {"retry-after", "30.5"}
      ]

      info = Error.extract_rate_limit_info(headers)

      assert info.retry_after == 30_500
    end

    test "handles empty reset value" do
      headers = [
        {"x-ratelimit-reset-requests", ""}
      ]

      info = Error.extract_rate_limit_info(headers)

      assert info.reset_at == nil
    end
  end

  # ============================================================================
  # Error Categorization for Uncommon Status Codes
  # ============================================================================

  describe "error categorization for uncommon status codes" do
    test "categorizes 418 I'm a Teapot as client error" do
      result = Error.parse_http_error(418, "I'm a teapot", [])

      assert result.category == :client
      assert result.status == 418
      assert result.retryable == false
      assert result.message =~ "Invalid request"
    end

    test "categorizes 599 Network Connect Timeout as server error" do
      result = Error.parse_http_error(599, "Network Connect Timeout Error", [])

      assert result.category == :server
      assert result.status == 599
      assert result.retryable == true
    end

    test "categorizes 408 Request Timeout as transient error" do
      result = Error.parse_http_error(408, "Request Timeout", [])

      assert result.category == :transient
      assert result.retryable == true
    end

    test "categorizes 413 Payload Too Large as client error" do
      result = Error.parse_http_error(413, "Request entity too large", [])

      assert result.category == :client
      assert result.retryable == false
    end

    test "categorizes 501 Not Implemented as server error" do
      result = Error.parse_http_error(501, "Not Implemented", [])

      assert result.category == :server
      assert result.retryable == true
    end

    test "Cloudflare 520 is retryable" do
      result = Error.parse_http_error(520, "Web server returned unknown error", [])

      assert result.category == :server
      assert result.retryable == true
    end

    test "Cloudflare 521 is retryable" do
      result = Error.parse_http_error(521, "Web server is down", [])

      assert result.category == :server
      assert result.retryable == true
    end

    test "Cloudflare 522 is retryable" do
      result = Error.parse_http_error(522, "Connection timed out", [])

      assert result.category == :server
      assert result.retryable == true
    end

    test "Cloudflare 523 is retryable" do
      result = Error.parse_http_error(523, "Origin is unreachable", [])

      assert result.category == :server
      assert result.retryable == true
    end

    test "Cloudflare 524 is retryable" do
      result = Error.parse_http_error(524, "A timeout occurred", [])

      assert result.category == :server
      assert result.retryable == true
    end

    test "Cloudflare 525 SSL handshake failed is server error" do
      result = Error.parse_http_error(525, "SSL Handshake Failed", [])

      assert result.category == :server
      assert result.retryable == true
    end
  end

  # ============================================================================
  # Complex Nested Error Body Structures
  # ============================================================================

  describe "complex nested error body structures" do
    test "handles deeply nested error message" do
      body = %{
        "error" => %{
          "details" => %{
            "inner" => %{
              "message" => "Deeply nested message"
            }
          }
        }
      }

      result = Error.parse_http_error(500, body, [])

      assert result.category == :server
      assert result.provider_message == "Deeply nested message"
    end

    test "handles error with multiple nested objects" do
      body = %{
        "error" => %{
          "type" => "validation_error",
          "code" => "invalid_field",
          "message" => "Field validation failed",
          "details" => %{
            "field" => "email",
            "constraint" => "format"
          }
        }
      }

      result = Error.parse_http_error(400, body, [])

      assert result.category == :client
      assert result.provider_message == "validation_error: Field validation failed"
    end

    test "handles error with null values" do
      body = %{
        "error" => %{
          "type" => nil,
          "code" => nil,
          "message" => "Something went wrong"
        }
      }

      result = Error.parse_http_error(500, body, [])

      assert result.category == :server
      assert result.provider_message == "Something went wrong"
    end

    test "handles error where error value is a list" do
      body = %{
        "error" => ["Error 1", "Error 2"]
      }

      result = Error.parse_http_error(400, body, [])

      # List doesn't match any specific pattern, falls back to map inspection
      assert result.category == :client
      assert result.provider_message =~ "Error 1"
    end

    test "handles error with nested arrays in details" do
      body = %{
        "error" => %{
          "message" => "Validation failed",
          "violations" => [
            %{"field" => "items[0].quantity", "message" => "Must be positive"},
            %{"field" => "items[1].price", "message" => "Required"}
          ]
        }
      }

      result = Error.parse_http_error(400, body, [])

      assert result.category == :client
      assert result.provider_message == "Validation failed"
    end

    test "handles nested provider messages without top-level message fields" do
      body = %{
        "error" => %{
          "details" => %{
            "violations" => [
              %{"field" => "items[0].quantity", "msg" => "Nested array message"}
            ]
          }
        }
      }

      result = Error.parse_http_error(400, body, [])

      assert result.category == :client
      assert result.provider_message == "Nested array message"
    end
  end

  # ============================================================================
  # Missing or Malformed Error Fields
  # ============================================================================

  describe "missing or malformed error fields" do
    test "handles empty error object" do
      body = %{"error" => %{}}

      result = Error.parse_http_error(500, body, [])

      assert result.category == :server
      # Empty map inspection
      assert result.provider_message =~ "%{}"
    end

    test "handles error field as empty string" do
      body = %{"error" => ""}

      result = Error.parse_http_error(500, body, [])

      assert result.category == :server
      assert result.provider_message == ""
    end

    test "handles error field as nil" do
      body = %{"error" => nil}

      result = Error.parse_http_error(500, body, [])

      assert result.category == :server
      # nil error value doesn't match specific patterns, falls back to map inspection
      assert result.provider_message =~ "error"
    end

    test "handles message field as nil" do
      body = %{"error" => %{"message" => nil, "type" => "error"}}

      result = Error.parse_http_error(500, body, [])

      assert result.category == :server
      # nil message doesn't match binary pattern, but "type" alone is extracted
      assert result.provider_message == "error"
    end

    test "handles message field as number" do
      body = %{"error" => %{"message" => 12_345}}

      result = Error.parse_http_error(500, body, [])

      assert result.category == :server
      # Numeric message doesn't match binary pattern
      assert result.provider_message =~ "12345"
    end

    test "handles type field as number" do
      body = %{"error" => %{"type" => 500, "message" => "Server error"}}

      result = Error.parse_http_error(500, body, [])

      assert result.category == :server
      assert result.provider_message == "Server error"
    end

    test "handles body as raw binary" do
      body = <<0, 1, 2, 3, 4>>

      result = Error.parse_http_error(500, body, [])

      assert result.category == :server
      # Raw binary won't parse as JSON, returns truncated version
      assert result.provider_message == body
    end

    test "handles body as integer" do
      body = 500

      result = Error.parse_http_error(500, body, [])

      assert result.category == :server
      assert result.provider_message == nil
    end

    test "handles partially valid JSON with extra content" do
      body = ~s({"error": "valid"}extra content)

      result = Error.parse_http_error(400, body, [])

      assert result.category == :client
      # Jason.decode should fail, falls back to string
      assert result.provider_message =~ "error"
    end

    test "handles very long field values" do
      long_value = String.duplicate("x", 1000)

      body = %{
        "error" => %{
          "type" => long_value,
          "message" => long_value
        }
      }

      result = Error.parse_http_error(500, body, [])

      assert result.category == :server
      # Message extraction for well-structured responses doesn't truncate
      assert result.provider_message == long_value
    end
  end

  # ============================================================================
  # Integration Tests - Full Parse and Retry Flow
  # ============================================================================

  describe "integration - provider error handling flow" do
    test "Anthropic rate limit error with headers" do
      body = %{
        "error" => %{
          "type" => "rate_limit_error",
          "message" => "Rate limit exceeded"
        }
      }

      headers = [
        {"x-ratelimit-limit-requests", "1000"},
        {"x-ratelimit-remaining-requests", "0"},
        {"retry-after", "45"}
      ]

      result = Error.parse_http_error(429, body, headers)

      assert result.category == :rate_limit
      assert result.retryable == true
      assert result.rate_limit_info.limit == 1000
      assert result.rate_limit_info.remaining == 0
      assert result.rate_limit_info.retry_after == 45_000

      # Retry delay should use rate limit info
      delay = Error.suggested_retry_delay_from_error(result)
      assert delay == 45_000
    end

    test "OpenAI quota error with headers" do
      body = %{
        "error" => %{
          "code" => "insufficient_quota",
          "message" => "You exceeded your current quota"
        }
      }

      headers = [
        {"x-ratelimit-limit-tokens", "1000000"},
        {"x-ratelimit-remaining-tokens", "0"},
        {"x-ratelimit-reset-tokens",
         "#{DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.to_unix()}"}
      ]

      result = Error.parse_http_error(429, body, headers)

      assert result.category == :rate_limit
      assert result.retryable == false
      assert result.rate_limit_info.limit == 1_000_000
      assert result.rate_limit_info.remaining == 0
      assert result.rate_limit_info.reset_at != nil

      # Retry delay should use reset_at
      delay = Error.suggested_retry_delay_from_error(result)
      assert delay >= 58_000 and delay <= 62_000
    end

    test "Google RetryInfo body supplies retry delay when headers are missing" do
      body = %{
        "error" => %{
          "code" => 429,
          "message" => "Quota exceeded for quota metric",
          "status" => "RESOURCE_EXHAUSTED",
          "details" => [
            %{
              "@type" => "type.googleapis.com/google.rpc.RetryInfo",
              "retryDelay" => "3.5s"
            }
          ]
        }
      }

      result = Error.parse_http_error(429, body, [])

      assert result.category == :rate_limit
      assert result.retryable == true
      assert result.rate_limit_info.retry_after == 3_500
      assert Error.suggested_retry_delay_from_error(result) == 3_500
    end

    test "Google minute quotas and ambiguous quota messages remain transient across boundaries" do
      for message <- [
            "Quota exhausted for this project",
            "You exceeded your current quota, please check your plan and billing details.",
            "Quota exceeded for requests per minute"
          ],
          quota_id <- [nil, "GenerateRequestsPerMinutePerProjectPerModel-FreeTier"],
          status <- [400, 429] do
        body = %{
          "error" => %{
            "message" => message,
            "status" => "RESOURCE_EXHAUSTED",
            "details" => [
              %{
                "@type" => "type.googleapis.com/google.rpc.QuotaFailure",
                "violations" => if(quota_id, do: [%{"quotaId" => quota_id}], else: [])
              },
              %{
                "@type" => "type.googleapis.com/google.rpc.RetryInfo",
                "retryDelay" => "3.5s"
              }
            ]
          }
        }

        for encoded_body <- [body, Jason.encode!(body)] do
          result = Error.parse_http_error(status, encoded_body)

          assert result.category == :rate_limit
          assert result.retryable
          assert Error.retryable?(result)
          assert Error.retryable?(result.message)
          assert Error.retryable?(Jason.decode!(Jason.encode!(result)))
          refute Error.quota_exhausted?(result)
          assert result.rate_limit_info.retry_after == 3_500
        end
      end
    end

    test "Google daily QuotaFailure overrides RetryInfo even alongside a minute violation" do
      body = %{
        "error" => %{
          "message" => "Quota exceeded for quota metric",
          "status" => "RESOURCE_EXHAUSTED",
          "details" => [
            %{
              "@type" => "type.googleapis.com/google.rpc.RetryInfo",
              "retryDelay" => "3.5s"
            },
            %{
              "@type" => "type.googleapis.com/google.rpc.QuotaFailure",
              "violations" => [
                %{"quotaId" => "GenerateRequestsPerMinutePerProjectPerModel-FreeTier"},
                %{"quotaId" => "GenerateRequestsPerDayPerProjectPerModel-FreeTier"}
              ]
            }
          ]
        }
      }

      for status <- [400, 429], encoded_body <- [body, Jason.encode!(body)] do
        result = Error.parse_http_error(status, encoded_body, [{"retry-after", "5"}])

        assert result.category == :rate_limit
        refute result.retryable
        refute Error.retryable?(result)
        refute Error.retryable?(result.message)
        refute Error.retryable?(Jason.decode!(Jason.encode!(result)))
        assert Error.quota_exhausted?(result)
        assert result.provider_message =~ "GenerateRequestsPerDayPerProjectPerModel-FreeTier"
        assert result.rate_limit_info.retry_after == 5_000
      end
    end

    test "Google explicit billing and plan exhaustion still fail fast despite RetryInfo" do
      for message <- [
            "Billing quota exhausted",
            "Plan quota exceeded",
            "Insufficient credits",
            "Daily quota exhausted"
          ] do
        body = %{
          "error" => %{
            "message" => message,
            "status" => "RESOURCE_EXHAUSTED",
            "details" => [
              %{
                "@type" => "type.googleapis.com/google.rpc.RetryInfo",
                "retryDelay" => "2s"
              }
            ]
          }
        }

        result = Error.parse_http_error(429, body)
        assert result.category == :rate_limit
        refute result.retryable
        refute Error.retryable?(result.message)
        assert Error.quota_exhausted?(result)
        assert result.rate_limit_info.retry_after == 2_000
      end
    end

    test "retry-after header takes precedence over Google RetryInfo body" do
      body = %{
        "error" => %{
          "code" => 429,
          "message" => "Quota exceeded for quota metric",
          "status" => "RESOURCE_EXHAUSTED",
          "details" => [
            %{
              "@type" => "type.googleapis.com/google.rpc.RetryInfo",
              "retryDelay" => "30s"
            }
          ]
        }
      }

      result = Error.parse_http_error(429, body, [{"retry-after", "5"}])

      assert result.category == :rate_limit
      assert result.rate_limit_info.retry_after == 5_000
      assert Error.suggested_retry_delay_from_error(result) == 5_000
    end

    test "provider rate-limit body shape overrides non-429 status" do
      body = %{
        "error" => %{
          "code" => 400,
          "message" => "Quota exhausted for this project",
          "status" => "RESOURCE_EXHAUSTED",
          "details" => [
            %{
              "@type" => "type.googleapis.com/google.rpc.RetryInfo",
              "retryDelay" => "2s"
            }
          ]
        }
      }

      result = Error.parse_http_error(400, body, [])

      assert result.category == :rate_limit
      assert result.retryable == true
      assert result.rate_limit_info.retry_after == 2_000
    end
  end
end
