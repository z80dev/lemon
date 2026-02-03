defmodule LemonGateway.Telegram.TruncateTest do
  use ExUnit.Case, async: true

  alias LemonGateway.Telegram.Truncate

  # Mock engine for testing
  defmodule MockEngine do
    def is_resume_line(line) do
      line = String.trim(line)
      Regex.match?(~r/^`?lemon\s+resume\s+[\w-]+`?$/i, line)
    end
  end

  describe "truncate_for_telegram/2 with engine module" do
    test "returns short text unchanged" do
      text = "Hello world"
      assert Truncate.truncate_for_telegram(text, MockEngine) == text
    end

    test "returns text at exactly max length unchanged" do
      text = String.duplicate("x", 4096)
      assert Truncate.truncate_for_telegram(text, MockEngine) == text
    end

    test "truncates long text without resume lines" do
      text = String.duplicate("x", 5000)
      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert String.length(result) <= 4096
      assert String.ends_with?(result, "...")
    end

    test "preserves single resume line at end" do
      content = String.duplicate("x", 5000)
      resume = "lemon resume abc123"
      text = content <> "\n" <> resume

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert String.length(result) <= 4096
      assert String.ends_with?(result, resume)
      assert String.contains?(result, "...")
    end

    test "preserves multiple resume lines at end" do
      content = String.duplicate("x", 5000)
      resume1 = "lemon resume abc123"
      resume2 = "lemon resume def456"
      text = content <> "\n" <> resume1 <> "\n" <> resume2

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert String.length(result) <= 4096
      assert String.ends_with?(result, resume2)
      assert String.contains?(result, resume1)
      assert String.contains?(result, "...")
    end

    test "preserves backtick-wrapped resume line" do
      content = String.duplicate("x", 5000)
      resume = "`lemon resume abc123`"
      text = content <> "\n" <> resume

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert String.length(result) <= 4096
      assert String.ends_with?(result, resume)
    end

    test "does not treat mid-text resume lines as trailing" do
      resume = "lemon resume abc123"
      content = String.duplicate("x", 5000)
      text = resume <> "\n" <> content

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert String.length(result) <= 4096
      # Resume line at beginning should be in the content, may be truncated
      refute String.ends_with?(result, resume)
    end

    test "handles text with only resume lines" do
      resume = "lemon resume abc123"
      result = Truncate.truncate_for_telegram(resume, MockEngine)
      assert result == resume
    end

    test "handles empty text" do
      assert Truncate.truncate_for_telegram("", MockEngine) == ""
    end

    test "handles nil-ish values" do
      assert Truncate.truncate_for_telegram(nil, MockEngine) == nil
    end

    test "handles whitespace between content and resume lines" do
      content = String.duplicate("x", 5000)
      text = content <> "\n\n\nlemon resume abc123"

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert String.length(result) <= 4096
      assert String.ends_with?(result, "lemon resume abc123")
    end

    test "tries to break at word boundaries" do
      # Create text that would require truncation, with words
      words = Enum.map(1..1000, fn i -> "word#{i}" end) |> Enum.join(" ")
      text = words <> "\nlemon resume abc123"

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert String.length(result) <= 4096
      assert String.ends_with?(result, "lemon resume abc123")
      # Should not cut in the middle of a word (unless forced by length)
    end

    test "handles very long resume line" do
      # If the resume line itself is very long
      long_id = String.duplicate("a", 100)
      resume = "lemon resume #{long_id}"
      content = String.duplicate("x", 5000)
      text = content <> "\n" <> resume

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert String.length(result) <= 4096
      assert String.ends_with?(result, resume)
    end

    test "handles resume lines consuming most of the limit" do
      # Many resume lines that consume most of the space
      resumes = Enum.map(1..100, fn i -> "lemon resume id#{i}" end) |> Enum.join("\n")
      content = String.duplicate("x", 5000)
      text = content <> "\n" <> resumes

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert String.length(result) <= 4096
    end
  end

  describe "truncate_for_telegram/1 generic version" do
    test "returns short text unchanged" do
      text = "Hello world"
      assert Truncate.truncate_for_telegram(text) == text
    end

    test "truncates long text" do
      text = String.duplicate("x", 5000)
      result = Truncate.truncate_for_telegram(text)

      assert String.length(result) <= 4096
      assert String.ends_with?(result, "...")
    end

    test "preserves codex resume line" do
      content = String.duplicate("x", 5000)
      resume = "codex resume thread_abc123"
      text = content <> "\n" <> resume

      result = Truncate.truncate_for_telegram(text)

      assert String.length(result) <= 4096
      assert String.ends_with?(result, resume)
    end

    test "preserves claude resume line" do
      content = String.duplicate("x", 5000)
      resume = "claude --resume session_xyz"
      text = content <> "\n" <> resume

      result = Truncate.truncate_for_telegram(text)

      assert String.length(result) <= 4096
      assert String.ends_with?(result, resume)
    end

    test "preserves lemon resume line" do
      content = String.duplicate("x", 5000)
      resume = "lemon resume abc123"
      text = content <> "\n" <> resume

      result = Truncate.truncate_for_telegram(text)

      assert String.length(result) <= 4096
      assert String.ends_with?(result, resume)
    end
  end

  describe "max_length/0" do
    test "returns telegram max length" do
      assert Truncate.max_length() == 4096
    end
  end

  describe "edge cases" do
    test "text that becomes exactly max length after truncation" do
      # Craft text that after truncation plus ellipsis equals exactly 4096
      resume = "lemon resume abc123"
      resume_len = String.length(resume)
      # We need: content_len + 3 (ellipsis) + 1 (newline) + resume_len = 4096
      content_len = 4096 - 3 - 1 - resume_len
      content = String.duplicate("x", content_len + 100) # Slightly over
      text = content <> "\n" <> resume

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert String.length(result) <= 4096
      assert String.ends_with?(result, resume)
    end

    test "unicode characters are handled correctly" do
      # Unicode takes multiple bytes but should count as single characters
      content = String.duplicate("\u{1F600}", 5000) # Emoji
      resume = "lemon resume abc123"
      text = content <> "\n" <> resume

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert String.length(result) <= 4096
      assert String.ends_with?(result, resume)
    end

    test "newlines are preserved in truncated content" do
      lines = Enum.map(1..1000, fn i -> "Line #{i}" end) |> Enum.join("\n")
      resume = "lemon resume abc123"
      text = lines <> "\n" <> resume

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert String.length(result) <= 4096
      assert String.ends_with?(result, resume)
      # Should have newlines in the truncated portion
      assert String.contains?(result, "\n")
    end

    test "text just over the limit truncates minimally" do
      resume = "lemon resume abc123"
      # Create text that's just over 4096
      content_size = 4096 - String.length(resume) - 1 + 10 # 10 chars over
      content = String.duplicate("x", content_size)
      text = content <> "\n" <> resume

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert String.length(result) <= 4096
      assert String.ends_with?(result, resume)
      # Should have truncated only what's necessary
    end

    test "handles CRLF line endings" do
      content = String.duplicate("x", 5000)
      resume = "lemon resume abc123"
      text = content <> "\r\n" <> resume

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert String.length(result) <= 4096
      # Should still find and preserve the resume line
    end
  end
end
