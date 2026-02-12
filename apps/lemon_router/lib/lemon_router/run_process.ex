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

  @gateway_submit_retry_base_ms 100
  @gateway_submit_retry_max_ms 2_000

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
  def abort(pid_or_run_id, reason \\ :user_requested)

  def abort(pid_or_run_id, reason) when is_pid(pid_or_run_id) do
    GenServer.cast(pid_or_run_id, {:abort, reason})
  end

  def abort(pid_or_run_id, reason) when is_binary(pid_or_run_id) do
    case Registry.lookup(LemonRouter.RunRegistry, pid_or_run_id) do
      [{pid, _}] -> abort(pid, reason)
      _ -> :ok
    end
  end

  @impl true
  def init(opts) do
    run_id = opts[:run_id]
    session_key = opts[:session_key]
    job = opts[:job]
    gateway_scheduler = opts[:gateway_scheduler] || LemonGateway.Scheduler

    # For tests and partial-boot scenarios, allow skipping gateway submission.
    submit_to_gateway? =
      case opts[:submit_to_gateway?] do
        nil -> true
        other -> other
      end

    # Subscribe to run events
    Bus.subscribe(Bus.run_topic(run_id))

    state = %{
      run_id: run_id,
      session_key: session_key,
      job: job,
      start_ts_ms: LemonCore.Clock.now_ms(),
      aborted: false,
      completed: false,
      saw_delta: false,
      session_registered?: false,
      submit_to_gateway?: submit_to_gateway?,
      gateway_scheduler: gateway_scheduler,
      gateway_submit_attempt: 0,
      gateway_submitted?: false
    }

    # Submit to gateway
    if submit_to_gateway? do
      send(self(), :submit_to_gateway)
    end

    {:ok, state}
  end

  @impl true
  def handle_info(:submit_to_gateway, state) do
    cond do
      state.gateway_submitted? or state.aborted or state.completed ->
        {:noreply, state}

      scheduler_available?(state.gateway_scheduler) ->
        state.gateway_scheduler.submit(state.job)
        {:noreply, %{state | gateway_submitted?: true, gateway_submit_attempt: 0}}

      true ->
        delay_ms = gateway_submit_retry_delay_ms(state.gateway_submit_attempt)
        Process.send_after(self(), :submit_to_gateway, delay_ms)

        Logger.warning(
          "Gateway scheduler unavailable; retrying submit for run_id=#{inspect(state.run_id)} " <>
            "in #{delay_ms}ms (attempt=#{state.gateway_submit_attempt + 1})"
        )

        {:noreply, %{state | gateway_submit_attempt: state.gateway_submit_attempt + 1}}
    end
  end

  # Handle run events from Bus
  def handle_info(%LemonCore.Event{type: :run_started} = event, state) do
    # Mark this run as the currently active run for the session.
    #
    # Note: strict single-flight is enforced by LemonGateway.ThreadWorker, which
    # serializes runs per session_key (scheduler thread_key is `{:session, session_key}`).
    if state.session_registered? do
      Bus.broadcast(Bus.session_topic(state.session_key), event)
      {:noreply, state}
    else
      case Registry.register(LemonRouter.SessionRegistry, state.session_key, %{
             run_id: state.run_id
           }) do
        {:ok, _pid} ->
          Bus.broadcast(Bus.session_topic(state.session_key), event)
          {:noreply, %{state | session_registered?: true}}

        {:error, {:already_registered, _pid}} ->
          Logger.warning(
            "SessionRegistry already has an active run for session_key=#{inspect(state.session_key)}; " <>
              "run_id=#{inspect(state.run_id)} violates strict single-flight; cancelling this run"
          )

          # Don't forward events into the session topic for a non-active run; otherwise
          # clients see interleaved streams for a single session_key.
          LemonGateway.Runtime.cancel_by_run_id(state.run_id, :single_flight_violation)

          {:stop, :normal, state}
      end
    end
  end

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

    # Telegram: StreamCoalescer finalizes by sending a final response as a new message.
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

      # Best-effort cancel of the gateway run. This does not currently remove
      # queued jobs for the same session_key; it only cancels the in-flight run.
      LemonGateway.Runtime.cancel_by_run_id(state.run_id, reason)

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
        LemonGateway.Runtime.cancel_by_run_id(state.run_id, :run_process_terminated)
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

        seq = Map.get(delta, :seq)
        text = Map.get(delta, :text)

        if is_integer(seq) and is_binary(text) do
          LemonRouter.StreamCoalescer.ingest_delta(
            state.session_key,
            channel_id,
            state.run_id,
            seq,
            text,
            meta: meta
          )
        else
          :ok
        end

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

  defp extract_completed_answer(%LemonCore.Event{payload: %{completed: %{answer: answer}}}),
    do: answer

  defp extract_completed_answer(%LemonCore.Event{payload: %{answer: answer}}), do: answer
  defp extract_completed_answer(_), do: nil

  defp extract_completed_resume(%LemonCore.Event{payload: %{completed: %{resume: resume}}}),
    do: resume

  defp extract_completed_resume(%LemonCore.Event{payload: %{resume: resume}}), do: resume

  defp extract_completed_resume(%LemonCore.Event{
         payload: %LemonGateway.Event.Completed{resume: resume}
       }),
       do: resume

  defp extract_completed_resume(_), do: nil

  defp normalize_resume_token(nil), do: nil

  defp normalize_resume_token(%LemonGateway.Types.ResumeToken{} = tok), do: tok

  defp normalize_resume_token(%{engine: engine, value: value})
       when is_binary(engine) and is_binary(value) do
    %LemonGateway.Types.ResumeToken{engine: engine, value: value}
  end

  defp normalize_resume_token(%{"engine" => engine, "value" => value})
       when is_binary(engine) and is_binary(value) do
    %LemonGateway.Types.ResumeToken{engine: engine, value: value}
  end

  defp normalize_resume_token(_), do: nil

  defp extract_completed_ok_and_error(%LemonCore.Event{payload: %{completed: %{ok: ok} = c}})
       when is_boolean(ok) do
    {ok, Map.get(c, :error) || Map.get(c, "error")}
  end

  defp extract_completed_ok_and_error(%LemonCore.Event{payload: %{ok: ok} = p})
       when is_boolean(ok) do
    {ok, Map.get(p, :error) || Map.get(p, "error")}
  end

  defp extract_completed_ok_and_error(%LemonCore.Event{
         payload: %LemonGateway.Event.Completed{ok: ok, error: err}
       })
       when is_boolean(ok),
       do: {ok, err}

  defp extract_completed_ok_and_error(_), do: {true, nil}

  defp format_run_error(nil), do: "unknown error"
  defp format_run_error(e) when is_binary(e), do: e
  defp format_run_error(e) when is_atom(e), do: Atom.to_string(e)
  defp format_run_error(e), do: inspect(e)

  defp maybe_finalize_stream_output(state, %LemonCore.Event{} = event) do
    with %{kind: :channel_peer, channel_id: "telegram"} <-
           LemonRouter.SessionKey.parse(state.session_key) do
      meta = extract_coalescer_meta(state.job)
      resume = event |> extract_completed_resume() |> normalize_resume_token()

      final_text =
        case extract_completed_answer(event) do
          answer when is_binary(answer) and answer != "" ->
            answer

          _ ->
            case extract_completed_ok_and_error(event) do
              {false, err} ->
                "Run failed: #{format_run_error(err)}"

              _ ->
                nil
            end
        end

      # StreamCoalescer handles optional resume footer formatting; RunProcess just passes metadata.
      meta = if resume, do: Map.put(meta, :resume, resume), else: meta

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
           LemonRouter.SessionKey.parse(state.session_key) do
      ok? =
        case event.payload do
          %{completed: %{ok: ok}} -> ok == true
          %{ok: ok} -> ok == true
          _ -> false
        end

      LemonRouter.ToolStatusCoalescer.finalize_run(
        state.session_key,
        channel_id,
        state.run_id,
        ok?
      )
    end

    :ok
  rescue
    _ -> :ok
  end

  defp ingest_action_to_tool_status_coalescer(state, action_ev) do
    case LemonRouter.SessionKey.parse(state.session_key) do
      %{kind: :channel_peer, channel_id: channel_id} when not is_nil(channel_id) ->
        meta = extract_coalescer_meta(state.job)

        LemonRouter.ToolStatusCoalescer.ingest_action(
          state.session_key,
          channel_id,
          state.run_id,
          action_ev,
          meta: meta
        )

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
        LemonRouter.ToolStatusCoalescer.flush(state.session_key, channel_id)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp flush_tool_status(state) do
    case LemonRouter.SessionKey.parse(state.session_key) do
      %{kind: :channel_peer, channel_id: channel_id} when not is_nil(channel_id) ->
        LemonRouter.ToolStatusCoalescer.flush(state.session_key, channel_id)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  # Unsubscribe control-plane EventBridge from run events
  defp unsubscribe_event_bridge(run_id) do
    LemonCore.EventBridge.unsubscribe_run(run_id)
  end

  defp scheduler_available?(scheduler) do
    case GenServer.whereis(scheduler) do
      pid when is_pid(pid) -> true
      _ -> false
    end
  end

  defp gateway_submit_retry_delay_ms(attempt) when is_integer(attempt) and attempt >= 0 do
    exponential = @gateway_submit_retry_base_ms * :math.pow(2, attempt)
    delay_ms = round(exponential)
    min(delay_ms, @gateway_submit_retry_max_ms)
  end
end
