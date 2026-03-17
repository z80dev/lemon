defmodule LemonRouter.StreamCoalescer do
  @moduledoc """
  Coalesces streaming deltas for efficient channel output.

  The coalescer buffers incoming deltas and flushes them to channels
  based on configurable thresholds:

  - `min_chars: 48` - Minimum characters before flushing
  - `idle_ms: 400` - Flush after this idle time
  - `max_latency_ms: 1200` - Maximum time before forced flush

  ## Output

  Produces semantic `LemonCore.DeliveryIntent` snapshots/finalization and
  hands them to `LemonChannels.Dispatcher`. Channel-specific presentation lives
  entirely in `lemon_channels`.
  """

  use GenServer

  require Logger

  alias LemonChannels.Dispatcher
  alias LemonCore.DeliveryIntent
  alias LemonRouter.ChannelContext
  alias LemonRouter.DeliveryRouteResolver

  @default_min_chars 200
  @default_idle_ms 800
  @default_max_latency_ms 3000

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
    :finalized,
    :pending_clear
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

  Delegates semantic finalization to the channels dispatcher.
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
  Commit the current turn: flush pending buffer, clear PresentationState for
  the `:answer` surface so the next delta creates a fresh message, and reset
  internal text accumulators. No-op when `full_text` is empty or `run_id`
  doesn't match.

  Used at turn boundaries (model text → tool action) in multi-turn runs so
  each intermediate answer becomes its own Telegram message instead of
  overwriting the previous one.
  """
  @spec commit_turn(session_key :: binary(), channel_id :: binary(), run_id :: binary()) :: :ok
  def commit_turn(session_key, channel_id, run_id)
      when is_binary(session_key) and is_binary(channel_id) and is_binary(run_id) do
    case Registry.lookup(LemonRouter.CoalescerRegistry, {session_key, channel_id}) do
      [{pid, _}] ->
        try do
          GenServer.call(pid, {:commit_turn, run_id}, 5_000)
        catch
          :exit, _ -> :ok
        end

      _ ->
        :ok
    end
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
      finalized: false,
      pending_clear: false
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:delta, run_id, seq, text, meta}, state) do
    now = System.system_time(:millisecond)

    # If a commit_turn deferred PresentationState clearing, do it now.
    # By this point the previous message's outbox delivery has had time to
    # complete, so the clear won't race with a pending create.
    state =
      if state.pending_clear and state.run_id == run_id do
        clear_presentation_state_answer(state)
        %{state | pending_clear: false}
      else
        state
      end

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
            finalized: false,
            pending_clear: false
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
              finalized: false
          }

        true ->
          %{state | meta: Map.merge(state.meta || %{}, compact_meta(meta))}
      end

    state = do_finalize(state, final_text)
    {:reply, :ok, state}
  end

  def handle_call({:commit_turn, run_id}, _from, state) do
    state =
      if state.run_id == run_id and is_binary(state.full_text) and state.full_text != "" do
        # Finalize the current answer message (handles pending creates, deferred
        # edits, and ensures the full text is delivered before we detach).
        state = do_finalize(state, state.full_text)

        cancel_timer(state.flush_timer)

        # Defer the PresentationState clear until the next delta arrives.
        # This avoids a race where the outbox hasn't delivered the finalize
        # edit yet (pending_create_ref still set) and clearing would discard
        # the deferred text update.
        %{
          state
          | buffer: "",
            full_text: "",
            last_sent_text: nil,
            flush_timer: nil,
            first_delta_ts: nil,
            finalized: false,
            pending_clear: true
        }
      else
        state
      end

    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:idle_timeout, state) do
    state = do_flush(state)
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

    case build_intent(state, :stream_snapshot, state.full_text) do
      {:ok, intent} ->
        case dispatcher().dispatch(intent) do
          :ok -> %{state | last_sent_text: state.full_text}
          {:error, _} -> state
        end

      :error ->
        state
    end
  end

  defp do_finalize(state, final_text) do
    text =
      cond do
        is_binary(final_text) and final_text != "" -> final_text
        is_binary(state.full_text) and state.full_text != "" -> state.full_text
        is_binary(state.buffer) and state.buffer != "" -> state.buffer
        true -> "Done"
      end

    state =
      case build_intent(state, :stream_finalize, text) do
        {:ok, intent} ->
          _ = dispatcher().dispatch(intent)
          %{state | last_sent_text: text, finalized: true}

        :error ->
          %{state | finalized: true}
      end

    cancel_timer(state.flush_timer)
    state
  rescue
    _ -> state
  end

  defp build_intent(state, kind, text) when is_binary(text) do
    with {:ok, route} <- DeliveryRouteResolver.resolve(state.session_key, state.channel_id, state.meta || %{}) do
      {:ok,
       %DeliveryIntent{
         intent_id: "#{state.run_id}:stream:#{state.last_seq}:#{Atom.to_string(kind)}",
         run_id: state.run_id,
         session_key: state.session_key,
         route: route,
         kind: kind,
         body: %{
           text: text,
           seq: state.last_seq
         },
         meta: Map.put(state.meta || %{}, :surface, :answer)
       }}
    else
      _ -> :error
    end
  end

  defp clear_presentation_state_answer(state) do
    with {:ok, route} <- DeliveryRouteResolver.resolve(state.session_key, state.channel_id, state.meta || %{}) do
      LemonChannels.PresentationState.clear(route, state.run_id, :answer)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

  defp dispatcher do
    Application.get_env(:lemon_router, :dispatcher, Dispatcher)
  end

  @max_full_text 100_000
  defp cap_full_text(text) when is_binary(text) and byte_size(text) > @max_full_text do
    keep = @max_full_text
    String.slice(text, String.length(text) - keep, keep)
  end

  defp cap_full_text(text), do: text
end
