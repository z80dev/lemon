defmodule LemonChannels.OutboxRateLimitRequeueTest do
  @moduledoc """
  Tests that rate-limited outbox entries are properly re-queued and eventually delivered.

  This test verifies the fix for P1: Rate-limited outbox entries were being dropped
  because process_next/1 dequeued the entry but didn't re-queue it when rate limited.
  """
  use ExUnit.Case, async: false

  alias LemonChannels.{Outbox, OutboundPayload, Registry}
  alias LemonChannels.Outbox.RateLimiter

  # Test plugin that tracks deliveries
  defmodule TrackingPlugin do
    @behaviour LemonChannels.Plugin

    @impl true
    def id, do: "tracking-test-channel"

    @impl true
    def meta do
      %{
        label: "Tracking Test Channel",
        capabilities: %{chunk_limit: 4096},
        docs: nil
      }
    end

    @impl true
    def child_spec(_opts) do
      %{id: __MODULE__, start: {Agent, :start_link, [fn -> [] end]}}
    end

    @impl true
    def normalize_inbound(_raw), do: {:error, :not_supported}

    @impl true
    def deliver(payload) do
      # Send delivery notification to test process stored in payload.meta
      if pid = payload.meta[:test_pid] do
        send(pid, {:delivered, payload.content})
      end

      {:ok, make_ref()}
    end

    @impl true
    def gateway_methods, do: []
  end

  setup do
    # Start required processes
    start_supervised_if_needed(RateLimiter)
    start_supervised_if_needed(Registry)
    start_supervised_if_needed(Outbox)

    # Register our tracking plugin
    Registry.register(TrackingPlugin)

    on_exit(fn ->
      Registry.unregister(TrackingPlugin.id())
    end)

    :ok
  end

  defp start_supervised_if_needed(module) do
    case Process.whereis(module) do
      nil -> start_supervised!(module)
      _pid -> :ok
    end
  end

  describe "rate-limited entry re-queue" do
    test "multiple rate-limited entries are all eventually delivered" do
      channel_id = TrackingPlugin.id()

      # Exhaust rate limiter tokens
      for _ <- 1..10 do
        RateLimiter.consume(channel_id, "multi-account")
      end

      # Enqueue multiple messages
      messages =
        for i <- 1..3 do
          content = "multi-message-#{i}-#{System.unique_integer([:positive])}"

          payload = %OutboundPayload{
            channel_id: channel_id,
            kind: :text,
            content: content,
            account_id: "multi-account",
            peer: %{kind: :dm, id: "user-1", thread_id: nil},
            meta: %{test_pid: self()}
          }

          {:ok, _ref} = Outbox.enqueue(payload)
          content
        end

      # All messages should eventually be delivered
      delivered =
        for _ <- 1..3 do
          assert_receive {:delivered, content}, 1000
          content
        end

      # All messages should have been delivered (order may vary)
      assert Enum.sort(delivered) == Enum.sort(messages)
    end

    test "entry is not lost when process_queue triggers during rate limiting" do
      # This test simulates the race condition where process_queue is
      # triggered multiple times while rate limited

      channel_id = TrackingPlugin.id()
      account = "race-account-#{System.unique_integer([:positive])}"

      # Exhaust rate limiter
      for _ <- 1..10 do
        RateLimiter.consume(channel_id, account)
      end

      payload = %OutboundPayload{
        channel_id: channel_id,
        kind: :text,
        content: "race-test-#{System.unique_integer([:positive])}",
        account_id: account,
        peer: %{kind: :dm, id: "user-1", thread_id: nil},
        meta: %{test_pid: self()}
      }

      {:ok, _ref} = Outbox.enqueue(payload)

      # Manually trigger process_queue multiple times to simulate race
      outbox_pid = Process.whereis(Outbox)
      send(outbox_pid, :process_queue)
      send(outbox_pid, :process_queue)
      send(outbox_pid, :process_queue)

      # The message should still be delivered exactly once
      assert_receive {:delivered, content}, 1000
      assert content == payload.content

      # Should not receive duplicate deliveries
      refute_receive {:delivered, _}, 100
    end
  end
end
