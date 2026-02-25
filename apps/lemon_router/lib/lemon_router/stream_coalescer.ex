defmodule LemonRouter.StreamCoalescer do
  @moduledoc """
  Coalesces streaming deltas for efficient channel output.

  The coalescer buffers incoming deltas and flushes them to channels
  based on configurable thresholds:

  - `min_chars: 48` - Minimum characters before flushing
  - `idle_ms: 400` - Flush after this idle time
  - `max_latency_ms: 1200` - Maximum time before forced flush

  ## Output

  Produces outbound payloads to channels with:
  - Kind `:edit` if channel supports edits
  - Kind `:text` chunks otherwise

  Channel-specific output strategies are handled by `LemonRouter.ChannelAdapter`.
  """

  use GenServer

  require Logger

  alias LemonRouter.ChannelAdapter
  alias LemonRouter.ChannelContext

  @default_min_chars 48
  @default_idle_ms 400
  @default_max_latency_ms 1200

  defstruct [
    :session_key,
    :channel_id,
    :run_id,
    :buffer,
    :full_text,
    :last_seq,
    :last_flush_ts,
    :first_delta_ts,
    :flush_timer,
    :config,
    :meta,
    :last_sent_text,
    :answer_create_ref,
    :deferred_answer_text,
    :pending_resume_indices,
    :finalized
  ]

  def start_link(opts) do
    session_key = Keyword.fetch!(opts, :session_key)
    channel_id = Keyword.fetch!(opts, :channel_id)
    name = via_tuple(session_key, channel_id)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  defp via_tuple(session_key, channel_id) do
    {:via, Registry, {LemonRouter.CoalescerRegistry, {session_key, channel_id}}}
  end

  @doc """
  Ingest a delta into the coalescer.

  ## Options

  - `:meta` - Optional metadata map, can include `:answer_msg_id` for edit mode
  """
  @spec ingest_delta(
          session_key :: binary(),
          channel_id :: binary(),
          run_id :: binary(),
          seq :: non_neg_integer(),
          text :: binary(),
          opts :: keyword()
        ) :: :ok
  def ingest_delta(session_key, channel_id, run_id, seq, text, opts \\ []) do
    meta = Keyword.get(opts, :meta, %{})

    case get_or_start_coalescer(session_key, channel_id, meta) do
      {:ok, pid} ->
        GenServer.cast(pid, {:delta, run_id, seq, text, meta})

      {:error, reason} ->
        Logger.warning("Failed to start coalescer: #{inspect(reason)}")
    end

    :ok
  end

  @doc """
  Finalize a run for a session/channel.

  Delegates to the channel adapter for finalization strategy.
  """
  @spec finalize_run(
          session_key :: binary(),
          channel_id :: binary(),
          run_id :: binary(),
          opts :: keyword()
        ) :: :ok
  def finalize_run(session_key, channel_id, run_id, opts \\ [])
      when is_binary(session_key) and is_binary(channel_id) and is_binary(run_id) do
    meta = Keyword.get(opts, :meta, %{})
    final_text = Keyword.get(opts, :final_text)

    case get_or_start_coalescer(session_key, channel_id, meta) do
      {:ok, pid} ->
        try do
          GenServer.call(pid, {:finalize, run_id, meta, final_text}, 5_000)
        catch
          :exit, _ -> :ok
        end

      _ ->
        :ok
    end

    :ok
  end

  @doc """
  Force flush the coalescer buffer.
  """
  @spec flush(session_key :: binary(), channel_id :: binary()) :: :ok
  def flush(session_key, channel_id) do
    case Registry.lookup(LemonRouter.CoalescerRegistry, {session_key, channel_id}) do
      [{pid, _}] -> GenServer.cast(pid, :flush)
      _ -> :ok
    end
  end

  defp get_or_start_coalescer(session_key, channel_id, meta) do
    case Registry.lookup(LemonRouter.CoalescerRegistry, {session_key, channel_id}) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        spec = {__MODULE__, session_key: session_key, channel_id: channel_id, meta: meta}

        case DynamicSupervisor.start_child(LemonRouter.CoalescerSupervisor, spec) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          error -> error
        end
    end
  end

  @impl true
  def init(opts) do
    session_key = Keyword.fetch!(opts, :session_key)
    channel_id = Keyword.fetch!(opts, :channel_id)

    config = %{
      min_chars: Keyword.get(opts, :min_chars, @default_min_chars),
      idle_ms: Keyword.get(opts, :idle_ms, @default_idle_ms),
      max_latency_ms: Keyword.get(opts, :max_latency_ms, @default_max_latency_ms)
    }

    state = %__MODULE__{
      session_key: session_key,
      channel_id: channel_id,
      run_id: nil,
      buffer: "",
      full_text: "",
      last_seq: 0,
      last_flush_ts: nil,
      first_delta_ts: nil,
      flush_timer: nil,
      config: config,
      meta: Keyword.get(opts, :meta, %{}),
      last_sent_text: nil,
      answer_create_ref: nil,
      deferred_answer_text: nil,
      pending_resume_indices: %{},
      finalized: false
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:delta, run_id, seq, text, meta}, state) do
    now = System.system_time(:millisecond)

    # Reset if run changed
    state =
      if state.run_id != run_id do
        cancel_timer(state.flush_timer)

        %{
          state
          | run_id: run_id,
            buffer: "",
            full_text: "",
            last_seq: 0,
            first_delta_ts: nil,
            flush_timer: nil,
            meta: compact_meta(meta),
            last_sent_text: nil,
            answer_create_ref: nil,
            deferred_answer_text: nil,
            pending_resume_indices: state.pending_resume_indices || %{},
            finalized: false
        }
      else
        %{state | meta: Map.merge(state.meta || %{}, compact_meta(meta))}
      end

    # If we've already finalized this run, ignore late deltas.
    if state.finalized == true and state.run_id == run_id do
      {:noreply, state}
    else
      # Only accept in-order deltas
      if seq <= state.last_seq do
        {:noreply, state}
      else
        new_full = cap_full_text(state.full_text <> text)

        state = %{
          state
          | buffer: state.buffer <> text,
            full_text: new_full,
            last_seq: seq,
            first_delta_ts: state.first_delta_ts || now
        }

        state = maybe_flush(state, now)
        {:noreply, state}
      end
    end
  end

  # Handle legacy delta messages without meta
  def handle_cast({:delta, run_id, seq, text}, state) do
    handle_cast({:delta, run_id, seq, text, %{}}, state)
  end

  def handle_cast(:flush, state) do
    state = do_flush(state)
    {:noreply, state}
  end

  @impl true
  def handle_call({:finalize, run_id, meta, final_text}, _from, state) do
    state =
      cond do
        state.run_id == nil ->
          %{
            state
            | run_id: run_id,
              meta: compact_meta(meta),
              answer_create_ref: nil,
              deferred_answer_text: nil,
              finalized: false
          }

        state.run_id != run_id ->
          cancel_timer(state.flush_timer)

          %{
            state
            | run_id: run_id,
              buffer: "",
              full_text: "",
              last_seq: 0,
              first_delta_ts: nil,
              flush_timer: nil,
              meta: compact_meta(meta),
              last_sent_text: nil,
              answer_create_ref: nil,
              deferred_answer_text: nil,
              pending_resume_indices: state.pending_resume_indices || %{},
              finalized: false
          }

        true ->
          %{state | meta: Map.merge(state.meta || %{}, compact_meta(meta))}
      end

    state = do_finalize(state, final_text)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:idle_timeout, state) do
    state = do_flush(state)
    {:noreply, state}
  end

  def handle_info({:outbox_delivered, ref, result}, state) when is_reference(ref) do
    adapter = ChannelAdapter.for(state.channel_id)
    snapshot = build_snapshot(state)
    updates = adapter.handle_delivery_ack(snapshot, ref, result)
    state = apply_updates(state, updates)

    {:noreply, state}
  end

  def handle_info({:pending_resume_cleanup_timeout, ref, attempt}, state)
      when is_reference(ref) and is_integer(attempt) and attempt > 0 do
    pending = state.pending_resume_indices || %{}

    state =
      case Map.get(pending, ref) do
        %{kind: :final_send} = entry ->
          new_pending =
            LemonRouter.ChannelAdapter.Telegram.handle_pending_resume_cleanup(
              pending,
              ref,
              entry,
              attempt
            )

          %{state | pending_resume_indices: new_pending}

        _ ->
          state
      end

    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ---- Internal ----

  defp compact_meta(meta), do: ChannelContext.compact_meta(meta)

  defp maybe_flush(state, now) do
    buffer_len = String.length(state.buffer)
    time_since_first = now - (state.first_delta_ts || now)

    cond do
      buffer_len >= state.config.min_chars ->
        do_flush(state)

      time_since_first >= state.config.max_latency_ms ->
        do_flush(state)

      true ->
        cancel_timer(state.flush_timer)
        timer = Process.send_after(self(), :idle_timeout, state.config.idle_ms)
        %{state | flush_timer: timer}
    end
  end

  defp do_flush(%{buffer: ""} = state), do: state

  defp do_flush(state) do
    state = emit_output(state)

    cancel_timer(state.flush_timer)

    %{
      state
      | buffer: "",
        first_delta_ts: nil,
        last_flush_ts: System.system_time(:millisecond),
        flush_timer: nil
    }
  end

  defp emit_output(state) do
    # Broadcast to session topic for any local subscribers
    if is_pid(Process.whereis(LemonCore.PubSub)) do
      LemonCore.Bus.broadcast(
        LemonCore.Bus.session_topic(state.session_key),
        %{
          type: :coalesced_output,
          session_key: state.session_key,
          channel_id: state.channel_id,
          run_id: state.run_id,
          text: state.buffer,
          seq: state.last_seq
        }
      )
    end

    adapter = ChannelAdapter.for(state.channel_id)
    snapshot = build_snapshot(state)

    case adapter.emit_stream_output(snapshot) do
      {:ok, updates} -> apply_updates(state, updates)
      :skip -> state
    end
  end

  defp do_finalize(state, final_text) do
    adapter = ChannelAdapter.for(state.channel_id)
    snapshot = build_snapshot(state)

    case adapter.finalize_stream(snapshot, final_text) do
      {:ok, updates} ->
        state = apply_updates(state, updates)
        cancel_timer(state.flush_timer)
        state

      :skip ->
        state
    end
  rescue
    _ -> state
  end

  defp build_snapshot(state) do
    %{
      session_key: state.session_key,
      channel_id: state.channel_id,
      run_id: state.run_id,
      buffer: state.buffer,
      full_text: state.full_text,
      last_seq: state.last_seq,
      meta: state.meta || %{},
      last_sent_text: state.last_sent_text,
      answer_create_ref: state.answer_create_ref,
      deferred_answer_text: state.deferred_answer_text,
      pending_resume_indices: state.pending_resume_indices || %{},
      finalized: state.finalized,
      config: state.config
    }
  end

  defp apply_updates(state, updates) when is_map(updates) do
    Enum.reduce(updates, state, fn {key, value}, acc ->
      if Map.has_key?(acc, key) do
        Map.put(acc, key, value)
      else
        acc
      end
    end)
  end

  defp apply_updates(state, _), do: state

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

  @max_full_text 100_000
  defp cap_full_text(text) when is_binary(text) and byte_size(text) > @max_full_text do
    keep = @max_full_text
    String.slice(text, String.length(text) - keep, keep)
  end

  defp cap_full_text(text), do: text
end
