defmodule LemonGateway.Telegram.TruncateTest do
  @moduledoc """
  Tests for LemonGateway.Telegram.Truncate message truncation logic.
  Covers short messages, long messages, resume line preservation, and edge cases.
  """
  use ExUnit.Case, async: true

  alias LemonGateway.Telegram.Truncate

  @max_length 4096

  # ============================================================================
  # max_length/0
  # ============================================================================

  describe "max_length/0" do
    test "returns 4096" do
      assert Truncate.max_length() == 4096
    end
  end

  # ============================================================================
  # Short messages (no truncation)
  # ============================================================================

  describe "truncate_for_telegram/1 - short messages" do
    test "returns short message unchanged" do
      text = "Hello, world!"
      assert Truncate.truncate_for_telegram(text) == text
    end

    test "returns empty string unchanged" do
      assert Truncate.truncate_for_telegram("") == ""
    end

    test "returns exactly max_length message unchanged" do
      text = String.duplicate("x", @max_length)
      assert Truncate.truncate_for_telegram(text) == text
    end

    test "handles non-binary input gracefully" do
      assert Truncate.truncate_for_telegram(nil) == nil
      assert Truncate.truncate_for_telegram(123) == 123
    end
  end

  # ============================================================================
  # Long messages (truncation needed)
  # ============================================================================

  describe "truncate_for_telegram/1 - long messages" do
    test "truncates message longer than max_length" do
      text = String.duplicate("x", @max_length + 100)
      result = Truncate.truncate_for_telegram(text)
      assert String.length(result) <= @max_length
    end

    test "truncated message ends with ellipsis" do
      text = String.duplicate("word ", 1000)
      result = Truncate.truncate_for_telegram(text)
      assert String.contains?(result, "...")
    end

    test "truncated result fits within limit" do
      text = String.duplicate("This is a longer sentence. ", 200)
      result = Truncate.truncate_for_telegram(text)
      assert String.length(result) <= @max_length
    end
  end

  # ============================================================================
  # Resume line preservation
  # ============================================================================

  describe "truncate_for_telegram/1 - resume lines" do
    test "preserves lemon resume line at end of long message" do
      body = String.duplicate("x", @max_length + 100)
      text = body <> "\nlemon resume abc123"
      result = Truncate.truncate_for_telegram(text)
      assert String.length(result) <= @max_length
      assert String.contains?(result, "lemon resume abc123")
    end

    test "preserves codex resume line at end of long message" do
      body = String.duplicate("x", @max_length + 100)
      text = body <> "\ncodex resume def456"
      result = Truncate.truncate_for_telegram(text)
      assert String.length(result) <= @max_length
      assert String.contains?(result, "codex resume def456")
    end

    test "preserves claude --resume line at end of long message" do
      body = String.duplicate("x", @max_length + 100)
      text = body <> "\nclaude --resume xyz789"
      result = Truncate.truncate_for_telegram(text)
      assert String.length(result) <= @max_length
      assert String.contains?(result, "claude --resume xyz789")
    end

    test "does not preserve resume line if message is short enough" do
      text = "Hello\nlemon resume abc123"
      result = Truncate.truncate_for_telegram(text)
      assert result == text
    end
  end

  # ============================================================================
  # Multi-byte character handling
  # ============================================================================

  describe "truncate_for_telegram/1 - unicode" do
    test "handles messages with emoji near the boundary" do
      # Each emoji is 1-2 characters in string length but may be more in UTF-16
      body = String.duplicate("🎉", 2000) <> String.duplicate("x", 3000)
      result = Truncate.truncate_for_telegram(body)
      assert String.length(result) <= @max_length
      assert String.valid?(result)
    end

    test "handles messages with CJK characters" do
      body = String.duplicate("日本語", 2000)
      result = Truncate.truncate_for_telegram(body)
      assert String.length(result) <= @max_length
      assert String.valid?(result)
    end
  end
end
