defmodule LemonRouter.RunProcess do
  @moduledoc """
  Process that owns a single run lifecycle.

  `RunProcess` expects a router-built `%LemonCore.ExecutionCommand{}` at init
  time. Router-owned conversation identity must already be resolved before this
  process submits work into the configured runtime.

  Each RunProcess:
  - Owns a run_id and its unique SessionRegistry key, released on process death
  - Manages abort state
  - Subscribes to Bus for run events
  - Maintains metadata snapshot
  - Emits router-level events
  - Bounds pre-start runtime submission retries with a terminal watchdog

  Heavy logic is delegated to focused submodules:
  - `RunProcess.Watchdog` -- idle-run state timeout and confirmation policy
  - `RunProcess.CompactionTrigger` -- context-overflow & compaction markers
  - `RunProcess.RetryHandler` -- zero-answer auto-retry
  - `LemonRouter.SurfaceManager` -- semantic answer/status coordination and fanout
  - `RunProcess.ArtifactTracker` -- generated file tracking and answer metadata enrichment
  - `LemonRouter.MediaJobRecorder` -- generated media delivery metadata recording

  ## Lifecycle transitions

  | State | Event | Next state / timeout |
  | --- | --- | --- |
  | submitting | runtime unavailable or engine session busy | submitting / named retry; deadline unchanged |
  | submitting | submission accepted | awaiting start / submission timers cancelled, gateway run monitored |
  | submitting | outcome unknown | awaiting start / gateway run adopted, bind grace if it is not found |
  | submitting | deadline, definite rejection or activation refusal | completing / one synthetic completion |
  | awaiting start | run started | running / idle state timeout |
  | awaiting start | gateway run DOWN | completion grace / named timeout |
  | running or confirming idle | output, action, keepalive | running / fresh idle timeout |
  | running | idle expiry | confirming idle, or aborting if no prompt can be delivered |
  | confirming idle | confirmation expiry or cancel | aborting / gateway cancel with the real reason |
  | active | abort or restart boundary | aborting / bounded missing-executor grace |
  | active or aborting | executor DOWN/missing | completion grace / named timeout |
  | any | run completed | stopped normally |

  Gateway bind, DOWN and abort grace periods are independent named timeouts.
  Metadata calls and unrelated events never restart them or the idle deadline.
  `:completing` prevents duplicate synthetic publication while the retained
  terminal event travels through the bus. No timer references or lifecycle
  booleans are retained in process data. Terminal evidence retention follows
  answer delivery and is best-effort: the durable run summary stays the
  authority, and boot reconciliation re-derives the evidence.
  """

  @behaviour :gen_statem

  @impl true
  def format_status(status) do
    LemonCore.StatusRedaction.gen_statem(status, [:run_id, :session_key, :queue_mode])
  end

  require Logger

  alias LemonCore.{Bus, Events, ExecutionCommand, Introspection}
  alias LemonRouter.MediaJobRecorder
  alias LemonRouter.RunProcess.{ArtifactTracker, CompactionTrigger, RetryHandler, Watchdog}
  alias LemonRouter.SurfaceManager

  @gateway_submit_retry_base_ms 100
  @gateway_submit_retry_max_ms 2_000
  @gateway_submit_deadline_ms 30_000
  @abort_completion_grace_ms 150
  @gateway_bind_grace_ms 200
  @gateway_missing_completion_grace_ms 1_500

  def start_link(opts) do
    run_id = opts[:run_id]

    session_key =
      case opts[:execution_request] do
        %ExecutionCommand{session_key: request_session_key} -> request_session_key
        _ -> opts[:session_key]
      end

    :gen_statem.start_link(via_tuple(run_id, session_key), __MODULE__, opts, [])
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

  defp via_tuple(run_id, session_key) do
    # Lifecycle-owned run index; session ownership is registered in init.
    {:via, Registry, {LemonRouter.RunRegistry, run_id, %{session_key: session_key}}}
  end

  @doc """
  Abort this run process.
  """
  @spec abort(pid() | binary(), reason :: term()) :: :ok
  def abort(pid_or_run_id, reason \\ :user_requested)

  def abort(pid_or_run_id, reason) when is_pid(pid_or_run_id) do
    :gen_statem.cast(pid_or_run_id, {:abort, reason})
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
    :gen_statem.cast(pid_or_run_id, {:watchdog_keep_alive, decision})
  end

  def keep_alive(pid_or_run_id, decision) when is_binary(pid_or_run_id) do
    case Registry.lookup(LemonRouter.RunRegistry, pid_or_run_id) do
      [{pid, _}] -> keep_alive(pid, decision)
      _ -> :ok
    end
  end

  @doc """
  Ask the run to stop for a runtime restart. It replies to `reply_to` with
  `{:restart_suspended, run_id, outcome, in_flight_titles}` when it aborts:
  `:clean` (no effectful action was executing), `:uncertain` (`mode: :now`
  interrupted one), `:not_started` (the runtime never started it) or
  `:not_running`. With `:boundary` it waits for executing actions to finish.
  """
  @spec suspend_for_restart(pid(), pid(), :boundary | :now) :: :ok
  def suspend_for_restart(pid, reply_to, mode \\ :boundary)
      when is_pid(pid) and is_pid(reply_to) and mode in [:boundary, :now] do
    :gen_statem.cast(pid, {:suspend_for_restart, reply_to, mode})
  end

  @doc false
  defdelegate estimate_input_tokens_from_prompt(state),
    to: CompactionTrigger

  # ---------------------------------------------------------------------------
  # State machine callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def callback_mode, do: :handle_event_function

  @impl true
  def init(opts) do
    run_id = opts[:run_id]
    init_session_key = opts[:session_key]

    engine_runtime =
      opts[:engine_runtime] || opts[:gateway_scheduler] || configured_engine_runtime()

    run_orchestrator = opts[:run_orchestrator] || LemonRouter.RunOrchestrator
    run_watchdog_timeout_ms = Watchdog.resolve_run_watchdog_timeout_ms(opts)
    run_watchdog_confirm_timeout_ms = Watchdog.resolve_run_watchdog_confirm_timeout_ms(opts)
    gateway_submit_deadline_ms = gateway_submit_deadline_ms(opts)

    with %ExecutionCommand{} = request <- opts[:execution_request],
         {:ok, execution_request} <-
           normalize_execution_request(
             request,
             init_session_key,
             opts[:conversation_key],
             run_id
           ),
         {:ok, _owner} <-
           Registry.register(LemonRouter.SessionRegistry, execution_request.session_key, %{
             run_id: run_id,
             conversation_key:
               opts[:conversation_key] || {:session, execution_request.session_key}
           }) do
      session_key = execution_request.session_key
      queue_mode = opts[:queue_mode] || :collect

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
        execution_request: execution_request,
        queue_mode: queue_mode,
        start_ts_ms: LemonCore.Clock.now_ms(),
        saw_delta: false,
        run_started_at_ms: nil,
        run_last_activity_at_ms: nil,
        run_watchdog_timeout_ms: run_watchdog_timeout_ms,
        run_watchdog_confirm_timeout_ms: run_watchdog_confirm_timeout_ms,
        engine_runtime: engine_runtime,
        run_orchestrator: run_orchestrator,
        gateway_submit_attempt: 0,
        gateway_submit_deadline_ms: gateway_submit_deadline_ms,
        gateway_submit_deadline_at_ms:
          System.monotonic_time(:millisecond) + gateway_submit_deadline_ms,
        gateway_submit_last_error: nil,
        gateway_run_pid: nil,
        gateway_run_ref: nil,
        coordinator_pid: opts[:coordinator_pid],
        conversation_key: execution_request.conversation_key,
        generated_image_paths: [],
        requested_send_files: [],
        task_status_surfaces: %{},
        task_status_refs: %{},
        artifact_tracker: opts[:artifact_tracker] || ArtifactTracker,
        effectful_actions: %{},
        restart_suspend: nil,
        abort_reason: nil,
        receipt_store: opts[:receipt_store] || LemonCore.Store
      }

      Logger.debug(
        "RunProcess init run_id=#{inspect(run_id)} session_key=#{inspect(session_key)} " <>
          "queue_mode=#{inspect(queue_mode)} " <>
          "submit_to_gateway?=#{inspect(submit_to_gateway?)}"
      )

      # Emit introspection event for run start
      Introspection.record(
        :run_started,
        %{
          queue_mode: queue_mode
        },
        run_id: run_id,
        session_key: session_key,
        engine: "lemon",
        provenance: :direct
      )

      # Persist the real native owner before it can invoke addressed tools.
      case LemonRouter.AgentMessagingSessions.capture(execution_request) do
        :ok ->
          if submit_to_gateway? do
            {:ok, :submitting, state,
             [
               {:next_event, :internal, :submit_to_gateway},
               {:state_timeout, gateway_submit_deadline_ms, :submission_deadline}
             ]}
          else
            {:ok, :awaiting_start, state}
          end

        {:error, _} ->
          {:stop, :agent_session_context_unavailable}
      end
    else
      {:error, {:already_registered, _pid}} -> {:stop, :session_busy}
      _ -> {:stop, {:invalid_execution_request, run_id}}
    end
  end

  @impl true
  def handle_event({:call, from}, :get_metadata, _phase, state) do
    metadata = %{
      session_key: state.session_key,
      agent_id:
        LemonCore.MapHelpers.get_key(state.execution_request.meta || %{}, :agent_id) ||
          LemonCore.SessionKey.agent_id(state.session_key),
      profile_id: LemonCore.MapHelpers.get_key(state.execution_request.meta || %{}, :profile_id),
      engine: "lemon",
      started_at_ms: state.run_started_at_ms || state.start_ts_ms
    }

    {:keep_state_and_data, [{:reply, from, metadata}]}
  end

  def handle_event(type, :submit_to_gateway, :submitting, state)
      when type == :internal or type == {:timeout, :submission_retry} do
    case LemonRouter.NativeLineage.validate_activation(state.execution_request) do
      :ok ->
        if runtime_available?(state.engine_runtime) do
          case submit_runtime_execution(state.engine_runtime, state) do
            :ok ->
              Logger.debug(
                "RunProcess submitted to gateway run_id=#{inspect(state.run_id)} " <>
                  "session_key=#{inspect(state.session_key)}"
              )

              # The runtime registers the run before acknowledging it, so a
              # run that exits without a completion is noticed even while it
              # waits for execution capacity.
              state = maybe_monitor_gateway_run(%{state | gateway_submit_attempt: 0})
              {:next_state, :awaiting_start, state, [{{:timeout, :submission_retry}, :cancel}]}

            {:error, :runtime_unavailable} ->
              retry_runtime_submission(state, :runtime_unavailable, "Engine runtime unavailable")

            # The previous run of this engine session may still be draining
            # its cancellation; the claim frees when it terminalizes.
            {:error, :session_in_use} ->
              retry_runtime_submission(state, :session_in_use, "Engine session busy")

            {:error, :outcome_unknown} ->
              adopt_ambiguous_submission(state)

            {:error, reason} ->
              terminalize_gateway_submission(%{state | gateway_submit_last_error: reason})
          end
        else
          retry_runtime_submission(state, :runtime_unavailable, "Engine runtime unavailable")
        end

      {:error, reason} ->
        # A failed pre-send fence cannot authorize a retry or a new F.
        terminalize_gateway_submission(%{state | gateway_submit_last_error: reason})
    end
  end

  def handle_event(:state_timeout, :submission_deadline, :submitting, state) do
    Logger.error(
      "RunProcess runtime submission deadline exceeded run_id=#{inspect(state.run_id)} " <>
        "session_key=#{inspect(state.session_key)} attempts=#{state.gateway_submit_attempt} " <>
        "last_error=#{inspect(state.gateway_submit_last_error)}"
    )

    terminalize_gateway_submission(state)
  end

  # Handle run events from Bus.
  def handle_event(:info, %LemonCore.Event{type: :run_started} = event, phase, state) do
    Bus.broadcast(Bus.session_topic(state.session_key), event)
    state = maybe_monitor_gateway_run(state)

    bind_actions =
      if is_nil(state.gateway_run_pid),
        do: [{{:timeout, :gateway_bind}, @gateway_bind_grace_ms, :ensure_bound}],
        else: []

    if phase in [:aborting, :completing] do
      {:keep_state, state}
    else
      {state, actions} = Watchdog.start(state)

      {:next_state, :running, state,
       [{{:timeout, :submission_retry}, :cancel} | actions ++ bind_actions]}
    end
  end

  def handle_event(:info, %LemonCore.Event{type: :run_completed} = event, _phase, state) do
    {ok?, err} = CompactionTrigger.extract_completed_ok_and_error(event)
    usage = CompactionTrigger.extract_completed_usage(event)

    Logger.info(
      "RunProcess completed run_id=#{inspect(state.run_id)} session_key=#{inspect(state.session_key)} " <>
        "ok=#{inspect(ok?)} error=#{inspect(err)} saw_delta=#{inspect(state.saw_delta)} " <>
        "usage_input_tokens=#{inspect(CompactionTrigger.usage_input_tokens(usage))}"
    )

    Logger.debug("RunProcess #{state.run_id} completed")

    # Emit introspection event for run completion
    duration_ms =
      if state.start_ts_ms, do: LemonCore.Clock.now_ms() - state.start_ts_ms, else: nil

    Introspection.record(
      :run_completed,
      %{
        ok: ok?,
        error: CompactionTrigger.safe_error_label(err),
        duration_ms: duration_ms,
        saw_delta: state.saw_delta
      },
      event_id: "run_completed:#{state.run_id}",
      run_id: state.run_id,
      session_key: state.session_key,
      engine: "lemon",
      provenance: :direct
    )

    LemonRouter.RunCountTracker.record_terminal(state.run_id, ok? == false)

    # If we were monitoring the gateway run process, stop monitoring it before we exit so
    # we don't race a :DOWN message and emit a synthetic completion.
    state = maybe_demonitor_gateway_run(state)

    # Emit router-level completion event
    Bus.broadcast(Bus.session_topic(state.session_key), event)

    # If the engine reports a context-window overflow, clear resume state so
    # the next message can start fresh instead of immediately failing again.
    CompactionTrigger.maybe_reset_resume_on_context_overflow(state, event)
    # Router owns resume-token persistence; the gateway no longer writes it.
    CompactionTrigger.maybe_store_chat_state(state, event)
    CompactionTrigger.maybe_mark_pending_compaction_near_limit(state, event)
    retried? = RetryHandler.maybe_retry_zero_answer_failure(state, event)

    # Mark any still-running tool calls as completed so the editable "Tool calls"
    # status message (Telegram) can't get stuck at [running] if a final action
    # completion event is missed/raced.
    SurfaceManager.finalize_status(state, event)

    # If we never streamed deltas, make sure any tool-status output is flushed
    # before we emit a single final answer chunk.
    if state.saw_delta == false do
      SurfaceManager.flush_status(state)
    end

    unless retried? do
      extra_meta = safe_finalize_meta(state, event)
      media_recording = safe_record_media_jobs(extra_meta, state)
      surface_event = strip_media_directives_from_event(event)

      Introspection.record(
        :answer_finalize_started,
        %{
          saw_delta: state.saw_delta,
          extra_meta_keys: Map.keys(extra_meta),
          media_jobs_recorded_count: media_recording.recorded_count,
          media_jobs_failed_count: media_recording.failed_count
        },
        run_id: state.run_id,
        session_key: state.session_key,
        engine: "lemon",
        provenance: :direct
      )

      # SurfaceManager finalizes the answer path through the existing answer-stream surface, so
      # channels keep their dedicated final-answer behavior separate from tool status UI.
      SurfaceManager.finalize_answer(state, surface_event, extra_meta)

      Introspection.record(
        :answer_finalize_completed,
        %{saw_delta: state.saw_delta},
        run_id: state.run_id,
        session_key: state.session_key,
        engine: "lemon",
        provenance: :direct
      )

      # If no streaming deltas were emitted, emit a final output chunk so channels respond.
      SurfaceManager.maybe_seed_final_answer(state, event)

      # Optional fanout: forward the final answer text to additional destinations.
      SurfaceManager.fanout_final_answer(state, event)
    end

    # Deliver first: terminal evidence is best-effort bookkeeping (see
    # `RunReceiptStore.retain_terminal_evidence_best_effort/2`).
    _ =
      LemonRouter.RunReceiptStore.retain_terminal_evidence_best_effort(
        state.receipt_store,
        state.run_id
      )

    {:stop, :normal, state}
  end

  def handle_event(:info, %LemonCore.Event{type: :delta, payload: delta} = event, phase, state) do
    # Forward delta to session subscribers
    Bus.broadcast(Bus.session_topic(state.session_key), event)

    # Finalize the previous tool-status segment before we start streaming a new answer chunk.
    if state.saw_delta == false do
      SurfaceManager.commit_status_segment(state, :status)
    end

    # Forward semantic answer text through the router surface façade.
    SurfaceManager.ingest_answer_delta(state, delta)

    Watchdog.activity(phase, %{state | saw_delta: true})
  end

  def handle_event(
        :info,
        %LemonCore.Event{type: :engine_action, payload: action_ev} = event,
        phase,
        state
      ) do
    {state, tool_status_surface, capture_current_turn?} =
      SurfaceManager.prepare_status_action(state, action_ev)

    state =
      if state.saw_delta and tool_start?(action_ev) and capture_current_turn? do
        SurfaceManager.handoff_answer_to_status(state, tool_status_surface)
        %{state | saw_delta: false}
      else
        state
      end

    # Forward engine action events to session subscribers
    Bus.broadcast(Bus.session_topic(state.session_key), event)

    # Forward semantic status updates through the router surface façade.
    SurfaceManager.ingest_status_action(state, action_ev, tool_status_surface)

    state = artifact_tracker(state).track_generated_images(state, action_ev)
    state = artifact_tracker(state).track_requested_send_files(state, action_ev)

    state = track_effectful_action(state, action_ev)

    case state do
      %{restart_suspend: reply_to, effectful_actions: in_flight}
      when is_pid(reply_to) and map_size(in_flight) == 0 ->
        abort_for_restart(state, reply_to, :clean)

      _ ->
        Watchdog.activity(phase, state)
    end
  end

  def handle_event(
        :info,
        %LemonCore.Event{type: :task_projected_child_action, payload: action_ev},
        phase,
        state
      ) do
    {state, tool_status_surface, _capture_current_turn?} =
      SurfaceManager.prepare_status_action(state, action_ev)

    SurfaceManager.ingest_projected_child_action(
      state,
      action_ev,
      tool_status_surface
    )

    Watchdog.activity(phase, state)
  end

  def handle_event(:info, %LemonCore.Event{} = event, _phase, state) do
    Bus.broadcast(Bus.session_topic(state.session_key), event)
    :keep_state_and_data
  end

  def handle_event(:state_timeout, :idle, :running, state) do
    case Watchdog.request_confirmation(state) do
      :ok ->
        {:next_state, :confirming_idle, state,
         [{:state_timeout, state.run_watchdog_confirm_timeout_ms, :confirmation}]}

      :error ->
        idle_abort(state)
    end
  end

  def handle_event(:state_timeout, :confirmation, :confirming_idle, state), do: idle_abort(state)

  # Give a real completion a grace window before synthesizing executor failure.
  def handle_event(
        :info,
        {:DOWN, ref, :process, pid, reason},
        phase,
        %{gateway_run_ref: ref, gateway_run_pid: pid} = state
      )
      when phase != :completing do
    {:keep_state, %{state | gateway_run_ref: nil, gateway_run_pid: nil},
     [{{:timeout, :gateway_down}, gateway_down_grace_ms(reason), reason}]}
  end

  def handle_event({:timeout, :gateway_down}, reason, phase, state) do
    if phase == :completing do
      :keep_state_and_data
    else
      Logger.warning(
        "RunProcess observed gateway run down run_id=#{inspect(state.run_id)} " <>
          "session_key=#{inspect(state.session_key)} reason=#{inspect(reason)}"
      )

      event =
        LemonCore.Event.new(
          :run_completed,
          Events.RunCompleted.new(%{
            completed:
              Events.Completion.new(%{
                ok: false,
                error: {:gateway_run_down, reason},
                meta: cancellation_meta(phase, state),
                answer: ""
              }),
            duration_ms: nil
          }),
          %{
            run_id: state.run_id,
            session_key: state.session_key,
            synthetic: true
          }
        )

      LemonRouter.RunCompletion.publish(state.execution_request, event)
      await_completion(state)
    end
  end

  def handle_event({:timeout, :abort_completion}, reason, :aborting, state) do
    cond do
      runtime_run_pid(state.engine_runtime, state.run_id) != nil ->
        cancel_runtime_run(state.engine_runtime, state.run_id, reason)
        {:keep_state, maybe_monitor_gateway_run(state)}

      true ->
        Logger.warning(
          "RunProcess finalizing aborted run without gateway pid run_id=#{inspect(state.run_id)} " <>
            "session_key=#{inspect(state.session_key)} reason=#{inspect(reason)}"
        )

        event =
          LemonCore.Event.new(
            :run_completed,
            Events.RunCompleted.new(%{
              completed:
                Events.Completion.new(%{
                  ok: false,
                  error: reason,
                  meta: %{cancelled: true, cancel_reason: reason},
                  answer: ""
                }),
              duration_ms: nil
            }),
            %{
              run_id: state.run_id,
              session_key: state.session_key,
              synthetic: true
            }
          )

        LemonRouter.RunCompletion.publish(state.execution_request, event)
        await_completion(state)
    end
  end

  def handle_event({:timeout, :gateway_bind}, :ensure_bound, _phase, state) do
    cond do
      not is_nil(state.gateway_run_pid) ->
        :keep_state_and_data

      runtime_run_pid(state.engine_runtime, state.run_id) != nil ->
        {:keep_state, maybe_monitor_gateway_run(state)}

      true ->
        Logger.warning(
          "RunProcess started without gateway pid; awaiting completion grace run_id=#{inspect(state.run_id)} " <>
            "session_key=#{inspect(state.session_key)}"
        )

        {:keep_state_and_data,
         [
           {{:timeout, :gateway_bind}, @gateway_missing_completion_grace_ms,
            :finalize_missing_gateway}
         ]}
    end
  end

  def handle_event({:timeout, :gateway_bind}, :finalize_missing_gateway, phase, state) do
    cond do
      not is_nil(state.gateway_run_pid) ->
        :keep_state_and_data

      runtime_run_pid(state.engine_runtime, state.run_id) != nil ->
        {:keep_state, maybe_monitor_gateway_run(state)}

      true ->
        Logger.warning(
          "RunProcess finalizing started run without gateway pid after completion grace " <>
            "run_id=#{inspect(state.run_id)} session_key=#{inspect(state.session_key)}"
        )

        event =
          LemonCore.Event.new(
            :run_completed,
            Events.RunCompleted.new(%{
              completed:
                Events.Completion.new(%{
                  ok: false,
                  error: :gateway_run_missing_after_start,
                  meta: cancellation_meta(phase, state),
                  answer: ""
                }),
              duration_ms: nil
            }),
            %{
              run_id: state.run_id,
              session_key: state.session_key,
              synthetic: true
            }
          )

        LemonRouter.RunCompletion.publish(state.execution_request, event)
        await_completion(state)
    end
  end

  def handle_event(:cast, {:abort, _reason}, phase, _state)
      when phase in [:aborting, :completing],
      do: :keep_state_and_data

  def handle_event(:cast, {:abort, reason}, _phase, state), do: do_abort(state, reason)

  # Drain: stop at the next point where no effectful action is executing, so the
  # journal never holds a tool call whose outcome is unknown. `:now` stops even
  # mid-tool and reports the in-flight actions as uncertain.
  def handle_event(:cast, {:suspend_for_restart, reply_to, mode}, phase, state) do
    cond do
      phase in [:aborting, :completing] ->
        send(reply_to, {:restart_suspended, state.run_id, :not_running, []})
        :keep_state_and_data

      is_nil(state.run_started_at_ms) ->
        abort_for_restart(state, reply_to, :not_started)

      map_size(state.effectful_actions) == 0 ->
        abort_for_restart(state, reply_to, :clean)

      mode == :now ->
        abort_for_restart(state, reply_to, :uncertain)

      true ->
        {:keep_state, %{state | restart_suspend: reply_to}}
    end
  end

  def handle_event(:cast, {:watchdog_keep_alive, _decision}, phase, _state)
      when phase in [:aborting, :completing],
      do: :keep_state_and_data

  def handle_event(:cast, {:watchdog_keep_alive, decision}, phase, state)
      when phase in [:running, :confirming_idle] and decision in [:continue, :keep_alive] do
    Logger.info(
      "RunProcess watchdog keepalive accepted run_id=#{inspect(state.run_id)} " <>
        "session_key=#{inspect(state.session_key)}"
    )

    {state, actions} = Watchdog.start(state)
    {:next_state, :running, state, actions}
  end

  def handle_event(:cast, {:watchdog_keep_alive, decision}, _phase, state)
      when decision in [:cancel, :stop, :kill] do
    do_abort(state, :user_requested)
  end

  def handle_event(_type, _event, _phase, _state), do: :keep_state_and_data

  # Every cancellation waits for the gateway's real completion or its DOWN, so
  # the next run cannot start while the cancelled one still holds its engine
  # session; only a run with no gateway process is synthesized after a grace.
  defp do_abort(state, reason) do
    Logger.debug(
      "RunProcess #{state.run_id} aborting: #{LemonCore.StatusRedaction.inspect_reason(reason)}"
    )

    cancel_runtime_run(state.engine_runtime, state.run_id, reason)

    actions =
      if is_nil(state.gateway_run_pid),
        do: [{{:timeout, :abort_completion}, @abort_completion_grace_ms, reason}],
        else: []

    {:next_state, :aborting, %{state | restart_suspend: nil, abort_reason: reason},
     [{{:timeout, :submission_retry}, :cancel} | actions]}
  end

  defp idle_abort(state) do
    Watchdog.log_idle_timeout(state)
    do_abort(state, :run_idle_watchdog_timeout)
  end

  defp cancellation_meta(:aborting, state),
    do: %{cancelled: true, cancel_reason: state.abort_reason}

  defp cancellation_meta(_phase, _state), do: %{cancelled: false}

  defp await_completion(state) do
    actions =
      for name <- [:submission_retry, :gateway_bind, :gateway_down, :abort_completion],
          do: {{:timeout, name}, :cancel}

    {:next_state, :completing, state, actions}
  end

  defp abort_for_restart(state, reply_to, outcome) do
    titles = state.effectful_actions |> Map.values() |> Enum.take(5)
    send(reply_to, {:restart_suspended, state.run_id, outcome, titles})
    do_abort(%{state | restart_suspend: nil}, :runtime_restart)
  end

  @effectful_action_kinds [:tool, :command, :file_change, :web_search, :subagent]

  defp track_effectful_action(state, %{action: %{id: id, kind: kind} = action, phase: phase})
       when is_binary(id) and kind in @effectful_action_kinds do
    in_flight = Map.get(state, :effectful_actions, %{})

    case phase do
      :started ->
        title = action |> Map.get(:title) |> to_string() |> String.slice(0, 120)
        Map.put(state, :effectful_actions, Map.put(in_flight, id, title))

      :completed ->
        Map.put(state, :effectful_actions, Map.delete(in_flight, id))

      _ ->
        state
    end
  end

  defp track_effectful_action(state, _action_ev), do: state

  @impl true
  def terminate(reason, _phase, state) do
    if is_pid(state.coordinator_pid) do
      send(state.coordinator_pid, {:run_process_terminated, state.run_id, reason})
    end

    # If not completed normally, emit failure event and attempt abort
    if reason != :normal do
      # Emit introspection event for run failure
      Introspection.record(
        :run_failed,
        %{
          reason: CompactionTrigger.safe_error_label(reason)
        },
        run_id: state.run_id,
        session_key: state.session_key,
        engine: "lemon",
        provenance: :direct
      )

      LemonRouter.RunCountTracker.record_terminal(state.run_id, true)

      Bus.broadcast(
        Bus.run_topic(state.run_id),
        LemonCore.Event.new(
          :run_failed,
          Events.RunFailed.new(%{
            run_id: state.run_id,
            session_key: state.session_key,
            reason: reason
          }),
          %{
            run_id: state.run_id,
            session_key: state.session_key,
            synthetic: true
          }
        )
      )

      # Best-effort abort of the gateway run on abnormal termination
      try do
        cancel_runtime_run(state.engine_runtime, state.run_id, :run_process_terminated)
      rescue
        _ -> :ok
      end
    end

    # Flush any pending coalescer output
    SurfaceManager.flush_all(state)

    # Unsubscribe control-plane EventBridge from run events
    unsubscribe_event_bridge(state.run_id)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Gateway monitoring
  # ---------------------------------------------------------------------------

  defp artifact_tracker(%{artifact_tracker: mod}) when is_atom(mod), do: mod
  defp artifact_tracker(_state), do: ArtifactTracker

  # Trackers implement finalize_meta/2. Probing with function_exported?/3 was
  # wrong: it is false until the module is loaded, so the first finalized run
  # after boot silently dropped final-answer MEDIA directives.
  defp safe_finalize_meta(state, event) do
    answer = CompactionTrigger.extract_completed_answer(event)
    artifact_tracker(state).finalize_meta(state, answer)
  rescue
    error ->
      Introspection.record(
        :answer_artifact_finalize_failed,
        %{error: Exception.message(error)},
        run_id: state.run_id,
        session_key: state.session_key,
        engine: "lemon",
        provenance: :direct
      )

      Logger.warning(
        "RunProcess artifact finalize_meta failed run_id=#{inspect(state.run_id)} " <>
          "session_key=#{inspect(state.session_key)} error=#{Exception.message(error)}"
      )

      %{}
  end

  defp strip_media_directives_from_event(%LemonCore.Event{payload: payload} = event)
       when is_map(payload) do
    %{event | payload: strip_media_directives_from_payload(payload)}
  end

  defp strip_media_directives_from_event(event), do: event

  defp strip_media_directives_from_payload(payload) do
    payload
    |> strip_media_directives_from_key(:answer)
    |> strip_media_directives_from_key("answer")
    |> strip_media_directives_from_completed(:completed)
    |> strip_media_directives_from_completed("completed")
  end

  defp strip_media_directives_from_completed(payload, key) do
    case Map.get(payload, key) do
      completed when is_map(completed) ->
        Map.put(payload, key, strip_media_directives_from_payload(completed))

      _ ->
        payload
    end
  end

  defp strip_media_directives_from_key(payload, key) do
    case Map.get(payload, key) do
      answer when is_binary(answer) ->
        Map.put(payload, key, ArtifactTracker.strip_media_directives(answer))

      _ ->
        payload
    end
  end

  defp safe_record_media_jobs(extra_meta, state) do
    MediaJobRecorder.record_auto_send_files(extra_meta, state)
  rescue
    error ->
      Introspection.record(
        :answer_media_jobs_record_failed,
        %{error: Exception.message(error)},
        run_id: state.run_id,
        session_key: state.session_key,
        engine: "lemon",
        provenance: :direct
      )

      %{recorded_count: 0, skipped_count: 0, failed_count: 1}
  end

  defp maybe_monitor_gateway_run(%{gateway_run_ref: ref} = state) when not is_nil(ref), do: state

  defp maybe_monitor_gateway_run(state) do
    with true <- Code.ensure_loaded?(Registry),
         pid when is_pid(pid) <- runtime_run_pid(state.engine_runtime, state.run_id) do
      %{state | gateway_run_pid: pid, gateway_run_ref: Process.monitor(pid)}
    else
      _ -> state
    end
  end

  defp maybe_demonitor_gateway_run(%{gateway_run_ref: nil} = state), do: state

  defp maybe_demonitor_gateway_run(%{gateway_run_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    %{state | gateway_run_ref: nil, gateway_run_pid: nil}
  end

  defp gateway_down_grace_ms(:normal), do: 200
  defp gateway_down_grace_ms(:shutdown), do: 200
  defp gateway_down_grace_ms({:shutdown, _}), do: 200
  defp gateway_down_grace_ms(_), do: 20

  # ---------------------------------------------------------------------------
  # Utility helpers
  # ---------------------------------------------------------------------------

  defp submit_runtime_execution(runtime, state) do
    if is_map(state.execution_request) and function_exported?(runtime, :submit_execution, 1) do
      case runtime.submit_execution(
             ExecutionCommand.ensure_conversation_key(state.execution_request)
           ) do
        :ok -> :ok
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
        # The runtime may have started the run without acknowledging it.
        _malformed_acknowledgement -> {:error, :outcome_unknown}
      end
    else
      :ok
    end
  catch
    :exit, _reason -> {:error, :outcome_unknown}
  end

  defp normalize_execution_request(
         %ExecutionCommand{} = request,
         session_key,
         conversation_key,
         run_id
       ) do
    normalized_request = %{
      request
      | session_key: request.session_key || session_key,
        conversation_key: request.conversation_key || conversation_key
    }

    {:ok, ExecutionCommand.ensure_conversation_key(normalized_request)}
  rescue
    ArgumentError ->
      {:error, {:invalid_execution_request, run_id}}
  end

  # Unsubscribe control-plane EventBridge from run events
  defp unsubscribe_event_bridge(run_id) do
    LemonCore.EventBridge.unsubscribe_run(run_id)
  end

  defp configured_engine_runtime do
    Application.get_env(:lemon_router, :engine_runtime)
  end

  @spec runtime_available?(term()) :: boolean()
  defp runtime_available?(runtime) when is_atom(runtime) do
    cond do
      not Code.ensure_loaded?(runtime) ->
        false

      function_exported?(runtime, :available?, 0) ->
        runtime.available?()

      true ->
        case GenServer.whereis(runtime) do
          pid when is_pid(pid) -> true
          _ -> false
        end
    end
  end

  defp runtime_available?(_), do: false

  defp cancel_runtime_run(runtime, run_id, reason) when is_atom(runtime) and is_binary(run_id) do
    if Code.ensure_loaded?(runtime) and function_exported?(runtime, :cancel_by_run_id, 2) do
      runtime.cancel_by_run_id(run_id, reason)
    else
      :ok
    end
  end

  defp cancel_runtime_run(_, _, _), do: :ok

  defp runtime_run_pid(runtime, run_id) when is_atom(runtime) and is_binary(run_id) do
    if Code.ensure_loaded?(runtime) and function_exported?(runtime, :run_pid, 1) do
      runtime.run_pid(run_id)
    end
  end

  defp runtime_run_pid(_, _), do: nil

  defp tool_start?(action_ev) when is_map(action_ev) do
    phase = Map.get(action_ev, :phase) || Map.get(action_ev, "phase")
    phase in [:started, "started"]
  end

  defp tool_start?(_), do: false

  @spec gateway_submit_retry_delay_ms(non_neg_integer()) :: non_neg_integer()
  defp gateway_submit_retry_delay_ms(attempt) when is_integer(attempt) and attempt >= 0 do
    exponential = @gateway_submit_retry_base_ms * :math.pow(2, attempt)
    delay_ms = round(exponential)
    min(delay_ms, @gateway_submit_retry_max_ms)
  end

  defp gateway_submit_deadline_ms(opts) do
    case opts[:gateway_submit_deadline_ms] do
      value when is_integer(value) and value > 0 -> value
      _ -> @gateway_submit_deadline_ms
    end
  end

  defp retry_runtime_submission(state, reason, log_prefix) do
    next_attempt = state.gateway_submit_attempt + 1
    now_ms = System.monotonic_time(:millisecond)

    if now_ms >= state.gateway_submit_deadline_at_ms do
      terminalize_gateway_submission(%{
        state
        | gateway_submit_attempt: next_attempt,
          gateway_submit_last_error: reason
      })
    else
      delay_ms = gateway_submit_retry_delay_ms(state.gateway_submit_attempt)
      remaining_ms = max(state.gateway_submit_deadline_at_ms - now_ms, 0)

      Logger.warning(
        "#{log_prefix} for run_id=#{inspect(state.run_id)} reason=#{inspect(reason)}; " <>
          "retrying in #{min(delay_ms, remaining_ms)}ms (attempt=#{next_attempt})"
      )

      {:keep_state,
       %{
         state
         | gateway_submit_attempt: next_attempt,
           gateway_submit_last_error: reason
       }, [{{:timeout, :submission_retry}, min(delay_ms, remaining_ms), :submit_to_gateway}]}
    end
  end

  # The runtime may have started the run before failing to acknowledge it, and
  # its fixed run ID must never be resubmitted. Adopt a live run; when none is
  # found, the bind grace lets a real completion win before one is synthesized.
  defp adopt_ambiguous_submission(state) do
    Logger.warning(
      "RunProcess runtime submission outcome unknown; adopting run_id=#{inspect(state.run_id)} " <>
        "session_key=#{inspect(state.session_key)}"
    )

    state = maybe_monitor_gateway_run(%{state | gateway_submit_attempt: 0})

    bind_actions =
      if is_nil(state.gateway_run_pid),
        do: [{{:timeout, :gateway_bind}, @gateway_bind_grace_ms, :ensure_bound}],
        else: []

    {:next_state, :awaiting_start, state,
     [{{:timeout, :submission_retry}, :cancel} | bind_actions]}
  end

  defp terminalize_gateway_submission(state) do
    error = %{
      type: :runtime_submission_failed,
      reason: state.gateway_submit_last_error || :runtime_unavailable,
      attempts: state.gateway_submit_attempt,
      deadline_ms: state.gateway_submit_deadline_ms
    }

    event =
      LemonCore.Event.new(
        :run_completed,
        Events.RunCompleted.new(%{
          completed:
            Events.Completion.new(%{
              ok: false,
              error: error,
              meta: %{cancelled: false},
              answer: ""
            }),
          duration_ms: LemonCore.Clock.now_ms() - state.start_ts_ms
        }),
        %{
          run_id: state.run_id,
          session_key: state.session_key,
          synthetic: true,
          failure_stage: :runtime_submission
        }
      )

    LemonRouter.RunCompletion.publish(state.execution_request, event)

    await_completion(state)
  end
end
