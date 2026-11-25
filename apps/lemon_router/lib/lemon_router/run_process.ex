defmodule LemonRouter.RunProcess do
  @moduledoc """
  The single owner of one run, from admission to its terminal record.

  `RunProcess` expects a router-built `%LemonCore.ExecutionCommand{}` at init
  time. It claims the run's engine session, waits for a global execution
  permit from `LemonRouter.Slots`, starts the executor (`CodingAgent.Executor`
  unless the `:executor` option names a test executor), receives the
  executor's events directly, persists and publishes them on `run:<run_id>`,
  and writes the run's terminal record through `LemonRouter.RunCompletion`.
  Steer, redirect and cancellation reach the executor only through this
  process. No other process owns the run.

  Each RunProcess:
  - Owns a run_id and its unique SessionRegistry key, released on process death
  - Owns the engine-session claim and execution permit, released before its
    completion is published so an observer can start the session's next run
  - Monitors the executor's runner process
  - Emits router-level events and semantic delivery

  Heavy logic is delegated to focused submodules:
  - `RunProcess.Execution` -- executor calls and bus payload shapes
  - `RunProcess.Watchdog` -- idle-run state timeout and confirmation policy
  - `RunProcess.CompactionTrigger` -- context-overflow & compaction markers
  - `RunProcess.RetryHandler` -- zero-answer auto-retry
  - `LemonRouter.SurfaceManager` -- semantic answer/status coordination and fanout
  - `RunProcess.ArtifactTracker` -- generated file tracking and answer metadata enrichment
  - `LemonRouter.MediaJobRecorder` -- generated media delivery metadata recording

  ## Lifecycle transitions

  | State | Event | Next state / timeout |
  | --- | --- | --- |
  | submitting | permit authority missing or engine session busy | submitting / named retry; deadline unchanged |
  | submitting | session claimed and permit requested | awaiting slot |
  | submitting | deadline, definite rejection, activation refusal or durable terminal record | stopped / one terminal record |
  | awaiting slot | permit granted, executor started | running / idle state timeout |
  | awaiting slot | permit granted, executor start failed | stopped / one failed completion |
  | awaiting slot | abort or permit authority lost | stopped / one completion |
  | running or confirming idle | output, action, keepalive | running / fresh idle timeout |
  | running | idle expiry | confirming idle, or aborting if no prompt can be delivered |
  | confirming idle | confirmation expiry or cancel | aborting / executor cancel with the real reason |
  | running | executor DOWN | presenting / one failed completion |
  | active | abort or restart boundary | aborting / executor cancel, 15 s drain |
  | aborting | executor completion, DOWN or drain expiry | presenting / one cancelled completion |
  | presenting | presentation returned | stopped normally; failed effects stay replayable |

  The executor sends its completion before it exits, so its DOWN can never
  overtake it. Admission and completion share a durable terminal fence. An
  existing decision is adopted, never contradicted; its outbox owns publication
  and replay of failed presentation effects.
  """

  @behaviour :gen_statem

  @impl true
  def format_status(status) do
    LemonCore.StatusRedaction.gen_statem(status, [:run_id, :session_key, :queue_mode])
  end

  require Logger

  import CodingAgent.Executor.Event, only: [is_started: 1, is_action_event: 1, is_completed: 1]

  alias CodingAgent.Executor.Event
  alias LemonCore.{Bus, Events, ExecutionCommand, Introspection, RunStore, TerminalOutbox}
  alias LemonRouter.{EngineSessionClaim, MediaJobRecorder, RunCompletion, Slots, SurfaceManager}

  alias LemonRouter.RunProcess.{
    ArtifactTracker,
    CompactionTrigger,
    Execution,
    RetryHandler,
    Watchdog
  }

  @submit_retry_base_ms 100
  @submit_retry_max_ms 2_000
  @submit_deadline_ms 30_000
  @cancel_drain_timeout_ms 15_000

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
  The live owner of `run_id`, or nil. A run registry that is restarting has no
  owner to offer, so steering falls back to queueing.
  """
  @spec whereis(binary()) :: pid() | nil
  def whereis(run_id) when is_binary(run_id) do
    case Registry.lookup(LemonRouter.RunRegistry, run_id) do
      [{pid, _}] when is_pid(pid) -> pid
      _ -> nil
    end
  rescue
    ArgumentError -> nil
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
    case whereis(pid_or_run_id) do
      pid when is_pid(pid) -> abort(pid, reason)
      nil -> :ok
    end
  end

  @doc """
  Deliver a steer, backlog steer or redirect for `submission_run_id` to the
  executor. `reply_to` receives `{:<mode>_accepted | :<mode>_rejected,
  submission_run_id}`; a run that has not started or already ended rejects.
  """
  @spec steer(pid(), :steer | :steer_backlog | :redirect, binary(), binary(), pid()) :: :ok
  def steer(pid, mode, submission_run_id, prompt, reply_to)
      when is_pid(pid) and mode in [:steer, :steer_backlog, :redirect] and
             is_binary(submission_run_id) and is_binary(prompt) and is_pid(reply_to) do
    :gen_statem.cast(pid, {:steer, mode, submission_run_id, prompt, reply_to})
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
    case whereis(pid_or_run_id) do
      pid when is_pid(pid) -> keep_alive(pid, decision)
      nil -> :ok
    end
  end

  @doc """
  Ask the run to stop for a runtime restart. It replies to `reply_to` with
  `{:restart_suspended, run_id, outcome, in_flight_titles}` when it aborts:
  `:clean` (no effectful action was executing), `:uncertain` (`mode: :now`
  interrupted one), `:not_started` (the executor never started it) or
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
    Process.flag(:trap_exit, true)
    run_id = opts[:run_id]
    init_session_key = opts[:session_key]
    run_watchdog_timeout_ms = Watchdog.resolve_run_watchdog_timeout_ms(opts)
    run_watchdog_confirm_timeout_ms = Watchdog.resolve_run_watchdog_confirm_timeout_ms(opts)
    submit_deadline_ms = submit_deadline_ms(opts)

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

      # Events other processes publish for this run (task projections, a
      # terminal record another writer won) arrive on the run topic.
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
        run_orchestrator: opts[:run_orchestrator] || LemonRouter.RunOrchestrator,
        executor: Execution.executor(opts),
        submit_attempt: 0,
        submit_deadline_ms: submit_deadline_ms,
        submit_deadline_at_ms: System.monotonic_time(:millisecond) + submit_deadline_ms,
        submit_last_error: nil,
        claim_key: nil,
        slots_ref: nil,
        slot_ref: nil,
        run_ref: nil,
        control_ctx: nil,
        executor_pid: nil,
        executor_ref: nil,
        last_resume: execution_request.resume,
        delta_seq: 0,
        accumulated_text: "",
        first_token_at_ms: nil,
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
          "queue_mode=#{inspect(queue_mode)}"
      )

      Introspection.record(
        :run_started,
        %{queue_mode: queue_mode},
        run_id: run_id,
        session_key: session_key,
        engine: "lemon",
        provenance: :direct
      )

      # Persist the real native owner before it can invoke addressed tools.
      case LemonRouter.AgentMessagingSessions.capture(execution_request) do
        :ok ->
          {:ok, :submitting, state,
           [
             {:next_event, :internal, :submit},
             {:state_timeout, submit_deadline_ms, :submission_deadline}
           ]}

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

  # --- Admission: activation fence, engine-session claim, durable terminal
  # fence, then a FIFO request for a global execution permit.

  def handle_event(type, :submit, :submitting, state)
      when type == :internal or type == {:timeout, :submission_retry} do
    case admit(state) do
      {:ok, state} ->
        {:next_state, :awaiting_slot, %{state | submit_attempt: 0},
         [{{:timeout, :submission_retry}, :cancel}]}

      # The previous run of this engine session may still be draining its
      # cancellation; the claim frees when it terminalizes.
      {:retry, :session_in_use, state} ->
        retry_submission(state, :session_in_use, "Engine session busy")

      {:retry, :runtime_unavailable, state} ->
        retry_submission(state, :runtime_unavailable, "Execution permits unavailable")

      {:terminal, state} ->
        adopt_terminal_record(state)

      {:unavailable, state} ->
        terminalize_submission(%{state | submit_last_error: :run_state_unavailable})

      # A failed pre-send fence cannot authorize a retry or a new run.
      {:error, reason, state} ->
        terminalize_submission(%{state | submit_last_error: reason})
    end
  end

  def handle_event(:state_timeout, :submission_deadline, :submitting, state) do
    Logger.error(
      "RunProcess submission deadline exceeded run_id=#{inspect(state.run_id)} " <>
        "session_key=#{inspect(state.session_key)} attempts=#{state.submit_attempt} " <>
        "last_error=#{inspect(state.submit_last_error)}"
    )

    terminalize_submission(state)
  end

  def handle_event(:info, {:slot_granted, slot_ref}, :awaiting_slot, %{slot_ref: nil} = state) do
    state = %{state | slot_ref: slot_ref}

    case terminal_fence(state) do
      :open -> start_executor(state)
      :terminal -> adopt_terminal_record(state)
      :unavailable -> finalize_start_failure(state, :run_state_unavailable)
    end
  end

  # A permit granted after cancellation is returned at once.
  def handle_event(:info, {:slot_granted, slot_ref}, _phase, state) do
    Slots.release(slot_ref)
    {:keep_state, state}
  end

  # The permit authority is gone with its FIFO: a waiting run can never be
  # granted, and a running one has lost its permit. Report the run instead of
  # exiting silently, so nobody waits for a completion that cannot come.
  def handle_event(:info, {:DOWN, ref, :process, _pid, _reason}, phase, %{slots_ref: ref} = state) do
    state = %{state | slots_ref: nil, slot_ref: nil}

    cond do
      phase == :aborting -> {:keep_state, state}
      is_pid(state.executor_pid) -> begin_cancel(state, :runtime_unavailable)
      true -> finalize_start_failure(state, :runtime_unavailable)
    end
  end

  # --- Executor events, received directly from the executor's runner.

  def handle_event(:info, {:engine_event, run_ref, event}, phase, %{run_ref: run_ref} = state)
      when is_map(event) do
    event =
      if phase == :aborting and is_completed(event), do: cancelled(event, state), else: event

    RunStore.append_event(state.run_id, event)
    {type, payload} = Execution.engine_event(event)
    bus_event = publish(state, type, payload)

    cond do
      is_completed(event) ->
        state = %{state | last_resume: Map.get(event, :resume) || state.last_resume}
        finalize(state, event)

      is_started(event) ->
        # Chat state is stored after completion; storing the resume token now
        # would let new messages auto-resume into this still-active run.
        {:keep_state, %{state | last_resume: Map.get(event, :resume) || state.last_resume}}

      is_action_event(event) ->
        on_engine_action(bus_event, phase, state)

      true ->
        :keep_state_and_data
    end
  end

  # Remote checkpoint frames share the executor sink so they cannot overtake
  # deltas/actions already received for this run.
  def handle_event(
        :info,
        {:engine_checkpoint, run_ref, type, payload},
        _phase,
        %{run_ref: run_ref} = state
      )
      when type in [:checkpoint_created, :checkpoint_restored, :checkpoint_deleted] and
             is_map(payload) do
    publish(state, type, payload, %{remote_node: true})
    :keep_state_and_data
  end

  def handle_event(
        :info,
        {:engine_delta, run_ref, %LemonCore.Event{type: :delta} = event},
        phase,
        %{run_ref: run_ref} = state
      ) do
    Bus.broadcast_from(Bus.run_topic(state.run_id), event)

    # The native session already publishes this delta in its cursor batch.
    unless is_map_key(event.meta || %{}, :session_seq) do
      Bus.broadcast(Bus.session_topic(state.session_key), event)
    end

    on_delta(state, phase, event.payload)
  end

  def handle_event(:info, {:engine_delta, run_ref, text}, phase, %{run_ref: run_ref} = state)
      when is_binary(text) do
    seq = state.delta_seq + 1

    delta =
      Events.Delta.new(%{
        run_id: state.run_id,
        ts_ms: System.system_time(:millisecond),
        seq: seq,
        text: text,
        meta: %{session_key: state.session_key}
      })

    publish(state, :delta, delta)
    on_delta(state, phase, delta)
  end

  def handle_event(
        :info,
        {:DOWN, ref, :process, pid, reason},
        phase,
        %{executor_pid: pid, executor_ref: ref} = state
      ) do
    state = %{state | executor_pid: nil, executor_ref: nil}

    if phase == :aborting do
      finalize_cancel(state)
    else
      finalize(
        state,
        failed_completion(state, %{type: :executor_down, reason: Execution.exit_class(reason)})
      )
    end
  end

  def handle_event(:info, {:EXIT, _pid, _reason}, _phase, _state), do: :keep_state_and_data

  def handle_event(:state_timeout, :cancel_drain, :aborting, state), do: finalize_cancel(state)

  # --- Events other processes publish on this run's topic.

  # The outbox may publish a decision that predates this owner. Adopt only a
  # committed attempt, never an unversioned notification on the run topic.
  def handle_event(
        :info,
        %LemonCore.Event{type: :run_completed, meta: %{attempt_id: attempt_id}} = event,
        _phase,
        state
      ) do
    case TerminalOutbox.decision(state.run_id) do
      {:ok, %{attempt_id: ^attempt_id}} ->
        if state.run_ref, do: Execution.control(state.executor, :cancel, state.control_ctx)
        complete_run(event, release_execution(state))

      _ ->
        :keep_state_and_data
    end
  end

  def handle_event(:info, %LemonCore.Event{type: type}, _phase, _state)
      when type in [:run_started, :run_completed],
      do: :keep_state_and_data

  def handle_event(:internal, {:present, event, retried?}, :presenting, state) do
    case present(state, event, retried?) do
      :ok -> TerminalOutbox.ack(state.run_id, :presentation)
      {:error, _} -> TerminalOutbox.failed(state.run_id, :presentation)
    end

    _ =
      LemonRouter.RunReceiptStore.retain_terminal_evidence_best_effort(
        state.receipt_store,
        state.run_id
      )

    {:stop, :normal, state}
  end

  def handle_event(
        :info,
        %LemonCore.Event{type: :task_projected_child_action, payload: action_ev},
        phase,
        state
      ) do
    {state, tool_status_surface, _capture_current_turn?} =
      SurfaceManager.prepare_status_action(state, action_ev)

    SurfaceManager.ingest_projected_child_action(state, action_ev, tool_status_surface)
    Watchdog.activity(phase, state)
  end

  def handle_event(:info, %LemonCore.Event{} = event, _phase, state) do
    Bus.broadcast(Bus.session_topic(state.session_key), event)
    :keep_state_and_data
  end

  # --- Watchdog.

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

  # --- Control.

  def handle_event(:cast, {:steer, mode, submission_run_id, prompt, reply_to}, phase, state) do
    result =
      if phase in [:running, :confirming_idle] and state.executor,
        do: steer_executor(mode, prompt, state),
        else: :rejected

    send(reply_to, {steer_reply(mode, result), submission_run_id})
    :keep_state_and_data
  end

  def handle_event(:cast, {:abort, _reason}, :aborting, _state), do: :keep_state_and_data
  def handle_event(:cast, {:abort, reason}, _phase, state), do: do_abort(state, reason)

  # Drain: stop at the next point where no effectful action is executing, so the
  # journal never holds a tool call whose outcome is unknown. `:now` stops even
  # mid-tool and reports the in-flight actions as uncertain.
  def handle_event(:cast, {:suspend_for_restart, reply_to, mode}, phase, state) do
    cond do
      phase == :aborting ->
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

  def handle_event(:cast, {:watchdog_keep_alive, _decision}, :aborting, _state),
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

  # ---------------------------------------------------------------------------
  # Admission
  # ---------------------------------------------------------------------------

  # Activation fence, engine-session claim, durable terminal fence, then a FIFO
  # permit request. Every outcome carries the state as far as it got, so a
  # claim taken here is retained (and later released) on every path.
  defp admit(state) do
    with :ok <- LemonRouter.NativeLineage.validate_activation(state.execution_request),
         {:ok, state} <- claim_engine_session(state) do
      case terminal_fence(state) do
        :open -> request_permit(state)
        other -> {other, state}
      end
    else
      {:retry, reason} -> {:retry, reason, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  # Claimed before requesting a permit, so contention never waits while
  # holding capacity.
  defp claim_engine_session(%{claim_key: key} = state) when not is_nil(key), do: {:ok, state}

  defp claim_engine_session(state) do
    key = Execution.claim_key(state.execution_request)

    case EngineSessionClaim.claim(key) do
      :ok -> {:ok, %{state | claim_key: key}}
      {:error, :session_in_use} -> {:retry, :session_in_use}
    end
  rescue
    ArgumentError -> {:retry, :runtime_unavailable}
  end

  defp terminal_fence(state) do
    case TerminalOutbox.decision(state.run_id) do
      {:ok, %{} = _decision} -> :terminal
      {:ok, nil} -> legacy_terminal_fence(state)
      _ -> :unavailable
    end
  end

  defp legacy_terminal_fence(state) do
    case RunStore.fetch(state.run_id) do
      {:ok, %{summary: %{completed: completed}}} when is_map(completed) -> :terminal
      {:error, :evicted} -> :terminal
      {:ok, nil} -> :open
      {:ok, %{summary: nil}} -> :open
      _ -> :unavailable
    end
  end

  defp request_permit(state) do
    case Process.whereis(Slots) do
      pid when is_pid(pid) ->
        ref = Process.monitor(pid)
        Slots.acquire(state.run_id)
        {:ok, %{state | slots_ref: ref}}

      nil ->
        {:retry, :runtime_unavailable, state}
    end
  end

  defp retry_submission(state, reason, log_prefix) do
    next_attempt = state.submit_attempt + 1
    now_ms = System.monotonic_time(:millisecond)

    if now_ms >= state.submit_deadline_at_ms do
      terminalize_submission(%{state | submit_attempt: next_attempt, submit_last_error: reason})
    else
      delay_ms = submit_retry_delay_ms(state.submit_attempt)
      remaining_ms = max(state.submit_deadline_at_ms - now_ms, 0)

      Logger.warning(
        "#{log_prefix} for run_id=#{inspect(state.run_id)} reason=#{inspect(reason)}; " <>
          "retrying in #{min(delay_ms, remaining_ms)}ms (attempt=#{next_attempt})"
      )

      {:keep_state, %{state | submit_attempt: next_attempt, submit_last_error: reason},
       [{{:timeout, :submission_retry}, min(delay_ms, remaining_ms), :submit}]}
    end
  end

  defp submit_retry_delay_ms(attempt) when is_integer(attempt) and attempt >= 0 do
    min(round(@submit_retry_base_ms * :math.pow(2, attempt)), @submit_retry_max_ms)
  end

  defp submit_deadline_ms(opts) do
    case opts[:submit_deadline_ms] do
      value when is_integer(value) and value > 0 -> value
      _ -> @submit_deadline_ms
    end
  end

  defp terminalize_submission(state) do
    error = %{
      type: :runtime_submission_failed,
      reason: state.submit_last_error || :runtime_unavailable,
      attempts: state.submit_attempt,
      deadline_ms: state.submit_deadline_ms
    }

    finalize(state, failed_completion(state, error), %{failure_stage: :runtime_submission})
  end

  # The durable record is the truth: adopt it without publishing a second one.
  defp adopt_terminal_record(state) do
    complete_run(RunCompletion.reconcile(state.run_id), release_execution(state))
  end

  # ---------------------------------------------------------------------------
  # Execution
  # ---------------------------------------------------------------------------

  defp start_executor(state) do
    command = state.execution_request
    publish(state, :run_started, Execution.run_started(state.run_id, state.session_key, command))

    LemonCore.Telemetry.run_start(state.run_id, %{
      session_key: state.session_key,
      engine: "lemon",
      origin: Execution.meta_field(command, :origin)
    })

    opts = [
      cwd: Execution.cwd(command),
      run_id: state.run_id,
      slot_lender: Slots,
      canonical_delta: true
    ]

    case Execution.start(state.executor, command, opts, self()) do
      {:ok, run_ref, control_ctx} ->
        executor_pid = Execution.runner_pid(control_ctx)

        state = %{
          state
          | run_ref: run_ref,
            control_ctx: control_ctx,
            executor_pid: executor_pid,
            executor_ref: if(executor_pid, do: Process.monitor(executor_pid))
        }

        {state, actions} = Watchdog.start(state)
        {:next_state, :running, state, actions}

      {:error, reason} ->
        finalize_start_failure(%{state | executor: nil}, reason)
    end
  end

  defp finalize_start_failure(state, reason) do
    Logger.warning(
      "RunProcess start failed run_id=#{inspect(state.run_id)} reason=#{inspect(reason)}"
    )

    finalize(state, failed_completion(state, reason))
  end

  defp steer_executor(:redirect, prompt, state) do
    case Execution.control(state.executor, :redirect, state.control_ctx, prompt) do
      :ok -> :accepted
      {:error, :unsupported} -> steer_executor(:steer, prompt, state)
      _ -> :rejected
    end
  end

  defp steer_executor(_mode, prompt, state) do
    case Execution.control(state.executor, :steer, state.control_ctx, prompt) do
      :ok -> :accepted
      _ -> :rejected
    end
  end

  defp steer_reply(:steer, :accepted), do: :steer_accepted
  defp steer_reply(:steer, :rejected), do: :steer_rejected
  defp steer_reply(:steer_backlog, :accepted), do: :steer_backlog_accepted
  defp steer_reply(:steer_backlog, :rejected), do: :steer_backlog_rejected
  defp steer_reply(:redirect, :accepted), do: :redirect_accepted
  defp steer_reply(:redirect, :rejected), do: :redirect_rejected

  defp maybe_first_token(%{first_token_at_ms: nil} = state) do
    LemonCore.Telemetry.run_first_token(state.run_id, state.start_ts_ms)
    %{state | first_token_at_ms: LemonCore.Clock.now_ms()}
  end

  defp maybe_first_token(state), do: state

  defp on_delta(state, phase, %{seq: seq, text: text} = delta) do
    state = maybe_first_token(state)

    if state.saw_delta == false, do: SurfaceManager.commit_status_segment(state, :status)

    SurfaceManager.ingest_answer_delta(state, delta)

    Watchdog.activity(phase, %{
      state
      | saw_delta: true,
        delta_seq: seq,
        accumulated_text: state.accumulated_text <> text
    })
  end

  defp on_engine_action(%LemonCore.Event{payload: action_ev}, phase, state) do
    {state, tool_status_surface, capture_current_turn?} =
      SurfaceManager.prepare_status_action(state, action_ev)

    state =
      if state.saw_delta and tool_start?(action_ev) and capture_current_turn? do
        SurfaceManager.handoff_answer_to_status(state, tool_status_surface)
        %{state | saw_delta: false}
      else
        state
      end

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

  defp publish(state, :run_started, payload) do
    state
    |> new_event(:run_started, payload, %{})
    |> LemonCore.Event.identify_run(state.run_id, attempt_id(state))
    |> Bus.publish_run_lifecycle()
  end

  # Publish on the run topic for other subscribers and forward to the session
  # topic. The owner handles its own events inline, never through the bus.
  defp publish(state, type, payload), do: publish(state, type, payload, %{})

  defp publish(state, type, payload, extra_meta) do
    event = new_event(state, type, payload, extra_meta)
    Bus.broadcast_from(Bus.run_topic(state.run_id), event)
    Bus.broadcast(Bus.session_topic(state.session_key), event)
    event
  end

  defp new_event(state, type, payload, extra_meta) do
    meta =
      state.run_id
      |> Execution.event_meta(state.session_key, state.execution_request)
      |> Map.merge(extra_meta)

    LemonCore.Event.new(type, payload, meta)
  end

  defp attempt_id(state) do
    context = state.execution_request.execution_context
    context && context.attempt_id
  end

  # ---------------------------------------------------------------------------
  # Cancellation
  # ---------------------------------------------------------------------------

  # The cancel request is asynchronous and advisory: while the executor
  # process lives, the permit and engine-session claim are held until it exits
  # or the drain deadline passes, so a next run of the same session can never
  # overlap tools still finishing here.
  defp do_abort(state, reason) do
    Logger.debug(
      "RunProcess #{state.run_id} aborting: #{LemonCore.StatusRedaction.inspect_reason(reason)}"
    )

    begin_cancel(%{state | restart_suspend: nil}, reason)
  end

  defp begin_cancel(state, reason) do
    state = %{state | abort_reason: reason}
    if state.executor, do: _ = Execution.control(state.executor, :cancel, state.control_ctx)

    if is_pid(state.executor_pid) do
      {:next_state, :aborting, state,
       [
         {{:timeout, :submission_retry}, :cancel},
         {:state_timeout, @cancel_drain_timeout_ms, :cancel_drain}
       ]}
    else
      Slots.cancel_by_run_id(state.run_id, reason)
      finalize_cancel(state)
    end
  end

  defp idle_abort(state) do
    Watchdog.log_idle_timeout(state)
    do_abort(state, :run_idle_watchdog_timeout)
  end

  defp abort_for_restart(state, reply_to, outcome) do
    titles = state.effectful_actions |> Map.values() |> Enum.take(5)
    send(reply_to, {:restart_suspended, state.run_id, outcome, titles})
    do_abort(%{state | restart_suspend: nil}, :runtime_restart)
  end

  defp finalize_cancel(state) do
    completed =
      Event.completed(%{
        engine: "lemon",
        resume: state.last_resume,
        ok: false,
        meta: %{cancelled: true, cancel_reason: state.abort_reason},
        error: state.abort_reason,
        answer: state.accumulated_text
      })

    finalize(state, completed)
  end

  defp cancelled(event, state) do
    %{
      event
      | ok: false,
        error: state.abort_reason,
        meta: Map.merge(event.meta || %{}, %{cancelled: true, cancel_reason: state.abort_reason})
    }
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

  # ---------------------------------------------------------------------------
  # Completion: the run's only terminal path
  # ---------------------------------------------------------------------------

  defp failed_completion(state, error) do
    Event.completed(%{
      engine: "lemon",
      ok: false,
      error: error,
      answer: "",
      resume: state.last_resume,
      meta: cancellation_meta(state)
    })
  end

  defp cancellation_meta(%{abort_reason: nil}), do: %{cancelled: false}
  defp cancellation_meta(state), do: %{cancelled: true, cancel_reason: state.abort_reason}

  # Release execution, commit the outcome and hand off its notification before
  # running presentation. A presentation crash cannot change execution truth.
  defp finalize(state, completed, extra_meta \\ nil) do
    answer = Map.get(completed, :answer)

    completed =
      completed
      |> Map.put(:run_id, state.run_id)
      |> Map.put(:session_key, state.session_key)
      |> Map.put(:answer, if(answer in [nil, ""], do: state.accumulated_text, else: answer))
      # A completion without a resume token keeps the one the run started with.
      |> Map.put(:resume, Map.get(completed, :resume) || state.last_resume)

    if Map.get(completed, :ok) != true,
      do: Execution.log_failure(state.run_id, state.session_key, completed)

    state = release_execution(state)
    duration_ms = LemonCore.Clock.now_ms() - state.start_ts_ms

    meta =
      state.run_id
      |> Execution.event_meta(state.session_key, state.execution_request)
      |> Map.merge(if extra_meta, do: Map.put(extra_meta, :synthetic, true), else: %{})
      |> Map.merge(if state.run_ref, do: %{}, else: %{synthetic: true})

    event =
      LemonCore.Event.new(
        :run_completed,
        Events.RunCompleted.new(%{
          completed: Execution.completion(completed),
          duration_ms: duration_ms
        }),
        meta
      )

    {_outcome, event} = RunCompletion.finalize(state.execution_request, event, router_owned: true)

    complete_run(event, state)
  end

  defp release_execution(state) do
    if state.slot_ref, do: Slots.release(state.slot_ref)
    if state.slots_ref, do: Process.demonitor(state.slots_ref, [:flush])
    if state.executor_ref, do: Process.demonitor(state.executor_ref, [:flush])
    if state.claim_key, do: EngineSessionClaim.release(state.claim_key)

    %{
      state
      | slot_ref: nil,
        slots_ref: nil,
        executor_ref: nil,
        executor_pid: nil,
        claim_key: nil,
        executor: nil
    }
  end

  defp complete_run(nil, state), do: {:stop, :normal, state}

  defp complete_run(event, state) do
    {ok?, err} = CompactionTrigger.extract_completed_ok_and_error(event)

    context_tokens =
      event |> CompactionTrigger.extract_completed_usage() |> Events.Usage.context_tokens()

    Logger.info(
      "RunProcess completed run_id=#{inspect(state.run_id)} session_key=#{inspect(state.session_key)} " <>
        "ok=#{inspect(ok?)} error=#{inspect(err)} saw_delta=#{inspect(state.saw_delta)} " <>
        "context_tokens=#{inspect(context_tokens)}"
    )

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

    # If the engine reports a context-window overflow, clear resume state so
    # the next message can start fresh instead of immediately failing again.
    CompactionTrigger.maybe_reset_resume_on_context_overflow(state, event)
    # Router owns resume-token persistence.
    CompactionTrigger.maybe_store_chat_state(state, event)
    CompactionTrigger.maybe_mark_pending_compaction_near_limit(state, event)
    retried? = RetryHandler.maybe_retry_zero_answer_failure(state, event)

    {:next_state, :presenting, state, [{:next_event, :internal, {:present, event, retried?}}]}
  end

  @impl true
  def terminate(reason, phase, state) do
    if is_pid(state.coordinator_pid) do
      send(state.coordinator_pid, {:run_process_terminated, state.run_id, reason})
    end

    if reason != :normal do
      if state.run_ref && state.executor,
        do: Execution.control(state.executor, :cancel, state.control_ctx)

      _ = release_execution(state)

      if committed_execution?(phase, state.run_id) do
        TerminalOutbox.failed(state.run_id, :presentation)
        record_termination(state, :answer_presentation_failed, reason)
      else
        record_termination(state, :run_failed, reason)
        LemonRouter.RunCountTracker.record_terminal(state.run_id, true)
        terminalize_crashed_owner(state, reason)
      end
    end

    SurfaceManager.flush_all(state)
    LemonCore.EventBridge.unsubscribe_run(state.run_id)
    :ok
  end

  defp record_termination(state, type, reason) do
    Introspection.record(
      type,
      %{reason: CompactionTrigger.safe_error_label(reason)},
      run_id: state.run_id,
      session_key: state.session_key,
      engine: "lemon",
      provenance: :direct
    )
  end

  # An owner failure is advisory. The one durable completion, below, is what
  # releases terminal-only subscribers and survives restart.
  defp terminalize_crashed_owner(state, reason) do
    new_event(
      state,
      :run_failed,
      Events.RunFailed.new(%{
        run_id: state.run_id,
        session_key: state.session_key,
        reason: Execution.exit_class(reason)
      }),
      %{synthetic: true}
    )
    |> LemonCore.Event.identify_run(state.run_id, attempt_id(state))
    |> Bus.publish_run_lifecycle()

    event =
      new_event(
        state,
        :run_completed,
        Events.RunCompleted.new(%{
          completed:
            Events.Completion.new(%{
              ok: false,
              error: :run_owner_terminated,
              answer: state.accumulated_text,
              meta: cancellation_meta(state)
            }),
          duration_ms: nil
        }),
        %{synthetic: true}
      )

    _ = RunCompletion.finalize(state.execution_request, event, router_owned: true)
  catch
    _kind, _reason -> :ok
  end

  defp present(state, event, retried?) do
    # Mark any still-running tool calls as completed so the editable "Tool calls"
    # status message (Telegram) can't get stuck at [running] if a final action
    # completion event is missed/raced.
    SurfaceManager.finalize_status(state, event)

    # If we never streamed deltas, make sure any tool-status output is flushed
    # before we emit a single final answer chunk.
    if state.saw_delta == false do
      SurfaceManager.flush_status(state)
    end

    if retried? do
      :ok
    else
      {artifact_status, extra_meta} = safe_finalize_meta(state, event)
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
      delivery = SurfaceManager.finalize_answer(state, surface_event, extra_meta)

      Introspection.record(
        :answer_finalize_completed,
        %{saw_delta: state.saw_delta},
        run_id: state.run_id,
        session_key: state.session_key,
        engine: "lemon",
        provenance: :direct
      )

      # Optional fanout: forward the final answer text to additional destinations.
      fanout = SurfaceManager.fanout_final_answer(state, surface_event)

      if delivery == :ok and fanout == :ok and artifact_status == :ok and
           media_recording.failed_count == 0,
         do: :ok,
         else: {:error, :presentation_failed}
    end
  end

  defp committed_execution?(:presenting, _run_id), do: true

  defp committed_execution?(_phase, run_id) do
    # An unavailable authority is not evidence that execution failed.
    LemonCore.TerminalOutbox.decision(run_id) != {:ok, nil}
  end

  @doc false
  def replay_presentation(
        run_id,
        %{started_at: started_at, summary: %{session_key: session_key} = summary} = record
      ) do
    cond do
      is_nil(Process.whereis(LemonRouter.RunRegistry)) ->
        :busy

      Registry.lookup(LemonRouter.RunRegistry, run_id) != [] ->
        :busy

      true ->
        event = LemonCore.TerminalOutbox.event(run_id, summary)

        state = %{
          run_id: run_id,
          session_key: session_key,
          saw_delta: false,
          terminal_replay: true,
          execution_request: %ExecutionCommand{
            run_id: run_id,
            session_key: session_key,
            meta: summary[:meta],
            cwd: summary[:presentation_cwd],
            prompt: summary[:prompt]
          }
        }

        state =
          Enum.reduce(record[:events] || [], state, fn
            %{__event__: :action_event} = action, acc ->
              acc
              |> ArtifactTracker.track_generated_images(action)
              |> ArtifactTracker.track_requested_send_files(action)

            _, acc ->
              acc
          end)

        :ok = LemonRouter.RunReceiptStore.retain_terminal_evidence(run_id)

        with :ok <- replay_conversation_projections(state, event, started_at) do
          present(state, event, false)
        end
    end
  end

  defp replay_conversation_projections(state, event, started_at) do
    with {:ok, index} <- LemonCore.RunStore.fetch_session_index(state.session_key) do
      if Registry.lookup(LemonRouter.SessionRegistry, state.session_key) == [] and
           is_map(index) and index.updated_at_ms <= started_at do
        CompactionTrigger.maybe_reset_resume_on_context_overflow(state, event)
        CompactionTrigger.maybe_store_chat_state(state, event)
        CompactionTrigger.maybe_mark_pending_compaction_near_limit(state, event)
      end

      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp artifact_tracker(%{artifact_tracker: mod}) when is_atom(mod), do: mod
  defp artifact_tracker(_state), do: ArtifactTracker

  # Trackers implement finalize_meta/2. Probing with function_exported?/3 was
  # wrong: it is false until the module is loaded, so the first finalized run
  # after boot silently dropped final-answer MEDIA directives.
  defp safe_finalize_meta(state, event) do
    answer = CompactionTrigger.extract_completed_answer(event)
    {:ok, artifact_tracker(state).finalize_meta(state, answer)}
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

      {:error, %{}}
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

  defp tool_start?(action_ev) when is_map(action_ev) do
    phase = Map.get(action_ev, :phase) || Map.get(action_ev, "phase")
    phase in [:started, "started"]
  end

  defp tool_start?(_), do: false
end
