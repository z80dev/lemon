defmodule Ai.Providers.GoogleSharedRetryTest do
  @moduledoc """
  Unit tests for GoogleShared retry and error handling utilities.
  """
  use ExUnit.Case, async: true

  alias Ai.Providers.GoogleShared

  # ============================================================================
  # Retry Delay Extraction Tests
  # ============================================================================

  describe "extract_retry_delay/2" do
    test "extracts delay from 'Your quota will reset after Xs' format" do
      error_text = "Your quota will reset after 39s"
      delay = GoogleShared.extract_retry_delay(error_text)

      assert delay != nil
      # 39s + 1s buffer = 40000ms
      assert delay == 40_000
    end

    test "extracts delay from hours+minutes+seconds format" do
      error_text = "Your quota will reset after 18h31m10s"
      delay = GoogleShared.extract_retry_delay(error_text)

      assert delay != nil
      # (18*3600 + 31*60 + 10) * 1000 + 1000 = 66_671_000
      expected = ((18 * 60 + 31) * 60 + 10) * 1000 + 1000
      assert delay == expected
    end

    test "extracts delay from minutes+seconds format" do
      error_text = "Your quota will reset after 10m15s"
      delay = GoogleShared.extract_retry_delay(error_text)

      assert delay != nil
      expected = (10 * 60 + 15) * 1000 + 1000
      assert delay == expected
    end

    test "extracts delay from 'Please retry in Xs' format" do
      error_text = "Please retry in 5s"
      delay = GoogleShared.extract_retry_delay(error_text)

      assert delay != nil
      assert delay == 6000
    end

    test "extracts delay from 'Please retry in Xms' format" do
      error_text = "Please retry in 500ms"
      delay = GoogleShared.extract_retry_delay(error_text)

      assert delay != nil
      # 500ms + 1000ms buffer, ceiled = 1500
      assert delay == 1500
    end

    test "extracts delay from retryDelay JSON field" do
      error_text = ~s({"error": {"message": "Rate limited", "retryDelay": "34.074824224s"}})
      delay = GoogleShared.extract_retry_delay(error_text)

      assert delay != nil
      # 34.074... seconds + 1s buffer, ceiled
      assert delay > 35_000
      assert delay < 36_000
    end

    test "extracts delay from retry-after header" do
      error_text = "Rate limited"
      headers = %{"retry-after" => "10"}
      delay = GoogleShared.extract_retry_delay(error_text, headers)

      assert delay != nil
      assert delay == 11_000
    end

    test "extracts delay from x-ratelimit-reset-after header" do
      error_text = "Rate limited"
      headers = %{"x-ratelimit-reset-after" => "5.5"}
      delay = GoogleShared.extract_retry_delay(error_text, headers)

      assert delay != nil
      assert delay == 6500
    end

    test "prefers header delay over text delay" do
      error_text = "Your quota will reset after 60s"
      headers = %{"retry-after" => "5"}
      delay = GoogleShared.extract_retry_delay(error_text, headers)

      assert delay == 6000
    end

    test "returns nil for unrecognized format" do
      error_text = "An unknown error occurred"
      delay = GoogleShared.extract_retry_delay(error_text)

      assert delay == nil
    end

    test "handles fractional seconds" do
      error_text = "Your quota will reset after 1.5s"
      delay = GoogleShared.extract_retry_delay(error_text)

      assert delay != nil
      assert delay == 2500
    end

    test "handles zero delay gracefully" do
      error_text = "Please retry in 0s"
      delay = GoogleShared.extract_retry_delay(error_text)

      # Zero or negative should return nil
      assert delay == nil
    end
  end

  # ============================================================================
  # Retryable Error Detection Tests
  # ============================================================================

  describe "retryable_error?/2" do
    test "returns true for 429 Too Many Requests" do
      assert GoogleShared.retryable_error?(429, "Rate limited") == true
    end

    test "returns true for 500 Internal Server Error" do
      assert GoogleShared.retryable_error?(500, "Internal error") == true
    end

    test "returns true for 502 Bad Gateway" do
      assert GoogleShared.retryable_error?(502, "Bad gateway") == true
    end

    test "returns true for 503 Service Unavailable" do
      assert GoogleShared.retryable_error?(503, "Service unavailable") == true
    end

    test "returns true for 504 Gateway Timeout" do
      assert GoogleShared.retryable_error?(504, "Gateway timeout") == true
    end

    test "returns true for RESOURCE_EXHAUSTED error" do
      assert GoogleShared.retryable_error?(400, "RESOURCE_EXHAUSTED: quota exceeded") == true
    end

    test "returns true for rate limit error text" do
      assert GoogleShared.retryable_error?(400, "rate limit exceeded") == true
      assert GoogleShared.retryable_error?(400, "RateLimit error") == true
    end

    test "returns true for overloaded error" do
      assert GoogleShared.retryable_error?(400, "Model is currently overloaded") == true
    end

    test "returns true for service unavailable text" do
      assert GoogleShared.retryable_error?(400, "service unavailable") == true
    end

    test "returns true for connection closed error" do
      assert GoogleShared.retryable_error?(0, "other side closed connection") == true
    end

    test "returns false for 400 with unrecognized error" do
      assert GoogleShared.retryable_error?(400, "Invalid request body") == false
    end

    test "returns false for 401 Unauthorized" do
      assert GoogleShared.retryable_error?(401, "Invalid API key") == false
    end

    test "returns false for 404 Not Found" do
      assert GoogleShared.retryable_error?(404, "Model not found") == false
    end
  end

  # ============================================================================
  # Error Message Extraction Tests
  # ============================================================================

  describe "extract_error_message/1" do
    test "extracts message from Google API error format" do
      error_json = Jason.encode!(%{
        "error" => %{
          "code" => 400,
          "message" => "API key not valid",
          "status" => "INVALID_ARGUMENT"
        }
      })

      assert GoogleShared.extract_error_message(error_json) == "API key not valid"
    end

    test "returns raw text for non-JSON error" do
      error_text = "Connection refused"
      assert GoogleShared.extract_error_message(error_text) == "Connection refused"
    end

    test "returns raw text for malformed JSON" do
      error_text = "{invalid json"
      assert GoogleShared.extract_error_message(error_text) == "{invalid json"
    end

    test "returns raw text when message is missing" do
      error_json = Jason.encode!(%{"error" => %{"code" => 500}})
      assert GoogleShared.extract_error_message(error_json) == error_json
    end
  end

  # ============================================================================
  # Unicode Sanitization Tests
  # ============================================================================

  describe "sanitize_surrogates/1" do
    test "passes through valid UTF-8" do
      text = "Hello, world! \u{1F600}"
      assert GoogleShared.sanitize_surrogates(text) == text
    end

    test "handles incomplete UTF-8 sequences" do
      # Incomplete multi-byte sequence
      invalid = <<0xE2, 0x82>>
      result = GoogleShared.sanitize_surrogates(invalid)
      assert is_binary(result)
      assert String.valid?(result)
    end

    test "handles non-binary input" do
      assert GoogleShared.sanitize_surrogates(123) == "123"
      assert GoogleShared.sanitize_surrogates(:atom) == "atom"
    end

    test "handles mixed valid and invalid bytes" do
      # Valid text followed by invalid byte
      mixed = "Hello" <> <<0xFF>>
      result = GoogleShared.sanitize_surrogates(mixed)
      assert is_binary(result)
      assert String.valid?(result)
    end
  end

  # ============================================================================
  # Cost Calculation Tests
  # ============================================================================

  describe "calculate_cost/2" do
    test "calculates cost based on model pricing" do
      model = %Ai.Types.Model{
        id: "gemini-2.5-pro",
        cost: %Ai.Types.ModelCost{
          input: 1.25,
          output: 5.0,
          cache_read: 0.3125,
          cache_write: 0.0
        }
      }

      usage = %{
        input: 1000,
        output: 500,
        cache_read: 200,
        cache_write: 0
      }

      result = GoogleShared.calculate_cost(model, usage)

      # input: 1000 * 1.25 / 1_000_000 = 0.00125
      assert_in_delta result.cost.input, 0.00125, 0.000001
      # output: 500 * 5.0 / 1_000_000 = 0.0025
      assert_in_delta result.cost.output, 0.0025, 0.000001
      # cache_read: 200 * 0.3125 / 1_000_000 = 0.0000625
      assert_in_delta result.cost.cache_read, 0.0000625, 0.0000001
      # total
      assert_in_delta result.cost.total, 0.00125 + 0.0025 + 0.0000625, 0.000001
    end

    test "handles zero usage" do
      model = %Ai.Types.Model{
        id: "test",
        cost: %Ai.Types.ModelCost{
          input: 1.0,
          output: 2.0,
          cache_read: 0.5,
          cache_write: 0.5
        }
      }

      usage = %{input: 0, output: 0, cache_read: 0, cache_write: 0}
      result = GoogleShared.calculate_cost(model, usage)

      assert result.cost.total == 0.0
    end
  end
end
