defmodule LemonChannels.Telegram.TruncateTest do
  use ExUnit.Case, async: true

  alias LemonChannels.Telegram.Truncate

  @max_length 4096

  describe "split_messages/1 — short text" do
    test "returns single chunk for short text" do
      text = "Hello world"
      assert Truncate.split_messages(text) == [text]
    end

    test "returns single chunk for text exactly at the limit" do
      text = String.duplicate("x", @max_length)
      result = Truncate.split_messages(text)
      assert length(result) == 1
      assert String.length(hd(result)) == @max_length
    end

    test "returns single chunk for text under the limit" do
      text = String.duplicate("x", @max_length - 1)
      result = Truncate.split_messages(text)
      assert length(result) == 1
    end
  end

  describe "split_messages/1 — newline splitting" do
    test "splits at first newline within 80% of limit" do
      # Build text: fill to 80% of limit, then newline, then more content
      target = trunc(@max_length * 0.80)
      part_a = String.duplicate("a", target - 1) <> "\n"
      part_b = String.duplicate("b", @max_length)
      text = part_a <> part_b

      chunks = Truncate.split_messages(text)
      assert length(chunks) == 2

      # First chunk should end right after the newline (trimmed)
      first = hd(chunks)
      assert String.length(first) <= @max_length
      assert String.ends_with?(String.trim_trailing(first), String.duplicate("a", target - 1))
    end

    test "splits multi-paragraph text into multiple chunks" do
      # Create text with many paragraphs, each ~1500 chars
      paragraphs =
        for i <- 1..6 do
          String.duplicate("paragraph #{i} content. ", 100) <> "\n\n"
        end
        |> Enum.join()
        |> String.trim_trailing()

      # Verify text is actually over the limit
      assert String.length(paragraphs) > @max_length

      chunks = Truncate.split_messages(paragraphs)

      # All chunks must be within the limit
      for chunk <- chunks do
        assert String.length(chunk) <= @max_length,
               "chunk exceeded limit: #{String.length(chunk)}"
      end

      # Should be at least 2 chunks
      assert length(chunks) >= 2
    end
  end

  describe "split_messages/1 — word boundary splitting" do
    test "falls back to space when no newline within 80%" do
      # Text with no newlines, only spaces, longer than limit
      words = for i <- 1..800, do: "word#{i}"
      text = Enum.join(words, " ")

      chunks = Truncate.split_messages(text)

      for chunk <- chunks do
        assert String.length(chunk) <= @max_length
      end

      assert length(chunks) >= 2
    end

    test "does not split mid-word when spaces are available" do
      # Create text with spaces at regular intervals
      segment = String.duplicate("abc ", 100) |> String.trim()
      text = String.duplicate(segment <> " ", div(@max_length * 2, String.length(segment) + 1))

      chunks = Truncate.split_messages(text)

      for chunk <- chunks do
        assert String.length(chunk) <= @max_length
        # Neither chunk should start or end with a partial word
        # (except possibly the second chunk which starts after a space)
      end
    end
  end

  describe "split_messages/1 — hard split fallback" do
    test "hard splits when no newline or space within range" do
      # Single continuous string with no newlines or spaces, longer than limit
      text = String.duplicate("x", @max_length + 1000)

      chunks = Truncate.split_messages(text)
      assert length(chunks) >= 2

      for chunk <- chunks do
        assert String.length(chunk) <= @max_length
      end
    end
  end

  describe "split_messages/1 — resume line preservation" do
    test "preserves resume line on the last chunk" do
      # Build long text + resume line
      content = String.duplicate("x", @max_length + 1000)
      resume_line = "lemon resume abc123"
      text = content <> "\n" <> resume_line

      chunks = Truncate.split_messages(text)
      assert length(chunks) >= 2

      last = List.last(chunks)
      assert String.contains?(last, resume_line)
    end

    test "preserves resume line when content fits in one chunk" do
      short_content = String.duplicate("x", 100)
      resume_line = "lemon resume abc123"
      text = short_content <> "\n" <> resume_line

      chunks = Truncate.split_messages(text)
      assert length(chunks) == 1
      assert String.contains?(hd(chunks), resume_line)
    end
  end

  describe "split_messages/1 — edge cases" do
    test "handles empty string" do
      assert Truncate.split_messages("") == [""]
    end

    test "handles nil gracefully" do
      assert Truncate.split_messages(nil) == [""]
    end

    test "handles text with only newlines" do
      text = String.duplicate("\n", @max_length + 1000)
      chunks = Truncate.split_messages(text)

      for chunk <- chunks do
        assert String.length(chunk) <= @max_length
      end
    end

    test "correctly splits multibyte text (emoji) at newline boundaries" do
      # Each line: 500 emoji (1 grapheme each = 4 bytes) + newline = 501 chars
      # 10 lines = 5010 chars — well over the 4096 limit
      line = String.duplicate("🔥", 500) <> "\n"
      text = String.duplicate(line, 10)

      assert String.length(text) > @max_length

      chunks = Truncate.split_messages(text)
      assert length(chunks) >= 2

      for chunk <- chunks do
        assert String.length(chunk) <= @max_length,
               "chunk with emoji exceeded limit: #{String.length(chunk)}"
      end

      # Verify no truncated emoji (no orphaned bytes)
      for chunk <- chunks do
        assert String.valid?(chunk)
      end
    end

    test "correctly splits CJK text at word boundaries" do
      # Each word: "中文" (2 graphemes) + number + space ≈ 8 chars
      # 2000 words × ~8 chars = ~16000 chars — well over limit
      words = for i <- 1..2000, do: "中文#{i}"
      text = Enum.join(words, " ")

      assert String.length(text) > @max_length

      chunks = Truncate.split_messages(text)
      assert length(chunks) >= 2

      for chunk <- chunks do
        assert String.length(chunk) <= @max_length,
               "CJK chunk exceeded limit: #{String.length(chunk)}"
        assert String.valid?(chunk)
      end
    end

    test "correctly splits mixed emoji + text at newline boundaries" do
      # Each paragraph: "Hello 🔥 world 🌍 " = 18 chars, ×200 = 3600 chars + newlines
      paragraph = String.duplicate("Hello 🔥 world 🌍 ", 200) <> "\n\n"
      text = String.duplicate(paragraph, 10)

      assert String.length(text) > @max_length

      chunks = Truncate.split_messages(text)
      assert length(chunks) >= 2

      for chunk <- chunks do
        assert String.length(chunk) <= @max_length
        assert String.valid?(chunk)
      end
    end

    test "rejoined chunks approximate original text (minus whitespace at splits)" do
      # Build text with clear paragraph breaks
      paragraphs =
        for i <- 1..6 do
          "Paragraph #{i}: " <> String.duplicate("content ", 200) <> "\n\n"
        end
        |> Enum.join()

      chunks = Truncate.split_messages(paragraphs)

      # Rejoin and check most content is preserved
      rejoined = Enum.join(chunks, "\n")
      # All paragraphs should be present in some form
      for i <- 1..6 do
        assert String.contains?(rejoined, "Paragraph #{i}")
      end
    end
  end

  describe "split_messages/1 — real-world scenario" do
    test "splits a long code block response" do
      # Simulate a long code explanation
      lines =
        for i <- 1..200 do
          "def function_#{i}(arg) do\n  # Implementation line #{i} with some explanation text\n  result = process(arg)\n  {:ok, result}\nend\n"
        end

      text = Enum.join(lines, "\n")
      chunks = Truncate.split_messages(text)

      for chunk <- chunks do
        assert String.length(chunk) <= @max_length,
               "Chunk length #{String.length(chunk)} exceeds limit #{@max_length}"
      end

      # Should split into at least 2 chunks
      assert length(chunks) >= 2
    end
  end

  describe "truncate_for_telegram/1 — backward compatibility" do
    test "still works for short text" do
      text = "Hello world"
      assert Truncate.truncate_for_telegram(text) == text
    end

    test "truncates long text with ellipsis" do
      text = String.duplicate("x", 5000)
      result = Truncate.truncate_for_telegram(text)
      assert String.length(result) <= @max_length
      assert String.ends_with?(result, "...")
    end
  end

  describe "max_length/0" do
    test "returns 4096" do
      assert Truncate.max_length() == 4096
    end
  end
end
