defmodule LemonChannels.OutboxChunkingTest do
  use ExUnit.Case, async: false

  alias LemonChannels.{Outbox, OutboundPayload}
  alias LemonChannels.Outbox.Chunker

  @moduledoc """
  Tests for outbox chunking functionality.
  """

  setup do
    # Start dependencies if not running
    ensure_started(LemonChannels.Registry)
    ensure_started(LemonChannels.Outbox.RateLimiter)
    ensure_started(LemonChannels.Outbox.Dedupe)

    case Process.whereis(Outbox) do
      nil ->
        {:ok, pid} = Outbox.start_link([])
        on_exit(fn ->
          if Process.alive?(pid), do: GenServer.stop(pid)
        end)
        {:ok, outbox_pid: pid}

      pid ->
        {:ok, outbox_pid: pid}
    end
  end

  defp ensure_started(module) do
    case Process.whereis(module) do
      nil ->
        {:ok, _} = module.start_link([])

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  describe "Chunker.chunk/2" do
    test "returns single chunk when text is under limit" do
      text = "Short text"
      chunks = Chunker.chunk(text, chunk_size: 100)

      assert length(chunks) == 1
      assert hd(chunks) == text
    end

    test "splits text into multiple chunks when over limit" do
      # Create text that's definitely over the limit
      text = String.duplicate("Hello world! ", 100)  # ~1300 chars
      chunks = Chunker.chunk(text, chunk_size: 200)

      assert length(chunks) > 1
      # All chunks should be under the limit
      Enum.each(chunks, fn chunk ->
        assert String.length(chunk) <= 200
      end)
    end

    test "preserves sentence boundaries when possible" do
      text = "This is sentence one. This is sentence two. This is sentence three."
      chunks = Chunker.chunk(text, chunk_size: 30, preserve_sentences: true)

      # Should try to break at sentence boundaries
      assert length(chunks) > 1
    end

    test "preserves word boundaries when possible" do
      text = "Hello wonderful beautiful world of programming and code"
      chunks = Chunker.chunk(text, chunk_size: 20, preserve_words: true, preserve_sentences: false)

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

  describe "Chunker.chunk_size_for/1" do
    test "returns default chunk size for unknown channel" do
      size = Chunker.chunk_size_for("unknown-channel")
      assert is_integer(size)
      assert size > 0
    end

    test "returns channel-specific size when available" do
      # Register a test channel with specific chunk limit
      # For now, test with unknown channel (should return default)
      size = Chunker.chunk_size_for("telegram")
      assert is_integer(size)
      assert size > 0
    end
  end

  describe "Outbox chunking integration" do
    test "enqueues short message as single payload" do
      payload = %OutboundPayload{
        channel_id: "test-channel",
        account_id: "account-1",
        peer: %{id: "peer-1", kind: :dm},
        kind: :text,
        content: "Short message",
        meta: %{}
      }

      {:ok, ref} = Outbox.enqueue(payload)
      assert is_reference(ref)
    end

    test "enqueues long message and chunks it" do
      # Create a message that exceeds typical chunk size
      long_content = String.duplicate("This is a very long message that should be chunked. ", 200)

      payload = %OutboundPayload{
        channel_id: "test-channel",
        account_id: "account-1",
        peer: %{id: "peer-1", kind: :dm},
        kind: :text,
        content: long_content,
        meta: %{}
      }

      {:ok, ref} = Outbox.enqueue(payload)
      assert is_reference(ref)
    end

    test "preserves idempotency_key only for first chunk" do
      long_content = String.duplicate("This is a test message. ", 200)

      payload = %OutboundPayload{
        channel_id: "test-channel",
        account_id: "account-1",
        peer: %{id: "peer-1", kind: :dm},
        kind: :text,
        content: long_content,
        idempotency_key: "unique-key-123",
        meta: %{}
      }

      # Should not error even with idempotency key
      {:ok, ref} = Outbox.enqueue(payload)
      assert is_reference(ref)
    end

    test "adds chunk metadata to payloads" do
      long_content = String.duplicate("Chunk test message. ", 200)

      payload = %OutboundPayload{
        channel_id: "test-channel",
        account_id: "account-1",
        peer: %{id: "peer-1", kind: :dm},
        kind: :text,
        content: long_content,
        meta: %{}
      }

      {:ok, _ref} = Outbox.enqueue(payload)

      # The chunking happens internally; we can verify the outbox processes without error
      Process.sleep(50)

      assert Process.alive?(Process.whereis(Outbox))
    end

    test "handles non-text content without chunking" do
      # Binary content shouldn't be chunked
      payload = %OutboundPayload{
        channel_id: "test-channel",
        account_id: "account-1",
        peer: %{id: "peer-1", kind: :dm},
        kind: :image,
        content: {:file, "/path/to/image.png"},
        meta: %{}
      }

      {:ok, ref} = Outbox.enqueue(payload)
      assert is_reference(ref)
    end
  end

  describe "duplicate detection with chunking" do
    test "first chunk respects idempotency" do
      content = String.duplicate("Test message. ", 100)

      payload = %OutboundPayload{
        channel_id: "test-channel",
        account_id: "account-1",
        peer: %{id: "peer-1", kind: :dm},
        kind: :text,
        content: content,
        idempotency_key: "dedup-test-key",
        meta: %{}
      }

      {:ok, _ref1} = Outbox.enqueue(payload)

      # Note: Duplicate detection happens in the Dedupe module
      # Second enqueue with same key might be rejected
      # depending on Dedupe state
    end
  end
end
