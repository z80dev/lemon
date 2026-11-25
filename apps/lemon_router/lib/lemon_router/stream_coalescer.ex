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

  Turn-boundary finalizations carry `meta.terminal_answer: false`: they finish
  a presentation segment, not the run's answer. Only `finalize_run/4` emits
  `meta.terminal_answer: true`, so channels can reserve final-answer effects
  such as speech synthesis for the completed answer.

  Each delta must fit the bounded ingress envelope. An oversized delta or a
  full ingress queue fences transient output: `current_text/3` returns `nil`
  while resync is required. Recovery requires authoritative `:final_text`
  from the owner via `finalize_run/4`.
  Admitted deltas retain a valid UTF-8 answer tail no larger than the
  coalescer's per-message ingress budget (65,536 encoded bytes by default, see
  `LemonRouter.CoalescerIngress`); this transient cap does not truncate the
  owner's final answer.

  ## Lifetime

  One coalescer exists per `{session_key, channel_id}` only while it has work.
  Finalizing a run drops its accumulated text, and a run that never streamed
  is finalized without starting a coalescer. An idle coalescer whose run is
  finalized, never started or no longer has a live `RunProcess` stops
  normally after the retirement grace (`LemonRouter.CoalescerIngress`).
  """

  use GenServer, restart: :transient

  @impl true
  def format_status(status) do
    LemonCore.StatusRedaction.gen_server(status, [
      :session_key,
      :channel_id,
      :run_id,
      :last_seq,
      :finalized
    ])
  end

  require Logger

  alias LemonChannels.Dispatcher
  alias LemonCore.DeliveryIntent
  alias LemonRouter.ChannelContext
  alias LemonRouter.CoalescerIngress
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
    :finalized,
    :pending_clear,
    :delivery,
    :retire_after_ms,
    :last_activity_ms,
    overflowed: false
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

    case CoalescerIngress.push(
           LemonRouter.CoalescerRegistry,
           {session_key, channel_id},
           run_id,
           {:delta, run_id, seq, text, meta},
           fn -> start_coalescer(session_key, channel_id, meta) end
         ) do
      {:error, reason} -> Logger.warning("Failed to start coalescer: #{inspect(reason)}")
      :ok -> :ok
    end

    :ok
  end

  @doc """
  Finalize a run for a session/channel.

  The final `:stream_finalize` intent is dispatched inside the coalescer's
  serialized loop, after every delta it already admitted, so it is the last
  write to the answer surface. A run that never streamed has no coalescer and
  is finalized directly, without starting one. While the coalescer remembers
  a completed run, duplicate finalization returns `:ok` without dispatching,
  changing the active stream, or extending the idle retirement grace.
  Returns `{:error, reason}` when the final intent could not be built or the
  dispatcher rejected it.
  """
  @spec finalize_run(
          session_key :: binary(),
          channel_id :: binary(),
          run_id :: binary(),
          opts :: keyword()
        ) :: :ok | {:error, term()}
  def finalize_run(session_key, channel_id, run_id, opts \\ [])
      when is_binary(session_key) and is_binary(channel_id) and is_binary(run_id) do
    meta = Keyword.get(opts, :meta, %{})
    final_text = Keyword.get(opts, :final_text)

    case call(session_key, channel_id, {:finalize, run_id, meta, final_text}) do
      {:ok, reply} ->
        reply

      :none ->
        finalize_unstreamed(session_key, channel_id, run_id, meta, final_text)
    end
  catch
    :exit, reason ->
      Logger.warning(
        "StreamCoalescer.finalize_run failed for session=#{inspect(session_key)} run_id=#{inspect(run_id)} reason=#{inspect(reason)}"
      )

      {:error, {:finalize_call_failed, reason}}
  end

  @spec current_text(binary(), binary(), binary()) :: binary() | nil
  def current_text(session_key, channel_id, run_id)
      when is_binary(session_key) and is_binary(channel_id) and is_binary(run_id) do
    case call(session_key, channel_id, {:current_text, run_id}) do
      {:ok, text} -> text
      :none -> nil
    end
  catch
    :exit, _ -> nil
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
    _ = call(session_key, channel_id, {:commit_turn, run_id})
    :ok
  catch
    :exit, _ -> :ok
  end

  @doc """
  Finalize the current answer turn, move its message tracking to another surface,
  and reset the answer coalescer so the next delta creates a fresh message.
  """
  @spec handoff_turn(
          session_key :: binary(),
          channel_id :: binary(),
          run_id :: binary(),
          target_surface :: term()
        ) :: {:ok, binary()} | :noop
  def handoff_turn(session_key, channel_id, run_id, target_surface)
      when is_binary(session_key) and is_binary(channel_id) and is_binary(run_id) and
             not is_nil(target_surface) do
    case call(session_key, channel_id, {:handoff_turn, run_id, target_surface}) do
      {:ok, reply} -> reply
      :none -> :noop
    end
  catch
    :exit, _ -> :noop
  end

  @doc """
  Force flush the coalescer buffer.
  """
  @spec flush(session_key :: binary(), channel_id :: binary()) :: :ok
  def flush(session_key, channel_id) do
    CoalescerIngress.push(LemonRouter.CoalescerRegistry, {session_key, channel_id}, nil, :flush)
  end

  defp call(session_key, channel_id, request) do
    CoalescerIngress.call(
      LemonRouter.CoalescerRegistry,
      {session_key, channel_id},
      request,
      5_000
    )
  end

  defp start_coalescer(session_key, channel_id, meta) do
    spec = {__MODULE__, session_key: session_key, channel_id: channel_id, meta: meta}

    case DynamicSupervisor.start_child(LemonRouter.CoalescerSupervisor, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  # Nothing streamed, so no coalescer holds state for this run: build the same
  # final intent a fresh coalescer would, in the caller.
  defp finalize_unstreamed(session_key, channel_id, run_id, meta, final_text) do
    state = %__MODULE__{
      session_key: session_key,
      channel_id: channel_id,
      run_id: run_id,
      buffer: "",
      full_text: "",
      last_seq: 0,
      meta: ChannelContext.compact_meta(meta),
      finalized: false
    }

    case do_finalize_with_result(state, final_text, true) do
      {:ok, _state} -> :ok
      {:error, reason, _state} -> {:error, reason}
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

    delivery =
      LemonRouter.CoalescerIngress.register(
        LemonRouter.CoalescerRegistry,
        {session_key, channel_id},
        opts
      )

    retire_after_ms = CoalescerIngress.retire_after_ms(opts)
    CoalescerIngress.schedule_retire_check(retire_after_ms)

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
      finalized: false,
      delivery: delivery,
      pending_clear: false,
      retire_after_ms: retire_after_ms,
      last_activity_ms: now_ms()
    }

    {:ok, state}
  end

  @impl true
  def handle_cast(message, state), do: cast(message, touch(state))

  defp cast({:delta, _, _, _, _}, %{overflowed: true} = state), do: {:noreply, state}

  defp cast({:delta, run_id, seq, text, meta}, state) do
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
            meta: ChannelContext.compact_meta(meta),
            finalized: false,
            pending_clear: false
        }
      else
        %{state | meta: Map.merge(state.meta || %{}, ChannelContext.compact_meta(meta))}
      end

    # If we've already finalized this run, ignore late deltas.
    if state.finalized == true and state.run_id == run_id do
      {:noreply, state}
    else
      # Only accept in-order deltas
      if seq <= state.last_seq do
        {:noreply, state}
      else
        new_full = cap_full_text(state.full_text <> text, state.delivery.max_bytes)

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
  defp cast({:delta, run_id, seq, text}, state) do
    cast({:delta, run_id, seq, text, %{}}, state)
  end

  defp cast(:flush, state) do
    state = do_flush(state)
    {:noreply, state}
  end

  @impl true
  def handle_call({:finalize, run_id, meta, final_text}, _from, state) do
    if LemonRouter.CoalescerIngress.completed?(
         LemonRouter.CoalescerRegistry,
         {state.session_key, state.channel_id},
         run_id
       ) do
      {:reply, :ok, state}
    else
      finalize_run_state(run_id, meta, final_text, touch(state))
    end
  end

  def handle_call(request, from, state), do: handle_request(request, from, touch(state))

  defp handle_request({:current_text, run_id}, _from, state) do
    state = LemonRouter.CoalescerIngress.observe_overflow(state)

    reply =
      if not state.overflowed and state.run_id == run_id and is_binary(state.full_text) and
           state.full_text != "" do
        state.full_text
      end

    {:reply, reply, state}
  end

  defp handle_request({:commit_turn, run_id}, _from, state) do
    state = LemonRouter.CoalescerIngress.observe_overflow(state)

    state =
      if not state.overflowed and state.run_id == run_id and is_binary(state.full_text) and
           state.full_text != "" do
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

  defp handle_request({:handoff_turn, run_id, target_surface}, _from, state) do
    state = LemonRouter.CoalescerIngress.observe_overflow(state)

    {reply, state} =
      if not state.overflowed and state.run_id == run_id and is_binary(state.full_text) and
           state.full_text != "" do
        text = state.full_text
        state = do_finalize(state, text)
        move_presentation_state_answer(state, target_surface)
        cancel_timer(state.flush_timer)

        state = %{
          state
          | buffer: "",
            full_text: "",
            flush_timer: nil,
            first_delta_ts: nil,
            finalized: false,
            pending_clear: false
        }

        {{:ok, text}, state}
      else
        {:noop, state}
      end

    {:reply, reply, state}
  end

  defp finalize_run_state(run_id, meta, final_text, state) do
    state =
      cond do
        state.run_id == nil ->
          %{
            state
            | run_id: run_id,
              meta: ChannelContext.compact_meta(meta),
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
              meta: ChannelContext.compact_meta(meta),
              finalized: false
          }

        true ->
          %{state | meta: Map.merge(state.meta || %{}, ChannelContext.compact_meta(meta))}
      end

    state = LemonRouter.CoalescerIngress.observe_overflow(state)

    if state.overflowed and not is_binary(final_text) do
      {:reply, {:error, :resync_required}, state}
    else
      case do_finalize_with_result(state, final_text, true) do
        {:ok, state} ->
          delivery =
            LemonRouter.CoalescerIngress.complete(
              LemonRouter.CoalescerRegistry,
              {state.session_key, state.channel_id},
              state.delivery,
              run_id
            )

          # The run's transient text is no longer needed once its final is out.
          {:reply, :ok,
           %{state | delivery: delivery, overflowed: false, full_text: "", meta: %{}}}

        {:error, reason, state} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  @impl true
  def handle_info({:lemon_bus_delivery, gate, message}, state) do
    if LemonCore.Bus.Delivery.matches?(state.delivery, gate) do
      case message do
        {:stream_resync, :overflow} ->
          {:noreply, LemonRouter.CoalescerIngress.observe_overflow(state)}

        _ ->
          handle_cast(message, state)
      end
    else
      {:noreply, state}
    end
  end

  def handle_info(:idle_timeout, state) do
    state = do_flush(state)
    {:noreply, state}
  end

  def handle_info(:retire_check, state) do
    case CoalescerIngress.retire_check(
           state,
           LemonRouter.CoalescerRegistry,
           {state.session_key, state.channel_id},
           &retirable?/1
         ) do
      {:stop, state} -> {:stop, :normal, state}
      {:keep, state, admitted} -> {:noreply, Enum.reduce(admitted, state, &cast_admitted/2)}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp cast_admitted(message, state) do
    {:noreply, state} = handle_cast(message, state)
    state
  end

  # ---- Internal ----

  defp touch(state), do: %{state | last_activity_ms: now_ms()}

  defp now_ms, do: System.monotonic_time(:millisecond)

  # Nothing a live producer still needs: the run is finalized (its fence lives
  # in the registry only for the retirement grace), never started, or its
  # RunProcess is gone.
  defp retirable?(%__MODULE__{run_id: nil}), do: true
  defp retirable?(%__MODULE__{finalized: true}), do: true

  defp retirable?(%__MODULE__{run_id: run_id}),
    do: not CoalescerIngress.producer_alive?(run_id, :answer)

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

  # A finalized stream never flushes again: a late snapshot would overwrite the
  # final multi-chunk answer with an older, single-message truncation.
  defp do_flush(%{finalized: true} = state), do: state

  defp do_flush(%{overflowed: true} = state), do: state

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
    case build_intent(state, :stream_snapshot, state.full_text) do
      {:ok, intent} ->
        _ = dispatcher().dispatch(intent)
        state

      :error ->
        state
    end
  end

  defp do_finalize(state, final_text) do
    case do_finalize_with_result(state, final_text, false) do
      {:ok, state} -> state
      {:error, _reason, state} -> state
    end
  end

  defp do_finalize_with_result(state, final_text, terminal_answer?) do
    text =
      cond do
        is_binary(final_text) and final_text != "" -> final_text
        is_binary(state.full_text) and state.full_text != "" -> state.full_text
        is_binary(state.buffer) and state.buffer != "" -> state.buffer
        true -> empty_response_text(state)
      end

    cancel_timer(state.flush_timer)

    # Pending transient text is superseded by the final text whether or not the
    # dispatcher accepts it; a later flush must never deliver it after the final.
    state = %{state | buffer: "", first_delta_ts: nil, flush_timer: nil}

    case dispatch_final(state, text, terminal_answer?) do
      :ok -> {:ok, %{state | finalized: true}}
      {:error, reason} -> {:error, reason, %{state | finalized: false}}
    end
  end

  defp dispatch_final(state, text, terminal_answer?) do
    case build_intent(state, :stream_finalize, text) do
      {:ok, intent} ->
        intent =
          if terminal_answer? and Map.get(intent.meta, :durable_terminal) == true,
            do: %{intent | intent_id: "#{state.run_id}:terminal-answer"},
            else: intent

        intent = %{intent | meta: Map.put(intent.meta, :terminal_answer, terminal_answer?)}

        case dispatcher().dispatch(intent) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "StreamCoalescer finalize dispatch failed session=#{inspect(state.session_key)} run_id=#{inspect(state.run_id)} reason=#{inspect(reason)}"
            )

            {:error, {:dispatch_failed, reason}}
        end

      :error ->
        {:error, :build_intent_failed}
    end
  end

  defp empty_response_text(state) do
    Logger.warning(
      "StreamCoalescer finalizing #{state.session_key} with empty text " <>
        "(run_id=#{state.run_id}, last_seq=#{state.last_seq})"
    )

    "⚠️ Empty response from model — no output was generated."
  end

  defp build_intent(state, kind, text) when is_binary(text) do
    case DeliveryRouteResolver.resolve(state.session_key, state.channel_id, state.meta || %{}) do
      {:ok, route} ->
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

      _ ->
        :error
    end
  end

  defp clear_presentation_state_answer(state) do
    with {:ok, route} <-
           DeliveryRouteResolver.resolve(state.session_key, state.channel_id, state.meta || %{}) do
      LemonChannels.PresentationState.clear(route, state.run_id, :answer)
    end

    :ok
  end

  defp move_presentation_state_answer(state, target_surface) when not is_nil(target_surface) do
    with {:ok, route} <-
           DeliveryRouteResolver.resolve(state.session_key, state.channel_id, state.meta || %{}) do
      LemonChannels.PresentationState.move(route, state.run_id, :answer, target_surface)
    end

    :ok
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

  defp dispatcher do
    Application.get_env(:lemon_router, :dispatcher, Dispatcher)
  end

  # The retained tail is capped at the coalescer's per-message ingress budget
  # (`delivery.max_bytes`, 65,536 encoded bytes by default): no single admitted
  # delivery can carry more, and the owner's final text is authoritative.
  #
  # Trim on bytes rather than graphemes. `String.length/1` and `String.slice/3`
  # both walk the binary one grapheme at a time, which cost milliseconds per
  # delta once an answer crossed the cap. Worse, for multi-byte text
  # `String.length(text) - keep` went negative, and `String.slice/3` reads a
  # negative start as an offset from the end — so it returned the whole string
  # and the cap never applied at all. The guard is byte-based, so bytes are the
  # consistent unit. See docs/benchmarks/platform-microbenchmarks.md.
  defp cap_full_text(text, max_bytes) when is_binary(text) and byte_size(text) > max_bytes do
    text
    |> binary_part(byte_size(text) - max_bytes, max_bytes)
    |> drop_partial_codepoint()
    |> :binary.copy()
  end

  defp cap_full_text(text, _max_bytes), do: text

  # Cutting on a byte boundary can land inside a multi-byte codepoint, leaving
  # an invalid binary that would fail JSON encoding on the way to a channel.
  # UTF-8 continuation bytes are 0b10xxxxxx and a codepoint is at most four
  # bytes, so at most three need dropping to reach a real boundary.
  defp drop_partial_codepoint(<<byte, rest::binary>>) when byte in 0x80..0xBF,
    do: drop_partial_codepoint(rest)

  defp drop_partial_codepoint(text), do: text
end
