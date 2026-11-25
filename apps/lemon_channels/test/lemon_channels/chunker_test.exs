defmodule LemonChannels.Outbox.ChunkerTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias LemonChannels.Outbox.Chunker

  describe "sentence boundaries" do
    test "a reversed-only sentence end falls back to the word break, then the hard break" do
      # Matches `[.!?]\\s` only when reversed; the old chunker raised ArithmeticError.
      assert Chunker.chunk("x ?yyyyyyyyyyyy", chunk_size: 10) ==
               ["x ", "?yyyyyyyyy", "yyy"]
    end

    test "a chunk window ending exactly at a sentence end makes progress" do
      # The old chunker computed break point 0 and recursed forever.
      assert Chunker.chunk("Hello wo. yyyyyyy", chunk_size: 10) == ["Hello wo. ", "yyyyyyy"]
    end

    test "breaks after the last sentence end, counted in graphemes" do
      # The old chunker split at `length - last_end` ("Hi. th").
      assert Chunker.chunk("Hi. there friend", chunk_size: 10) ==
               ["Hi. ", "there ", "friend"]

      # Multi-byte text made the old byte-based break negative, splitting from
      # the end of the whole remaining text.
      assert Chunker.chunk("ééééé. ab cdefgh", chunk_size: 10) == ["ééééé. ", "ab cdefgh"]
    end

    test "rejects a non-positive chunk size instead of looping" do
      assert_raise ArgumentError, fn -> Chunker.chunk("abc", chunk_size: 0) end
      assert_raise ArgumentError, fn -> Chunker.chunk("abc", chunk_size: nil) end
    end
  end

  describe "properties" do
    @alphabet ["a", "b", "é", "語", "👩‍👩‍👧", ".", "!", "?", " ", "  ", "\n", "\r\n", "\t"]

    property "chunks fit the limit and lose only whitespace at chunk starts" do
      check all(
              parts <- list_of(member_of(@alphabet), max_length: 200),
              chunk_size <- integer(1..40),
              preserve_words <- boolean(),
              preserve_sentences <- boolean(),
              max_runs: 500
            ) do
        text = Enum.join(parts)

        chunks =
          Chunker.chunk(text,
            chunk_size: chunk_size,
            preserve_words: preserve_words,
            preserve_sentences: preserve_sentences
          )

        assert chunks != []
        assert Enum.all?(chunks, &(String.length(&1) <= chunk_size))
        assert_reassembles(text, chunks)
      end
    end

    # Every chunk is a non-empty prefix of what remains; only whitespace that
    # would start a next chunk (or trail the last one) is dropped.
    defp assert_reassembles("", [""]), do: :ok
    defp assert_reassembles(remaining, []), do: assert(remaining == "")

    defp assert_reassembles(text, [chunk | rest]) do
      assert chunk != ""
      assert String.starts_with?(text, chunk)

      text
      |> binary_part(byte_size(chunk), byte_size(text) - byte_size(chunk))
      |> String.trim_leading()
      |> assert_reassembles(rest)
    end
  end

  describe "chunk/2" do
    test "returns single chunk for short text" do
      text = "Hello, world!"
      assert Chunker.chunk(text) == [text]
    end

    test "returns single chunk when text equals chunk size" do
      text = String.duplicate("a", 100)
      assert Chunker.chunk(text, chunk_size: 100) == [text]
    end

    test "splits text at word boundaries" do
      text = "Hello world this is a test"
      chunks = Chunker.chunk(text, chunk_size: 15)

      assert length(chunks) > 1
      # Each chunk should be under limit
      for chunk <- chunks do
        assert String.length(chunk) <= 15
      end
    end

    test "handles text without spaces" do
      text = String.duplicate("a", 50)
      chunks = Chunker.chunk(text, chunk_size: 20)

      # 20 + 20 + 10
      assert length(chunks) == 3
    end

    test "preserves all content when chunking" do
      text = "Hello world this is a longer text that needs to be split into multiple chunks."
      chunks = Chunker.chunk(text, chunk_size: 20, preserve_words: false)

      rejoined = Enum.join(chunks, "")
      # Allow for trimmed whitespace
      assert String.replace(rejoined, " ", "") == String.replace(text, " ", "")
    end

    test "preserves word boundaries when possible" do
      text = "Hello wonderful beautiful world of programming and code"

      chunks =
        Chunker.chunk(text, chunk_size: 20, preserve_words: true, preserve_sentences: false)

      # Should produce multiple chunks
      assert length(chunks) > 1

      # All chunks combined should equal original text
      rejoined = Enum.join(chunks, "")
      assert rejoined == text
    end

    test "handles empty string" do
      chunks = Chunker.chunk("", chunk_size: 100)
      assert chunks == [""]
    end
  end
end
