defmodule Ai.Providers.HttpTraceTest do
  @moduledoc """
  Tests for Ai.Providers.HttpTrace helper functions.
  Covers trace ID generation, body utilities, header normalization,
  and text size helpers.
  """
  use ExUnit.Case, async: true

  alias Ai.Providers.HttpTrace

  # ============================================================================
  # new_trace_id/1
  # ============================================================================

  describe "new_trace_id/1" do
    test "returns a string prefixed with the provider name" do
      id = HttpTrace.new_trace_id("anthropic")
      assert is_binary(id)
      assert String.starts_with?(id, "anthropic-")
    end

    test "accepts atom provider names" do
      id = HttpTrace.new_trace_id(:openai)
      assert String.starts_with?(id, "openai-")
    end

    test "generates unique IDs on successive calls" do
      ids = for _ <- 1..10, do: HttpTrace.new_trace_id("test")
      assert length(Enum.uniq(ids)) == 10
    end
  end

  # ============================================================================
  # body_bytes/1
  # ============================================================================

  describe "body_bytes/1" do
    test "returns byte_size for binary body" do
      assert HttpTrace.body_bytes("hello") == 5
    end

    test "handles empty binary" do
      assert HttpTrace.body_bytes("") == 0
    end

    test "handles multi-byte UTF-8" do
      # "é" is 2 bytes in UTF-8
      assert HttpTrace.body_bytes("é") == 2
    end

    test "returns inspected size for non-binary body" do
      result = HttpTrace.body_bytes(%{key: "value"})
      assert is_integer(result)
      assert result > 0
    end
  end

  # ============================================================================
  # body_preview/2
  # ============================================================================

  describe "body_preview/2" do
    test "returns full body when under limit" do
      assert HttpTrace.body_preview("short", 100) == "short"
    end

    test "truncates long binary body" do
      long = String.duplicate("a", 2000)
      preview = HttpTrace.body_preview(long, 100)
      assert byte_size(preview) < byte_size(long)
      assert String.contains?(preview, "truncated")
    end

    test "handles non-binary body" do
      preview = HttpTrace.body_preview([1, 2, 3], 100)
      assert is_binary(preview)
    end

    test "uses default max_bytes when not specified" do
      long = String.duplicate("x", 5000)
      preview = HttpTrace.body_preview(long)
      assert byte_size(preview) < byte_size(long)
    end
  end

  # ============================================================================
  # response_header_value/2
  # ============================================================================

  describe "response_header_value/2" do
    test "finds header by name (case-insensitive) in map" do
      headers = %{"Content-Type" => "application/json", "X-Request-Id" => "abc123"}
      assert HttpTrace.response_header_value(headers, "content-type") == "application/json"
      assert HttpTrace.response_header_value(headers, "Content-Type") == "application/json"
    end

    test "finds header in keyword list format" do
      headers = [{"content-type", "text/plain"}, {"x-custom", "val"}]
      assert HttpTrace.response_header_value(headers, "content-type") == "text/plain"
    end

    test "returns nil for missing header" do
      headers = %{"Content-Type" => "application/json"}
      assert HttpTrace.response_header_value(headers, "x-missing") == nil
    end

    test "accepts list of header names and returns first match" do
      headers = %{"x-request-id" => "abc", "x-amzn-requestid" => "def"}
      result = HttpTrace.response_header_value(headers, ["x-request-id", "x-amzn-requestid"])
      assert result == "abc"
    end

    test "falls through to second name when first not present" do
      headers = %{"x-amzn-requestid" => "def"}
      result = HttpTrace.response_header_value(headers, ["x-request-id", "x-amzn-requestid"])
      assert result == "def"
    end

    test "handles nil headers" do
      assert HttpTrace.response_header_value(nil, "content-type") == nil
    end

    test "handles atom header keys" do
      headers = %{content_type: "application/json"}
      assert HttpTrace.response_header_value(headers, "content_type") == "application/json"
    end
  end

  # ============================================================================
  # summarize_text_size/1
  # ============================================================================

  describe "summarize_text_size/1" do
    test "returns 0 for nil" do
      assert HttpTrace.summarize_text_size(nil) == 0
    end

    test "returns byte_size for binary" do
      assert HttpTrace.summarize_text_size("hello") == 5
    end

    test "returns 0 for non-binary non-nil" do
      assert HttpTrace.summarize_text_size(123) == 0
    end

    test "returns 0 for empty string" do
      assert HttpTrace.summarize_text_size("") == 0
    end
  end

  # ============================================================================
  # log/4 and log_error/4
  # ============================================================================

  describe "log/4" do
    test "returns :ok regardless of trace state" do
      assert :ok = HttpTrace.log("test", "event", %{key: "value"})
    end

    test "handles empty payload" do
      assert :ok = HttpTrace.log("test", "request", %{})
    end
  end

  describe "log_error/4" do
    test "returns :ok" do
      assert :ok = HttpTrace.log_error("test", "error_event", %{error: "something"})
    end
  end

  # ============================================================================
  # enabled?/0
  # ============================================================================

  describe "enabled?/0" do
    test "returns boolean" do
      result = HttpTrace.enabled?()
      assert is_boolean(result)
    end
  end
end
