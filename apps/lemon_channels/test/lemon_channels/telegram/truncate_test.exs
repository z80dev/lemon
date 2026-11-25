defmodule LemonChannels.Telegram.TruncateTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias LemonChannels.Telegram.{Formatter, Truncate}

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
        assert Enum.all?(String.split(chunk), &(&1 == "abc"))
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

    test "retains resume lines and ellipsis in a single status message" do
      resume = "lemon resume abc123"
      text = String.duplicate("x", 5000) <> "\n" <> resume <> "\n  "
      result = Truncate.truncate_for_telegram(text)

      assert String.length(result) == @max_length
      assert String.ends_with?(result, "...\n" <> resume)
      assert length(Regex.scan(~r/lemon resume abc123/, result)) == 1
    end
  end

  describe "split_messages/1 — properties" do
    property "random paragraphs, fences and tables split into fitting, fence-balanced messages" do
      word = member_of(["word", "**bold**", "`code`", "👩‍👩‍👧‍👦", "語", "é", "x"])

      paragraph =
        map(list_of(word, min_length: 1, max_length: 700), &Enum.join(&1, " "))

      fence =
        map(list_of(string(:alphanumeric, max_length: 120), max_length: 300), fn lines ->
          {:fence, lines}
        end)

      table =
        map(
          list_of(string(:alphanumeric, min_length: 1, max_length: 70), max_length: 200),
          fn cells ->
            {:table, cells}
          end
        )

      # Resized so most runs exceed one message and exercise every split path.
      check all(
              blocks <-
                resize(
                  list_of(one_of([paragraph, fence, table]), min_length: 1, max_length: 6),
                  300
                ),
              max_runs: 25
            ) do
        code_lines =
          Enum.flat_map(blocks, fn
            {:fence, lines} -> lines
            _ -> []
          end)

        text = Enum.map_join(blocks, "\n\n", &block_source/1)

        chunks = Truncate.split_messages(text)
        assert [_ | _] = chunks

        for chunk <- chunks do
          assert_fits_telegram(chunk)
          fence_lines = chunk |> String.split("\n") |> Enum.count(&(&1 == "```"))
          assert rem(fence_lines, 2) == 0
        end

        chunk_lines = chunks |> Enum.flat_map(&String.split(&1, "\n")) |> MapSet.new()
        assert Enum.all?(code_lines, &(&1 == "" or MapSet.member?(chunk_lines, &1)))
      end
    end
  end

  describe "rendered UTF-16 sizing, tables and code fences" do
    test "a 100-row table and a 5000-character fence split into valid, fitting Markdown" do
      header = ["| Row | Name | Detail |", "| --- | ---- | ------ |"]

      rows =
        for i <- 1..100 do
          # One wide cell pads every rendered row, so the rendered table is far
          # larger than its source.
          detail = if i == 50, do: String.duplicate("w", 60), else: "d#{i}"
          "| #{i} | name #{i} | #{detail} |"
        end

      code_lines = for i <- 1..125, do: "IO.puts(\"line #{i} of the fenced code block\")"
      code = Enum.join(code_lines, "\n")
      assert String.length(code) >= 5_000

      resume = "lemon resume abc123"

      text =
        Enum.join(
          ["Here is the report:", "" | header ++ rows] ++
            ["", "And the code:", "", "```elixir", code, "```", "", resume],
          "\n"
        )

      chunks = Truncate.split_messages(text)
      assert length(chunks) >= 2

      for chunk <- chunks do
        assert_fits_telegram(chunk)
        assert_valid_markdown(chunk)
      end

      assert String.ends_with?(List.last(chunks), resume)
      assert Enum.count(Enum.join(chunks, "\n") |> String.split("\n"), &(&1 == resume)) == 1

      # Every table row appears exactly once, and every chunk carrying rows
      # starts its table with the header, so rendered columns stay aligned.
      chunk_lines = Enum.map(chunks, &String.split(&1, "\n"))
      assert Enum.filter(List.flatten(chunk_lines), &(&1 in rows)) == rows

      for lines <- chunk_lines, Enum.any?(lines, &(&1 in rows)) do
        [first_row | _] = Enum.drop_while(lines, &(&1 not in (header ++ rows)))
        assert first_row == hd(header)

        table_widths =
          lines
          |> Enum.join("\n")
          |> Formatter.prepare_for_telegram()
          |> elem(0)
          |> String.split("\n")
          |> Enum.filter(&String.starts_with?(&1, "| "))
          |> Enum.map(&String.length/1)
          |> Enum.uniq()

        assert length(table_widths) == 1
      end

      # The code reaches the reader intact, split only between lines and
      # always inside a `pre` entity.
      pre_text =
        chunks
        |> Enum.flat_map(&pre_entity_texts/1)
        |> Enum.map_join("\n", &String.trim_trailing(&1, "\n"))

      assert pre_text == code
    end

    test "a ZWJ-emoji reply splits by UTF-16 units, not graphemes" do
      family = "👩‍👩‍👧‍👦"
      assert String.length(family) == 1
      assert utf16_units(family) == 11

      text = String.duplicate(family <> " ", 1_000)
      assert String.length(text) < @max_length

      chunks = Truncate.split_messages(text)
      assert length(chunks) >= 3
      Enum.each(chunks, &assert_fits_telegram/1)
      assert Enum.join(chunks, " ") |> String.split() |> Enum.all?(&(&1 == family))
      assert chunks |> Enum.join(" ") |> String.split() |> length() == 1_000
    end

    test "a fence too large for one message becomes several closed fences" do
      code = Enum.map_join(1..300, "\n", &"line #{&1} #{String.duplicate("c", 20)}")
      text = "~~~python\n" <> code <> "\n~~~"

      chunks = Truncate.split_messages(text)
      assert length(chunks) >= 2

      for chunk <- chunks do
        assert_fits_telegram(chunk)
        assert_valid_markdown(chunk)
        assert String.starts_with?(chunk, "~~~python\n")
        assert String.ends_with?(chunk, "\n~~~")
      end

      assert chunks
             |> Enum.flat_map(&pre_entity_texts/1)
             |> Enum.map_join("\n", &String.trim_trailing(&1, "\n")) ==
               code
    end

    test "content around a fence never splits it while it fits whole" do
      prose = String.duplicate("Some prose before the code. ", 140)
      code = Enum.map_join(1..40, "\n", &"step_#{&1}()")
      text = prose <> "\n\n```\n" <> code <> "\n```\n\nAfter."

      chunks = Truncate.split_messages(text)

      fenced = Enum.filter(chunks, &String.contains?(&1, "```"))
      assert [chunk] = fenced
      assert String.contains?(chunk, "```\n" <> code <> "\n```")
      Enum.each(chunks, &assert_valid_markdown/1)
    end

    test "truncate_for_telegram keeps a status message whole by rendered size" do
      rows = for i <- 1..200, do: "| #{i} | #{String.duplicate("v", 30)} |"
      resume = "lemon resume abc123"
      text = Enum.join(["| k | v |", "| - | - |" | rows] ++ [resume], "\n")

      result = Truncate.truncate_for_telegram(text)

      assert_fits_telegram(result)
      assert_valid_markdown(result)
      assert String.ends_with?(result, "\n...\n" <> resume)
      assert String.starts_with?(result, "| k | v |\n| - | - |\n| 1 |")
    end

    test "truncate_for_telegram closes a truncated fence before the ellipsis" do
      code = Enum.map_join(1..400, "\n", &"value_#{&1} = compute(#{&1})")
      result = Truncate.truncate_for_telegram("```\n" <> code <> "\n```")

      assert_fits_telegram(result)
      assert_valid_markdown(result)
      assert String.ends_with?(result, "\n```\n...")
    end
  end

  defp assert_fits_telegram(chunk) do
    {rendered, opts} = Formatter.prepare_for_telegram(chunk)
    assert utf16_units(chunk) <= @max_length
    assert utf16_units(rendered) <= @max_length

    for %{"offset" => offset, "length" => length} <- (opts || %{})[:entities] || [] do
      assert offset + length <= utf16_units(rendered)
    end
  end

  # Round trip: the chunk parses without warnings (no unclosed fence) and
  # renders to non-empty text.
  defp assert_valid_markdown(chunk) do
    assert {:ok, _ast, []} = EarmarkParser.as_ast(chunk)
    assert {rendered, _opts} = Formatter.prepare_for_telegram(chunk)
    assert String.trim(rendered) != ""
  end

  defp pre_entity_texts(chunk) do
    {rendered, opts} = Formatter.prepare_for_telegram(chunk)
    utf16 = :unicode.characters_to_binary(rendered, :utf8, :utf16)

    for %{"type" => "pre", "offset" => offset, "length" => length} <-
          (opts || %{})[:entities] || [] do
      utf16
      |> binary_part(offset * 2, length * 2)
      |> :unicode.characters_to_binary(:utf16, :utf8)
    end
  end

  defp utf16_units(text),
    do: text |> :unicode.characters_to_binary(:utf8, :utf16) |> byte_size() |> div(2)

  defp block_source({:fence, lines}), do: Enum.join(["```" | lines] ++ ["```"], "\n")

  defp block_source({:table, cells}) do
    rows = cells |> Enum.with_index() |> Enum.map(fn {cell, i} -> "| #{i} | #{cell} |" end)
    Enum.join(["| n | cell |", "| --- | --- |" | rows], "\n")
  end

  defp block_source(paragraph) when is_binary(paragraph), do: paragraph
end
