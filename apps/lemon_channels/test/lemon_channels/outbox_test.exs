defmodule LemonChannels.OutboxTest do
  use ExUnit.Case, async: false

  alias LemonChannels.{Outbox, OutboundPayload}
  alias LemonChannels.Outbox.RateLimiter

  defmodule TestChannelPlugin do
    @behaviour LemonChannels.Plugin

    @impl true
    def id, do: "test-channel"

    @impl true
    def meta do
      %{
        label: "Test Channel",
        capabilities: %{
          edit_support: false,
          chunk_limit: 4096
        },
        docs: nil
      }
    end

    @impl true
    def child_spec(_opts) do
      %{
        id: __MODULE__,
        start: {Task, :start_link, [fn -> :ok end]}
      }
    end

    @impl true
    def normalize_inbound(_raw), do: {:error, :not_implemented}

    @impl true
    def deliver(_payload), do: {:ok, :delivered}

    @impl true
    def gateway_methods, do: []
  end

  setup do
    case LemonChannels.Registry.register(TestChannelPlugin) do
      :ok -> :ok
      {:error, :already_registered} -> :ok
    end

    on_exit(fn ->
      _ = LemonChannels.Registry.unregister(TestChannelPlugin.id())
    end)

    {:ok, outbox_pid: Process.whereis(Outbox)}
  end

  describe "enqueue/1" do
    test "rejects a payload whose idempotency key was already delivered" do
      channel = "idempotent-#{System.unique_integer([:positive])}"
      idempotency_key = "unique-key-#{System.unique_integer()}"

      LemonChannels.Outbox.Dedupe.mark(channel, idempotency_key)
      assert :duplicate = LemonChannels.Outbox.Dedupe.check(channel, idempotency_key)

      payload = %OutboundPayload{
        channel_id: channel,
        account_id: "account-1",
        peer: %{kind: :dm, id: "user-1", thread_id: nil},
        kind: :text,
        content: "Idempotent message",
        idempotency_key: idempotency_key
      }

      assert {:error, :duplicate} = Outbox.enqueue(payload)
    end

    test "coalesces queued edits for the same message", %{outbox_pid: outbox_pid} do
      original_state = :sys.get_state(outbox_pid)
      group_key = {{"test-channel", "account-1", :dm, "user-1", nil}, :edit, "42"}

      on_exit(fn ->
        :sys.replace_state(outbox_pid, fn _ -> original_state end)
      end)

      :sys.replace_state(outbox_pid, fn state ->
        %{state | queue: :queue.new(), processing_groups: %{group_key => make_ref()}}
      end)

      payload1 = %OutboundPayload{
        channel_id: "test-channel",
        kind: :edit,
        content: %{message_id: "42", text: "old"},
        account_id: "account-1",
        peer: %{kind: :dm, id: "user-1", thread_id: nil}
      }

      payload2 = %OutboundPayload{
        channel_id: "test-channel",
        kind: :edit,
        content: %{message_id: "42", text: "new"},
        account_id: "account-1",
        peer: %{kind: :dm, id: "user-1", thread_id: nil}
      }

      assert {:ok, _ref} = Outbox.enqueue(payload1)
      assert {:ok, _ref} = Outbox.enqueue(payload2)

      state = :sys.get_state(outbox_pid)
      queued = :queue.to_list(state.queue)

      assert length(queued) == 1
      assert hd(queued).payload.content == %{message_id: "42", text: "new"}
    end
  end

  describe "queue backpressure" do
    test "rejects enqueue with telemetry when the queue is full", %{outbox_pid: outbox_pid} do
      original_state = :sys.get_state(outbox_pid)

      on_exit(fn ->
        :sys.replace_state(outbox_pid, fn _ -> original_state end)
      end)

      handler_id = "test-outbox-queue-reject-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:lemon, :channels, :outbox, :rejected],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      filled_queue =
        :queue.from_list([
          full_queue_entry(:placeholder_1)
        ])

      :sys.replace_state(outbox_pid, fn state ->
        %{state | queue: filled_queue, processing: %{}, max_queue_size: 1}
      end)

      payload = %OutboundPayload{
        channel_id: "test-channel",
        kind: :text,
        content: "queue full telemetry",
        account_id: "account-1",
        peer: %{kind: :dm, id: "user-1", thread_id: nil}
      }

      assert {:error, :queue_full} = Outbox.enqueue(payload)

      assert_receive {:telemetry, [:lemon, :channels, :outbox, :rejected], measurements,
                      metadata},
                     1_000

      assert measurements.max_queue_size == 1
      assert measurements.queue_depth >= 1
      assert metadata.reason == :queue_full
    end
  end

  describe "stats/0" do
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
    test "multiple messages are retained when rate limited" do
      channel = "multi-retention-#{System.unique_integer([:positive])}"
      account = "account-1"

      # Exhaust rate limit
      for _ <- 1..20 do
        RateLimiter.consume(channel, account)
      end

      initial_stats = Outbox.stats()
      initial_enqueued = initial_stats.enqueued_total

      # Enqueue multiple messages
      for i <- 1..5 do
        payload = %OutboundPayload{
          channel_id: channel,
          account_id: account,
          peer: %{kind: :dm, id: "test-user", thread_id: nil},
          kind: :text,
          content: "Message #{i}"
        }

        result = Outbox.enqueue(payload)
        assert {:ok, _ref} = result
      end

      # All messages should be enqueued
      new_stats = Outbox.stats()
      # Chunking may enqueue more than 5, but it must enqueue at least 5.
      assert new_stats.enqueued_total >= initial_enqueued + 5
    end
  end

  defp full_queue_entry(payload) do
    %{
      ref: make_ref(),
      payload: payload,
      attempts: 0,
      available_at_ms: System.monotonic_time(:millisecond) + 60_000,
      chunk_index: 0,
      group_key: {:test, payload}
    }
  end
end
