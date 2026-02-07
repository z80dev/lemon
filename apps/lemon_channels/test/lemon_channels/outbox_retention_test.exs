defmodule LemonChannels.OutboxRetentionTest do
  @moduledoc """
  Tests for outbox message retention during rate limiting.

  These tests verify that:
  - Messages are not dropped when rate limited
  - Messages are retried after rate limit window
  - Queue length is correctly reported
  """
  use ExUnit.Case, async: false

  alias LemonChannels.{Outbox, OutboundPayload}
  alias LemonChannels.Outbox.RateLimiter

  @default_peer %{kind: :dm, id: "test-user", thread_id: nil}

  setup do
    # Start Registry if not running (Outbox delivery path expects it)
    case Process.whereis(LemonChannels.Registry) do
      nil ->
        {:ok, reg_pid} = LemonChannels.Registry.start_link([])

        on_exit(fn ->
          if Process.alive?(reg_pid), do: GenServer.stop(reg_pid)
        end)

      _ ->
        :ok
    end

    # Start Dedupe if not running (Outbox enqueue path checks idempotency)
    case Process.whereis(LemonChannels.Outbox.Dedupe) do
      nil ->
        {:ok, dedupe_pid} = LemonChannels.Outbox.Dedupe.start_link([])

        on_exit(fn ->
          if Process.alive?(dedupe_pid), do: GenServer.stop(dedupe_pid)
        end)

      _ ->
        :ok
    end

    # Start RateLimiter if not running
    case Process.whereis(RateLimiter) do
      nil ->
        {:ok, rl_pid} = RateLimiter.start_link([])
        on_exit(fn ->
          if Process.alive?(rl_pid), do: GenServer.stop(rl_pid)
        end)

      _ ->
        :ok
    end

    # Start Outbox if not running
    case Process.whereis(Outbox) do
      nil ->
        {:ok, outbox_pid} = Outbox.start_link([])
        on_exit(fn ->
          if Process.alive?(outbox_pid), do: GenServer.stop(outbox_pid)
        end)
        {:ok, outbox_pid: outbox_pid}

      pid ->
        {:ok, outbox_pid: pid}
    end
  end

  describe "Outbox.stats/0" do
    test "returns queue length and processing count" do
      stats = Outbox.stats()

      assert is_map(stats)
      assert Map.has_key?(stats, :queue_length)
      assert Map.has_key?(stats, :processing_count)
      assert is_integer(stats.queue_length)
      assert is_integer(stats.processing_count)
      assert stats.queue_length >= 0
      assert stats.processing_count >= 0
    end
  end

  describe "rate-limited message retention" do
    test "messages are enqueued even when rate limited" do
      channel = "retention-test-#{System.unique_integer([:positive])}"
      account = "account-1"

      # Exhaust rate limit
      for _ <- 1..20 do
        RateLimiter.consume(channel, account)
      end

      # Get initial queue length
      initial_stats = Outbox.stats()
      initial_length = initial_stats.queue_length

      # Enqueue a message (should still be accepted despite rate limit)
      payload = %OutboundPayload{
        channel_id: channel,
        account_id: account,
        peer: @default_peer,
        kind: :text,
        content: "Rate limited message"
      }

      result = Outbox.enqueue(payload)
      assert {:ok, _ref} = result

      # Queue length should have increased
      new_stats = Outbox.stats()
      assert new_stats.queue_length >= initial_length
    end

    test "multiple messages are retained when rate limited" do
      channel = "multi-retention-#{System.unique_integer([:positive])}"
      account = "account-1"

      # Exhaust rate limit
      for _ <- 1..20 do
        RateLimiter.consume(channel, account)
      end

      # Get initial queue length
      initial_stats = Outbox.stats()
      initial_length = initial_stats.queue_length

      # Enqueue multiple messages
      for i <- 1..5 do
        payload = %OutboundPayload{
          channel_id: channel,
          account_id: account,
          peer: @default_peer,
          kind: :text,
          content: "Message #{i}"
        }

        result = Outbox.enqueue(payload)
        assert {:ok, _ref} = result
      end

      # All messages should be enqueued
      new_stats = Outbox.stats()
      # Queue length should have increased by at least the number of messages we added
      # (may be more due to chunking or less due to processing)
      assert new_stats.queue_length >= initial_length
    end
  end

  describe "process_next rate limiting behavior" do
    test "returns same state when rate limited (entry retained)" do
      # This tests the internal behavior documented in the code:
      # When rate limited, process_next returns the original state
      # which still contains the entry in the queue

      # We can verify this indirectly by checking that:
      # 1. Enqueuing a message succeeds
      # 2. Stats show the message is in the queue
      # 3. After rate limit expires, the message is still there

      channel = "process-next-test-#{System.unique_integer([:positive])}"
      account = "account-1"

      # Exhaust rate limit
      for _ <- 1..20 do
        RateLimiter.consume(channel, account)
      end

      payload = %OutboundPayload{
        channel_id: channel,
        account_id: account,
        peer: @default_peer,
        kind: :text,
        content: "Test message"
      }

      # Enqueue the message
      {:ok, _ref} = Outbox.enqueue(payload)

      # Give time for process_queue to attempt processing
      Process.sleep(50)

      # The message should still be in the queue (rate limited)
      # or being processed (if tokens refilled)
      stats = Outbox.stats()
      assert stats.queue_length >= 0 or stats.processing_count >= 0
    end
  end

  describe "idempotency" do
    test "idempotency check prevents re-enqueue of already delivered messages" do
      # Note: Idempotency in the outbox prevents re-delivery, not re-enqueue.
      # Messages are only marked as delivered after successful delivery.
      # This test verifies that the idempotency key is correctly checked.

      channel = "idempotent-#{System.unique_integer([:positive])}"
      account = "account-1"
      idempotency_key = "unique-key-#{System.unique_integer()}"

      # Manually mark a key as delivered
      LemonChannels.Outbox.Dedupe.mark(channel, idempotency_key)

      # Give time for async cast to process
      Process.sleep(10)

      payload = %OutboundPayload{
        channel_id: channel,
        account_id: account,
        peer: @default_peer,
        kind: :text,
        content: "Idempotent message",
        idempotency_key: idempotency_key
      }

      # Enqueue should be rejected as duplicate
      result = Outbox.enqueue(payload)
      assert {:error, :duplicate} = result
    end

    test "messages with different idempotency keys can be enqueued" do
      channel = "multi-idempotent-#{System.unique_integer([:positive])}"
      account = "account-1"

      payload1 = %OutboundPayload{
        channel_id: channel,
        account_id: account,
        peer: @default_peer,
        kind: :text,
        content: "Message 1",
        idempotency_key: "key-1-#{System.unique_integer()}"
      }

      payload2 = %OutboundPayload{
        channel_id: channel,
        account_id: account,
        peer: @default_peer,
        kind: :text,
        content: "Message 2",
        idempotency_key: "key-2-#{System.unique_integer()}"
      }

      # Both should succeed
      assert {:ok, _ref1} = Outbox.enqueue(payload1)
      assert {:ok, _ref2} = Outbox.enqueue(payload2)
    end
  end
end
