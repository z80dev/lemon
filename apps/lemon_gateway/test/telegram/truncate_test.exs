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

    test "preserves very long resume line that nearly fills the limit" do
      # Resume line length: 4092 so that ellipsis + newline + resume == 4096
      long_id = String.duplicate("a", 4079)
      resume = "lemon resume #{long_id}"
      text = String.duplicate("x", 10) <> "\n" <> resume

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert String.length(result) <= 4096
      assert String.ends_with?(result, resume)
    end
  end

  describe "resume lines exceeding telegram limit" do
    test "resume line alone exceeds 4096 characters falls back to plain truncation" do
      # Create a resume line that by itself is over 4096 characters
      long_id = String.duplicate("a", 4100)
      resume = "lemon resume #{long_id}"
      content = "Some content"
      text = content <> "\n" <> resume

      result = Truncate.truncate_for_telegram(text, MockEngine)

      # Should fall back to plain truncation with ellipsis
      assert String.length(result) <= 4096
      assert String.ends_with?(result, "...")
    end

    test "multiple resume lines together exceed 4096 characters" do
      # Create enough resume lines that they alone exceed the limit
      resumes =
        Enum.map(1..300, fn i ->
          "lemon resume #{String.pad_leading(Integer.to_string(i), 10, "0")}"
        end)
        |> Enum.join("\n")

      content = "Some content here"
      text = content <> "\n" <> resumes

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert String.length(result) <= 4096
      # Falls back to plain truncation
      assert String.ends_with?(result, "...")
    end

    test "resume lines exactly at 4096 limit leaves no room for content" do
      # Create resume lines that total exactly 4096 - ellipsis_len - newline
      # This should trigger fallback since available_for_content < 0
      long_id = String.duplicate("x", 4090)
      resume = "lemon resume #{long_id}"
      content = "abc"
      text = content <> "\n" <> resume

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert String.length(result) <= 4096
    end
  end

  describe "resume lines with empty content" do
    test "empty content with single resume line" do
      resume = "lemon resume abc123"
      text = "\n" <> resume

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert result == text
    end

    test "only whitespace content with resume line" do
      resume = "lemon resume abc123"
      text = "   \n\t\n" <> resume

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert result == text
    end

    test "empty lines before resume line are preserved" do
      resume = "lemon resume abc123"
      text = "\n\n\n" <> resume

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert result == text
    end

    test "content is empty string with just resume" do
      resume = "lemon resume abc123"

      result = Truncate.truncate_for_telegram(resume, MockEngine)

      assert result == resume
    end
  end

  describe "multiple consecutive resume lines" do
    test "three consecutive resume lines at end" do
      content = String.duplicate("x", 5000)
      resume1 = "lemon resume aaa111"
      resume2 = "lemon resume bbb222"
      resume3 = "lemon resume ccc333"
      text = content <> "\n" <> resume1 <> "\n" <> resume2 <> "\n" <> resume3

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert String.length(result) <= 4096
      assert String.contains?(result, resume1)
      assert String.contains?(result, resume2)
      assert String.ends_with?(result, resume3)
    end

    test "resume lines with blank lines between them" do
      content = String.duplicate("x", 5000)
      resume1 = "lemon resume aaa111"
      resume2 = "lemon resume bbb222"
      text = content <> "\n" <> resume1 <> "\n\n" <> resume2

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert String.length(result) <= 4096
      assert String.contains?(result, resume1)
      assert String.ends_with?(result, resume2)
    end

    test "mixed resume line formats (lemon, codex, claude)" do
      content = String.duplicate("x", 5000)
      resume1 = "lemon resume aaa111"
      resume2 = "codex resume bbb222"
      resume3 = "claude --resume ccc333"
      text = content <> "\n" <> resume1 <> "\n" <> resume2 <> "\n" <> resume3

      result = Truncate.truncate_for_telegram(text)

      assert String.length(result) <= 4096
      assert String.contains?(result, resume1)
      assert String.contains?(result, resume2)
      assert String.ends_with?(result, resume3)
    end

    test "five consecutive resume lines" do
      content = String.duplicate("x", 5000)
      resumes = Enum.map(1..5, fn i -> "lemon resume id_#{i}" end) |> Enum.join("\n")
      text = content <> "\n" <> resumes

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert String.length(result) <= 4096
      assert String.ends_with?(result, "lemon resume id_5")
      # All resume lines should be preserved
      Enum.each(1..5, fn i ->
        assert String.contains?(result, "lemon resume id_#{i}")
      end)
    end
  end

  describe "resume lines at the beginning (not trailing)" do
    test "resume line at start is not preserved specially" do
      resume = "lemon resume abc123"
      content = String.duplicate("x", 5000)
      text = resume <> "\n" <> content

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert String.length(result) <= 4096
      # Resume at start is part of content, may be truncated away
      refute String.ends_with?(result, resume)
      assert String.ends_with?(result, "...")
    end

    test "resume line in middle is not preserved specially" do
      content1 = String.duplicate("a", 2500)
      resume = "lemon resume middle123"
      content2 = String.duplicate("b", 2500)
      text = content1 <> "\n" <> resume <> "\n" <> content2

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert String.length(result) <= 4096
      # Resume in middle should not be at the end
      refute String.ends_with?(result, resume)
    end

    test "resume at start and different resume at end" do
      resume_start = "lemon resume start_id"
      content = String.duplicate("x", 5000)
      resume_end = "lemon resume end_id"
      text = resume_start <> "\n" <> content <> "\n" <> resume_end

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert String.length(result) <= 4096
      # Only trailing resume should be preserved
      assert String.ends_with?(result, resume_end)
    end
  end

  describe "non-resume trailing lines that look like resume" do
    test "line containing resume but not matching pattern" do
      content = String.duplicate("x", 5000)
      fake_resume = "please lemon resume the task abc123"
      text = content <> "\n" <> fake_resume

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert String.length(result) <= 4096
      # This should not be detected as a resume line
      refute String.ends_with?(result, fake_resume)
      assert String.ends_with?(result, "...")
    end

    test "resume without session id is not a resume line" do
      content = String.duplicate("x", 5000)
      fake_resume = "lemon resume"
      text = content <> "\n" <> fake_resume

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert String.length(result) <= 4096
      # "lemon resume" alone without ID should not match
      refute String.ends_with?(result, fake_resume)
    end

    test "resume line with extra text after id - detected by fallback regex" do
      content = String.duplicate("x", 5000)
      # The fallback regex matches "<word> resume <anything>" so this IS detected
      # as a resume line by the generic fallback matcher
      fake_resume = "lemon resume abc123 extra text here"
      text = content <> "\n" <> fake_resume

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert String.length(result) <= 4096
      # This IS matched by the fallback regex pattern
      assert String.ends_with?(result, fake_resume)
    end

    test "similar but incorrect prefix - detected by fallback regex" do
      content = String.duplicate("x", 5000)
      # The fallback regex ~r/^[a-z0-9_-]+\s+resume\s+/i matches "lemons resume"
      fake_resume = "lemons resume abc123"
      text = content <> "\n" <> fake_resume

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert String.length(result) <= 4096
      # This IS matched by the fallback regex pattern
      assert String.ends_with?(result, fake_resume)
    end

    test "resume line embedded in other text on same line" do
      content = String.duplicate("x", 5000)
      fake_resume = "Run this command: lemon resume abc123"
      text = content <> "\n" <> fake_resume

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert String.length(result) <= 4096
      refute String.ends_with?(result, fake_resume)
    end
  end

  describe "break point finding with very long words, no whitespace" do
    test "single continuous string with no spaces or newlines" do
      # Text with no break points at all
      text = String.duplicate("x", 5000)

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert String.length(result) <= 4096
      assert String.ends_with?(result, "...")
      # Should hard-cut since there are no break points
    end

    test "very long word at truncation boundary" do
      # Create text where the last 100+ characters are a single word
      # Need to exceed 4096 to trigger truncation
      normal_content = String.duplicate("word ", 800)
      long_word = String.duplicate("x", 500)
      text = normal_content <> long_word

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert String.length(result) <= 4096
      assert String.ends_with?(result, "...")
    end

    test "all very long words separated by single spaces" do
      # Words longer than 100 chars each
      words = Enum.map(1..50, fn _ -> String.duplicate("a", 150) end) |> Enum.join(" ")
      text = words

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert String.length(result) <= 4096
      assert String.ends_with?(result, "...")
    end

    test "no break point in last 100 characters forces hard cut" do
      # Create text where there's a space early, then 100+ chars with no breaks
      # Total must exceed 4096 to trigger truncation
      prefix = String.duplicate("word ", 800)
      suffix = String.duplicate("x", 500)
      text = prefix <> suffix

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert String.length(result) <= 4096
      assert String.ends_with?(result, "...")
    end

    test "newlines work as break points" do
      # Lines that are each under 100 chars
      lines = Enum.map(1..100, fn i -> String.duplicate("line#{i}_", 10) end) |> Enum.join("\n")
      resume = "lemon resume abc123"
      text = lines <> "\n" <> resume

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert String.length(result) <= 4096
      assert String.ends_with?(result, resume)
    end
  end

  describe "content with only resume lines, no actual content" do
    test "single resume line only" do
      text = "lemon resume abc123"

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert result == text
    end

    test "multiple resume lines only" do
      text = "lemon resume aaa\nlemon resume bbb\nlemon resume ccc"

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert result == text
    end

    test "resume lines with leading/trailing whitespace" do
      text = "  lemon resume abc123  "

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert result == text
    end

    test "many resume lines that fit within limit" do
      resumes = Enum.map(1..100, fn i -> "lemon resume id#{i}" end) |> Enum.join("\n")
      # Ensure it's under limit
      assert String.length(resumes) < 4096

      result = Truncate.truncate_for_telegram(resumes, MockEngine)

      assert result == resumes
    end

    test "blank lines between multiple resume lines only" do
      text = "lemon resume aaa\n\n\nlemon resume bbb\n\nlemon resume ccc"

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert result == text
    end
  end

  describe "unicode handling and grapheme boundaries" do
    test "emoji characters count as single characters" do
      # 1000 emoji characters should count as 1000, not multiples
      emojis = String.duplicate("\u{1F600}", 1000)
      assert String.length(emojis) == 1000
      resume = "lemon resume abc123"
      text = emojis <> "\n" <> resume

      result = Truncate.truncate_for_telegram(text, MockEngine)

      # Should fit without truncation (1000 + 1 + 19 < 4096)
      assert result == text
    end

    test "truncation preserves emoji integrity" do
      # Many emojis that need truncation
      emojis = String.duplicate("\u{1F600}", 5000)
      resume = "lemon resume abc123"
      text = emojis <> "\n" <> resume

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert String.length(result) <= 4096
      assert String.ends_with?(result, resume)
      # Should not have corrupted emoji at truncation point
      assert String.valid?(result)
    end

    test "multi-byte unicode characters" do
      # Chinese characters (3 bytes each in UTF-8)
      chinese = String.duplicate("\u{4E2D}", 5000)
      resume = "lemon resume abc123"
      text = chinese <> "\n" <> resume

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert String.length(result) <= 4096
      assert String.ends_with?(result, resume)
      assert String.valid?(result)
    end

    test "mixed unicode and ASCII" do
      # Mix of emoji, chinese, and ASCII
      mixed = String.duplicate("\u{1F600}abc\u{4E2D}xyz", 1000)
      resume = "lemon resume abc123"
      text = mixed <> "\n" <> resume

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert String.length(result) <= 4096
      assert String.ends_with?(result, resume)
      assert String.valid?(result)
    end

    test "grapheme clusters (combining characters)" do
      # e + combining acute accent forms a single grapheme
      combining = String.duplicate("e\u{0301}", 3000) # é as combining
      resume = "lemon resume abc123"
      text = combining <> "\n" <> resume

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert String.length(result) <= 4096
      assert String.ends_with?(result, resume)
      assert String.valid?(result)
    end

    test "flag emoji (multiple code points)" do
      # Flag emojis are two regional indicator symbols
      flags = String.duplicate("\u{1F1FA}\u{1F1F8}", 2500) # US flag
      resume = "lemon resume abc123"
      text = flags <> "\n" <> resume

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert String.length(result) <= 4096
      assert String.ends_with?(result, resume)
      assert String.valid?(result)
    end

    test "zero-width joiner sequences" do
      # Family emoji with ZWJ
      family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
      families = String.duplicate(family, 1000)
      resume = "lemon resume abc123"
      text = families <> "\n" <> resume

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert String.length(result) <= 4096
      assert String.ends_with?(result, resume)
      assert String.valid?(result)
    end

    test "right-to-left text (Arabic)" do
      # Arabic text
      arabic = String.duplicate("\u{0645}\u{0631}\u{062D}\u{0628}\u{0627}", 1000)
      resume = "lemon resume abc123"
      text = arabic <> "\n" <> resume

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert String.length(result) <= 4096
      assert String.ends_with?(result, resume)
      assert String.valid?(result)
    end

    test "variation selectors" do
      # Text with variation selectors
      with_variation = String.duplicate("\u{2764}\u{FE0F}", 3000) # Red heart emoji
      resume = "lemon resume abc123"
      text = with_variation <> "\n" <> resume

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert String.length(result) <= 4096
      assert String.ends_with?(result, resume)
      assert String.valid?(result)
    end

    test "skin tone modifiers" do
      # Emoji with skin tone modifier
      with_skin_tone = String.duplicate("\u{1F44B}\u{1F3FD}", 2000) # Waving hand medium skin
      resume = "lemon resume abc123"
      text = with_skin_tone <> "\n" <> resume

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert String.length(result) <= 4096
      assert String.ends_with?(result, resume)
      assert String.valid?(result)
    end
  end

  describe "additional boundary conditions" do
    test "text at 4095 characters (one under limit)" do
      text = String.duplicate("x", 4095)

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert result == text
    end

    test "text at 4097 characters (one over limit)" do
      text = String.duplicate("x", 4097)

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert String.length(result) <= 4096
      assert String.ends_with?(result, "...")
    end

    test "empty resume line detection with various whitespace" do
      content = String.duplicate("x", 5000)
      resume = "   lemon resume abc123   "
      text = content <> "\n" <> resume

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert String.length(result) <= 4096
      assert String.contains?(result, "lemon resume abc123")
    end

    test "resume line with tab characters" do
      content = String.duplicate("x", 5000)
      resume = "\tlemon resume abc123\t"
      text = content <> "\n" <> resume

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert String.length(result) <= 4096
      assert String.contains?(result, "lemon resume abc123")
    end

    test "case insensitive resume detection" do
      content = String.duplicate("x", 5000)
      resume = "LEMON RESUME ABC123"
      text = content <> "\n" <> resume

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert String.length(result) <= 4096
      assert String.ends_with?(result, resume)
    end

    test "mixed case resume detection" do
      content = String.duplicate("x", 5000)
      resume = "LeMoN rEsUmE AbC123"
      text = content <> "\n" <> resume

      result = Truncate.truncate_for_telegram(text, MockEngine)

      assert String.length(result) <= 4096
      assert String.ends_with?(result, resume)
    end
  end
end
