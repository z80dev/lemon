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

  alias LemonCore.{Bus, Introspection, RunRequest, SessionKey}
  alias LemonChannels.OutboundPayload
  alias LemonChannels.Types.ResumeToken
  alias LemonRouter.{ChannelContext, ChannelsDelivery}

  @default_auto_send_generated_max_files 3
  @default_max_download_bytes 50 * 1024 * 1024
  @default_compaction_reserve_tokens 16_384
  @default_codex_context_window_tokens 400_000
  @default_preemptive_compaction_trigger_ratio 0.9
  @default_run_idle_watchdog_timeout_ms 2 * 60 * 60 * 1000
  @default_run_idle_watchdog_confirm_timeout_ms 5 * 60 * 1000
  @idle_keepalive_continue_callback_prefix "lemon:idle:c:"
  @idle_keepalive_stop_callback_prefix "lemon:idle:k:"
  @gateway_submit_retry_base_ms 100
  @gateway_submit_retry_max_ms 2_000
  @session_register_retry_ms 25
  @session_register_retry_max_ms 250
  @zero_answer_retry_max_attempts 1
  @image_extensions MapSet.new(~w(.png .jpg .jpeg .gif .webp .bmp .svg .tif .tiff .heic .heif))
  @context_overflow_error_markers [
    "context_length_exceeded",
    "context length exceeded",
    "context window",
    "http 413",
    "payload too large",
    "request entity too large",
    "string too long",
    "maximum length",
    "invalid 'input[",
    "input["
  ]
  @zero_answer_retry_prefix """
  Retry notice: the previous attempt failed before producing an answer.
  Before taking new actions, first check for partially completed work from the prior attempt and continue from current state instead of repeating completed steps.
  """

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

  @doc """
  Keep an active run alive (or cancel it) when watchdog keepalive UI is used.
  """
  @spec keep_alive(pid() | binary(), decision :: :continue | :cancel) :: :ok
  def keep_alive(pid_or_run_id, decision \\ :continue)

  def keep_alive(pid_or_run_id, decision) when is_pid(pid_or_run_id) do
    GenServer.cast(pid_or_run_id, {:watchdog_keep_alive, decision})
  end

  def keep_alive(pid_or_run_id, decision) when is_binary(pid_or_run_id) do
    case Registry.lookup(LemonRouter.RunRegistry, pid_or_run_id) do
      [{pid, _}] -> keep_alive(pid, decision)
      _ -> :ok
    end
  end

  @impl true
  def init(opts) do
    run_id = opts[:run_id]
    session_key = opts[:session_key]
    job = opts[:job]
    gateway_scheduler = opts[:gateway_scheduler] || LemonGateway.Scheduler
    run_orchestrator = opts[:run_orchestrator] || LemonRouter.RunOrchestrator
    run_watchdog_timeout_ms = resolve_run_watchdog_timeout_ms(opts)
    run_watchdog_confirm_timeout_ms = resolve_run_watchdog_confirm_timeout_ms(opts)

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
      run_started_at_ms: nil,
      run_last_activity_at_ms: nil,
      run_watchdog_timeout_ms: run_watchdog_timeout_ms,
      run_watchdog_confirm_timeout_ms: run_watchdog_confirm_timeout_ms,
      run_watchdog_ref: nil,
      run_watchdog_confirmation_ref: nil,
      run_watchdog_awaiting_confirmation?: false,
      pending_run_started_event: nil,
      session_register_retry_ref: nil,
      session_register_retry_attempt: 0,
      submit_to_gateway?: submit_to_gateway?,
      gateway_scheduler: gateway_scheduler,
      run_orchestrator: run_orchestrator,
      gateway_submit_attempt: 0,
      gateway_submitted?: false,
      gateway_run_pid: nil,
      gateway_run_ref: nil,
      generated_image_paths: [],
      requested_send_files: []
    }

    Logger.debug(
      "RunProcess init run_id=#{inspect(run_id)} session_key=#{inspect(session_key)} " <>
        "engine=#{inspect(job && job.engine_id)} queue_mode=#{inspect(job && job.queue_mode)} " <>
        "submit_to_gateway?=#{inspect(submit_to_gateway?)}"
    )

    # Emit introspection event for run start
    Introspection.record(:run_started, %{
      engine_id: job && job.engine_id,
      queue_mode: job && job.queue_mode
    }, run_id: run_id, session_key: session_key, engine: "lemon", provenance: :direct)

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

        Logger.debug(
          "RunProcess submitted to gateway run_id=#{inspect(state.run_id)} " <>
            "session_key=#{inspect(state.session_key)}"
        )

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
          Logger.debug(
            "RunProcess session registered run_id=#{inspect(state.run_id)} session_key=#{inspect(state.session_key)}"
          )

          Bus.broadcast(Bus.session_topic(state.session_key), event)
          state =
            state
            |> Map.put(:session_registered?, true)
            |> schedule_run_watchdog()
            |> maybe_monitor_gateway_run()

          {:noreply, state}

        {:error, {:already_registered, _pid}} ->
          # We expect the gateway to serialize runs per session_key. This can still happen
          # briefly when the previous RunProcess is finalizing output and hasn't torn down
          # yet. Do NOT cancel the run (that drops a user message); instead, retry
          # registration until the old entry is released.
          {active_pid, active_run_id} = lookup_active_session(state.session_key)

          Logger.debug(
            "SessionRegistry already has an active run for session_key=#{inspect(state.session_key)}; " <>
              "active_run_id=#{inspect(active_run_id)} active_pid=#{inspect(active_pid)}; " <>
              "deferring registration for run_id=#{inspect(state.run_id)}"
          )

          state =
            state
            |> schedule_run_watchdog()
            |> maybe_monitor_gateway_run()
            |> put_pending_run_started(event)
            |> schedule_session_register_retry()

          {:noreply, state}
      end
    end
  end

  def handle_info(%LemonCore.Event{type: :run_completed} = event, state) do
    {ok?, err} = extract_completed_ok_and_error(event)
    usage = extract_completed_usage(event)

    Logger.info(
      "RunProcess completed run_id=#{inspect(state.run_id)} session_key=#{inspect(state.session_key)} " <>
        "ok=#{inspect(ok?)} error=#{inspect(err)} saw_delta=#{inspect(state.saw_delta)} " <>
        "usage_input_tokens=#{inspect(usage_input_tokens(usage))}"
    )

    Logger.debug("RunProcess #{state.run_id} completed")

    # Emit introspection event for run completion
    duration_ms =
      if state.start_ts_ms, do: LemonCore.Clock.now_ms() - state.start_ts_ms, else: nil

    Introspection.record(:run_completed, %{
      ok: ok?,
      error: safe_error_label(err),
      duration_ms: duration_ms,
      saw_delta: state.saw_delta
    }, run_id: state.run_id, session_key: state.session_key, engine: "lemon", provenance: :direct)

    # Free the session key ASAP so the next queued run can become active without
    # tripping the SessionRegistry single-flight guard.
    _ = Registry.unregister(LemonRouter.SessionRegistry, state.session_key)

    # If we were monitoring the gateway run process, stop monitoring it before we exit so
    # we don't race a :DOWN message and emit a synthetic completion.
    state =
      state
      |> cancel_run_watchdog()
      |> cancel_run_watchdog_confirmation()
      |> maybe_demonitor_gateway_run()

    # Emit router-level completion event
    Bus.broadcast(Bus.session_topic(state.session_key), event)

    # If the engine reports a context-window overflow, clear resume state so
    # the next message can start fresh instead of immediately failing again.
    maybe_reset_resume_on_context_overflow(state, event)
    maybe_mark_pending_compaction_near_limit(state, event)
    retried? = maybe_retry_zero_answer_failure(state, event)

    # Mark any still-running tool calls as completed so the editable "Tool calls"
    # status message (Telegram) can't get stuck at [running] if a final action
    # completion event is missed/raced.
    finalize_tool_status(state, event)

    # If we never streamed deltas, make sure any tool-status output is flushed
    # before we emit a single final answer chunk.
    if state.saw_delta == false do
      flush_tool_status(state)
    end

    unless retried? do
      # Telegram: StreamCoalescer finalizes by sending/editing a dedicated answer message; the
      # progress message is reserved for tool-call status + cancel UI and is never overwritten.
      maybe_finalize_stream_output(state, event)

      # If no streaming deltas were emitted, emit a final output chunk so channels respond.
      #
      # Note: Telegram final output is handled by maybe_finalize_stream_output/2 instead to avoid
      # producing a terminal :edit update to the progress message.
      maybe_emit_final_output(state, event)

      # Optional fanout: forward the final answer text to additional destinations.
      maybe_fanout_final_output(state, event)
    end

    {:stop, :normal, %{state | completed: true}}
  end

  def handle_info(%LemonCore.Event{type: :delta, payload: delta} = event, state) do
    state = touch_run_watchdog(state)

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
    state = touch_run_watchdog(state)

    # Forward engine action events to session subscribers
    Bus.broadcast(Bus.session_topic(state.session_key), event)

    # Also ingest into ToolStatusCoalescer for channel delivery
    ingest_action_to_tool_status_coalescer(state, action_ev)

    state = maybe_track_generated_images(state, action_ev)
    state = maybe_track_requested_send_files(state, action_ev)

    {:noreply, state}
  end

  def handle_info(%LemonCore.Event{} = event, state) do
    state = touch_run_watchdog(state)

    # Forward other events to session subscribers
    Bus.broadcast(Bus.session_topic(state.session_key), event)
    {:noreply, state}
  end

  def handle_info(:retry_session_register, state) do
    # Timer fired.
    state = %{state | session_register_retry_ref: nil}

    cond do
      state.session_registered? or state.aborted or state.completed ->
        {:noreply, state}

      true ->
        case Registry.register(LemonRouter.SessionRegistry, state.session_key, %{
               run_id: state.run_id
             }) do
          {:ok, _pid} ->
            if %LemonCore.Event{} = ev = state.pending_run_started_event do
              Bus.broadcast(Bus.session_topic(state.session_key), ev)
            end

            state =
              state
              |> Map.put(:session_registered?, true)
              |> Map.put(:pending_run_started_event, nil)
              |> Map.put(:session_register_retry_attempt, 0)
              |> maybe_monitor_gateway_run()

            {:noreply, state}

          {:error, {:already_registered, _pid}} ->
            {:noreply, schedule_session_register_retry(state)}

          _ ->
            {:noreply, schedule_session_register_retry(state)}
        end
    end
  rescue
    _ -> {:noreply, state}
  end

  def handle_info(:run_watchdog_timeout, state) do
    state = %{state | run_watchdog_ref: nil}

    if state.completed do
      {:noreply, state}
    else
      state = touch_run_watchdog_activity(state)

      cond do
        state.run_watchdog_awaiting_confirmation? ->
          {:noreply, state}

        true ->
          case maybe_request_watchdog_confirmation(state) do
            {:ok, next_state} -> {:noreply, next_state}
            :error -> {:noreply, fail_run_for_idle_timeout(state)}
          end
      end
    end
  rescue
    _ -> {:noreply, state}
  end

  def handle_info(:run_watchdog_confirmation_timeout, state) do
    state = %{state | run_watchdog_confirmation_ref: nil}

    if state.completed do
      {:noreply, state}
    else
      {:noreply, fail_run_for_idle_timeout(state)}
    end
  rescue
    _ -> {:noreply, state}
  end

  # If the gateway run process dies without emitting a completion event, synthesize a failure
  # completion so the session can make progress (and SessionRegistry is eventually cleared).
  def handle_info(
        {:DOWN, ref, :process, pid, reason},
        %{gateway_run_ref: ref, gateway_run_pid: pid} = state
      ) do
    # Normal completions should be handled by :run_completed; give the bus a small grace window.
    delay_ms = gateway_down_grace_ms(reason)
    Process.send_after(self(), {:gateway_run_down, reason}, delay_ms)
    {:noreply, %{state | gateway_run_ref: nil, gateway_run_pid: nil}}
  end

  def handle_info({:gateway_run_down, reason}, state) do
    if state.completed do
      {:noreply, state}
    else
      Logger.warning(
        "RunProcess observed gateway run down run_id=#{inspect(state.run_id)} " <>
          "session_key=#{inspect(state.session_key)} reason=#{inspect(reason)}"
      )

      event =
        LemonCore.Event.new(
          :run_completed,
          %{
            completed: %{
              ok: false,
              error: {:gateway_run_down, reason},
              answer: ""
            },
            duration_ms: nil
          },
          %{
            run_id: state.run_id,
            session_key: state.session_key,
            synthetic: true
          }
        )

      Bus.broadcast(Bus.run_topic(state.run_id), event)
      {:noreply, state}
    end
  rescue
    _ -> {:noreply, state}
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
  def handle_cast({:watchdog_keep_alive, decision}, state) do
    cond do
      state.completed ->
        {:noreply, state}

      decision in [:continue, :keep_alive] ->
        Logger.info(
          "RunProcess watchdog keepalive accepted run_id=#{inspect(state.run_id)} " <>
            "session_key=#{inspect(state.session_key)}"
        )

        state =
          state
          |> clear_watchdog_confirmation()
          |> schedule_run_watchdog()

        {:noreply, state}

      decision in [:cancel, :stop, :kill] ->
        Logger.warning(
          "RunProcess watchdog keepalive cancelled by user run_id=#{inspect(state.run_id)} " <>
            "session_key=#{inspect(state.session_key)}"
        )

        {:noreply, fail_run_for_user_cancel(state)}

      true ->
        {:noreply, state}
    end
  end

  @impl true
  def terminate(reason, state) do
    # Unregister from session registry
    Registry.unregister(LemonRouter.SessionRegistry, state.session_key)

    # If not completed normally, emit failure event and attempt abort
    if reason != :normal and not state.completed do
      # Emit introspection event for run failure
      Introspection.record(:run_failed, %{
        reason: safe_error_label(reason)
      }, run_id: state.run_id, session_key: state.session_key, engine: "lemon", provenance: :direct)

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

  defp maybe_monitor_gateway_run(%{gateway_run_ref: ref} = state) when not is_nil(ref), do: state

  defp maybe_monitor_gateway_run(state) do
    with true <- Code.ensure_loaded?(Registry),
         true <- Code.ensure_loaded?(LemonGateway.RunRegistry),
         [{pid, _}] when is_pid(pid) <- Registry.lookup(LemonGateway.RunRegistry, state.run_id) do
      %{state | gateway_run_pid: pid, gateway_run_ref: Process.monitor(pid)}
    else
      _ -> state
    end
  rescue
    _ -> state
  end

  defp maybe_demonitor_gateway_run(%{gateway_run_ref: nil} = state), do: state

  defp maybe_demonitor_gateway_run(%{gateway_run_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    %{state | gateway_run_ref: nil, gateway_run_pid: nil}
  rescue
    _ -> %{state | gateway_run_ref: nil, gateway_run_pid: nil}
  end

  defp gateway_down_grace_ms(:normal), do: 200
  defp gateway_down_grace_ms(:shutdown), do: 200
  defp gateway_down_grace_ms({:shutdown, _}), do: 200
  defp gateway_down_grace_ms(_), do: 20

  defp lookup_active_session(session_key) do
    case Registry.lookup(LemonRouter.SessionRegistry, session_key) do
      [{pid, %{run_id: run_id}}] when is_pid(pid) and is_binary(run_id) ->
        {pid, run_id}

      [{pid, value}] when is_pid(pid) and is_map(value) ->
        run_id = fetch(value, :run_id)
        {pid, run_id}

      [{pid, _value}] when is_pid(pid) ->
        {pid, nil}

      _ ->
        {nil, nil}
    end
  end

  defp put_pending_run_started(%{pending_run_started_event: %LemonCore.Event{}} = state, _ev),
    do: state

  defp put_pending_run_started(state, %LemonCore.Event{} = ev),
    do: %{state | pending_run_started_event: ev}

  defp put_pending_run_started(state, _), do: state

  defp schedule_session_register_retry(%{session_register_retry_ref: ref} = state)
       when not is_nil(ref) do
    state
  end

  defp schedule_session_register_retry(state) do
    attempt = (state.session_register_retry_attempt || 0) + 1
    delay_ms = min(@session_register_retry_ms * attempt, @session_register_retry_max_ms)
    ref = Process.send_after(self(), :retry_session_register, delay_ms)

    Logger.debug(
      "RunProcess session register retry scheduled run_id=#{inspect(state.run_id)} " <>
        "session_key=#{inspect(state.session_key)} attempt=#{attempt} delay_ms=#{delay_ms}"
    )

    %{state | session_register_retry_ref: ref, session_register_retry_attempt: attempt}
  end

  defp schedule_run_watchdog(state) do
    timeout_ms = state.run_watchdog_timeout_ms || @default_run_idle_watchdog_timeout_ms
    now_ms = LemonCore.Clock.now_ms()
    _ = cancel_run_watchdog_timer(state)
    ref = Process.send_after(self(), :run_watchdog_timeout, timeout_ms)
    run_started_at_ms = if is_integer(state.run_started_at_ms), do: state.run_started_at_ms, else: now_ms

    %{
      state
      | run_started_at_ms: run_started_at_ms,
        run_last_activity_at_ms: now_ms,
        run_watchdog_ref: ref
    }
  end

  defp touch_run_watchdog(%{run_started_at_ms: started_at} = state) when is_integer(started_at) do
    state
    |> touch_run_watchdog_activity()
    |> clear_watchdog_confirmation()
    |> schedule_run_watchdog()
  end

  defp touch_run_watchdog(state), do: state

  defp touch_run_watchdog_activity(state) do
    %{state | run_last_activity_at_ms: LemonCore.Clock.now_ms()}
  end

  defp cancel_run_watchdog(%{run_watchdog_ref: nil} = state), do: state

  defp cancel_run_watchdog(%{run_watchdog_ref: ref} = state) do
    _ = Process.cancel_timer(ref)
    %{state | run_watchdog_ref: nil}
  end

  defp cancel_run_watchdog_timer(%{run_watchdog_ref: nil}), do: :ok

  defp cancel_run_watchdog_timer(%{run_watchdog_ref: ref}) do
    _ = Process.cancel_timer(ref)
    :ok
  end

  defp resolve_run_watchdog_timeout_ms(opts) do
    timeout_ms =
      opts[:run_watchdog_timeout_ms] ||
        Application.get_env(
          :lemon_router,
          :run_process_idle_watchdog_timeout_ms,
          nil
        ) ||
        Application.get_env(
          :lemon_router,
          :run_process_watchdog_timeout_ms,
          @default_run_idle_watchdog_timeout_ms
        )

    if is_integer(timeout_ms) and timeout_ms > 0,
      do: timeout_ms,
      else: @default_run_idle_watchdog_timeout_ms
  end

  defp resolve_run_watchdog_confirm_timeout_ms(opts) do
    timeout_ms =
      opts[:run_watchdog_confirm_timeout_ms] ||
        Application.get_env(
          :lemon_router,
          :run_process_idle_watchdog_confirm_timeout_ms,
          @default_run_idle_watchdog_confirm_timeout_ms
        )

    if is_integer(timeout_ms) and timeout_ms > 0,
      do: timeout_ms,
      else: @default_run_idle_watchdog_confirm_timeout_ms
  end

  defp maybe_request_watchdog_confirmation(state) do
    with {:ok, payload} <- watchdog_confirmation_payload(state),
         {:ok, _ref} <-
           ChannelsDelivery.enqueue(payload,
             context: %{component: :run_process, phase: :watchdog_keepalive_prompt}
           ) do
      timeout_ms =
        state.run_watchdog_confirm_timeout_ms || @default_run_idle_watchdog_confirm_timeout_ms

      ref = Process.send_after(self(), :run_watchdog_confirmation_timeout, timeout_ms)

      Logger.warning(
        "RunProcess watchdog idle prompt sent run_id=#{inspect(state.run_id)} " <>
          "session_key=#{inspect(state.session_key)} confirm_timeout_ms=#{timeout_ms}"
      )

      {:ok, put_in_watchdog_confirmation(state, ref)}
    else
      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp watchdog_confirmation_payload(state) do
    parsed = ChannelContext.parse_session_key(state.session_key)

    with "telegram" <- parsed.channel_id,
         peer_kind when peer_kind in [:dm, :group, :channel] <- parsed.peer_kind,
         peer_id when is_binary(peer_id) and peer_id != "" <- parsed.peer_id do
      idle_timeout_ms = state.run_watchdog_timeout_ms || @default_run_idle_watchdog_timeout_ms
      mins = max(1, div(idle_timeout_ms, 60_000))

      text =
        "Still running, but no output for about #{mins} minutes.\n" <>
          "Keep waiting?"

      reply_markup = %{
        "inline_keyboard" => [
          [
            %{
              "text" => "Keep Waiting",
              "callback_data" => @idle_keepalive_continue_callback_prefix <> state.run_id
            },
            %{
              "text" => "Stop Run",
              "callback_data" => @idle_keepalive_stop_callback_prefix <> state.run_id
            }
          ]
        ]
      }

      payload = %OutboundPayload{
        channel_id: "telegram",
        account_id: parsed.account_id || "default",
        peer: %{kind: peer_kind, id: peer_id, thread_id: parsed.thread_id},
        kind: :text,
        content: text,
        idempotency_key: "#{state.run_id}:watchdog:prompt:#{idle_timeout_ms}",
        meta: %{
          run_id: state.run_id,
          session_key: state.session_key,
          reply_markup: reply_markup
        }
      }

      {:ok, payload}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp fail_run_for_idle_timeout(state) do
    timeout_ms = state.run_watchdog_timeout_ms || @default_run_idle_watchdog_timeout_ms

    Logger.error(
      "RunProcess watchdog idle timeout run_id=#{inspect(state.run_id)} " <>
        "session_key=#{inspect(state.session_key)} idle_timeout_ms=#{timeout_ms}"
    )

    emit_synthetic_run_completion(state, {:run_idle_watchdog_timeout, timeout_ms}, timeout_ms)
    clear_watchdog_confirmation(state)
  end

  defp fail_run_for_user_cancel(state) do
    emit_synthetic_run_completion(state, :user_requested, nil)
    clear_watchdog_confirmation(state)
  end

  defp emit_synthetic_run_completion(state, error, duration_ms) do
    try do
      LemonGateway.Runtime.cancel_by_run_id(state.run_id, :run_watchdog_timeout)
    rescue
      _ -> :ok
    end

    event =
      LemonCore.Event.new(
        :run_completed,
        %{
          completed: %{
            ok: false,
            error: error,
            answer: ""
          },
          duration_ms: duration_ms
        },
        %{
          run_id: state.run_id,
          session_key: state.session_key,
          synthetic: true
        }
      )

    Bus.broadcast(Bus.run_topic(state.run_id), event)
  end

  defp put_in_watchdog_confirmation(state, ref) do
    state
    |> cancel_run_watchdog_confirmation()
    |> Map.put(:run_watchdog_confirmation_ref, ref)
    |> Map.put(:run_watchdog_awaiting_confirmation?, true)
  end

  defp clear_watchdog_confirmation(state) do
    state
    |> cancel_run_watchdog_confirmation()
    |> Map.put(:run_watchdog_awaiting_confirmation?, false)
  end

  defp cancel_run_watchdog_confirmation(%{run_watchdog_confirmation_ref: nil} = state), do: state

  defp cancel_run_watchdog_confirmation(%{run_watchdog_confirmation_ref: ref} = state) do
    _ = Process.cancel_timer(ref)
    %{state | run_watchdog_confirmation_ref: nil}
  end

  # Ingest delta into StreamCoalescer for channel delivery
  defp ingest_delta_to_coalescer(state, delta) do
    case ChannelContext.channel_id(state.session_key) do
      {:ok, channel_id} ->
        meta = ChannelContext.coalescer_meta_from_job(state.job)

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
        :ok
    end
  rescue
    _ -> :ok
  end

  # If the run completed without streaming deltas, emit a single delta with the final answer.
  defp maybe_emit_final_output(state, %LemonCore.Event{} = event) do
    with false <- state.saw_delta,
         answer when is_binary(answer) and answer != "" <- extract_completed_answer(event),
         {:ok, channel_id} <- ChannelContext.channel_id(state.session_key) do
      # Telegram final output is handled via StreamCoalescer.finalize_run/4
      # so we avoid emitting a terminal :edit update to the progress message.
      if channel_id == "telegram" do
        :ok
      else
        meta = ChannelContext.coalescer_meta_from_job(state.job)

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

  # Best-effort final-answer fanout to additional routes supplied by AgentInbox.
  #
  # This keeps execution single-run while allowing notifications to multiple destinations.
  # Fanout routes are expected in `job.meta[:fanout_routes]` with route maps:
  # `%{channel_id, account_id, peer_kind, peer_id, thread_id}`.
  defp maybe_fanout_final_output(state, %LemonCore.Event{} = event) do
    with answer when is_binary(answer) <- extract_completed_answer(event),
         true <- String.trim(answer) != "",
         routes when is_list(routes) and routes != [] <- fanout_routes_from_job(state.job) do
      primary_signature = primary_route_signature(state.session_key)

      routes
      |> Enum.map(&normalize_fanout_route/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(&fanout_route_signature/1)
      |> Enum.reject(&(fanout_route_signature(&1) == primary_signature))
      |> Enum.with_index()
      |> Enum.each(fn {route, idx} ->
        payload = fanout_payload(route, state, answer, idx + 1)

        case ChannelsDelivery.enqueue(payload,
               context: %{component: :run_process, phase: :fanout_final_output}
             ) do
          {:ok, _ref} ->
            :ok

          {:error, :duplicate} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "Failed to enqueue fanout output for run_id=#{inspect(state.run_id)} route=#{inspect(route)} reason=#{inspect(reason)}"
            )
        end
      end)
    else
      _ -> :ok
    end

    :ok
  rescue
    _ -> :ok
  end

  defp maybe_fanout_final_output(_state, _event), do: :ok

  defp fanout_routes_from_job(%LemonGateway.Types.Job{meta: meta}) when is_map(meta) do
    fetch(meta, :fanout_routes) || []
  rescue
    _ -> []
  end

  defp fanout_routes_from_job(_), do: []

  defp primary_route_signature(session_key) when is_binary(session_key) do
    case SessionKey.parse(session_key) do
      %{
        kind: :channel_peer,
        channel_id: channel_id,
        account_id: account_id,
        peer_kind: peer_kind,
        peer_id: peer_id,
        thread_id: thread_id
      } ->
        {channel_id, account_id, peer_kind, peer_id, thread_id}

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp primary_route_signature(_), do: nil

  defp normalize_fanout_route(route) when is_map(route) do
    channel_id = fetch(route, :channel_id)
    account_id = fetch(route, :account_id) || "default"
    peer_kind = normalize_fanout_peer_kind(fetch(route, :peer_kind))
    peer_id = fetch(route, :peer_id)
    thread_id = fetch(route, :thread_id)

    cond do
      not is_binary(channel_id) or channel_id == "" ->
        nil

      not is_binary(account_id) or account_id == "" ->
        nil

      not is_binary(peer_id) or peer_id == "" ->
        nil

      is_nil(peer_kind) ->
        nil

      true ->
        %{
          channel_id: channel_id,
          account_id: account_id,
          peer_kind: peer_kind,
          peer_id: peer_id,
          thread_id: if(is_binary(thread_id) and thread_id != "", do: thread_id, else: nil)
        }
    end
  rescue
    _ -> nil
  end

  defp normalize_fanout_route(_), do: nil

  defp normalize_fanout_peer_kind(kind) when kind in [:dm, :group, :channel], do: kind

  defp normalize_fanout_peer_kind(kind) when is_binary(kind) do
    case String.downcase(String.trim(kind)) do
      "dm" -> :dm
      "group" -> :group
      "channel" -> :channel
      _ -> nil
    end
  end

  defp normalize_fanout_peer_kind(_), do: nil

  defp fanout_route_signature(route) when is_map(route) do
    {route.channel_id, route.account_id, route.peer_kind, route.peer_id, route.thread_id}
  end

  defp fanout_payload(route, state, answer, index) do
    %OutboundPayload{
      channel_id: route.channel_id,
      account_id: route.account_id,
      peer: %{
        kind: route.peer_kind,
        id: route.peer_id,
        thread_id: route.thread_id
      },
      kind: :text,
      content: answer,
      idempotency_key: "#{state.run_id}:fanout:#{index}",
      meta: %{
        run_id: state.run_id,
        session_key: state.session_key,
        fanout: true,
        fanout_index: index
      }
    }
  end

  @spec extract_from_completed_or_payload(LemonCore.Event.t() | term(), atom()) :: term()
  defp extract_from_completed_or_payload(%LemonCore.Event{payload: payload}, field)
       when is_map(payload) do
    completed = fetch(payload, :completed)

    value = if is_map(completed), do: fetch(completed, field), else: nil
    if is_nil(value), do: fetch(payload, field), else: value
  end

  defp extract_from_completed_or_payload(_, _), do: nil

  @spec extract_completed_answer(LemonCore.Event.t() | term()) :: binary() | nil
  defp extract_completed_answer(event), do: extract_from_completed_or_payload(event, :answer)

  @spec extract_completed_resume(LemonCore.Event.t() | term()) :: term()
  defp extract_completed_resume(event), do: extract_from_completed_or_payload(event, :resume)

  @spec normalize_resume_token(term()) :: ResumeToken.t() | nil
  defp normalize_resume_token(nil), do: nil

  defp normalize_resume_token(%ResumeToken{} = tok), do: tok

  defp normalize_resume_token(%{engine: engine, value: value})
       when is_binary(engine) and is_binary(value) do
    %ResumeToken{engine: engine, value: value}
  end

  defp normalize_resume_token(%{"engine" => engine, "value" => value})
       when is_binary(engine) and is_binary(value) do
    %ResumeToken{engine: engine, value: value}
  end

  defp normalize_resume_token(_), do: nil

  @spec extract_completed_ok_and_error(LemonCore.Event.t() | term()) :: {boolean(), term()}
  defp extract_completed_ok_and_error(event) do
    ok = extract_from_completed_or_payload(event, :ok)

    if is_boolean(ok) do
      error = extract_from_completed_or_payload(event, :error)
      {ok, error}
    else
      {true, nil}
    end
  end

  # Produce a safe, bounded label for introspection error payloads.
  # Avoids leaking raw term dumps, stacktraces, or secrets.
  @spec safe_error_label(term()) :: String.t() | nil
  defp safe_error_label(nil), do: nil
  defp safe_error_label(err) when is_atom(err), do: Atom.to_string(err)
  defp safe_error_label(err) when is_binary(err), do: String.slice(err, 0, 80)

  defp safe_error_label(%{__exception__: true} = err),
    do: err.__struct__ |> Module.split() |> Enum.join(".") |> String.slice(0, 80)

  defp safe_error_label({tag, _detail}) when is_atom(tag), do: Atom.to_string(tag)
  defp safe_error_label(_), do: "unknown_error"

  @spec extract_completed_usage(LemonCore.Event.t() | term()) :: map() | nil
  defp extract_completed_usage(event) do
    case extract_from_completed_or_payload(event, :usage) do
      usage when is_map(usage) -> usage
      _ -> nil
    end
  end

  defp maybe_reset_resume_on_context_overflow(state, %LemonCore.Event{} = event) do
    case extract_completed_ok_and_error(event) do
      {false, err} ->
        if context_length_exceeded_error?(err) do
          Logger.warning(
            "RunProcess context overflow run_id=#{inspect(state.run_id)} session_key=#{inspect(state.session_key)} " <>
              "error=#{inspect(err)}"
          )

          # Clear generic chat-state resume for all sessions so the next run can start fresh.
          _ = safe_delete_chat_state(state.session_key)

          # Mark a generic pending compaction for any channel type.
          LemonCore.Store.put(:pending_compaction, state.session_key, %{
            reason: "overflow",
            session_key: state.session_key,
            set_at_ms: System.system_time(:millisecond)
          })

          # Telegram-specific: reset resume state and mark Telegram pending compaction.
          reset_telegram_resume_state(state.session_key)
          mark_telegram_pending_compaction(state.session_key, :overflow)
        end

      _ ->
        :ok
    end

    :ok
  rescue
    _ -> :ok
  end

  defp maybe_reset_resume_on_context_overflow(_state, _event), do: :ok

  defp maybe_mark_pending_compaction_near_limit(state, %LemonCore.Event{} = event) do
    with {true, _} <- extract_completed_ok_and_error(event),
         usage when is_map(usage) <- extract_completed_usage(event),
         input_tokens when is_integer(input_tokens) and input_tokens > 0 <-
           usage_input_tokens(usage),
         cfg <- preemptive_compaction_config(state.session_key),
         true <- cfg.enabled,
         context_window when is_integer(context_window) and context_window > 0 <-
           resolve_preemptive_compaction_context_window(state, event, cfg),
         threshold when is_integer(threshold) and threshold > 0 <-
           preemptive_compaction_threshold(
             context_window,
             cfg.reserve_tokens,
             cfg.trigger_ratio
           ),
         true <- input_tokens >= threshold do
      Logger.warning(
        "RunProcess pending compaction marker run_id=#{inspect(state.run_id)} " <>
          "session_key=#{inspect(state.session_key)} input_tokens=#{input_tokens} " <>
          "threshold=#{threshold} context_window=#{context_window}"
      )

      compaction_details = %{
        input_tokens: input_tokens,
        threshold_tokens: threshold,
        context_window_tokens: context_window
      }

      # Generic compaction marker for all session types
      LemonCore.Store.put(:pending_compaction, state.session_key, %{
        reason: "near_limit",
        session_key: state.session_key,
        set_at_ms: System.system_time(:millisecond),
        input_tokens: input_tokens,
        threshold_tokens: threshold,
        context_window_tokens: context_window
      })

      # Telegram-specific compaction marker (preserves existing behavior)
      mark_telegram_pending_compaction(
        state.session_key,
        :near_limit,
        compaction_details
      )
    else
      _ -> :ok
    end

    :ok
  rescue
    _ -> :ok
  end

  defp maybe_mark_pending_compaction_near_limit(_state, _event), do: :ok

  @spec context_length_exceeded_error?(term()) :: boolean()
  defp context_length_exceeded_error?(err) do
    text =
      cond do
        is_binary(err) ->
          err

        is_atom(err) ->
          Atom.to_string(err)

        true ->
          inspect(err, limit: 200, printable_limit: 8_000)
      end
      |> String.downcase()

    Enum.any?(@context_overflow_error_markers, &String.contains?(text, &1))
  rescue
    _ -> false
  end

  defp reset_telegram_resume_state(session_key) when is_binary(session_key) do
    with %{kind: :channel_peer, channel_id: "telegram"} = parsed <-
           ChannelContext.parse_session_key(session_key) do
      account_id = normalize_telegram_account_id(parsed)

      chat_id = ChannelContext.parse_int(parsed.peer_id)
      thread_id = ChannelContext.parse_int(parsed.thread_id)

      _ = safe_delete_chat_state(session_key)

      if is_integer(chat_id) do
        _ = safe_delete_selected_resume(account_id, chat_id, thread_id)
        _ = safe_clear_thread_index(:telegram_msg_session, account_id, chat_id, thread_id)
        _ = safe_clear_thread_index(:telegram_msg_resume, account_id, chat_id, thread_id)
      end

      Logger.warning(
        "Reset Telegram resume state after context_length_exceeded for session_key=#{inspect(session_key)}"
      )
    else
      _ -> :ok
    end

    :ok
  rescue
    _ -> :ok
  end

  defp reset_telegram_resume_state(_), do: :ok

  defp mark_telegram_pending_compaction(session_key, reason) when is_binary(session_key) do
    mark_telegram_pending_compaction(session_key, reason, %{})
  end

  defp mark_telegram_pending_compaction(_session_key, _reason), do: :ok

  defp mark_telegram_pending_compaction(session_key, reason, details)
       when is_binary(session_key) and is_map(details) do
    with %{kind: :channel_peer, channel_id: "telegram"} = parsed <-
           ChannelContext.parse_session_key(session_key) do
      account_id = normalize_telegram_account_id(parsed)

      chat_id = ChannelContext.parse_int(parsed.peer_id)
      thread_id = ChannelContext.parse_int(parsed.thread_id)

      if is_integer(chat_id) and Code.ensure_loaded?(LemonCore.Store) and
           function_exported?(LemonCore.Store, :put, 3) do
        payload =
          %{
            reason: to_string(reason || "unknown"),
            session_key: session_key,
            set_at_ms: System.system_time(:millisecond)
          }
          |> Map.merge(compaction_marker_details(details))

        LemonCore.Store.put(
          :telegram_pending_compaction,
          {account_id, chat_id, thread_id},
          payload
        )
      end
    else
      _ -> :ok
    end

    :ok
  rescue
    _ -> :ok
  end

  defp mark_telegram_pending_compaction(_session_key, _reason, _details), do: :ok

  defp normalize_telegram_account_id(parsed) do
    case parsed.account_id do
      account when is_binary(account) and account != "" -> account
      _ -> "default"
    end
  end

  @spec usage_input_tokens(map() | term()) :: non_neg_integer() | nil
  defp usage_input_tokens(usage) when is_map(usage) do
    {primary_key, primary_tokens} = find_primary_token_count(usage)
    cached_tokens = sum_cached_tokens(usage)
    compute_total_input_tokens(primary_key, primary_tokens, cached_tokens)
  rescue
    _ -> nil
  end

  defp usage_input_tokens(_), do: nil

  @primary_token_keys [:input_tokens, :input, :prompt_tokens]
  @cached_token_keys [:cached_input_tokens, :cache_read_input_tokens, :cache_creation_input_tokens]

  @spec find_primary_token_count(map()) :: {atom() | nil, non_neg_integer() | nil}
  defp find_primary_token_count(usage) do
    Enum.find_value(@primary_token_keys, {nil, nil}, fn key ->
      case maybe_parse_positive_int(fetch(usage, key)) do
        value when is_integer(value) -> {key, value}
        _ -> nil
      end
    end)
  end

  @spec sum_cached_tokens(map()) :: non_neg_integer()
  defp sum_cached_tokens(usage) do
    Enum.reduce(@cached_token_keys, 0, fn key, acc ->
      case maybe_parse_positive_int(fetch(usage, key)) do
        value when is_integer(value) -> acc + value
        _ -> acc
      end
    end)
  end

  @spec compute_total_input_tokens(atom() | nil, non_neg_integer() | nil, non_neg_integer()) ::
          non_neg_integer() | nil
  defp compute_total_input_tokens(key, tokens, cached) when is_integer(tokens) and key in [:input_tokens, :input],
    do: tokens + cached

  defp compute_total_input_tokens(_key, tokens, _cached) when is_integer(tokens), do: tokens
  defp compute_total_input_tokens(_key, _tokens, cached) when cached > 0, do: cached
  defp compute_total_input_tokens(_key, _tokens, _cached), do: nil

  @spec maybe_parse_positive_int(term()) :: pos_integer() | nil
  defp maybe_parse_positive_int(value) when is_integer(value) and value > 0, do: value

  defp maybe_parse_positive_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp maybe_parse_positive_int(_), do: nil

  defp preemptive_compaction_config(session_key) when is_binary(session_key) do
    channel_cfg =
      case ChannelContext.parse_session_key(session_key) do
        %{channel_id: channel_id} when is_binary(channel_id) and channel_id != "" ->
          try do
            channel_atom = String.to_existing_atom(channel_id)
            LemonChannels.GatewayConfig.get(channel_atom, %{}) || %{}
          rescue
            _ -> %{}
          end

        _ ->
          %{}
      end

    channel_cfg = normalize_map(channel_cfg)
    cfg = fetch(channel_cfg, :compaction) |> normalize_map()

    enabled =
      case fetch(cfg, :enabled) do
        nil -> true
        value -> truthy?(value)
      end

    %{
      enabled: enabled,
      context_window_tokens: positive_int_or(fetch(cfg, :context_window_tokens), nil),
      reserve_tokens:
        positive_int_or(fetch(cfg, :reserve_tokens), default_compaction_reserve_tokens()),
      trigger_ratio:
        compaction_trigger_ratio_or(
          fetch(cfg, :trigger_ratio),
          @default_preemptive_compaction_trigger_ratio
        )
    }
  rescue
    _ ->
      %{
        enabled: true,
        context_window_tokens: nil,
        reserve_tokens: default_compaction_reserve_tokens(),
        trigger_ratio: @default_preemptive_compaction_trigger_ratio
      }
  end

  defp preemptive_compaction_config(_session_key) do
    %{
      enabled: true,
      context_window_tokens: nil,
      reserve_tokens: default_compaction_reserve_tokens(),
      trigger_ratio: @default_preemptive_compaction_trigger_ratio
    }
  rescue
    _ ->
      %{
        enabled: true,
        context_window_tokens: nil,
        reserve_tokens: @default_compaction_reserve_tokens,
        trigger_ratio: @default_preemptive_compaction_trigger_ratio
      }
  end

  defp default_compaction_reserve_tokens do
    case LemonCore.Config.cached() do
      %{agent: agent_cfg} when is_map(agent_cfg) ->
        agent_cfg
        |> fetch(:compaction)
        |> normalize_map()
        |> fetch(:reserve_tokens)
        |> positive_int_or(@default_compaction_reserve_tokens)

      _ ->
        @default_compaction_reserve_tokens
    end
  rescue
    _ -> @default_compaction_reserve_tokens
  end

  defp resolve_preemptive_compaction_context_window(state, event, cfg) when is_map(cfg) do
    cfg.context_window_tokens ||
      resolve_context_window_from_model(state) ||
      resolve_context_window_from_engine(state, event)
  end

  defp resolve_preemptive_compaction_context_window(_state, _event, _cfg), do: nil

  defp resolve_context_window_from_model(state) when is_map(state) do
    model =
      state
      |> Map.get(:job)
      |> case do
        %LemonGateway.Types.Job{meta: meta} when is_map(meta) -> fetch(meta, :model)
        _ -> nil
      end

    model_context_window(model)
  rescue
    _ -> nil
  end

  defp resolve_context_window_from_model(_), do: nil

  defp model_context_window(model) when is_binary(model) do
    model
    |> model_lookup_candidates()
    |> Enum.find_value(fn candidate ->
      if Code.ensure_loaded?(Ai.Models) and function_exported?(Ai.Models, :find_by_id, 1) do
        case Ai.Models.find_by_id(candidate) do
          %{context_window: cw} when is_integer(cw) and cw > 0 -> cw
          _ -> nil
        end
      else
        nil
      end
    end)
  rescue
    _ -> nil
  end

  defp model_context_window(_), do: nil

  defp model_lookup_candidates(model) when is_binary(model) do
    trimmed = String.trim(model)

    after_colon =
      case String.split(trimmed, ":", parts: 2) do
        [_prefix, rest] -> rest
        _ -> nil
      end

    after_slash =
      case String.split(trimmed, "/", parts: 2) do
        [_prefix, rest] -> rest
        _ -> nil
      end

    nested_after_colon_slash =
      case after_colon do
        value when is_binary(value) ->
          case String.split(value, "/", parts: 2) do
            [_prefix, rest] -> rest
            _ -> nil
          end

        _ ->
          nil
      end

    [trimmed, after_colon, after_slash, nested_after_colon_slash]
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.uniq()
  end

  defp model_lookup_candidates(_), do: []

  defp resolve_context_window_from_engine(state, event) do
    engine =
      extract_completed_engine(event) ||
        case Map.get(state, :job) do
          %LemonGateway.Types.Job{} = job ->
            job.engine_id

          _ ->
            nil
        end

    engine_text = String.downcase(to_string(engine || ""))
    if String.contains?(engine_text, "codex"), do: @default_codex_context_window_tokens, else: nil
  rescue
    _ -> nil
  end

  @spec extract_completed_engine(LemonCore.Event.t() | term()) :: binary() | nil
  defp extract_completed_engine(event) do
    case extract_from_completed_or_payload(event, :engine) do
      engine when is_binary(engine) and engine != "" -> engine
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp preemptive_compaction_threshold(context_window, reserve_tokens, trigger_ratio)
       when is_integer(context_window) and context_window > 0 and is_integer(reserve_tokens) and
              reserve_tokens > 0 and is_float(trigger_ratio) and trigger_ratio > 0.0 do
    reserve_threshold = max(context_window - reserve_tokens, 1)
    ratio_threshold = max(trunc(context_window * trigger_ratio), 1)
    min(reserve_threshold, ratio_threshold)
  end

  defp preemptive_compaction_threshold(_context_window, _reserve_tokens, _trigger_ratio), do: nil

  defp compaction_trigger_ratio_or(value, _default)
       when is_float(value) and value > 0.0 and value <= 1.0 do
    value
  end

  defp compaction_trigger_ratio_or(value, _default)
       when is_integer(value) and value > 0 and value <= 1 do
    value * 1.0
  end

  defp compaction_trigger_ratio_or(value, _default)
       when is_integer(value) and value > 1 and value <= 100 do
    value / 100.0
  end

  defp compaction_trigger_ratio_or(value, default) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _} when parsed > 0.0 and parsed <= 1.0 ->
        parsed

      {parsed, _} when parsed > 1.0 and parsed <= 100.0 ->
        parsed / 100.0

      _ ->
        default
    end
  end

  defp compaction_trigger_ratio_or(_value, default), do: default

  defp compaction_marker_details(details) when is_map(details) do
    Enum.reduce(details, %{}, fn
      {_key, nil}, acc ->
        acc

      {key, value}, acc when is_atom(key) or is_binary(key) ->
        Map.put(acc, key, value)

      _, acc ->
        acc
    end)
  end

  defp compaction_marker_details(_), do: %{}

  defp safe_delete_chat_state(key), do: LemonCore.Store.delete_chat_state(key)

  defp safe_delete_selected_resume(account_id, chat_id, thread_id)
       when is_binary(account_id) and is_integer(chat_id) do
    LemonCore.Store.delete(:telegram_selected_resume, {account_id, chat_id, thread_id})

    :ok
  rescue
    _ -> :ok
  end

  defp safe_delete_selected_resume(_account_id, _chat_id, _thread_id), do: :ok

  defp safe_clear_thread_index(table, account_id, chat_id, thread_id)
       when is_atom(table) and is_binary(account_id) and is_integer(chat_id) do
    LemonCore.Store.list(table)
    |> Enum.each(fn
      {{acc, cid, tid, _msg_id} = key, _value}
      when acc == account_id and cid == chat_id and tid == thread_id ->
        _ = LemonCore.Store.delete(table, key)

      _ ->
        :ok
    end)

    :ok
  rescue
    _ -> :ok
  end

  defp safe_clear_thread_index(_table, _account_id, _chat_id, _thread_id), do: :ok

  defp maybe_retry_zero_answer_failure(state, %LemonCore.Event{} = event) do
    with {:retry, %RunRequest{} = request, error_text, attempt} <-
           build_zero_answer_retry_request(state, event),
         {:ok, retry_run_id} <- submit_retry_request(state.run_orchestrator, request) do
      Logger.warning(
        "RunProcess #{state.run_id} auto-retrying empty-answer failure " <>
          "(attempt=#{attempt}/#{@zero_answer_retry_max_attempts}) " <>
          "new_run_id=#{inspect(retry_run_id)} reason=#{error_text}"
      )

      true
    else
      :skip ->
        false

      {:error, reason} ->
        Logger.warning(
          "RunProcess #{state.run_id} auto-retry submission failed: #{inspect(reason)}"
        )

        false
    end
  rescue
    error ->
      Logger.warning("RunProcess #{state.run_id} auto-retry crashed: #{Exception.message(error)}")

      false
  end

  defp build_zero_answer_retry_request(state, %LemonCore.Event{} = event) do
    {ok?, error} = extract_completed_ok_and_error(event)
    answer = extract_completed_answer(event)
    meta = normalize_retry_meta(state.job.meta)
    prior_attempt = retry_attempt_from_meta(meta)
    prompt = state.job.prompt

    cond do
      ok? == true ->
        :skip

      not empty_answer?(answer) ->
        :skip

      not retryable_zero_answer_error?(error) ->
        :skip

      not (is_binary(prompt) and String.trim(prompt) != "") ->
        :skip

      prior_attempt >= @zero_answer_retry_max_attempts ->
        :skip

      true ->
        attempt = prior_attempt + 1
        reason_text = format_run_error(error)

        retry_meta =
          meta
          |> Map.put(:zero_answer_retry_attempt, attempt)
          |> Map.put(:zero_answer_retry_of_run, state.run_id)
          |> Map.put(:zero_answer_retry_reason, reason_text)

        retry_prompt = build_zero_answer_retry_prompt(prompt, state.run_id, reason_text)

        request =
          RunRequest.new(%{
            origin: retry_origin_from_meta(meta),
            session_key: state.session_key,
            agent_id: SessionKey.agent_id(state.session_key || "") || "default",
            prompt: retry_prompt,
            queue_mode: state.job.queue_mode,
            engine_id: state.job.engine_id,
            cwd: state.job.cwd,
            tool_policy: state.job.tool_policy,
            meta: retry_meta
          })

        {:retry, request, reason_text, attempt}
    end
  end

  defp submit_retry_request(run_orchestrator, %RunRequest{} = request) do
    cond do
      function_exported?(run_orchestrator, :submit, 1) ->
        run_orchestrator.submit(request)

      function_exported?(run_orchestrator, :submit_run, 1) ->
        run_orchestrator.submit_run(request)

      true ->
        {:error, :run_orchestrator_unavailable}
    end
  end

  defp normalize_retry_meta(meta) when is_map(meta), do: meta
  defp normalize_retry_meta(_), do: %{}

  defp retry_attempt_from_meta(meta) when is_map(meta) do
    case fetch(meta, :zero_answer_retry_attempt) do
      attempt when is_integer(attempt) and attempt >= 0 -> attempt
      _ -> 0
    end
  end

  defp retry_origin_from_meta(meta) when is_map(meta) do
    fetch(meta, :origin) || :unknown
  end

  defp empty_answer?(answer) when is_binary(answer), do: String.trim(answer) == ""
  defp empty_answer?(_), do: true

  defp retryable_zero_answer_error?(error)
       when error in [:user_requested, :interrupted, :new_session, :timeout],
       do: false

  defp retryable_zero_answer_error?({:assistant_error, reason}) do
    not context_length_exceeded_error?(reason)
  end

  defp retryable_zero_answer_error?(error) when is_binary(error) do
    down = String.downcase(error)

    (String.contains?(down, "assistant_error") or String.contains?(down, "assistant error")) and
      not context_length_exceeded_error?(error)
  end

  defp retryable_zero_answer_error?(error) when is_map(error) do
    text = error |> inspect(limit: 50, printable_limit: 2_000) |> String.downcase()

    (String.contains?(text, "assistant_error") or String.contains?(text, "assistant error")) and
      not context_length_exceeded_error?(error)
  end

  defp retryable_zero_answer_error?(_), do: false

  defp build_zero_answer_retry_prompt(prompt, failed_run_id, reason_text)
       when is_binary(prompt) and is_binary(reason_text) do
    @zero_answer_retry_prefix <>
      "\nPrevious run: #{failed_run_id}\nFailure: #{reason_text}\n\n" <>
      "Original request:\n" <>
      prompt
  end

  defp format_run_error(nil), do: "unknown error"

  defp format_run_error({:assistant_error, msg}) when is_binary(msg),
    do: format_assistant_error(msg)

  defp format_run_error({:assistant_error, reason}), do: "assistant error: #{inspect(reason)}"
  defp format_run_error(e) when is_binary(e), do: e
  defp format_run_error(e) when is_atom(e), do: Atom.to_string(e)
  defp format_run_error(e), do: inspect(e)

  defp format_assistant_error(msg) when is_binary(msg) do
    down = String.downcase(msg)

    cond do
      String.contains?(down, "bad_record_mac") or
          (String.contains?(down, "req.transporterror") and String.contains?(down, "tls_alert")) ->
        "temporary TLS/network error while contacting the model provider; please retry"

      true ->
        msg
    end
  end

  defp maybe_finalize_stream_output(state, %LemonCore.Event{} = event) do
    with %{kind: :channel_peer, channel_id: "telegram"} <-
           ChannelContext.parse_session_key(state.session_key) do
      meta = ChannelContext.coalescer_meta_from_job(state.job)
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
      meta = maybe_add_auto_send_generated_files(meta, state)

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
    case ChannelContext.channel_id(state.session_key) do
      {:ok, channel_id} ->
        ok? =
          case event.payload do
            %{completed: %{ok: ok}} -> ok == true
            %{ok: ok} -> ok == true
            _ -> false
          end

        meta = ChannelContext.coalescer_meta_from_job(state.job)

        LemonRouter.ToolStatusCoalescer.finalize_run(
          state.session_key,
          channel_id,
          state.run_id,
          ok?,
          meta: meta
        )

      _ ->
        :ok
    end

    :ok
  rescue
    _ -> :ok
  end

  defp ingest_action_to_tool_status_coalescer(state, action_ev) do
    case ChannelContext.channel_id(state.session_key) do
      {:ok, channel_id} ->
        meta = ChannelContext.coalescer_meta_from_job(state.job)

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
    case ChannelContext.channel_id(state.session_key) do
      {:ok, channel_id} ->
        LemonRouter.StreamCoalescer.flush(state.session_key, channel_id)
        LemonRouter.ToolStatusCoalescer.flush(state.session_key, channel_id)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp flush_tool_status(state) do
    case ChannelContext.channel_id(state.session_key) do
      {:ok, channel_id} ->
        LemonRouter.ToolStatusCoalescer.flush(state.session_key, channel_id)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp maybe_track_generated_images(state, action_ev) do
    paths = extract_generated_image_paths(action_ev)

    if paths == [] do
      state
    else
      existing = state.generated_image_paths || []
      %{state | generated_image_paths: merge_paths(existing, paths)}
    end
  end

  defp maybe_track_requested_send_files(state, action_ev) do
    files = extract_requested_send_files(action_ev)

    if files == [] do
      state
    else
      existing = state.requested_send_files || []
      %{state | requested_send_files: merge_files(existing, files)}
    end
  end

  defp merge_paths(existing, new_paths) do
    Enum.uniq(existing ++ new_paths)
  end
  defp extract_requested_send_files(action_ev) do
    action = fetch(action_ev, :action)
    phase = fetch(action_ev, :phase)
    ok = fetch(action_ev, :ok)

    cond do
      not phase_completed?(phase) ->
        []

      ok == false ->
        []

      true ->
        detail = fetch(action, :detail)
        result_meta = fetch(detail, :result_meta)
        auto_send_files = fetch(result_meta, :auto_send_files)

        case auto_send_files do
          files when is_list(files) ->
            files
            |> Enum.map(&normalize_requested_send_file/1)
            |> Enum.reject(&is_nil/1)

          _ ->
            []
        end
    end
  end

  defp normalize_requested_send_file(file) when is_map(file) do
    path = fetch(file, :path)
    filename = fetch(file, :filename)
    caption = fetch(file, :caption)

    if is_binary(path) and path != "" do
      %{
        path: path,
        filename:
          case filename do
            x when is_binary(x) and x != "" -> x
            _ -> Path.basename(path)
          end,
        caption:
          case caption do
            x when is_binary(x) and x != "" -> x
            _ -> nil
          end
      }
    else
      nil
    end
  end

  defp normalize_requested_send_file(_), do: nil

  defp extract_generated_image_paths(action_ev) do
    action = fetch(action_ev, :action)
    kind = fetch(action, :kind)
    phase = fetch(action_ev, :phase)
    ok = fetch(action_ev, :ok)

    cond do
      not file_change_kind?(kind) ->
        []

      not phase_completed?(phase) ->
        []

      ok == false ->
        []

      true ->
        detail = fetch(action, :detail)

        case fetch(detail, :changes) do
          changes when is_list(changes) ->
            changes
            |> Enum.flat_map(fn change ->
              case extract_image_change_path(change) do
                nil -> []
                path -> [path]
              end
            end)

          _ ->
            []
        end
    end
  end

  defp extract_image_change_path(change) do
    path = fetch(change, :path)
    kind = fetch(change, :kind)

    cond do
      not is_binary(path) or path == "" ->
        nil

      deleted_change_kind?(kind) ->
        nil

      not image_path?(path) ->
        nil

      true ->
        path
    end
  end

  defp file_change_kind?(kind) when kind in [:file_change, "file_change"], do: true
  defp file_change_kind?(_), do: false

  defp phase_completed?(phase) when phase in [:completed, "completed"], do: true
  defp phase_completed?(_), do: false

  defp deleted_change_kind?(kind) when kind in [:deleted, "deleted", :remove, "remove"], do: true
  defp deleted_change_kind?(_), do: false

  @spec image_path?(term()) :: boolean()
  defp image_path?(path) when is_binary(path),
    do: path |> Path.extname() |> String.downcase() |> then(&MapSet.member?(@image_extensions, &1))

  defp image_path?(_), do: false

  defp maybe_add_auto_send_generated_files(meta, state) when is_map(meta) do
    explicit_files =
      state.requested_send_files
      |> resolve_explicit_send_files(state.job && state.job.cwd)

    cfg = telegram_auto_send_generated_config()

    generated_files =
      if cfg.enabled do
        state.generated_image_paths
        |> select_recent_paths(cfg.max_files)
        |> resolve_generated_files(state.job && state.job.cwd, cfg.max_bytes)
      else
        []
      end

    files = merge_files(explicit_files, generated_files)

    if files == [] do
      meta
    else
      Map.put(meta, :auto_send_files, files)
    end
  end

  defp maybe_add_auto_send_generated_files(meta, _state), do: meta

  defp select_recent_paths(paths, max_files) when is_list(paths) and is_integer(max_files) do
    if max_files > 0 and length(paths) > max_files do
      Enum.take(paths, -max_files)
    else
      paths
    end
  end

  defp select_recent_paths(paths, _max_files), do: paths

  defp resolve_generated_files(paths, cwd, max_bytes) when is_list(paths) do
    paths
    |> Enum.map(&resolve_generated_path(&1, cwd))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.flat_map(fn path ->
      case file_within_limit(path, max_bytes) do
        {:ok, file} -> [file]
        _ -> []
      end
    end)
  end

  defp resolve_generated_files(_, _cwd, _max_bytes), do: []

  defp resolve_explicit_send_files(files, cwd) when is_list(files) do
    max_bytes = telegram_files_max_download_bytes()

    files
    |> Enum.map(&resolve_explicit_send_file(&1, cwd, max_bytes))
    |> Enum.reject(&is_nil/1)
  end

  defp resolve_explicit_send_files(_, _cwd), do: []

  defp resolve_explicit_send_file(file, cwd, max_bytes) when is_map(file) do
    path = fetch(file, :path)
    caption = fetch(file, :caption)
    filename = fetch(file, :filename)

    resolved_path = resolve_file_path(path, cwd)

    with path when is_binary(path) and path != "" <- path,
         resolved when is_binary(resolved) <- resolved_path,
         {:ok, %{path: valid_path}} <- file_within_limit(resolved, max_bytes) do
      %{
        path: valid_path,
        filename:
          case filename do
            x when is_binary(x) and x != "" -> x
            _ -> Path.basename(valid_path)
          end,
        caption:
          case caption do
            x when is_binary(x) and x != "" -> x
            _ -> nil
          end
      }
    else
      _ -> nil
    end
  end

  defp resolve_explicit_send_file(_, _cwd, _max_bytes), do: nil

  defp resolve_file_path(path, cwd) do
    cond do
      is_binary(cwd) and cwd != "" ->
        resolve_generated_path(path, cwd) || absolute_path_or_nil(path)

      is_binary(path) and Path.type(path) == :absolute ->
        Path.expand(path)

      true ->
        nil
    end
  end

  defp absolute_path_or_nil(path) do
    if is_binary(path) and Path.type(path) == :absolute, do: Path.expand(path)
  end

  defp resolve_generated_path(path, _cwd) when not is_binary(path), do: nil

  defp resolve_generated_path(path, cwd) when is_binary(cwd) and cwd != "" do
    root = Path.expand(cwd)

    absolute =
      if Path.type(path) == :absolute do
        Path.expand(path)
      else
        Path.expand(path, root)
      end

    if path_within_root?(absolute, root) do
      absolute
    else
      nil
    end
  end

  defp resolve_generated_path(_path, _cwd), do: nil

  defp merge_files(first, second) when is_list(first) and is_list(second) do
    {merged, _seen} =
      Enum.reduce(first ++ second, {[], MapSet.new()}, fn file, {acc, seen} ->
        key = {Map.get(file, :path), Map.get(file, :caption)}

        if MapSet.member?(seen, key) do
          {acc, seen}
        else
          {[file | acc], MapSet.put(seen, key)}
        end
      end)

    Enum.reverse(merged)
  end

  defp merge_files(first, second) when is_list(first), do: first ++ List.wrap(second)
  defp merge_files(_first, second) when is_list(second), do: second
  defp merge_files(_, _), do: []

  defp path_within_root?(absolute, root) when is_binary(absolute) and is_binary(root) do
    rel = Path.relative_to(absolute, root)
    rel == "." or not String.starts_with?(rel, "..")
  end

  defp file_within_limit(path, max_bytes) when is_binary(path) and is_integer(max_bytes) do
    with true <- File.regular?(path),
         {:ok, %File.Stat{size: size}} <- File.stat(path),
         true <- size <= max_bytes do
      {:ok, %{path: path, filename: Path.basename(path), caption: nil}}
    else
      _ -> :error
    end
  end

  defp file_within_limit(_path, _max_bytes), do: :error

  defp telegram_auto_send_generated_config do
    telegram_cfg = LemonChannels.GatewayConfig.get(:telegram, %{}) || %{}

    telegram_cfg = normalize_map(telegram_cfg)

    files_cfg = fetch(telegram_cfg, :files)
    files_cfg = normalize_map(files_cfg)

    enabled? =
      truthy?(fetch(files_cfg, :enabled)) and
        truthy?(fetch(files_cfg, :auto_send_generated_images))

    %{
      enabled: enabled?,
      max_files:
        positive_int_or(
          fetch(files_cfg, :auto_send_generated_max_files),
          @default_auto_send_generated_max_files
        ),
      max_bytes:
        positive_int_or(fetch(files_cfg, :max_download_bytes), @default_max_download_bytes)
    }
  rescue
    _ ->
      %{
        enabled: false,
        max_files: @default_auto_send_generated_max_files,
        max_bytes: @default_max_download_bytes
      }
  end

  defp fetch(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Map.get(map, Atom.to_string(key))
    end
  end

  defp fetch(_, _), do: nil

  @spec normalize_map(term()) :: map()
  defp normalize_map(value) when is_map(value), do: value

  defp normalize_map(value) when is_list(value) do
    if Keyword.keyword?(value) do
      Enum.into(value, %{})
    else
      %{}
    end
  end

  defp normalize_map(_), do: %{}

  @spec truthy?(term()) :: boolean()
  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_), do: false

  @spec positive_int_or(term(), term()) :: pos_integer() | term()
  defp positive_int_or(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_int_or(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp positive_int_or(_value, default), do: default

  defp telegram_files_max_download_bytes do
    telegram_cfg = LemonChannels.GatewayConfig.get(:telegram, %{}) || %{}

    telegram_cfg = normalize_map(telegram_cfg)
    files_cfg = fetch(telegram_cfg, :files) |> normalize_map()

    positive_int_or(fetch(files_cfg, :max_download_bytes), @default_max_download_bytes)
  rescue
    _ -> @default_max_download_bytes
  end

  # Unsubscribe control-plane EventBridge from run events
  defp unsubscribe_event_bridge(run_id) do
    LemonCore.EventBridge.unsubscribe_run(run_id)
  end

  @spec scheduler_available?(term()) :: boolean()
  defp scheduler_available?(scheduler) do
    case GenServer.whereis(scheduler) do
      pid when is_pid(pid) -> true
      _ -> false
    end
  end

  @spec gateway_submit_retry_delay_ms(non_neg_integer()) :: non_neg_integer()
  defp gateway_submit_retry_delay_ms(attempt) when is_integer(attempt) and attempt >= 0 do
    exponential = @gateway_submit_retry_base_ms * :math.pow(2, attempt)
    delay_ms = round(exponential)
    min(delay_ms, @gateway_submit_retry_max_ms)
  end
end
