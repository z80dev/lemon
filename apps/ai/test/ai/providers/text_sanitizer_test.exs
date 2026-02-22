defmodule Ai.Providers.TextSanitizerTest do
  use ExUnit.Case, async: true

  alias Ai.Providers.TextSanitizer

  describe "sanitize/1 with nil input" do
    # nil should be normalized to an empty string so downstream consumers
    # never have to handle nil text values.
    test "returns an empty string" do
      assert TextSanitizer.sanitize(nil) == ""
    end
  end

  describe "sanitize/1 with valid UTF-8 binaries" do
    # The most common case: well-formed UTF-8 text should pass through unchanged.
    test "returns a simple ASCII string unchanged" do
      assert TextSanitizer.sanitize("hello world") == "hello world"
    end

    # An empty binary is valid UTF-8 and should be returned as-is.
    test "returns an empty string unchanged" do
      assert TextSanitizer.sanitize("") == ""
    end

    # Multi-byte UTF-8 characters (e.g. CJK, emoji) must survive the roundtrip.
    test "preserves multi-byte UTF-8 characters" do
      text = "こんにちは世界"
      assert TextSanitizer.sanitize(text) == text
    end

    # Emoji are 4-byte UTF-8 sequences; verify they are preserved.
    test "preserves emoji characters" do
      text = "Hello 👋🌍🎉"
      assert TextSanitizer.sanitize(text) == text
    end

    # Strings containing mixed scripts and diacritics should be unmodified.
    test "preserves mixed unicode scripts" do
      text = "café résumé naïve Ñoño"
      assert TextSanitizer.sanitize(text) == text
    end

    # Newlines, tabs, and other whitespace are valid UTF-8 and must be kept.
    test "preserves strings with newlines and whitespace" do
      text = "line1\nline2\ttab\r\nwindows"
      assert TextSanitizer.sanitize(text) == text
    end

    # The Unicode replacement character itself is a valid codepoint.
    test "preserves strings already containing the replacement character" do
      text = "before\uFFFDafter"
      assert TextSanitizer.sanitize(text) == text
    end

    # Null bytes within a binary are valid UTF-8 (they encode U+0000).
    test "preserves strings with null bytes" do
      text = "hello\0world"
      assert TextSanitizer.sanitize(text) == text
    end

    # A longer string should not be truncated or corrupted.
    test "handles long strings" do
      text = String.duplicate("abcdefghij", 10_000)
      assert TextSanitizer.sanitize(text) == text
    end
  end

  describe "sanitize/1 with invalid UTF-8 sequences" do
    # A byte above 0x7F that doesn't start a valid multi-byte sequence is invalid.
    # The sanitizer should keep the valid prefix and append a replacement character.
    test "replaces a trailing invalid byte with the replacement character" do
      # 0xFF is never valid in UTF-8
      input = "hello" <> <<0xFF>>
      result = TextSanitizer.sanitize(input)
      assert String.starts_with?(result, "hello")
      assert String.ends_with?(result, "\uFFFD")
    end

    # An invalid byte in the middle of otherwise valid text should trigger
    # the error branch, preserving whatever valid prefix was decoded.
    test "handles invalid bytes in the middle of text" do
      input = "ab" <> <<0xFF>> <> "cd"
      result = TextSanitizer.sanitize(input)
      assert String.contains?(result, "\uFFFD")
    end

    # A standalone continuation byte (0x80-0xBF) without a leading byte is invalid.
    test "handles a standalone continuation byte" do
      input = <<0x80>>
      result = TextSanitizer.sanitize(input)
      assert result == "\uFFFD"
    end

    # An overlong 2-byte sequence (e.g. 0xC0 0xAF) is invalid UTF-8.
    test "handles overlong encoding" do
      input = <<0xC0, 0xAF>>
      result = TextSanitizer.sanitize(input)
      assert String.contains?(result, "\uFFFD")
    end
  end

  describe "sanitize/1 with incomplete UTF-8 sequences" do
    # A leading byte for a 2-byte sequence (0xC2) at end-of-input with no
    # continuation byte is incomplete. The valid prefix should be kept.
    test "handles an incomplete 2-byte sequence at end of string" do
      # 0xC2 expects one continuation byte
      input = "hello" <> <<0xC2>>
      result = TextSanitizer.sanitize(input)
      assert String.starts_with?(result, "hello")
      assert String.ends_with?(result, "\uFFFD")
    end

    # A leading byte for a 3-byte sequence with only one continuation byte.
    test "handles an incomplete 3-byte sequence" do
      # 0xE2 expects two continuation bytes; only one provided
      input = "test" <> <<0xE2, 0x82>>
      result = TextSanitizer.sanitize(input)
      assert String.starts_with?(result, "test")
      assert String.ends_with?(result, "\uFFFD")
    end

    # A leading byte for a 4-byte sequence with fewer than three continuation bytes.
    test "handles an incomplete 4-byte sequence" do
      # 0xF0 expects three continuation bytes; only two provided
      input = "data" <> <<0xF0, 0x9F, 0x98>>
      result = TextSanitizer.sanitize(input)
      assert String.starts_with?(result, "data")
      assert String.ends_with?(result, "\uFFFD")
    end
  end

  describe "sanitize/1 with non-binary types" do
    # Atoms should be converted to their string representation.
    test "converts an atom to a string" do
      assert TextSanitizer.sanitize(:hello) == "hello"
    end

    # Integers should be converted via the String.Chars protocol.
    test "converts an integer to a string" do
      assert TextSanitizer.sanitize(42) == "42"
    end

    # Floats should be converted via the String.Chars protocol.
    test "converts a float to a string" do
      assert TextSanitizer.sanitize(3.14) == "3.14"
    end

    # Lists that implement String.Chars (charlists) should be converted.
    test "converts a charlist to a string" do
      assert TextSanitizer.sanitize(~c"hello") == "hello"
    end
  end

  describe "sanitize/1 return type" do
    # Regardless of input type, the return value must always be a binary string.
    test "always returns a binary" do
      inputs = [nil, "", "hello", :atom, 123, <<0xFF>>]

      for input <- inputs do
        result = TextSanitizer.sanitize(input)
        assert is_binary(result), "Expected binary for input #{inspect(input)}, got #{inspect(result)}"
      end
    end
  end
end
