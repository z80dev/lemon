defmodule LemonChannels.OutboxArchitectureTest do
  use ExUnit.Case, async: false

  alias LemonChannels.{Outbox, OutboundPayload, Registry}
  alias LemonChannels.Outbox.{Chunker, Dedupe, RateLimiter}

  defmodule BlockingPlugin do
    @behaviour LemonChannels.Plugin

    @impl true
    def id, do: "outbox-blocking-channel"

    @impl true
    def meta do
      %{
        label: "Outbox Blocking Test Channel",
        capabilities: %{chunk_limit: 200},
        docs: nil
      }
    end

    @impl true
    def child_spec(_opts), do: %{id: __MODULE__, start: {Agent, :start_link, [fn -> :ok end]}}

    @impl true
    def normalize_inbound(_raw), do: {:error, :not_supported}

    @impl true
    def deliver(payload) do
      test_pid = payload.meta[:test_pid]
      send(test_pid, {:deliver_started, self(), payload.meta[:chunk_index]})

      receive do
        :release -> :ok
      end

      send(test_pid, {:delivered, payload.meta[:chunk_index]})
      {:ok, make_ref()}
    end

    @impl true
    def gateway_methods, do: []
  end

  defmodule CrashPlugin do
    @behaviour LemonChannels.Plugin

    @impl true
    def id, do: "outbox-crash-channel"

    @impl true
    def meta do
      %{
        label: "Outbox Crash Test Channel",
        capabilities: %{chunk_limit: 4096},
        docs: nil
      }
    end

    @impl true
    def child_spec(_opts), do: %{id: __MODULE__, start: {Agent, :start_link, [fn -> :ok end]}}

    @impl true
    def normalize_inbound(_raw), do: {:error, :not_supported}

    @impl true
    def deliver(_payload) do
      exit(:boom)
    end

    @impl true
    def gateway_methods, do: []
  end

  setup do
    start_supervised_if_needed(Registry)
    start_supervised_if_needed(RateLimiter)
    start_supervised_if_needed(Dedupe)
    start_supervised_if_needed(Outbox)

    :ok
  end

  defp start_supervised_if_needed(module) do
    case Process.whereis(module) do
      nil -> start_supervised!(module)
      _pid -> :ok
    end
  end

  defp eventually(assertion_fun, timeout_ms \\ 250) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(assertion_fun, deadline)
  end

  defp do_eventually(assertion_fun, deadline) do
    assertion_fun.()
  rescue
    e in ExUnit.AssertionError ->
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(10)
        do_eventually(assertion_fun, deadline)
      else
        reraise(e, __STACKTRACE__)
      end
  end

  test "per-group ordering: chunked payload delivers one in-flight chunk at a time (prevents reordering)" do
    Registry.register(BlockingPlugin)
    on_exit(fn -> Registry.unregister(BlockingPlugin.id()) end)

    baseline_processing = Outbox.stats().processing_count

    # Keep chunk_count <= 5 to avoid rate limiting burst interference.
    content = String.duplicate("0123456789 ", 60) |> String.trim_trailing()
    chunks = Chunker.chunk(content, chunk_size: BlockingPlugin.meta().capabilities.chunk_limit)
    chunk_count = length(chunks)
    assert chunk_count in 2..5

    account_id = "acct-#{System.unique_integer([:positive])}"

    payload = %OutboundPayload{
      channel_id: BlockingPlugin.id(),
      kind: :text,
      content: content,
      account_id: account_id,
      peer: %{kind: :dm, id: "user-1", thread_id: nil},
      meta: %{test_pid: self()}
    }

    {:ok, _ref} = Outbox.enqueue(payload)

    outbox_pid = Process.whereis(Outbox)

    for chunk_index <- 0..(chunk_count - 1) do
      # Try to nudge the outbox into processing; only one chunk should start at a time for this group.
      send(outbox_pid, :process_queue)
      send(outbox_pid, :process_queue)
      send(outbox_pid, :process_queue)

      assert_receive {:deliver_started, pid, ^chunk_index}, 500

      # Ensure we don't start the next chunk for this delivery group until the
      # current chunk is released (prevents reordering).
      if chunk_index + 1 < chunk_count do
        next_index = chunk_index + 1
        refute_receive {:deliver_started, _pid2, ^next_index}, 100
      end

      send(pid, :release)
      assert_receive {:delivered, ^chunk_index}, 500
    end

    eventually(fn ->
      stats2 = Outbox.stats()
      assert stats2.processing_count <= baseline_processing
    end)
  end

  test "processing_count tracks multiple in-flight deliveries across independent delivery groups" do
    Registry.register(BlockingPlugin)
    on_exit(fn -> Registry.unregister(BlockingPlugin.id()) end)

    baseline_processing = Outbox.stats().processing_count

    outbox_pid = Process.whereis(Outbox)
    account_id = "acct-#{System.unique_integer([:positive])}"

    payloads =
      for i <- 1..3 do
        %OutboundPayload{
          channel_id: BlockingPlugin.id(),
          kind: :text,
          content: "hello #{i}",
          account_id: account_id,
          peer: %{kind: :dm, id: "user-#{i}", thread_id: nil},
          meta: %{test_pid: self()}
        }
      end

    Enum.each(payloads, fn p ->
      {:ok, _ref} = Outbox.enqueue(p)
    end)

    # Start all three groups
    send(outbox_pid, :process_queue)
    send(outbox_pid, :process_queue)
    send(outbox_pid, :process_queue)

    workers =
      for _ <- 1..3 do
        assert_receive {:deliver_started, pid, _chunk_index}, 500
        pid
      end

    Enum.each(workers, fn pid -> send(pid, :release) end)

    for _ <- 1..3 do
      assert_receive {:delivered, _chunk_index}, 500
    end

    eventually(fn ->
      stats2 = Outbox.stats()
      assert stats2.processing_count <= baseline_processing
    end)
  end

  test "a crashing delivery worker does not wedge processing bookkeeping (supervised task + crash handling)" do
    Registry.register(CrashPlugin)
    on_exit(fn -> Registry.unregister(CrashPlugin.id()) end)

    baseline_processing = Outbox.stats().processing_count
    notify_ref = make_ref()

    payload = %OutboundPayload{
      channel_id: CrashPlugin.id(),
      kind: :text,
      content: "boom",
      account_id: "acct-#{System.unique_integer([:positive])}",
      peer: %{kind: :dm, id: "user-1", thread_id: nil},
      notify_pid: self(),
      notify_ref: notify_ref,
      meta: %{notify_tag: :outbox_arch_crash}
    }

    {:ok, _ref} = Outbox.enqueue(payload)

    outbox_pid = Process.whereis(Outbox)
    send(outbox_pid, :process_queue)

    # We should receive a failure notification (from the supervised task DOWN handler).
    assert_receive {:outbox_arch_crash, ^notify_ref, {:error, {:worker_exit, _reason}}}, 1000

    eventually(fn ->
      stats = Outbox.stats()
      assert stats.processing_count <= baseline_processing
    end)
  end
end
