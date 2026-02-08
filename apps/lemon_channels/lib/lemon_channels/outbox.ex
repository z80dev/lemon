defmodule LemonChannels.Outbox do
  @moduledoc """
  Outbox for queuing and delivering outbound messages.

  The outbox provides:
  - Queued delivery with retry
  - Idempotency checking
  - Rate limiting
  - Automatic chunking for long messages
  - Telemetry emission
  """

  use GenServer

  require Logger

  alias LemonChannels.{OutboundPayload, Registry}
  alias LemonChannels.Outbox.{Chunker, Dedupe, RateLimiter}

  @worker_supervisor LemonChannels.Outbox.WorkerSupervisor

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Enqueue a payload for delivery.

  If the content exceeds the channel's chunk limit, it will be automatically
  split into multiple messages.

  Returns `{:ok, ref}` or `{:error, reason}`.
  """
  @spec enqueue(OutboundPayload.t()) :: {:ok, reference()} | {:error, term()}
  def enqueue(%OutboundPayload{} = payload) do
    GenServer.call(__MODULE__, {:enqueue, payload})
  end

  @doc """
  Returns current outbox statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @impl true
  def init(_opts) do
    # The Outbox is sometimes started standalone in tests. Ensure the task supervisor
    # exists so we can safely run supervised delivery tasks.
    _ = ensure_worker_supervisor_started()

    {:ok, %{queue: :queue.new(), processing: %{}, processing_groups: %{}, enqueued_total: 0}}
  end

  @impl true
  def handle_call({:enqueue, payload}, _from, state) do
    # Check idempotency
    case check_idempotency(payload) do
      :duplicate ->
        {:reply, {:error, :duplicate}, state}

      :ok ->
        ref = make_ref()

        # Apply chunking if needed
        payloads = maybe_chunk_payload(payload)

        # Check rate limit
        case RateLimiter.check(payload.channel_id, payload.account_id) do
          :ok ->
            # Enqueue all chunks for processing
            state = enqueue_payloads(state, ref, payloads)

            # Trigger processing
            send(self(), :process_queue)

            {:reply, {:ok, ref}, state}

          {:rate_limited, wait_ms} ->
            # Still enqueue but will be delayed
            state = enqueue_payloads(state, ref, payloads)

            # Schedule processing after rate limit delay
            Process.send_after(self(), :process_queue, wait_ms)

            {:reply, {:ok, ref}, state}
        end
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      queue_length: :queue.len(state.queue),
      processing_count: map_size(state.processing),
      enqueued_total: state.enqueued_total
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:process_queue, state) do
    # Preserve delivery ordering per "delivery group" (channel/account/peer/thread),
    # while still allowing concurrency across independent groups.
    #
    # Chunked messages share the same delivery group and must not be delivered
    # concurrently, otherwise chunks can reorder on the wire.
    {:noreply, process_available(state)}
  end

  # Task.Supervisor.async_nolink/2 sends `{ref, result}` on success, and `{:DOWN, ref, ...}`
  # on failure. We key `processing` by the task monitor ref for correct per-chunk bookkeeping.
  def handle_info({task_ref, result}, state) when is_reference(task_ref) do
    case Map.pop(state.processing, task_ref) do
      {nil, _} ->
        {:noreply, state}

      {entry, processing} ->
        # Flush a pending DOWN for this task ref if it already arrived.
        Process.demonitor(task_ref, [:flush])
        state = %{state | processing: processing}
        state = release_processing_group(state, entry, task_ref)

        maybe_notify_delivery(entry.payload, result)

        case result do
          {:ok, _delivery_ref} ->
            # Mark as delivered for idempotency
            mark_delivered(entry.payload)

            # Continue processing queue
            send(self(), :process_queue)
            {:noreply, state}

          {:error, reason} ->
            # Retry only for retryable failures.
            #
            # `:unknown_channel` is a configuration/programming error and will never succeed by retrying.
            if retryable_reason?(reason) and entry.attempts < 3 do
              entry = %{entry | attempts: entry.attempts + 1}
              queue = :queue.in(entry, state.queue)
              Process.send_after(self(), :process_queue, retry_delay(entry.attempts))
              {:noreply, %{state | queue: queue}}
            else
              Logger.warning(
                "Delivery failed after #{entry.attempts} attempts: #{inspect(reason)}"
              )

              # Continue processing queue even after failure
              send(self(), :process_queue)
              {:noreply, state}
            end
        end
    end
  end

  def handle_info({:DOWN, task_ref, :process, _worker_pid, reason}, state)
      when is_reference(task_ref) do
    case Map.pop(state.processing, task_ref) do
      {nil, _processing} ->
        {:noreply, state}

      {entry, processing} ->
        state = %{state | processing: processing}
        state = release_processing_group(state, entry, task_ref)

        # Treat unexpected worker exits as delivery failures. This is the critical difference
        # from raw spawn/1: we always clean up bookkeeping and keep the queue moving.
        result = {:error, {:worker_exit, reason}}

        maybe_notify_delivery(entry.payload, result)

        if retryable_reason?(reason) and entry.attempts < 3 do
          entry = %{entry | attempts: entry.attempts + 1}
          queue = :queue.in(entry, state.queue)
          Process.send_after(self(), :process_queue, retry_delay(entry.attempts))
          {:noreply, %{state | queue: queue}}
        else
          Logger.warning(
            "Delivery worker exited after #{entry.attempts} attempts: #{inspect(reason)}"
          )

          send(self(), :process_queue)
          {:noreply, state}
        end
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp maybe_notify_delivery(%OutboundPayload{notify_pid: pid, notify_ref: ref} = payload, result)
       when is_pid(pid) and is_reference(ref) do
    tag = get_in(payload.meta || %{}, [:notify_tag]) || :outbox_delivered

    try do
      send(pid, {tag, ref, result})
    rescue
      _ -> :ok
    end

    :ok
  end

  defp maybe_notify_delivery(_payload, _result), do: :ok

  # Chunk a payload if its content exceeds the channel's chunk limit
  defp maybe_chunk_payload(%OutboundPayload{content: content, channel_id: channel_id} = payload)
       when is_binary(content) do
    chunk_size = Chunker.chunk_size_for(channel_id)

    if String.length(content) <= chunk_size do
      [payload]
    else
      # Split into chunks
      chunks = Chunker.chunk(content, chunk_size: chunk_size)

      # Create a payload for each chunk
      chunks
      |> Enum.with_index()
      |> Enum.map(fn {chunk_content, index} ->
        chunk_payload = %OutboundPayload{
          payload
          | content: chunk_content,
            # Only use idempotency key for first chunk
            idempotency_key: if(index == 0, do: payload.idempotency_key, else: nil),
            # Add chunk metadata
            meta:
              Map.merge(payload.meta || %{}, %{
                chunk_index: index,
                chunk_count: length(chunks),
                is_continuation: index > 0
              })
        }

        # For continuation chunks, remove reply_to to avoid threading issues
        if index > 0 do
          %{chunk_payload | reply_to: nil}
        else
          chunk_payload
        end
      end)
    end
  end

  defp maybe_chunk_payload(payload) do
    # Non-text content or already processed
    [payload]
  end

  defp enqueue_payloads(state, ref, payloads) do
    state =
      Enum.reduce(payloads, state, fn payload, acc ->
        entry = %{
          ref: ref,
          payload: payload,
          attempts: 0,
          chunk_index: get_in(payload.meta || %{}, [:chunk_index]) || 0,
          group_key: delivery_group_key(payload)
        }

        queue = :queue.in(entry, acc.queue)
        %{acc | queue: queue}
      end)

    %{state | enqueued_total: state.enqueued_total + length(payloads)}
  end

  defp process_available(state) do
    {state, min_wait_ms} = do_process_available(state, nil)

    if is_integer(min_wait_ms) do
      Process.send_after(self(), :process_queue, min_wait_ms)
    end

    state
  end

  defp do_process_available(state, min_wait_ms) do
    case dequeue_next_available(state.queue, state.processing_groups) do
      :none ->
        {state, min_wait_ms}

      {entry, queue} ->
        case RateLimiter.consume(entry.payload.channel_id, entry.payload.account_id) do
          :ok ->
            case start_delivery_task(entry) do
              {:ok, %Task{} = task} ->
                processing = Map.put(state.processing, task.ref, entry)
                processing_groups = Map.put(state.processing_groups, entry.group_key, task.ref)
                state = %{state | queue: queue, processing: processing, processing_groups: processing_groups}
                do_process_available(state, min_wait_ms)

              {:error, reason} ->
                Logger.warning("Failed to start outbox delivery worker: #{inspect(reason)}")
                requeued = :queue.in(entry, queue)
                { %{state | queue: requeued}, min_wait_ms || 50 }
            end

          {:rate_limited, wait_ms} ->
            requeued = :queue.in(entry, queue)
            min_wait_ms = if is_integer(min_wait_ms), do: min(min_wait_ms, wait_ms), else: wait_ms
            do_process_available(%{state | queue: requeued}, min_wait_ms)
        end
    end
  end

  defp dequeue_next_available(queue, processing_groups) do
    len = :queue.len(queue)
    do_dequeue_next_available(queue, processing_groups, len)
  end

  defp do_dequeue_next_available(_queue, _processing_groups, 0), do: :none

  defp do_dequeue_next_available(queue, processing_groups, remaining) do
    case :queue.out(queue) do
      {:empty, _} ->
        :none

      {{:value, entry}, rest} ->
        if Map.has_key?(processing_groups, entry.group_key) do
          # Group is currently in-flight; rotate to preserve per-group ordering.
          do_dequeue_next_available(:queue.in(entry, rest), processing_groups, remaining - 1)
        else
          {entry, rest}
        end
    end
  end

  defp release_processing_group(state, entry, task_ref) do
    group_key = entry.group_key

    processing_groups =
      case Map.get(state.processing_groups, group_key) do
        ^task_ref -> Map.delete(state.processing_groups, group_key)
        _ -> state.processing_groups
      end

    %{state | processing_groups: processing_groups}
  end

  defp delivery_group_key(%OutboundPayload{} = payload) do
    peer = payload.peer || %{}
    {payload.channel_id, payload.account_id, Map.get(peer, :kind), Map.get(peer, :id), Map.get(peer, :thread_id)}
  end

  defp start_delivery_task(entry) do
    _ = ensure_worker_supervisor_started()

    payload = entry.payload

    try do
      {:ok, Task.Supervisor.async_nolink(@worker_supervisor, fn -> do_deliver(payload) end)}
    catch
      :exit, reason -> {:error, reason}
    end
  end

  defp ensure_worker_supervisor_started do
    case Process.whereis(@worker_supervisor) do
      nil ->
        case Task.Supervisor.start_link(name: @worker_supervisor) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, _} = err -> err
        end

      _pid ->
        :ok
    end
  end

  defp do_deliver(payload) do
    start_time = System.monotonic_time()

    meta = %{
      channel_id: payload.channel_id,
      account_id: payload.account_id,
      chunk_index: get_in(payload.meta || %{}, [:chunk_index])
    }

    # Emit telemetry start
    LemonCore.Telemetry.emit(
      [:lemon, :channels, :deliver, :start],
      %{system_time: System.system_time()},
      meta
    )

    result =
      case Registry.get_plugin(payload.channel_id) do
        nil ->
          {:error, :unknown_channel}

        plugin ->
          try do
            plugin.deliver(payload)
          rescue
            e ->
              # Emit telemetry exception
              LemonCore.Telemetry.emit(
                [:lemon, :channels, :deliver, :exception],
                %{duration: System.monotonic_time() - start_time},
                Map.merge(meta, %{
                  kind: :exception,
                  reason: Exception.message(e),
                  stacktrace: __STACKTRACE__
                })
              )

              {:error, {:exception, e}}
          end
      end

    # Emit telemetry stop
    duration = System.monotonic_time() - start_time

    LemonCore.Telemetry.emit(
      [:lemon, :channels, :deliver, :stop],
      %{duration: duration},
      Map.merge(meta, %{ok: match?({:ok, _}, result)})
    )

    result
  end

  defp check_idempotency(%{idempotency_key: nil}), do: :ok

  defp check_idempotency(%{idempotency_key: key, channel_id: channel_id}) do
    case Dedupe.check(channel_id, key) do
      :new -> :ok
      :duplicate -> :duplicate
    end
  end

  defp mark_delivered(%{idempotency_key: nil}), do: :ok

  defp mark_delivered(%{idempotency_key: key, channel_id: channel_id}) do
    Dedupe.mark(channel_id, key)
  end

  defp retry_delay(attempt) do
    # Exponential backoff: 1s, 2s, 4s
    :math.pow(2, attempt - 1) |> round() |> Kernel.*(1000)
  end

  defp retryable_reason?(:unknown_channel), do: false
  defp retryable_reason?(:normal), do: true
  defp retryable_reason?(:shutdown), do: true
  defp retryable_reason?(_reason), do: true
end
