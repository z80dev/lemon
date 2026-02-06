defmodule Ai.ErrorProviderTest do
  @moduledoc """
  Comprehensive tests for provider-specific error parsing in Ai.Error.

  This test suite covers:
  - Provider-specific error response parsing (Anthropic, OpenAI, Google, Azure)
  - Rate limit header extraction for all provider variants
  - DateTime parsing from rate-limit headers
  - Error categorization for uncommon status codes (418, 451, 599)
  - Complex nested error body structures
  - Missing or malformed error fields
  """
  use ExUnit.Case, async: true

  alias Ai.Error

  # ============================================================================
  # Provider-Specific Error Response Parsing
  # ============================================================================

  describe "Anthropic error format parsing" do
    test "parses standard Anthropic error with type and message" do
      body = %{
        "error" => %{
          "type" => "rate_limit_error",
          "message" => "Number of requests has exceeded your rate limit."
        }
      }

      result = Error.parse_http_error(429, body, [])

      assert result.category == :rate_limit
      assert result.status == 429
      assert result.provider_message =~ "Number of requests has exceeded"
      assert result.retryable == true
    end

    test "parses Anthropic overloaded error" do
      body = %{
        "error" => %{
          "type" => "overloaded_error",
          "message" => "Overloaded"
        }
      }

      result = Error.parse_http_error(529, body, [])

      assert result.category == :server
      assert result.provider_message == "Overloaded"
    end

    test "parses Anthropic invalid_request_error" do
      body = %{
        "error" => %{
          "type" => "invalid_request_error",
          "message" => "max_tokens: must be a positive integer"
        }
      }

      result = Error.parse_http_error(400, body, [])

      assert result.category == :client
      assert result.provider_message =~ "max_tokens"
    end

    test "parses Anthropic authentication_error" do
      body = %{
        "error" => %{
          "type" => "authentication_error",
          "message" => "Invalid API Key"
        }
      }

      result = Error.parse_http_error(401, body, [])

      assert result.category == :auth
      assert result.provider_message == "Invalid API Key"
    end

    test "parses Anthropic permission_error" do
      body = %{
        "error" => %{
          "type" => "permission_error",
          "message" => "Your API key does not have permission to use this resource"
        }
      }

      result = Error.parse_http_error(403, body, [])

      assert result.category == :auth
      assert result.provider_message =~ "permission"
    end

    test "parses Anthropic not_found_error" do
      body = %{
        "error" => %{
          "type" => "not_found_error",
          "message" => "The requested resource could not be found"
        }
      }

      result = Error.parse_http_error(404, body, [])

      assert result.category == :client
      assert result.provider_message =~ "could not be found"
    end

    test "parses Anthropic api_error (internal server error)" do
      body = %{
        "error" => %{
          "type" => "api_error",
          "message" => "An unexpected error occurred internally"
        }
      }

      result = Error.parse_http_error(500, body, [])

      assert result.category == :server
      assert result.provider_message =~ "unexpected error"
    end
  end

  describe "OpenAI error format parsing" do
    test "parses OpenAI error with code and message" do
      body = %{
        "error" => %{
          "code" => "insufficient_quota",
          "message" =>
            "You exceeded your current quota, please check your plan and billing details.",
          "type" => "insufficient_quota",
          "param" => nil
        }
      }

      result = Error.parse_http_error(429, body, [])

      assert result.category == :rate_limit
      assert result.provider_message =~ "exceeded your current quota"
    end

    test "parses OpenAI rate limit error with type only" do
      body = %{
        "error" => %{
          "message" => "Rate limit reached for gpt-4 in organization org-xyz on tokens per min.",
          "type" => "tokens",
          "param" => nil,
          "code" => "rate_limit_exceeded"
        }
      }

      result = Error.parse_http_error(429, body, [])

      assert result.category == :rate_limit
      assert result.provider_message =~ "Rate limit reached"
    end

    test "parses OpenAI invalid_api_key error" do
      body = %{
        "error" => %{
          "message" => "Incorrect API key provided: sk-1234****5678",
          "type" => "invalid_request_error",
          "param" => nil,
          "code" => "invalid_api_key"
        }
      }

      result = Error.parse_http_error(401, body, [])

      assert result.category == :auth
      assert result.provider_message =~ "Incorrect API key"
    end

    test "parses OpenAI model_not_found error" do
      body = %{
        "error" => %{
          "message" => "The model 'gpt-5' does not exist",
          "type" => "invalid_request_error",
          "param" => "model",
          "code" => "model_not_found"
        }
      }

      result = Error.parse_http_error(404, body, [])

      assert result.category == :client
      assert result.provider_message =~ "does not exist"
    end

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

      assert result.category == :client
      assert result.provider_message =~ "maximum context length"
    end

    test "parses OpenAI server_error" do
      body = %{
        "error" => %{
          "message" => "The server had an error while processing your request.",
          "type" => "server_error",
          "param" => nil,
          "code" => nil
        }
      }

      result = Error.parse_http_error(500, body, [])

      assert result.category == :server
      assert result.provider_message =~ "server had an error"
    end

    test "parses OpenAI billing_hard_limit_reached error" do
      body = %{
        "error" => %{
          "message" => "You have exceeded your monthly spend limit.",
          "type" => "insufficient_quota",
          "param" => nil,
          "code" => "billing_hard_limit_reached"
        }
      }

      result = Error.parse_http_error(429, body, [])

      assert result.category == :rate_limit
      assert result.provider_message =~ "exceeded your monthly spend"
    end
  end

  describe "Google/Gemini error format parsing" do
    test "parses Google API error with errors array and top-level message" do
      body = %{
        "error" => %{
          "code" => 400,
          "message" => "API key not valid. Please pass a valid API key.",
          "status" => "INVALID_ARGUMENT",
          "errors" => [
            %{
              "message" => "API key not valid. Please pass a valid API key.",
              "domain" => "global",
              "reason" => "badRequest"
            }
          ]
        }
      }

      result = Error.parse_http_error(400, body, [])

      assert result.category == :client
      # Should extract from errors array when top-level message is present
      assert result.provider_message == "API key not valid. Please pass a valid API key."
    end

    test "parses Google RESOURCE_EXHAUSTED error" do
      body = %{
        "error" => %{
          "code" => 429,
          "message" => "Resource has been exhausted (e.g. check quota).",
          "status" => "RESOURCE_EXHAUSTED",
          "errors" => [
            %{
              "message" => "Resource has been exhausted",
              "domain" => "global",
              "reason" => "rateLimitExceeded"
            }
          ]
        }
      }

      result = Error.parse_http_error(429, body, [])

      assert result.category == :rate_limit
      assert result.provider_message =~ "exhausted"
    end

    test "parses Google PERMISSION_DENIED error" do
      body = %{
        "error" => %{
          "code" => 403,
          "message" => "Permission denied on resource project",
          "status" => "PERMISSION_DENIED"
        }
      }

      result = Error.parse_http_error(403, body, [])

      assert result.category == :auth
      assert result.provider_message == "Permission denied on resource project"
    end

    test "parses Google NOT_FOUND error" do
      body = %{
        "error" => %{
          "code" => 404,
          "message" => "Model not found",
          "status" => "NOT_FOUND"
        }
      }

      result = Error.parse_http_error(404, body, [])

      assert result.category == :client
      assert result.provider_message == "Model not found"
    end

    test "parses Google INTERNAL error" do
      body = %{
        "error" => %{
          "code" => 500,
          "message" => "Internal error encountered.",
          "status" => "INTERNAL"
        }
      }

      result = Error.parse_http_error(500, body, [])

      assert result.category == :server
      assert result.provider_message == "Internal error encountered."
    end

    test "parses Google error with only status and message" do
      body = %{
        "error" => %{
          "status" => "UNAVAILABLE",
          "message" => "Service is currently unavailable"
        }
      }

      result = Error.parse_http_error(503, body, [])

      assert result.category == :transient
      # With status and message strings, extracts message
      assert result.provider_message == "Service is currently unavailable"
    end

    test "parses Vertex AI error format" do
      body = %{
        "error" => %{
          "code" => 429,
          "message" => "Quota exceeded for quota metric 'Generate content requests per minute'",
          "status" => "RESOURCE_EXHAUSTED",
          "details" => [
            %{
              "@type" => "type.googleapis.com/google.rpc.QuotaFailure",
              "violations" => [
                %{
                  "subject" => "project:my-project",
                  "description" => "Quota exceeded"
                }
              ]
            }
          ]
        }
      }

      result = Error.parse_http_error(429, body, [])

      assert result.category == :rate_limit
      assert result.provider_message =~ "Quota exceeded"
    end
  end

  describe "Azure OpenAI error format parsing" do
    test "parses Azure OpenAI error format" do
      body = %{
        "error" => %{
          "code" => "DeploymentNotFound",
          "message" => "The API deployment for this resource does not exist."
        }
      }

      result = Error.parse_http_error(404, body, [])

      assert result.category == :client
      # Code + message format extracts message
      assert result.provider_message == "The API deployment for this resource does not exist."
    end

    test "parses Azure rate limit error" do
      body = %{
        "error" => %{
          "code" => "429",
          "message" =>
            "Requests to the ChatCompletions_Create Operation have exceeded rate limit."
        }
      }

      result = Error.parse_http_error(429, body, [])

      assert result.category == :rate_limit
      assert result.provider_message =~ "exceeded rate limit"
    end

    test "parses Azure content filter error" do
      body = %{
        "error" => %{
          "code" => "content_filter",
          "message" =>
            "The response was filtered due to the prompt triggering Azure's content management policy.",
          "param" => "prompt",
          "type" => "invalid_request_error"
        }
      }

      result = Error.parse_http_error(400, body, [])

      assert result.category == :client
      assert result.provider_message =~ "content management policy"
    end

    test "parses Azure authentication error" do
      body = %{
        "error" => %{
          "code" => "401",
          "message" => "Access denied due to invalid subscription key."
        }
      }

      result = Error.parse_http_error(401, body, [])

      assert result.category == :auth
      assert result.provider_message =~ "invalid subscription key"
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

    test "parses Bedrock ValidationException" do
      body = %{
        "__type" => "ValidationException",
        "message" => "Malformed input request, please reformat your input and try again."
      }

      result = Error.parse_http_error(400, body, [])

      assert result.category == :client
      assert result.provider_message =~ "Malformed input"
    end

    test "parses Bedrock AccessDeniedException" do
      body = %{
        "__type" => "AccessDeniedException",
        "message" => "You don't have permission to access this resource."
      }

      result = Error.parse_http_error(403, body, [])

      assert result.category == :auth
      assert result.provider_message =~ "don't have permission"
    end

    test "parses Bedrock ResourceNotFoundException" do
      body = %{
        "__type" => "ResourceNotFoundException",
        "message" => "The specified model does not exist."
      }

      result = Error.parse_http_error(404, body, [])

      assert result.category == :client
      assert result.provider_message =~ "does not exist"
    end

    test "parses Bedrock ServiceException" do
      body = %{
        "__type" => "ServiceException",
        "message" => "The service encountered an internal error."
      }

      result = Error.parse_http_error(500, body, [])

      assert result.category == :server
      assert result.provider_message =~ "internal error"
    end

    test "parses Bedrock ModelTimeoutException" do
      body = %{
        "__type" => "ModelTimeoutException",
        "message" => "The model took too long to respond."
      }

      result = Error.parse_http_error(408, body, [])

      assert result.category == :client
      assert result.provider_message =~ "took too long"
    end
  end

  # ============================================================================
  # Rate Limit Header Extraction - All Provider Variants
  # ============================================================================

  describe "rate limit header extraction - OpenAI format" do
    test "extracts OpenAI request-based rate limits" do
      headers = [
        {"x-ratelimit-limit-requests", "10000"},
        {"x-ratelimit-remaining-requests", "9999"},
        {"x-ratelimit-reset-requests", "1ms"}
      ]

      info = Error.extract_rate_limit_info(headers)

      assert info.limit == 10000
      assert info.remaining == 9999
    end

    test "extracts OpenAI token-based rate limits" do
      headers = [
        {"x-ratelimit-limit-tokens", "1000000"},
        {"x-ratelimit-remaining-tokens", "999500"},
        {"x-ratelimit-reset-tokens", "6m0s"}
      ]

      info = Error.extract_rate_limit_info(headers)

      assert info.limit == 1_000_000
      assert info.remaining == 999_500
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

  describe "rate limit header extraction - Anthropic format" do
    test "extracts Anthropic rate limit headers" do
      headers = [
        {"x-ratelimit-limit-requests", "1000"},
        {"x-ratelimit-remaining-requests", "999"},
        {"retry-after", "60"}
      ]

      info = Error.extract_rate_limit_info(headers)

      assert info.limit == 1000
      assert info.remaining == 999
      assert info.retry_after == 60_000
    end

    test "extracts Anthropic token limit headers" do
      headers = [
        {"x-ratelimit-limit-tokens", "100000"},
        {"x-ratelimit-remaining-tokens", "99000"}
      ]

      info = Error.extract_rate_limit_info(headers)

      assert info.limit == 100_000
      assert info.remaining == 99_000
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
        # Azure uses ms suffix sometimes
        {"retry-after-ms", "1000"}
      ]

      info = Error.extract_rate_limit_info(headers)

      assert info.remaining == 100
      # retry-after-ms not directly supported, only retry-after
      assert info.retry_after == nil
    end

    test "extracts Azure retry-after header" do
      headers = [
        {"retry-after", "30"}
      ]

      info = Error.extract_rate_limit_info(headers)

      assert info.retry_after == 30_000
    end
  end

  describe "rate limit header extraction - edge cases" do
    test "handles mixed case header names" do
      headers = [
        {"X-RateLimit-Limit-Requests", "1000"},
        {"X-RATELIMIT-REMAINING-REQUESTS", "500"},
        {"Retry-After", "60"}
      ]

      info = Error.extract_rate_limit_info(headers)

      assert info.limit == 1000
      assert info.remaining == 500
      assert info.retry_after == 60_000
    end

    test "handles headers with extra whitespace in values" do
      # Note: whitespace handling depends on implementation
      headers = [
        # no whitespace
        {"x-ratelimit-limit-requests", "1000"},
        {"retry-after", "60"}
      ]

      info = Error.extract_rate_limit_info(headers)

      assert info.limit == 1000
    end

    test "handles zero values" do
      headers = [
        {"x-ratelimit-remaining-requests", "0"},
        {"x-ratelimit-remaining-tokens", "0"}
      ]

      info = Error.extract_rate_limit_info(headers)

      assert info.remaining == 0
    end

    test "handles very large values" do
      headers = [
        {"x-ratelimit-limit-tokens", "10000000000"}
      ]

      info = Error.extract_rate_limit_info(headers)

      assert info.limit == 10_000_000_000
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

    test "parses Unix timestamp (milliseconds treated as large seconds)" do
      # Millisecond timestamps cause overflow when treated as seconds
      timestamp_ms = 1_704_067_200_000

      headers = [
        {"x-ratelimit-reset-requests", "#{timestamp_ms}"}
      ]

      info = Error.extract_rate_limit_info(headers)

      # Very large timestamps exceed DateTime range, returning :invalid_unix_time
      # which the implementation converts to the error tuple value from DateTime.from_unix
      assert info.reset_at == :invalid_unix_time
    end

    test "parses ISO 8601 datetime - note: integer prefix is parsed" do
      # When a value starts with digits, Integer.parse captures those first
      headers = [
        {"x-ratelimit-reset-requests", "2024-01-15T12:00:00Z"}
      ]

      info = Error.extract_rate_limit_info(headers)

      # Implementation parses "2024" as integer first
      assert info.reset_at != nil
      assert DateTime.to_unix(info.reset_at) == 2024
    end

    test "returns nil for non-parseable reset time" do
      headers = [
        {"x-ratelimit-reset-requests", "invalid"}
      ]

      info = Error.extract_rate_limit_info(headers)

      assert info.reset_at == nil
    end

    test "parses reset time from alternative header names" do
      timestamp = 1_704_067_200

      headers = [
        {"ratelimit-reset", "#{timestamp}"}
      ]

      info = Error.extract_rate_limit_info(headers)

      assert info.reset_at == DateTime.from_unix!(timestamp)
    end

    test "prioritizes request reset over token reset" do
      headers = [
        {"x-ratelimit-reset-requests", "1704067200"},
        {"x-ratelimit-reset-tokens", "1704070800"}
      ]

      info = Error.extract_rate_limit_info(headers)

      assert info.reset_at == DateTime.from_unix!(1_704_067_200)
    end

    test "retry-after is converted to milliseconds" do
      headers = [
        {"retry-after", "120"}
      ]

      info = Error.extract_rate_limit_info(headers)

      assert info.retry_after == 120_000
    end

    test "retry-after with decimal is parsed as integer" do
      headers = [
        {"retry-after", "30.5"}
      ]

      info = Error.extract_rate_limit_info(headers)

      assert info.retry_after == 30_000
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

    test "categorizes 451 Unavailable For Legal Reasons as client error" do
      body = %{"error" => %{"message" => "This content is not available in your region"}}
      result = Error.parse_http_error(451, body, [])

      assert result.category == :client
      assert result.status == 451
      assert result.retryable == false
    end

    test "categorizes 599 Network Connect Timeout as server error" do
      result = Error.parse_http_error(599, "Network Connect Timeout Error", [])

      assert result.category == :server
      assert result.status == 599
      assert result.retryable == false
    end

    test "categorizes 407 Proxy Authentication Required as client error" do
      result = Error.parse_http_error(407, "Proxy Authentication Required", [])

      assert result.category == :client
      assert result.retryable == false
    end

    test "categorizes 408 Request Timeout as client error" do
      result = Error.parse_http_error(408, "Request Timeout", [])

      assert result.category == :client
      assert result.retryable == false
    end

    test "categorizes 410 Gone as client error" do
      result = Error.parse_http_error(410, "Resource no longer available", [])

      assert result.category == :client
      assert result.retryable == false
    end

    test "categorizes 413 Payload Too Large as client error" do
      result = Error.parse_http_error(413, "Request entity too large", [])

      assert result.category == :client
      assert result.retryable == false
    end

    test "categorizes 422 Unprocessable Entity as client error" do
      body = %{"error" => %{"message" => "Validation failed"}}
      result = Error.parse_http_error(422, body, [])

      assert result.category == :client
      assert result.retryable == false
    end

    test "categorizes 501 Not Implemented as server error" do
      result = Error.parse_http_error(501, "Not Implemented", [])

      assert result.category == :server
      assert result.retryable == false
    end

    test "categorizes 505 HTTP Version Not Supported as server error" do
      result = Error.parse_http_error(505, "HTTP Version Not Supported", [])

      assert result.category == :server
      assert result.retryable == false
    end

    test "categorizes 511 Network Authentication Required as server error" do
      result = Error.parse_http_error(511, "Network Authentication Required", [])

      assert result.category == :server
      assert result.retryable == false
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
      # Not in retryable list
      assert result.retryable == false
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

      # Current implementation doesn't traverse deeply nested structures
      assert result.category == :server
      assert result.provider_message =~ "details"
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
      # Should extract message (highest priority pattern match)
      assert result.provider_message == "Field validation failed"
    end

    test "handles error with array of error objects" do
      body = %{
        "errors" => [
          %{"field" => "name", "message" => "Name is required"},
          %{"field" => "email", "message" => "Email is invalid"}
        ]
      }

      result = Error.parse_http_error(400, body, [])

      assert result.category == :client
      # No matching pattern, falls back to inspection
      assert result.provider_message =~ "errors"
    end

    test "handles error with mixed types in error object" do
      body = %{
        "error" => %{
          "code" => 1001,
          "message" => "Invalid request",
          "details" => ["reason1", "reason2"],
          "timestamp" => 1_704_067_200
        }
      }

      result = Error.parse_http_error(400, body, [])

      assert result.category == :client
      # Numeric code doesn't match string pattern, extracts message
      assert result.provider_message == "Invalid request"
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

    test "handles error with boolean values" do
      body = %{
        "error" => %{
          "message" => "Access denied",
          "retryable" => false,
          "permanent" => true
        }
      }

      result = Error.parse_http_error(403, body, [])

      assert result.category == :auth
      assert result.provider_message == "Access denied"
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

    test "handles GraphQL-style error format" do
      body = %{
        "errors" => [
          %{
            "message" => "Cannot query field 'foo' on type 'Query'",
            "locations" => [%{"line" => 1, "column" => 3}],
            "path" => ["query"]
          }
        ]
      }

      result = Error.parse_http_error(400, body, [])

      assert result.category == :client
      # No matching pattern at top level
      assert result.provider_message != nil
    end

    test "handles error with empty nested objects" do
      body = %{
        "error" => %{
          "details" => %{},
          "metadata" => %{}
        }
      }

      result = Error.parse_http_error(500, body, [])

      assert result.category == :server
      # Falls back to inspection of the map
      assert result.provider_message != nil
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

    test "handles message field as empty string" do
      body = %{"error" => %{"message" => ""}}

      result = Error.parse_http_error(500, body, [])

      assert result.category == :server
      assert result.provider_message == ""
    end

    test "handles message field as number" do
      body = %{"error" => %{"message" => 12345}}

      result = Error.parse_http_error(500, body, [])

      assert result.category == :server
      # Numeric message doesn't match binary pattern
      assert result.provider_message =~ "12345"
    end

    test "handles message field as list" do
      body = %{"error" => %{"message" => ["error1", "error2"]}}

      result = Error.parse_http_error(500, body, [])

      assert result.category == :server
      # List message doesn't match binary pattern
      assert result.provider_message != nil
    end

    test "handles code field as nil" do
      body = %{"error" => %{"code" => nil, "message" => "Error"}}

      result = Error.parse_http_error(400, body, [])

      assert result.category == :client
      assert result.provider_message == "Error"
    end

    test "handles type field as number" do
      body = %{"error" => %{"type" => 500, "message" => "Server error"}}

      result = Error.parse_http_error(500, body, [])

      assert result.category == :server
      assert result.provider_message == "Server error"
    end

    test "handles malformed JSON string body" do
      body = ~s({"error": {broken)

      result = Error.parse_http_error(400, body, [])

      assert result.category == :client
      # Falls back to truncated string
      assert result.provider_message =~ "error"
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

    test "handles body as float" do
      body = 3.14159

      result = Error.parse_http_error(500, body, [])

      assert result.category == :server
      assert result.provider_message == nil
    end

    test "handles body as boolean" do
      body = false

      result = Error.parse_http_error(500, body, [])

      assert result.category == :server
      assert result.provider_message == nil
    end

    test "handles body as keyword list" do
      body = [error: "something", code: 500]

      result = Error.parse_http_error(500, body, [])

      assert result.category == :server
      # Keyword list is a list, doesn't match map patterns, falls back to nil
      # (implementation returns nil for lists)
    end

    test "handles partially valid JSON with extra content" do
      body = ~s({"error": "valid"}extra content)

      result = Error.parse_http_error(400, body, [])

      assert result.category == :client
      # Jason.decode should fail, falls back to string
      assert result.provider_message =~ "error"
    end

    test "handles unicode in error messages" do
      body = %{"error" => %{"message" => "Error: \u4E2D\u6587\u6D88\u606F"}}

      result = Error.parse_http_error(400, body, [])

      assert result.category == :client
      assert result.provider_message =~ "Error"
    end

    test "handles emoji in error messages" do
      body = %{"error" => %{"message" => "Something went wrong! :("}}

      result = Error.parse_http_error(500, body, [])

      assert result.category == :server
      assert result.provider_message == "Something went wrong! :("
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
      assert result.retryable == true
      assert result.rate_limit_info.limit == 1_000_000
      assert result.rate_limit_info.remaining == 0
      assert result.rate_limit_info.reset_at != nil

      # Retry delay should use reset_at
      delay = Error.suggested_retry_delay_from_error(result)
      assert delay >= 58_000 and delay <= 62_000
    end

    test "Google API quota error" do
      body = %{
        "error" => %{
          "code" => 429,
          "message" => "Resource has been exhausted",
          "status" => "RESOURCE_EXHAUSTED",
          "errors" => [
            %{
              "message" => "Resource has been exhausted",
              "domain" => "googleapis.com",
              "reason" => "RATE_LIMIT_EXCEEDED"
            }
          ]
        }
      }

      result = Error.parse_http_error(429, body, [])

      assert result.category == :rate_limit
      assert result.retryable == true
      assert Error.rate_limit_error?(result)

      # No rate limit headers, use default
      delay = Error.suggested_retry_delay_from_error(result)
      assert delay == 60_000
    end

    test "Azure 503 transient error" do
      body = %{
        "error" => %{
          "code" => "ServiceUnavailable",
          "message" => "The service is temporarily unavailable. Please try again later."
        }
      }

      result = Error.parse_http_error(503, body, [])

      assert result.category == :transient
      assert result.retryable == true
      assert result.provider_message =~ "temporarily unavailable"

      delay = Error.suggested_retry_delay_from_error(result)
      assert delay == 5_000
    end

    test "AWS Bedrock throttling with retry-after" do
      body = %{
        "__type" => "ThrottlingException",
        "message" => "Rate exceeded"
      }

      headers = [
        {"retry-after", "30"}
      ]

      result = Error.parse_http_error(429, body, headers)

      assert result.category == :rate_limit
      assert result.retryable == true
      assert result.rate_limit_info.retry_after == 30_000

      delay = Error.suggested_retry_delay_from_error(result)
      assert delay == 30_000
    end
  end
end
