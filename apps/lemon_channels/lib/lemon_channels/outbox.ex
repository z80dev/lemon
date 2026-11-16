defmodule LemonChannels.Outbox do
  @moduledoc """
  Outbox for queuing and delivering outbound messages.

  The outbox provides:
  - Queued delivery with retry
  - Idempotency checking
  - Rate limiting
  - Automatic chunking for long messages
  - Telemetry emission

  Enqueue acknowledges only after pending records cross the Store durability
  barrier. Restart reloads their FIFO sequence and original idempotency keys.
  Pending content expires after the caller policy `retention_ms` (24 hours by
  default); confirmed keys retain the existing one-hour TTL, bounded by
  `max_dedupe_entries` (5,000). Production crash recovery requires a persistent
  Store backend; the ETS backend is intentionally ephemeral.

  The queue owner never synchronously calls the limiter, dedupe, registry or
  Store during admission. Store writes/barriers run in one linked, monitored
  task; a failed barrier reports unknown admission and retries only that same
  idempotent storage operation. Deliveries use a Task.Supervisor whose
  `max_children` is the caller policy `max_concurrency` (default 32).

  Named instances accept `:name`, `:store` and `:worker_supervisor` in
  `start_link/1`; `enqueue/2` and `stats/1` address them without changing the
  default instance. Startup limit options override the application defaults.

  ## Duplicate-delivery policy: at-least-once, bounded

  Delivery is at-least-once for the channels whose adapters report an unknown outcome. A delivery whose outcome is
  unknown (an adapter `{:outcome_unknown, _}` result, an adapter exception or a
  worker exit: the platform may have accepted the write) is retried with the
  same payload, and therefore the same idempotency key, instead of being
  dropped. A duplicate message is preferred over a silently lost one. This
  deliberately exempts outbox message delivery from the repository rule that an
  `:outcome_unknown` mutation is never automatically retried. The shapes the
  outbox treats as unknown live in `LemonChannels.DeliveryError.outcome_unknown?/1`.
  SMTP reports a lost connection once DATA was issued, and the WhatsApp bridge
  reports an exception thrown by its send call, as unknown.

  Retries are bounded by `max_attempts` (default 3 retries), one budget shared
  by all retryable failures, with exponential backoff. When the budget is spent
  the last failure is reported to the notifier as terminal. Dedupe is marked only
  on confirmed delivery, so a confirmed send is never re-sent: a repeated
  enqueue with the same idempotency key, and a pending retry whose key was
  confirmed meanwhile, are suppressed with `{:error, :duplicate}`. Unrecognized
  errors and definite rejections are never retried.

  Voice transcript delivery reports every terminal physical chunk to
  `VoiceReplyDelivery`, independently of presentation notifications. Receipt
  tokens are `{enqueue_ref, chunk_index}` and remain unchanged across retries.
  Confirmed duplicates count as transcript success. Voice transcript chunks
  retain separate stable dedupe keys so a confirmed head never confirms a
  failed tail, and queued transcript edits are not superseded.
  """

  use GenServer

  require Logger

  alias LemonChannels.{OutboundPayload, Registry}
  alias LemonChannels.Outbox.{Chunker, Dedupe, QueueStore, RateLimiter}

  @worker_supervisor LemonChannels.Outbox.WorkerSupervisor
  @default_max_attempts 3
  @default_max_queue_size 5_000
  @default_max_concurrency 32
  @default_retention_ms 24 * 60 * 60 * 1000
  @default_max_dedupe_entries 5_000
  @cleanup_interval_ms 60_000
  @call_timeout_ms 5_000

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Enqueue a payload for delivery.

  If the content exceeds the channel's chunk limit, it will be automatically
  split into multiple messages.

  Returns `{:ok, ref}` or `{:error, reason}`.

  A call timeout returns `{:error, {:outcome_unknown, :enqueue_timeout}}`:
  admission may still complete. Callers must not resend automatically; retries
  of an admitted delivery are owned by the outbox itself (see above).
  """
  @spec enqueue(GenServer.server(), OutboundPayload.t()) :: {:ok, reference()} | {:error, term()}
  def enqueue(server \\ __MODULE__, %OutboundPayload{} = payload) do
    request = :gen_server.send_request(server, {:enqueue, payload})

    case :gen_server.receive_response(request, @call_timeout_ms) do
      {:reply, result} ->
        result

      {:error, {:noproc, _server}} ->
        {:error, :channels_outbox_unavailable}

      {:error, {_reason, _server}} ->
        {:error, {:outcome_unknown, :enqueue_interrupted}}

      :timeout ->
        Logger.warning("Outbox enqueue acknowledgement timed out; admission is unknown")
        {:error, {:outcome_unknown, :enqueue_timeout}}
    end
  catch
    :exit, {:noproc, _} -> {:error, :channels_outbox_unavailable}
    :exit, _reason -> {:error, {:outcome_unknown, :enqueue_interrupted}}
  end

  @doc """
  Returns current outbox statistics.
  """
  @spec stats(GenServer.server()) :: map()
  def stats(server \\ __MODULE__) do
    GenServer.call(server, :stats)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    :ok = ensure_worker_supervisor_started(opts)
    store = Keyword.get(opts, :store, LemonCore.Store)
    receipt_limit = positive_option(:max_dedupe_entries, @default_max_dedupe_entries, opts)

    case QueueStore.load(store, receipt_limit) do
      {:ok, entries, receipts, sequence} ->
        send(self(), :process_queue)
        Process.send_after(self(), :prune, @cleanup_interval_ms)

        {:ok,
         %{
           queue: :queue.from_list(entries),
           processing: %{},
           processing_groups: %{},
           enqueued_total: 0,
           max_queue_size: max_queue_size(opts),
           max_concurrency: max_concurrency(opts),
           retention_ms: positive_option(:retention_ms, @default_retention_ms, opts),
           worker_supervisor: Keyword.get(opts, :worker_supervisor, @worker_supervisor),
           max_attempts:
             if(Keyword.has_key?(opts, :max_attempts), do: max_attempts(opts), else: nil),
           store: store,
           sequence: sequence,
           pending_count: 0,
           storage_queue: :queue.new(),
           storage_current: nil,
           storage_task: nil,
           receipts: receipts,
           receipt_limit: receipt_limit
         }}

      _ ->
        {:stop, :outbox_store_unavailable}
    end
  end

  @impl true
  def handle_call({:enqueue, payload}, from, state) do
    # Check idempotency
    case check_enqueue_idempotency(payload) do
      :duplicate ->
        ref = make_ref()

        payload
        |> maybe_chunk_payload()
        |> Enum.with_index()
        |> Enum.each(fn {chunk, index} ->
          token = {chunk.idempotency_key || ref, index}
          LemonChannels.VoiceReplyDelivery.receipt(chunk, {:ok, :duplicate}, token)
        end)

        {:reply, {:error, :duplicate}, state}

      :ok ->
        ref = make_ref()

        # Apply chunking if needed
        payloads = maybe_chunk_payload(payload)
        chunk_count = length(payloads)

        if queue_full?(state, chunk_count) do
          queue_depth = queue_depth(state)

          LemonCore.Telemetry.emit(
            [:lemon, :channels, :outbox, :rejected],
            %{count: 1, queue_depth: queue_depth, max_queue_size: state.max_queue_size},
            %{
              reason: :queue_full,
              channel_id: payload.channel_id,
              account_id: payload.account_id,
              chunk_count: chunk_count
            }
          )

          {:reply, {:error, :queue_full}, state}
        else
          {entries, sequence} = build_entries(state, ref, payloads)
          {queue, superseded} = remove_superseded(state.queue, entries)

          operation = %{
            action: {:admit, from, ref, entries},
            puts: Enum.map(entries, &QueueStore.pending_put/1),
            deletes: Enum.map(superseded, &QueueStore.pending_delete/1)
          }

          state = %{
            state
            | queue: queue,
              sequence: sequence,
              pending_count: state.pending_count + chunk_count
          }

          {:noreply, queue_storage(state, operation)}
        end
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      queue_length: :queue.len(state.queue),
      processing_count: map_size(state.processing),
      queue_depth: queue_depth(state),
      max_queue_size: state.max_queue_size,
      enqueued_total: state.enqueued_total,
      pending_count: state.pending_count,
      max_concurrency: state.max_concurrency
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

  def handle_info({ref, result}, %{storage_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_storage(%{state | storage_task: nil}, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{storage_task: %Task{ref: ref}} = state) do
    {:noreply, finish_storage(%{state | storage_task: nil}, {:error, :outbox_persistence_failed})}
  end

  def handle_info(:retry_storage, state) do
    {:noreply, start_storage(state)}
  end

  def handle_info(:prune, state) do
    Process.send_after(self(), :prune, @cleanup_interval_ms)
    now = System.system_time(:millisecond)

    {expired, receipts} =
      state.receipts
      |> :queue.to_list()
      |> Enum.split_with(fn {_id, receipt} -> receipt.expires_at_ms < now end)

    operation = %{
      action: :prune,
      puts: [],
      deletes: Enum.map(expired, &QueueStore.receipt_delete/1)
    }

    state = %{state | receipts: :queue.from_list(receipts)}
    state = if expired == [], do: state, else: queue_storage(state, operation)
    send(self(), :process_queue)
    {:noreply, state}
  end

  # Task.Supervisor.async_nolink/2 sends `{ref, result}` on success, and `{:DOWN, ref, ...}`
  # on failure. We key `processing` by the task monitor ref for correct per-chunk bookkeeping.
  def handle_info({task_ref, result}, state) when is_reference(task_ref) do
    case Map.get(state.processing, task_ref) do
      nil ->
        {:noreply, state}

      entry ->
        Process.demonitor(task_ref, [:flush])

        case result do
          {:ok, _delivery_ref} ->
            receipt = QueueStore.receipt(entry)
            receipts = :queue.in(receipt, state.receipts)
            {evicted, receipts} = trim_receipts(receipts, state.receipt_limit)

            operation = %{
              action: {:complete, task_ref, entry, result},
              puts: [QueueStore.receipt_put(receipt)],
              deletes: [
                QueueStore.pending_delete(entry) | Enum.map(evicted, &QueueStore.receipt_delete/1)
              ]
            }

            {:noreply, queue_storage(%{state | receipts: receipts}, operation)}

          {:error, {:delivery_not_started, _reason}} ->
            state = finish_processing(state, task_ref, entry)
            entry = %{entry | available_at_ms: System.system_time(:millisecond) + 50}
            Process.send_after(self(), :process_queue, 50)
            {:noreply, %{state | queue: insert_ordered(state.queue, entry)}}

          {:error, reason} ->
            reason = LemonChannels.DeliveryError.classify(reason)
            {:noreply, handle_delivery_failure(state, task_ref, entry, reason)}
        end
    end
  end

  def handle_info({:DOWN, task_ref, :process, _worker_pid, reason}, state)
      when is_reference(task_ref) do
    case Map.get(state.processing, task_ref) do
      nil ->
        {:noreply, state}

      entry ->
        # The platform may have accepted the write before the worker died.
        {:noreply, handle_delivery_failure(state, task_ref, entry, {:worker_exit, reason})}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.storage_task, do: Process.exit(state.storage_task.pid, :shutdown)

    Enum.each(state.processing, fn {_ref, entry} ->
      if pid = Map.get(entry, :worker_pid), do: Process.exit(pid, :shutdown)
    end)

    :ok
  end

  # Retryable failures are requeued while the shared `max_attempts` budget
  # lasts; the retried entry keeps its payload and therefore its idempotency key.
  # Anything else, or an exhausted budget, is reported as a terminal failure.
  # `:unknown_channel` is a configuration/programming error and will never
  # succeed by retrying.
  defp handle_delivery_failure(state, task_ref, entry, reason) do
    if retryable_reason?(reason) and entry.attempts < (state.max_attempts || max_attempts()) do
      {entry, delay_ms} = schedule_retry(entry, reason)
      Logger.warning("Outbox delivery retry scheduled; attempt=#{entry.attempts}")

      queue_storage(state, %{
        action: {:retry, task_ref, entry, delay_ms},
        puts: [QueueStore.pending_put(entry)],
        deletes: []
      })
    else
      Logger.warning("Outbox delivery failed; retries=#{entry.attempts}")

      queue_storage(state, %{
        action: {:complete, task_ref, entry, {:error, finalize_failure_reason(reason)}},
        puts: [],
        deletes: [QueueStore.pending_delete(entry)]
      })
    end
  end

  # Voice confirmation observes every physical chunk, including continuations
  # without presentation notification refs. Retry attempts retain this token.
  defp notify_delivery(entry, result) do
    receipt_result = if result == {:error, :duplicate}, do: {:ok, :duplicate}, else: result

    LemonChannels.VoiceReplyDelivery.receipt(
      entry.payload,
      receipt_result,
      {entry.payload.idempotency_key || entry.ref, entry.chunk_index}
    )

    maybe_notify_delivery(entry.payload, result)
  end

  defp maybe_notify_delivery(%OutboundPayload{notify_pid: pid, notify_ref: ref} = payload, result)
       when is_pid(pid) and is_reference(ref) do
    tag = get_in(payload.meta || %{}, [:notify_tag]) || :outbox_delivered

    send(pid, {tag, ref, result})

    :ok
  end

  defp maybe_notify_delivery(_payload, _result), do: :ok

  defp outbox_failure_meta(entry) do
    %{kind: entry.payload.kind, attempts: entry.attempts}
  end

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
        # Only the first chunk carries the notify ref so PresentationState
        # receives exactly one delivery notification per logical message.
        # Subsequent chunks are follow-ups whose message_ids aren't tracked
        # for edits.
        {notify_pid, notify_ref} =
          if index == 0 do
            {payload.notify_pid, payload.notify_ref}
          else
            {nil, nil}
          end

        chunk_payload = %OutboundPayload{
          payload
          | content: chunk_content,
            # Voice transcript continuations need independent confirmation.
            idempotency_key: chunk_idempotency_key(payload, index),
            # Only first chunk notifies PresentationState
            notify_pid: notify_pid,
            notify_ref: notify_ref,
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

  defp build_entries(state, ref, payloads) do
    now = System.system_time(:millisecond)

    Enum.map_reduce(payloads, state.sequence, fn payload, sequence ->
      id = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

      payload =
        if payload.channel_id == "discord",
          do: %{payload | meta: Map.put(payload.meta || %{}, :delivery_id, make_ref())},
          else: payload

      entry = %{
        durable_id: id,
        sequence: sequence + 1,
        expires_at_ms: now + state.retention_ms,
        ref: ref,
        payload: payload,
        attempts: 0,
        available_at_ms: nil,
        chunk_index: get_in(payload.meta || %{}, [:chunk_index]) || 0,
        group_key: delivery_group_key(payload)
      }

      {entry, sequence + 1}
    end)
  end

  defp remove_superseded(queue, entries) do
    edits = Enum.filter(entries, &(&1.payload.kind == :edit))
    remove_superseded_edits(queue, edits)
  end

  defp remove_superseded_edits(queue, []), do: {queue, []}

  defp remove_superseded_edits(queue, entries) do
    {superseded, kept} =
      queue
      |> :queue.to_list()
      |> Enum.split_with(fn queued ->
        Enum.any?(entries, fn entry ->
          not is_nil(edit_target_message_id(entry.payload)) and
            queued.group_key == entry.group_key and queued.payload.kind == :edit and
            not voice_transcript?(queued.payload) and
            edit_target_message_id(queued.payload) == edit_target_message_id(entry.payload)
        end)
      end)

    {:queue.from_list(kept), superseded}
  end

  defp insert_ordered(queue, entry) do
    case :queue.peek_r(queue) do
      :empty ->
        :queue.in(entry, queue)

      {:value, last} when last.sequence <= entry.sequence ->
        :queue.in(entry, queue)

      _ ->
        {before, after_entries} =
          queue |> :queue.to_list() |> Enum.split_while(&(&1.sequence <= entry.sequence))

        :queue.from_list(before ++ [entry | after_entries])
    end
  end

  defp process_available(state) do
    {state, min_wait_ms} = do_process_available(state, nil)

    if is_integer(min_wait_ms) do
      Process.send_after(self(), :process_queue, min_wait_ms)
    end

    state
  end

  defp do_process_available(state, min_wait_ms)
       when map_size(state.processing) >= state.max_concurrency,
       do: {state, min_wait_ms}

  defp do_process_available(state, min_wait_ms) do
    case dequeue_next_available(state.queue, state.processing_groups) do
      {:none, queue, wait_ms} ->
        {%{state | queue: queue}, min_wait(min_wait_ms, wait_ms)}

      {:ready, entry, queue, wait_ms} ->
        min_wait_ms = min_wait(min_wait_ms, wait_ms)

        cond do
          retry_already_confirmed?(entry) ->
            suppress_confirmed_retry(entry)
            state = stage_removal(state, entry, queue, {:error, :duplicate})
            do_process_available(state, min_wait_ms)

          Map.get(entry, :expires_at_ms, :infinity) <= System.system_time(:millisecond) ->
            state = stage_removal(state, entry, queue, {:error, :expired})
            do_process_available(state, min_wait_ms)

          Map.get(entry, :recovered, false) and
              is_nil(Registry.get_plugin(entry.payload.channel_id)) ->
            entry = %{entry | available_at_ms: System.system_time(:millisecond) + 1_000}
            state = %{state | queue: insert_ordered(queue, entry)}
            do_process_available(state, min_wait(min_wait_ms, 1_000))

          true ->
            dispatch_entry(state, entry, queue, min_wait_ms)
        end
    end
  end

  defp dispatch_entry(state, entry, queue, min_wait_ms) do
    case RateLimiter.consume(entry.payload.channel_id, entry.payload.account_id) do
      :ok ->
        task = start_delivery_task(entry, state.worker_supervisor)
        entry = Map.put(entry, :worker_pid, task.pid)
        processing = Map.put(state.processing, task.ref, entry)
        processing_groups = Map.put(state.processing_groups, entry.group_key, task.ref)

        state = %{
          state
          | queue: queue,
            processing: processing,
            processing_groups: processing_groups
        }

        do_process_available(state, min_wait_ms)

      {:rate_limited, wait_ms} ->
        entry = %{entry | available_at_ms: System.system_time(:millisecond) + wait_ms}
        requeued = insert_ordered(queue, entry)
        min_wait_ms = min_wait(min_wait_ms, wait_ms)
        do_process_available(%{state | queue: requeued}, min_wait_ms)
    end
  end

  # Also covers a crash between persisting a confirmed receipt and deleting its
  # pending record. No recovered confirmed key reaches the adapter again.
  defp retry_already_confirmed?(entry) do
    Dedupe.check(entry.payload.channel_id, QueueStore.delivery_key(entry)) == :duplicate
  end

  defp suppress_confirmed_retry(entry) do
    Logger.info(
      "Suppressed delivery retry: idempotency key already confirmed delivered " <>
        "meta=#{inspect(outbox_failure_meta(entry))}"
    )
  end

  defp dequeue_next_available(queue, processing_groups) do
    scan_available(
      :queue.to_list(queue),
      [],
      MapSet.new(Map.keys(processing_groups)),
      System.system_time(:millisecond),
      nil
    )
  end

  defp scan_available([], skipped, _blocked, _now, wait_ms),
    do: {:none, :queue.from_list(Enum.reverse(skipped)), wait_ms}

  defp scan_available([entry | rest], skipped, blocked, now, wait_ms) do
    entry_wait =
      if Map.get(entry, :expires_at_ms, :infinity) <= now, do: 0, else: entry_wait_ms(entry, now)

    if MapSet.member?(blocked, entry.group_key) or entry_wait > 0 do
      wait_ms = if entry_wait > 0, do: min_wait(wait_ms, entry_wait), else: wait_ms
      scan_available(rest, [entry | skipped], MapSet.put(blocked, entry.group_key), now, wait_ms)
    else
      {:ready, entry, :queue.from_list(Enum.reverse(skipped, rest)), wait_ms}
    end
  end

  defp stage_removal(state, entry, queue, result) do
    ref = make_ref()

    state = %{
      state
      | queue: queue,
        processing: Map.put(state.processing, ref, entry),
        processing_groups: Map.put(state.processing_groups, entry.group_key, ref)
    }

    queue_storage(state, %{
      action: {:complete, ref, entry, result},
      puts: [],
      deletes: [QueueStore.pending_delete(entry)]
    })
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

    base =
      {payload.channel_id, payload.account_id, Map.get(peer, :kind), Map.get(peer, :id),
       Map.get(peer, :thread_id)}

    case payload.kind do
      :edit -> {base, :edit, edit_target_message_id(payload)}
      :delete -> {base, :delete, edit_target_message_id(payload)}
      _ -> base
    end
  end

  defp edit_target_message_id(%OutboundPayload{kind: :edit, content: %{message_id: id}})
       when not is_nil(id),
       do: to_string(id)

  defp edit_target_message_id(%OutboundPayload{kind: :edit, content: %{"message_id" => id}})
       when not is_nil(id),
       do: to_string(id)

  defp edit_target_message_id(_payload), do: nil

  defp start_delivery_task(entry, worker_supervisor) do
    payload = entry.payload

    # Task.Supervisor admission is synchronous by design. A linked launcher
    # keeps that call off the queue owner; both launcher and delivery die with
    # the owner, while adapter failures cannot take the owner down.
    Task.async(fn ->
      launcher = self()

      try do
        case LemonCore.TaskSupervisor.async_nolink(worker_supervisor, fn ->
               Process.link(launcher)
               do_deliver(payload)
             end) do
          {:ok, task} -> Task.await(task, :infinity)
          {:error, reason} -> {:error, {:delivery_not_started, reason}}
        end
      catch
        :exit, _ -> {:error, {:outcome_unknown, :worker_exit}}
      end
    end)
  end

  defp ensure_worker_supervisor_started(opts) do
    worker_supervisor = Keyword.get(opts, :worker_supervisor, @worker_supervisor)

    case Process.whereis(worker_supervisor) do
      nil ->
        %{start: {module, function, args}} =
          LemonCore.TaskSupervisor.child_spec(worker_supervisor_options(opts))

        case apply(module, function, args) do
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
            # Validate inside the isolated worker. A broken adapter contract must
            # not crash the queue owner and lose unrelated pending deliveries.
            case plugin.deliver(payload) do
              {:ok, _} = result -> result
              {:error, _} = result -> result
            end
          rescue
            error ->
              LemonCore.Telemetry.emit(
                [:lemon, :channels, :deliver, :exception],
                %{duration: System.monotonic_time() - start_time},
                Map.put(meta, :kind, :exception)
              )

              # Do not let Task log arbitrary adapter exception text or frames.
              {:error, {:worker_exit, {error, []}}}
          catch
            :exit, reason -> {:error, {:worker_exit, reason}}
            _kind, _reason -> {:error, {:worker_exit, :adapter_failure}}
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

  defp voice_transcript?(payload) do
    not is_nil(get_in(payload.meta || %{}, [:intent_meta, :voice_reply_id]))
  end

  defp chunk_idempotency_key(payload, 0), do: payload.idempotency_key

  defp chunk_idempotency_key(payload, index) do
    if voice_transcript?(payload) and is_binary(payload.idempotency_key),
      do: "#{payload.idempotency_key}:chunk:#{index}",
      else: nil
  end

  defp check_enqueue_idempotency(payload) do
    if voice_transcript?(payload) do
      if Enum.all?(maybe_chunk_payload(payload), &(check_idempotency(&1) == :duplicate)),
        do: :duplicate,
        else: :ok
    else
      check_idempotency(payload)
    end
  end

  defp check_idempotency(%{idempotency_key: nil}), do: :ok

  defp check_idempotency(%{idempotency_key: key, channel_id: channel_id}) do
    case Dedupe.check(channel_id, key) do
      :new -> :ok
      :duplicate -> :duplicate
    end
  end

  defp mark_delivered(entry) do
    Dedupe.mark(entry.payload.channel_id, QueueStore.delivery_key(entry))
  end

  @doc false
  def worker_supervisor_options(opts \\ []) do
    [
      name: Keyword.get(opts, :worker_supervisor, @worker_supervisor),
      max_children: max_concurrency(opts)
    ]
  end

  defp max_concurrency(opts),
    do: positive_option(:max_concurrency, @default_max_concurrency, opts)

  defp positive_option(key, default, overrides) do
    config = Application.get_env(:lemon_channels, __MODULE__, [])
    config = if is_list(config), do: config, else: []

    case Keyword.get(overrides, key, Keyword.get(config, key, default)) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  defp queue_storage(state, operation) do
    state = %{state | storage_queue: :queue.in(operation, state.storage_queue)}
    if is_nil(state.storage_current), do: start_storage(state), else: state
  end

  defp start_storage(%{storage_task: %Task{}} = state), do: state

  defp start_storage(%{storage_current: nil} = state) do
    case :queue.out(state.storage_queue) do
      {:empty, _} ->
        state

      {{:value, operation}, queue} ->
        start_storage(%{state | storage_current: operation, storage_queue: queue})
    end
  end

  defp start_storage(state) do
    %{store: store, storage_current: operation} = state

    task =
      Task.async(fn ->
        try do
          QueueStore.commit(store, operation.puts, operation.deletes)
        rescue
          _ -> {:error, :outbox_persistence_failed}
        catch
          _kind, _reason -> {:error, :outbox_persistence_failed}
        end
      end)

    %{state | storage_task: task}
  end

  defp finish_storage(state, :ok) do
    operation = state.storage_current
    state = %{state | storage_current: nil}

    state =
      case operation.action do
        {:admit, from, ref, entries} ->
          if from, do: GenServer.reply(from, {:ok, ref})

          queue =
            Enum.reduce(entries, state.queue, fn entry, queue -> insert_ordered(queue, entry) end)

          state = %{
            state
            | queue: queue,
              pending_count: state.pending_count - length(entries),
              enqueued_total: state.enqueued_total + length(entries)
          }

          emit_queue_depth_telemetry(state, :enqueued, %{chunk_count: length(entries)})
          state

        {:retry, ref, entry, delay_ms} ->
          state = finish_processing(state, ref, entry)
          state = %{state | queue: insert_ordered(state.queue, entry)}
          Process.send_after(self(), :process_queue, delay_ms)

          emit_queue_depth_telemetry(state, :retry_scheduled, %{
            delay_ms: delay_ms,
            attempts: entry.attempts,
            channel_id: entry.payload.channel_id
          })

          state

        {:complete, ref, entry, result} ->
          if match?({:ok, _}, result), do: mark_delivered(entry)
          state = finish_processing(state, ref, entry)
          notify_delivery(entry, result)
          state

        :prune ->
          state
      end

    send(self(), :process_queue)
    start_storage(state)
  end

  defp finish_storage(state, _failure) do
    Logger.warning("Outbox persistence failed; retaining bounded pending operation")

    operation =
      case state.storage_current.action do
        {:admit, from, ref, entries} ->
          if from,
            do: GenServer.reply(from, {:error, {:outcome_unknown, :outbox_persistence_failed}})

          %{state.storage_current | action: {:admit, nil, ref, entries}}

        _ ->
          state.storage_current
      end

    Process.send_after(self(), :retry_storage, 1_000)
    %{state | storage_current: operation}
  end

  defp finish_processing(state, ref, entry) do
    state = %{state | processing: Map.delete(state.processing, ref)}
    release_processing_group(state, entry, ref)
  end

  defp trim_receipts(receipts, limit) do
    {evicted, kept} =
      receipts |> :queue.to_list() |> Enum.split(max(:queue.len(receipts) - limit, 0))

    {evicted, :queue.from_list(kept)}
  end

  defp max_attempts(overrides \\ []) do
    case Application.get_env(:lemon_channels, __MODULE__, []) do
      opts when is_list(opts) ->
        case Keyword.get(
               overrides,
               :max_attempts,
               Keyword.get(opts, :max_attempts, @default_max_attempts)
             ) do
          value when is_integer(value) and value >= 0 -> value
          _ -> @default_max_attempts
        end

      _ ->
        @default_max_attempts
    end
  end

  defp max_queue_size(overrides) do
    case Application.get_env(:lemon_channels, __MODULE__, []) do
      opts when is_list(opts) ->
        case Keyword.get(
               overrides,
               :max_queue_size,
               Keyword.get(opts, :max_queue_size, @default_max_queue_size)
             ) do
          :infinity -> :infinity
          value when is_integer(value) and value > 0 -> value
          _ -> @default_max_queue_size
        end

      _ ->
        @default_max_queue_size
    end
  end

  defp schedule_retry(entry, reason) do
    attempt = entry.attempts + 1
    delay_ms = retry_delay(attempt, reason)
    available_at_ms = System.system_time(:millisecond) + delay_ms
    {%{entry | attempts: attempt, available_at_ms: available_at_ms}, delay_ms}
  end

  defp retry_delay(attempt, reason) do
    max(exponential_retry_delay(attempt), retry_after_ms(reason))
  end

  defp exponential_retry_delay(attempt) do
    # Exponential backoff: 1s, 2s, 4s
    LemonCore.Retry.exponential_backoff(1000, max(attempt - 1, 0))
  end

  defp retry_after_ms({:http_error, 429, body}) do
    parse_retry_after_ms(body)
  end

  defp retry_after_ms({:worker_exit, reason}) do
    retry_after_ms(reason)
  end

  defp retry_after_ms(_reason), do: 0

  defp parse_retry_after_ms(body), do: LemonCore.Retry.parse_retry_after(body)

  defp finalize_failure_reason(reason) do
    case retry_after_ms(reason) do
      ms when is_integer(ms) and ms > 0 ->
        {:rate_limited, %{reason: reason, retry_after_ms: ms}}

      _ ->
        reason
    end
  end

  defp entry_wait_ms(%{available_at_ms: nil}, _now_ms), do: 0

  defp entry_wait_ms(%{available_at_ms: available_at_ms}, now_ms)
       when is_integer(available_at_ms) do
    max(available_at_ms - now_ms, 0)
  end

  defp entry_wait_ms(_entry, _now_ms), do: 0

  defp min_wait(nil, nil), do: nil
  defp min_wait(nil, wait_ms), do: wait_ms
  defp min_wait(wait_ms, nil), do: wait_ms
  defp min_wait(wait_a, wait_b), do: min(wait_a, wait_b)

  defp retryable_reason?({:http_error, 429, _body}), do: true
  defp retryable_reason?({:failed_connect, _reason}), do: true
  defp retryable_reason?(:econnrefused), do: true
  defp retryable_reason?(:nxdomain), do: true
  defp retryable_reason?(reason), do: LemonChannels.DeliveryError.outcome_unknown?(reason)

  defp queue_full?(state, incoming_count)
       when is_integer(incoming_count) and incoming_count > 0 do
    case state.max_queue_size do
      :infinity ->
        false

      max when is_integer(max) and max > 0 ->
        queue_depth(state) + incoming_count > max

      _ ->
        false
    end
  end

  defp queue_full?(_state, _incoming_count), do: false

  defp queue_depth(state) do
    :queue.len(state.queue) + map_size(state.processing) + state.pending_count
  end

  defp emit_queue_depth_telemetry(state, event, metadata) do
    LemonCore.Telemetry.emit(
      [:lemon, :channels, :outbox, :queue],
      %{depth: queue_depth(state), max_queue_size: state.max_queue_size, count: 1},
      Map.put(metadata, :event, event)
    )
  end
end
