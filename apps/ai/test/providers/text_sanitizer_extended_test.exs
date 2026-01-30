defmodule Ai.Providers.TextSanitizerExtendedTest do
  @moduledoc """
  Extended unit tests for TextSanitizer with additional edge cases.
  """
  use ExUnit.Case, async: true

  alias Ai.Providers.TextSanitizer

  # ============================================================================
  # Valid UTF-8 Tests
  # ============================================================================

  describe "valid UTF-8 handling" do
    test "passes through ASCII text unchanged" do
      text = "Hello, World! 123"
      assert TextSanitizer.sanitize(text) == text
    end

    test "passes through multi-byte UTF-8 characters" do
      text = "日本語テスト"
      assert TextSanitizer.sanitize(text) == text
    end

    test "passes through emoji" do
      text = "Hello 👋 World 🌍"
      assert TextSanitizer.sanitize(text) == text
    end

    test "handles empty string" do
      assert TextSanitizer.sanitize("") == ""
    end

    test "handles whitespace-only string" do
      text = "   \t\n\r  "
      assert TextSanitizer.sanitize(text) == text
    end

    test "handles mixed content" do
      text = "Hello 你好 مرحبا שלום 🌟"
      assert TextSanitizer.sanitize(text) == text
    end
  end

  # ============================================================================
  # Invalid UTF-8 Tests
  # ============================================================================

  describe "invalid UTF-8 handling" do
    test "replaces invalid continuation byte" do
      # 0x80 is an invalid start byte (continuation byte used as start)
      invalid = <<0x80, 0x80>>
      result = TextSanitizer.sanitize(invalid)
      assert is_binary(result)
      assert String.valid?(result)
    end

    test "replaces overlong encoding" do
      # Overlong encoding of '/' (U+002F)
      # Should be 0x2F, but encoded as 2 bytes: 0xC0 0xAF
      invalid = <<0xC0, 0xAF>>
      result = TextSanitizer.sanitize(invalid)
      assert is_binary(result)
      assert String.valid?(result)
    end

    test "replaces truncated multi-byte sequence" do
      # Start of 3-byte sequence without continuation bytes
      invalid = <<0xE0>>
      result = TextSanitizer.sanitize(invalid)
      assert is_binary(result)
      assert String.valid?(result)
    end

    test "replaces incomplete 4-byte sequence" do
      # Start of 4-byte sequence (0xF0) with only 2 continuation bytes
      invalid = <<0xF0, 0x90, 0x80>>
      result = TextSanitizer.sanitize(invalid)
      assert is_binary(result)
      assert String.valid?(result)
    end

    test "handles mixed valid and invalid bytes" do
      # "Hello" + invalid byte + "World"
      mixed = "Hello" <> <<0xFF>> <> "World"
      result = TextSanitizer.sanitize(mixed)
      assert is_binary(result)
      assert String.valid?(result)
      # Should preserve the valid parts
      assert String.contains?(result, "Hello")
    end

    test "handles invalid byte in middle of valid text" do
      invalid = "abc" <> <<0xC3, 0x28>> <> "def"
      result = TextSanitizer.sanitize(invalid)
      assert is_binary(result)
      assert String.valid?(result)
    end

    test "handles sequence of invalid bytes" do
      invalid = <<0xFF, 0xFE, 0xFD, 0xFC>>
      result = TextSanitizer.sanitize(invalid)
      assert is_binary(result)
      assert String.valid?(result)
    end
  end

  # ============================================================================
  # Surrogate Handling Tests
  # ============================================================================

  describe "surrogate character handling" do
    # Note: In Elixir/Erlang, UTF-8 strings cannot contain unpaired surrogates
    # These tests verify the sanitizer handles related edge cases

    test "handles text with replacement character" do
      # U+FFFD is the replacement character
      text = "Hello \uFFFD World"
      result = TextSanitizer.sanitize(text)
      assert result == text
    end

    test "handles BOM character" do
      # U+FEFF is the byte order mark
      text = "\uFEFFHello"
      result = TextSanitizer.sanitize(text)
      assert result == text
    end
  end

  # ============================================================================
  # Non-Binary Input Tests
  # ============================================================================

  describe "non-binary input handling" do
    test "converts integer to string" do
      assert TextSanitizer.sanitize(42) == "42"
      assert TextSanitizer.sanitize(-123) == "-123"
      assert TextSanitizer.sanitize(0) == "0"
    end

    test "converts float to string" do
      assert TextSanitizer.sanitize(3.14) == "3.14"
      assert TextSanitizer.sanitize(-2.5) == "-2.5"
    end

    test "converts atom to string" do
      assert TextSanitizer.sanitize(:hello) == "hello"
      assert TextSanitizer.sanitize(:world) == "world"
    end

    test "converts nil to empty string" do
      assert TextSanitizer.sanitize(nil) == ""
    end

    test "converts list to string" do
      # Charlists are converted to strings via to_string
      assert is_binary(TextSanitizer.sanitize(~c"hello"))
    end

    test "converts boolean to string" do
      assert TextSanitizer.sanitize(true) == "true"
      assert TextSanitizer.sanitize(false) == "false"
    end
  end

  # ============================================================================
  # Edge Case Tests
  # ============================================================================

  describe "edge cases" do
    test "handles very long strings" do
      long_text = String.duplicate("a", 100_000)
      result = TextSanitizer.sanitize(long_text)
      assert String.length(result) == 100_000
    end

    test "handles strings with null bytes" do
      # Null bytes are valid in UTF-8
      text = "Hello\0World"
      result = TextSanitizer.sanitize(text)
      assert result == text
    end

    test "handles control characters" do
      # Control characters are valid UTF-8
      text = "Line1\nLine2\tTabbed\rReturn"
      result = TextSanitizer.sanitize(text)
      assert result == text
    end

    test "handles private use area characters" do
      # Private use area: U+E000 to U+F8FF
      text = "\uE000\uE001\uE002"
      result = TextSanitizer.sanitize(text)
      assert result == text
    end

    test "handles zero-width characters" do
      # Zero-width space: U+200B
      # Zero-width non-joiner: U+200C
      # Zero-width joiner: U+200D
      text = "Hello\u200B\u200C\u200DWorld"
      result = TextSanitizer.sanitize(text)
      assert result == text
    end

    test "handles right-to-left text" do
      text = "مرحبا بالعالم"
      result = TextSanitizer.sanitize(text)
      assert result == text
    end

    test "handles combining characters" do
      # é can be represented as e + combining acute accent
      text = "cafe\u0301"
      result = TextSanitizer.sanitize(text)
      assert result == text
    end
  end

  # ============================================================================
  # Performance Tests
  # ============================================================================

  describe "performance characteristics" do
    test "sanitizing valid UTF-8 is efficient" do
      text = String.duplicate("Hello, World! 🌟 ", 1000)

      # Should complete quickly for valid input
      {time_us, result} = :timer.tc(fn -> TextSanitizer.sanitize(text) end)

      assert result == text
      # Should be under 10ms for this size
      assert time_us < 10_000
    end

    test "sanitizing invalid UTF-8 completes" do
      # Create a string with invalid bytes
      invalid = String.duplicate(<<0xFF, 0xFE>>, 1000)

      {time_us, result} = :timer.tc(fn -> TextSanitizer.sanitize(invalid) end)

      assert is_binary(result)
      assert String.valid?(result)
      # Should complete in reasonable time
      assert time_us < 100_000
    end
  end
end
