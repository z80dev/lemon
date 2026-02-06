defmodule LemonRouter.RunProcess do
  @moduledoc """
  Process that owns a single run lifecycle.

  Each RunProcess:
  - Owns a run_id
  - Manages abort state
  - Subscribes to Bus for run events
  - Maintains metadata snapshot
  - Emits router-level events
  """

  use GenServer

  require Logger

  alias LemonCore.Bus

  def start_link(opts) do
    run_id = opts[:run_id]
    GenServer.start_link(__MODULE__, opts, name: via_tuple(run_id))
  end

  def child_spec(opts) do
    run_id = opts[:run_id]

    %{
      id: {__MODULE__, run_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5000
    }
  end

  defp via_tuple(run_id) do
    {:via, Registry, {LemonRouter.RunRegistry, run_id}}
  end

  @doc """
  Abort this run process.
  """
  @spec abort(pid() | binary(), reason :: term()) :: :ok
  def abort(pid, reason \\ :user_requested) when is_pid(pid) do
    GenServer.cast(pid, {:abort, reason})
  end

  def abort(run_id, reason) when is_binary(run_id) do
    case Registry.lookup(LemonRouter.RunRegistry, run_id) do
      [{pid, _}] -> abort(pid, reason)
      _ -> :ok
    end
  end

  @impl true
  def init(%{run_id: run_id, session_key: session_key, job: job}) do
    # Subscribe to run events
    Bus.subscribe(Bus.run_topic(run_id))

    # Register in session registry
    Registry.register(LemonRouter.SessionRegistry, session_key, %{run_id: run_id})

    state = %{
      run_id: run_id,
      session_key: session_key,
      job: job,
      start_ts_ms: LemonCore.Clock.now_ms(),
      aborted: false,
      completed: false,
      saw_delta: false
    }

    # Submit to gateway
    send(self(), :submit_to_gateway)

    {:ok, state}
  end

  @impl true
  def handle_info(:submit_to_gateway, state) do
    # Submit job to gateway scheduler
    LemonGateway.Scheduler.submit(state.job)
    {:noreply, state}
  end

  # Handle run events from Bus
  def handle_info(%LemonCore.Event{type: :run_completed} = event, state) do
    Logger.debug("RunProcess #{state.run_id} completed")

    # Emit router-level completion event
    Bus.broadcast(Bus.session_topic(state.session_key), event)

    # Mark any still-running tool calls as completed so the editable "Tool calls"
    # status message (Telegram) can't get stuck at [running] if a final action
    # completion event is missed/raced.
    finalize_tool_status(state, event)

    # If we never streamed deltas, make sure any tool-status output is flushed
    # before we emit a single final answer chunk.
    if state.saw_delta == false do
      flush_tool_status(state)
    end

    # Telegram: delete the "Running..." progress message and send the final response as a new message,
    # so it always appears below the last tool-call/status message.
    maybe_finalize_stream_output(state, event)

    # If no streaming deltas were emitted, emit a final output chunk so channels respond.
    #
    # Note: Telegram final output is handled by maybe_finalize_stream_output/2 instead to avoid
    # producing a terminal :edit update to the progress message.
    maybe_emit_final_output(state, event)

    {:stop, :normal, %{state | completed: true}}
  end

  def handle_info(%LemonCore.Event{type: :delta, payload: delta} = event, state) do
    # Forward delta to session subscribers
    Bus.broadcast(Bus.session_topic(state.session_key), event)

    # Ensure any pending tool-status output is emitted before we start streaming the answer.
    if state.saw_delta == false do
      flush_tool_status(state)
    end

    # Also ingest into StreamCoalescer for channel delivery
    ingest_delta_to_coalescer(state, delta)

    {:noreply, %{state | saw_delta: true}}
  end

  def handle_info(%LemonCore.Event{type: :engine_action, payload: action_ev} = event, state) do
    # Forward engine action events to session subscribers
    Bus.broadcast(Bus.session_topic(state.session_key), event)

    # Also ingest into ToolStatusCoalescer for channel delivery
    ingest_action_to_tool_status_coalescer(state, action_ev)

    {:noreply, state}
  end

  def handle_info(%LemonCore.Event{} = event, state) do
    # Forward other events to session subscribers
    Bus.broadcast(Bus.session_topic(state.session_key), event)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def handle_cast({:abort, reason}, state) do
    if state.aborted or state.completed do
      {:noreply, state}
    else
      Logger.debug("RunProcess #{state.run_id} aborting: #{inspect(reason)}")

      # Signal abort to gateway
      # Note: We rely on the gateway's abort mechanism
      LemonRouter.Router.abort_run(state.run_id, reason)

      {:noreply, %{state | aborted: true}}
    end
  end

  @impl true
  def terminate(reason, state) do
    # Unregister from session registry
    Registry.unregister(LemonRouter.SessionRegistry, state.session_key)

    # If not completed normally, emit failure event and attempt abort
    if reason != :normal and not state.completed do
      Bus.broadcast(Bus.run_topic(state.run_id), %{
        type: :run_failed,
        run_id: state.run_id,
        session_key: state.session_key,
        reason: reason
      })

      # Best-effort abort of the gateway run on abnormal termination
      try do
        LemonGateway.Scheduler.abort(state.run_id, :run_process_terminated)
      rescue
        _ -> :ok
      end
    end

    # Flush any pending coalescer output
    flush_coalescer(state)

    # Unsubscribe control-plane EventBridge from run events
    unsubscribe_event_bridge(state.run_id)

    :ok
  end

  # Ingest delta into StreamCoalescer for channel delivery
  defp ingest_delta_to_coalescer(state, delta) do
    # Extract channel_id from session_key using SessionKey parser
    case LemonRouter.SessionKey.parse(state.session_key) do
      %{kind: :channel_peer, channel_id: channel_id} when not is_nil(channel_id) ->
        # Build meta from job for progress_msg_id
        meta = extract_coalescer_meta(state.job)

        LemonRouter.StreamCoalescer.ingest_delta(
          state.session_key,
          channel_id,
          state.run_id,
          delta.seq,
          delta.text,
          meta: meta
        )

      _ ->
        # Not a channel session, no coalescing needed
        :ok
    end
  rescue
    _ -> :ok
  end

  # Extract metadata relevant for coalescer (e.g., progress_msg_id for edit mode)
  defp extract_coalescer_meta(%{meta: meta}) when is_map(meta) do
    %{
      progress_msg_id: meta[:progress_msg_id],
      status_msg_id: meta[:status_msg_id],
      user_msg_id: meta[:user_msg_id]
    }
  end
  defp extract_coalescer_meta(_), do: %{}

  # If the run completed without streaming deltas, emit a single delta with the final answer.
  defp maybe_emit_final_output(state, %LemonCore.Event{} = event) do
    with false <- state.saw_delta,
         answer when is_binary(answer) and answer != "" <- extract_completed_answer(event),
         %{kind: :channel_peer, channel_id: channel_id} when not is_nil(channel_id) <-
           LemonRouter.SessionKey.parse(state.session_key) do
      # Telegram final output is handled via StreamCoalescer.finalize_run/4
      # so we avoid emitting a terminal :edit update to the progress message.
      if channel_id == "telegram" do
        :ok
      else
      meta = extract_coalescer_meta(state.job)
      LemonRouter.StreamCoalescer.ingest_delta(
        state.session_key,
        channel_id,
        state.run_id,
        1,
        answer,
        meta: meta
      )
      end
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  defp extract_completed_answer(%LemonCore.Event{payload: %{completed: %{answer: answer}}}), do: answer
  defp extract_completed_answer(%LemonCore.Event{payload: %{answer: answer}}), do: answer
  defp extract_completed_answer(%LemonCore.Event{payload: %LemonGateway.Event.Completed{answer: answer}}), do: answer
  defp extract_completed_answer(_), do: nil

  defp maybe_finalize_stream_output(state, %LemonCore.Event{} = event) do
    with %{kind: :channel_peer, channel_id: "telegram"} <- LemonRouter.SessionKey.parse(state.session_key),
         true <- Code.ensure_loaded?(LemonRouter.StreamCoalescer) do
      meta = extract_coalescer_meta(state.job)
      final_text = extract_completed_answer(event)

      LemonRouter.StreamCoalescer.finalize_run(
        state.session_key,
        "telegram",
        state.run_id,
        meta: meta,
        final_text: final_text
      )
    else
      _ -> :ok
    end

    :ok
  rescue
    _ -> :ok
  end

  defp finalize_tool_status(state, %LemonCore.Event{} = event) do
    with %{kind: :channel_peer, channel_id: channel_id} when not is_nil(channel_id) <-
           LemonRouter.SessionKey.parse(state.session_key),
         true <- Code.ensure_loaded?(LemonRouter.ToolStatusCoalescer) do
      ok? =
        case event.payload do
          %{completed: %{ok: ok}} -> ok == true
          %LemonGateway.Event.Completed{ok: ok} -> ok == true
          %{ok: ok} -> ok == true
          _ -> false
        end

      LemonRouter.ToolStatusCoalescer.finalize_run(state.session_key, channel_id, state.run_id, ok?)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp ingest_action_to_tool_status_coalescer(state, action_ev) do
    case LemonRouter.SessionKey.parse(state.session_key) do
      %{kind: :channel_peer, channel_id: channel_id} when not is_nil(channel_id) ->
        meta = extract_coalescer_meta(state.job)

        if Code.ensure_loaded?(LemonRouter.ToolStatusCoalescer) do
          LemonRouter.ToolStatusCoalescer.ingest_action(
            state.session_key,
            channel_id,
            state.run_id,
            action_ev,
            meta: meta
          )
        end

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  # Flush any pending coalesced output on termination
  defp flush_coalescer(state) do
    case LemonRouter.SessionKey.parse(state.session_key) do
      %{kind: :channel_peer, channel_id: channel_id} when not is_nil(channel_id) ->
        LemonRouter.StreamCoalescer.flush(state.session_key, channel_id)
        if Code.ensure_loaded?(LemonRouter.ToolStatusCoalescer) do
          LemonRouter.ToolStatusCoalescer.flush(state.session_key, channel_id)
        end

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp flush_tool_status(state) do
    case LemonRouter.SessionKey.parse(state.session_key) do
      %{kind: :channel_peer, channel_id: channel_id} when not is_nil(channel_id) ->
        if Code.ensure_loaded?(LemonRouter.ToolStatusCoalescer) do
          LemonRouter.ToolStatusCoalescer.flush(state.session_key, channel_id)
        end

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  # Unsubscribe control-plane EventBridge from run events
  defp unsubscribe_event_bridge(run_id) do
    if Code.ensure_loaded?(LemonControlPlane.EventBridge) do
      LemonControlPlane.EventBridge.unsubscribe_run(run_id)
    end
  rescue
    _ -> :ok
  end
end
