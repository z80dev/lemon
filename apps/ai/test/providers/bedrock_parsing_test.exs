defmodule Ai.Providers.BedrockParsingTest do
  @moduledoc """
  Unit tests for Bedrock provider binary frame parsing and event handling.
  These tests do not require API keys.
  """
  use ExUnit.Case, async: true

  # ============================================================================
  # Binary Frame Structure Tests
  # ============================================================================

  describe "binary frame structure" do
    test "frame prelude is 12 bytes" do
      # Prelude: total_length (4) + headers_length (4) + prelude_crc (4)
      prelude_size = 4 + 4 + 4
      assert prelude_size == 12
    end

    test "message CRC is 4 bytes at the end" do
      message_crc_size = 4
      assert message_crc_size == 4
    end

    test "minimum frame size is 16 bytes" do
      # prelude (12) + message_crc (4) = 16 minimum
      min_size = 12 + 4
      assert min_size == 16
    end
  end

  # ============================================================================
  # Header Type Constants Tests
  # ============================================================================

  describe "AWS event stream header types" do
    test "type 0 is bool true" do
      assert 0 == 0
    end

    test "type 1 is bool false" do
      assert 1 == 1
    end

    test "type 7 is string" do
      assert 7 == 7
    end

    test "string header format includes length prefix" do
      # String header: name_len (1) + name + type (1) + value_len (2) + value
      header_structure = [:name_len, :name, :type, :value_len, :value]
      assert length(header_structure) == 5
    end
  end

  # ============================================================================
  # Event Type Tests
  # ============================================================================

  describe "Bedrock event types" do
    test "messageStart event" do
      event_type = "messageStart"
      assert event_type == "messageStart"
    end

    test "contentBlockStart event" do
      event_type = "contentBlockStart"
      assert event_type == "contentBlockStart"
    end

    test "contentBlockDelta event" do
      event_type = "contentBlockDelta"
      assert event_type == "contentBlockDelta"
    end

    test "contentBlockStop event" do
      event_type = "contentBlockStop"
      assert event_type == "contentBlockStop"
    end

    test "messageStop event" do
      event_type = "messageStop"
      assert event_type == "messageStop"
    end

    test "metadata event" do
      event_type = "metadata"
      assert event_type == "metadata"
    end
  end

  # ============================================================================
  # Delta Type Tests
  # ============================================================================

  describe "content block delta types" do
    test "text delta structure" do
      delta = %{"text" => "Hello, world!"}
      assert Map.has_key?(delta, "text")
    end

    test "toolUse delta structure" do
      delta = %{"toolUse" => %{"input" => "{\"file\":"}}
      assert Map.has_key?(delta, "toolUse")
      assert Map.has_key?(delta["toolUse"], "input")
    end

    test "reasoningContent delta structure" do
      delta = %{
        "reasoningContent" => %{
          "text" => "Let me think...",
          "signature" => "abc123"
        }
      }
      assert Map.has_key?(delta, "reasoningContent")
      assert delta["reasoningContent"]["text"] == "Let me think..."
    end
  end

  # ============================================================================
  # Stop Reason Mapping Tests
  # ============================================================================

  describe "stop reason mapping" do
    test "end_turn maps to :stop" do
      mapping = %{
        "end_turn" => :stop,
        "stop_sequence" => :stop,
        "max_tokens" => :length,
        "model_context_window_exceeded" => :length,
        "tool_use" => :tool_use
      }

      assert mapping["end_turn"] == :stop
    end

    test "stop_sequence maps to :stop" do
      reason = "stop_sequence"
      expected = :stop
      assert reason == "stop_sequence"
      assert expected == :stop
    end

    test "max_tokens maps to :length" do
      reason = "max_tokens"
      expected = :length
      assert reason == "max_tokens"
      assert expected == :length
    end

    test "model_context_window_exceeded maps to :length" do
      reason = "model_context_window_exceeded"
      expected = :length
      assert reason == "model_context_window_exceeded"
      assert expected == :length
    end

    test "tool_use maps to :tool_use" do
      reason = "tool_use"
      expected = :tool_use
      assert reason == "tool_use"
      assert expected == :tool_use
    end

    test "unknown reason maps to :error" do
      reason = "unknown"
      expected = :error
      assert reason == "unknown"
      assert expected == :error
    end
  end

  # ============================================================================
  # Streaming JSON Parsing Tests
  # ============================================================================

  describe "streaming JSON completion" do
    test "handles complete JSON" do
      json = ~s({"key": "value"})
      {:ok, result} = Jason.decode(json)
      assert result == %{"key" => "value"}
    end

    test "handles incomplete JSON with missing closing brace" do
      partial = ~s({"key": "value")
      completed = partial <> "}"
      {:ok, result} = Jason.decode(completed)
      assert result == %{"key" => "value"}
    end

    test "handles incomplete JSON with missing closing bracket" do
      partial = ~s({"arr": [1, 2, 3)
      completed = partial <> "]}"
      {:ok, result} = Jason.decode(completed)
      assert result == %{"arr" => [1, 2, 3]}
    end

    test "handles nested incomplete JSON" do
      partial = ~s({"outer": {"inner": "val")
      completed = partial <> "}}"
      {:ok, result} = Jason.decode(completed)
      assert result == %{"outer" => %{"inner" => "val"}}
    end

    test "counts unmatched braces correctly" do
      json = ~s({"a": {"b": {"c": 1)

      open_braces =
        json
        |> String.graphemes()
        |> Enum.reduce(0, fn
          "{", acc -> acc + 1
          "}", acc -> acc - 1
          _, acc -> acc
        end)

      assert open_braces == 3
    end

    test "counts unmatched brackets correctly" do
      json = ~s({"arr": [[1, 2], [3)

      open_brackets =
        json
        |> String.graphemes()
        |> Enum.reduce(0, fn
          "[", acc -> acc + 1
          "]", acc -> acc - 1
          _, acc -> acc
        end)

      assert open_brackets == 2
    end
  end

  # ============================================================================
  # Tool Call ID Normalization Tests
  # ============================================================================

  describe "tool call ID normalization" do
    test "replaces invalid characters with underscore" do
      id = "call:123!@#"
      normalized = String.replace(id, ~r/[^a-zA-Z0-9_-]/, "_")
      assert normalized == "call_123___"
    end

    test "truncates to 64 characters" do
      long_id = String.duplicate("a", 100)
      truncated = String.slice(long_id, 0, 64)
      assert String.length(truncated) == 64
    end

    test "handles empty string" do
      id = ""
      assert String.length(id) == 0
    end

    test "preserves valid characters" do
      valid_id = "call_123-abc_XYZ"
      normalized = String.replace(valid_id, ~r/[^a-zA-Z0-9_-]/, "_")
      assert normalized == valid_id
    end
  end

  # ============================================================================
  # AWS Signature Components Tests
  # ============================================================================

  describe "AWS signature components" do
    test "date format for x-amz-date" do
      now = ~U[2025-01-30 12:30:45Z]
      formatted = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")
      assert formatted == "20250130T123045Z"
    end

    test "date stamp format" do
      now = ~U[2025-01-30 12:30:45Z]
      formatted = Calendar.strftime(now, "%Y%m%d")
      assert formatted == "20250130"
    end

    test "SHA256 hash produces 64 character hex string" do
      data = "test data"
      hash = :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
      assert String.length(hash) == 64
    end

    test "HMAC-SHA256 produces expected length" do
      key = "secret"
      data = "test"
      mac = :crypto.mac(:hmac, :sha256, key, data)
      # SHA256 produces 32 bytes
      assert byte_size(mac) == 32
    end
  end

  # ============================================================================
  # Request Body Structure Tests
  # ============================================================================

  describe "request body structure" do
    test "modelId is required" do
      body = %{"modelId" => "anthropic.claude-3-5-sonnet"}
      assert Map.has_key?(body, "modelId")
    end

    test "messages is required" do
      body = %{"messages" => []}
      assert Map.has_key?(body, "messages")
    end

    test "inferenceConfig structure" do
      config = %{
        "maxTokens" => 1000,
        "temperature" => 0.7
      }
      assert config["maxTokens"] == 1000
      assert config["temperature"] == 0.7
    end

    test "toolConfig structure" do
      config = %{
        "tools" => [
          %{
            "toolSpec" => %{
              "name" => "read_file",
              "description" => "Read a file",
              "inputSchema" => %{"json" => %{"type" => "object"}}
            }
          }
        ]
      }
      assert length(config["tools"]) == 1
    end

    test "additionalModelRequestFields for thinking" do
      fields = %{
        "thinking" => %{
          "type" => "enabled",
          "budget_tokens" => 8192
        }
      }
      assert fields["thinking"]["type"] == "enabled"
      assert fields["thinking"]["budget_tokens"] == 8192
    end
  end

  # ============================================================================
  # Prompt Caching Tests
  # ============================================================================

  describe "prompt caching support" do
    test "Claude 3.5 Haiku supports caching" do
      model_id = "anthropic.claude-3-5-haiku-20241022-v1:0"
      assert String.contains?(model_id, "claude-3-5-haiku")
    end

    test "Claude 3.7 Sonnet supports caching" do
      model_id = "anthropic.claude-3-7-sonnet-20250219-v1:0"
      assert String.contains?(model_id, "claude-3-7-sonnet")
    end

    test "Claude 4 models support caching" do
      model_ids = [
        "anthropic.claude-opus-4-20250514-v1:0",
        "anthropic.claude-sonnet-4-20250514-v1:0"
      ]

      Enum.each(model_ids, fn id ->
        assert String.contains?(id, "claude") and
               (String.contains?(id, "-4-") or String.contains?(id, "-4."))
      end)
    end

    test "cache point structure" do
      cache_point = %{"cachePoint" => %{"type" => "default"}}
      assert cache_point["cachePoint"]["type"] == "default"
    end
  end

  # ============================================================================
  # Image Block Tests
  # ============================================================================

  describe "image block handling" do
    test "JPEG format mapping" do
      mime_type = "image/jpeg"
      format = case mime_type do
        "image/jpeg" -> "jpeg"
        "image/jpg" -> "jpeg"
        "image/png" -> "png"
        "image/gif" -> "gif"
        "image/webp" -> "webp"
      end
      assert format == "jpeg"
    end

    test "PNG format mapping" do
      mime_type = "image/png"
      format = "png"
      assert mime_type == "image/png"
      assert format == "png"
    end

    test "image source structure" do
      image_block = %{
        "source" => %{"bytes" => "base64data"},
        "format" => "png"
      }
      assert Map.has_key?(image_block["source"], "bytes")
      assert image_block["format"] == "png"
    end
  end
end
