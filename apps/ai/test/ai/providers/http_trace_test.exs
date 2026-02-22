defmodule Ai.Providers.HttpTraceTest do
  @moduledoc """
  Tests for pure functions in Ai.Providers.HttpTrace.

  Covers trace ID generation, body utilities, header normalization,
  and text size helpers. Uses async: true since these tests do not
  depend on global state.
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
      ids = for _ <- 1..20, do: HttpTrace.new_trace_id("test")
      assert length(Enum.uniq(ids)) == 20
    end

    test "suffix is base-36 encoded (alphanumeric uppercase)" do
      id = HttpTrace.new_trace_id("prov")
      suffix = id |> String.replace_prefix("prov-", "")
      assert suffix != ""
      assert Regex.match?(~r/^[0-9A-Z]+$/, suffix)
    end

    test "handles empty string provider" do
      id = HttpTrace.new_trace_id("")
      assert String.starts_with?(id, "-")
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
      # emoji: 4 bytes
      assert HttpTrace.body_bytes("🎉") == 4
    end

    test "returns inspected size for map" do
      result = HttpTrace.body_bytes(%{key: "value"})
      assert is_integer(result)
      assert result > 0
    end

    test "returns inspected size for list" do
      result = HttpTrace.body_bytes([1, 2, 3])
      assert is_integer(result)
      assert result > 0
    end

    test "returns inspected size for integer" do
      result = HttpTrace.body_bytes(42)
      assert is_integer(result)
      assert result > 0
    end

    test "returns inspected size for nil" do
      result = HttpTrace.body_bytes(nil)
      assert is_integer(result)
      assert result > 0
    end

    test "handles large binary" do
      large = String.duplicate("x", 100_000)
      assert HttpTrace.body_bytes(large) == 100_000
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

    test "includes truncation marker with byte count" do
      long = String.duplicate("b", 500)
      preview = HttpTrace.body_preview(long, 50)
      assert preview =~ ~r/\.\.\.\[truncated \d+ bytes\]/
    end

    test "handles non-binary body (list)" do
      preview = HttpTrace.body_preview([1, 2, 3], 100)
      assert is_binary(preview)
    end

    test "handles non-binary body (map)" do
      preview = HttpTrace.body_preview(%{a: 1}, 100)
      assert is_binary(preview)
    end

    test "uses default max_bytes when not specified" do
      long = String.duplicate("x", 5000)
      preview = HttpTrace.body_preview(long)
      assert byte_size(preview) < byte_size(long)
      assert String.contains?(preview, "truncated")
    end

    test "handles empty binary" do
      assert HttpTrace.body_preview("", 100) == ""
    end

    test "truncates respecting UTF-8 boundaries" do
      # Create a string with multi-byte characters
      # Each "é" is 2 bytes; truncate in the middle
      str = String.duplicate("é", 100)
      preview = HttpTrace.body_preview(str, 50)
      assert String.valid?(preview)
    end

    test "handles nil body" do
      preview = HttpTrace.body_preview(nil, 100)
      assert is_binary(preview)
    end

    test "body exactly at max_bytes is not truncated" do
      body = String.duplicate("a", 100)
      assert HttpTrace.body_preview(body, 100) == body
    end

    test "body one byte over max_bytes is truncated" do
      body = String.duplicate("a", 101)
      preview = HttpTrace.body_preview(body, 100)
      assert String.contains?(preview, "truncated")
    end
  end

  # ============================================================================
  # response_header_value/2
  # ============================================================================

  describe "response_header_value/2" do
    test "finds header by name (case-insensitive) in map" do
      headers = %{"Content-Type" => "application/json"}
      assert HttpTrace.response_header_value(headers, "content-type") == "application/json"
      assert HttpTrace.response_header_value(headers, "Content-Type") == "application/json"
      assert HttpTrace.response_header_value(headers, "CONTENT-TYPE") == "application/json"
    end

    test "finds header in tuple list format" do
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

    test "falls through to second name when first absent" do
      headers = %{"x-amzn-requestid" => "def"}
      result = HttpTrace.response_header_value(headers, ["x-request-id", "x-amzn-requestid"])
      assert result == "def"
    end

    test "handles nil headers" do
      assert HttpTrace.response_header_value(nil, "content-type") == nil
    end

    test "handles atom header keys in map" do
      headers = %{content_type: "application/json"}
      assert HttpTrace.response_header_value(headers, "content_type") == "application/json"
    end

    test "handles atom header keys in list" do
      headers = [{:content_type, "application/json"}]
      assert HttpTrace.response_header_value(headers, "content_type") == "application/json"
    end

    test "handles list header values (takes first element)" do
      headers = %{"content-type" => ["text/html", "charset=utf-8"]}
      assert HttpTrace.response_header_value(headers, "content-type") == "text/html"
    end

    test "handles integer header values via to_string" do
      headers = %{"content-length" => 42}
      assert HttpTrace.response_header_value(headers, "content-length") == "42"
    end

    test "handles empty map" do
      assert HttpTrace.response_header_value(%{}, "content-type") == nil
    end

    test "handles empty list" do
      assert HttpTrace.response_header_value([], "content-type") == nil
    end

    test "returns nil when all names miss" do
      headers = %{"x-other" => "val"}
      assert HttpTrace.response_header_value(headers, ["x-foo", "x-bar"]) == nil
    end

    test "ignores non-tuple entries in list headers" do
      headers = [{"content-type", "text/plain"}, "bad-entry", 42]
      assert HttpTrace.response_header_value(headers, "content-type") == "text/plain"
    end

    test "handles non-map non-list headers gracefully" do
      assert HttpTrace.response_header_value("not-headers", "x") == nil
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

    test "returns 0 for non-binary non-nil (integer)" do
      assert HttpTrace.summarize_text_size(123) == 0
    end

    test "returns 0 for empty string" do
      assert HttpTrace.summarize_text_size("") == 0
    end

    test "handles multi-byte UTF-8" do
      assert HttpTrace.summarize_text_size("café") == 5
    end

    test "returns 0 for list" do
      assert HttpTrace.summarize_text_size([1, 2]) == 0
    end

    test "returns 0 for map" do
      assert HttpTrace.summarize_text_size(%{}) == 0
    end
  end

  # ============================================================================
  # log/4 and log_error/4
  # ============================================================================

  describe "log/4" do
    test "returns :ok" do
      assert :ok = HttpTrace.log("test", "event", %{key: "value"})
    end

    test "handles empty payload" do
      assert :ok = HttpTrace.log("test", "request", %{})
    end

    test "accepts custom log level" do
      assert :ok = HttpTrace.log("test", "event", %{data: 1}, :warning)
    end
  end

  describe "log_error/4" do
    test "returns :ok" do
      assert :ok = HttpTrace.log_error("test", "error_event", %{error: "something"})
    end

    test "handles empty payload" do
      assert :ok = HttpTrace.log_error("test", "error_event", %{})
    end

    test "accepts custom log level" do
      assert :ok = HttpTrace.log_error("test", "error", %{}, :warning)
    end
  end
end

# ==============================================================================
# Separate module for tests that manipulate global state (System env vars).
# Must be async: false to avoid interference with other tests.
# ==============================================================================

defmodule Ai.Providers.HttpTraceEnabledTest do
  @moduledoc """
  Tests for Ai.Providers.HttpTrace.enabled?/0.

  Uses async: false because these tests mutate the LEMON_AI_HTTP_TRACE
  environment variable.
  """
  use ExUnit.Case, async: false

  alias Ai.Providers.HttpTrace

  @trace_env "LEMON_AI_HTTP_TRACE"

  setup do
    original = System.get_env(@trace_env)

    on_exit(fn ->
      if original do
        System.put_env(@trace_env, original)
      else
        System.delete_env(@trace_env)
      end
    end)

    :ok
  end

  describe "enabled?/0" do
    test "returns true when env var is set to \"1\"" do
      System.put_env(@trace_env, "1")
      assert HttpTrace.enabled?() == true
    end

    test "returns false when env var is not set" do
      System.delete_env(@trace_env)
      assert HttpTrace.enabled?() == false
    end

    test "returns false when env var is \"0\"" do
      System.put_env(@trace_env, "0")
      assert HttpTrace.enabled?() == false
    end

    test "returns false when env var is \"true\"" do
      System.put_env(@trace_env, "true")
      assert HttpTrace.enabled?() == false
    end

    test "returns false when env var is empty string" do
      System.put_env(@trace_env, "")
      assert HttpTrace.enabled?() == false
    end
  end
end
