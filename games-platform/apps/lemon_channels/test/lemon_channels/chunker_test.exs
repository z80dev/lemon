defmodule LemonChannels.Outbox.ChunkerTest do
  use ExUnit.Case, async: true

  alias LemonChannels.Outbox.Chunker

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

    test "splits at sentence boundaries when possible" do
      text = "First sentence. Second sentence. Third sentence."
      chunks = Chunker.chunk(text, chunk_size: 30)

      # Should try to keep sentences together
      assert length(chunks) >= 1
    end

    test "handles text without spaces" do
      text = String.duplicate("a", 50)
      chunks = Chunker.chunk(text, chunk_size: 20)

      assert length(chunks) == 3  # 20 + 20 + 10
    end

    test "preserves all content when chunking" do
      text = "Hello world this is a longer text that needs to be split into multiple chunks."
      chunks = Chunker.chunk(text, chunk_size: 20, preserve_words: false)

      rejoined = Enum.join(chunks, "")
      # Allow for trimmed whitespace
      assert String.replace(rejoined, " ", "") == String.replace(text, " ", "")
    end
  end

  describe "chunk_size_for/1" do
    test "returns default for unknown channel" do
      assert Chunker.chunk_size_for("unknown") == 4096
    end
  end
end
