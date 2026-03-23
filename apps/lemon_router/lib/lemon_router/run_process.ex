defmodule LemonRouter.RunProcess do
  @moduledoc """
  Process that owns a single run lifecycle.

  `RunProcess` expects a router-built `%LemonGateway.ExecutionRequest{}` at init
  time. Router-owned conversation identity must already be resolved before this
  process submits work into the gateway.

  Each RunProcess:
  - Owns a run_id
  - Manages abort state
  - Subscribes to Bus for run events
  - Maintains metadata snapshot
  - Emits router-level events

  Heavy logic is delegated to focused submodules:
  - `RunProcess.Watchdog` -- idle-run watchdog timer
  - `RunProcess.CompactionTrigger` -- context-overflow & compaction markers
  - `RunProcess.RetryHandler` -- zero-answer auto-retry
  - `RunProcess.OutputTracker` -- delta ingestion, final output, fanout, file tracking
  """

  use GenServer

  require Logger

  alias LemonGateway.ExecutionRequest
  alias LemonCore.{Bus, Introspection}
  alias LemonRouter.RunProcess.{CompactionTrigger, OutputTracker, RetryHandler, Watchdog}

  @gateway_submit_retry_base_ms 100
  @gateway_submit_retry_max_ms 2_000
  @abort_completion_grace_ms 150
  @gateway_bind_grace_ms 200
  @gateway_missing_completion_grace_ms 1_500

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

  @doc false
  defdelegate estimate_input_tokens_from_prompt(state),
    to: CompactionTrigger

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    run_id = opts[:run_id]
    init_session_key = opts[:session_key]
    gateway_scheduler = opts[:gateway_scheduler] || LemonGateway.Scheduler
    run_orchestrator = opts[:run_orchestrator] || LemonRouter.RunOrchestrator
    run_watchdog_timeout_ms = Watchdog.resolve_run_watchdog_timeout_ms(opts)
    run_watchdog_confirm_timeout_ms = Watchdog.resolve_run_watchdog_confirm_timeout_ms(opts)

    with %ExecutionRequest{} = request <- opts[:execution_request],
         {:ok, execution_request} <-
           normalize_execution_request(
             request,
             init_session_key,
             opts[:conversation_key],
             run_id
           ) do
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
        aborted: false,
        completed: false,
        saw_delta: false,
        run_started_at_ms: nil,
        run_last_activity_at_ms: nil,
        run_watchdog_timeout_ms: run_watchdog_timeout_ms,
        run_watchdog_confirm_timeout_ms: run_watchdog_confirm_timeout_ms,
        run_watchdog_ref: nil,
        run_watchdog_confirmation_ref: nil,
        run_watchdog_awaiting_confirmation?: false,
        submit_to_gateway?: submit_to_gateway?,
        gateway_scheduler: gateway_scheduler,
        run_orchestrator: run_orchestrator,
        gateway_submit_attempt: 0,
        gateway_submitted?: false,
        gateway_run_pid: nil,
        gateway_run_ref: nil,
        coordinator_pid: opts[:coordinator_pid],
        conversation_key: execution_request.conversation_key,
        generated_image_paths: [],
        requested_send_files: [],
        task_status_surfaces: %{},
        task_status_refs: %{}
      }

      Logger.debug(
        "RunProcess init run_id=#{inspect(run_id)} session_key=#{inspect(session_key)} " <>
          "engine=#{inspect(execution_request && execution_request.engine_id)} " <>
          "queue_mode=#{inspect(queue_mode)} " <>
          "submit_to_gateway?=#{inspect(submit_to_gateway?)}"
      )

      # Emit introspection event for run start
      Introspection.record(
        :run_started,
        %{
          engine_id: execution_request && execution_request.engine_id,
          queue_mode: queue_mode
        },
        run_id: run_id,
        session_key: session_key,
        engine: "lemon",
        provenance: :direct
      )

      # Submit to gateway
      if submit_to_gateway? do
        send(self(), :submit_to_gateway)
      end

      {:ok, state}
    else
      _ -> {:stop, {:invalid_execution_request, run_id}}
    end
  end

  @impl true
  def handle_info(:submit_to_gateway, state) do
    cond do
      state.gateway_submitted? or state.aborted or state.completed ->
        {:noreply, state}

      scheduler_available?(state.gateway_scheduler) ->
        submit_gateway_execution(state.gateway_scheduler, state)

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
    Bus.broadcast(Bus.session_topic(state.session_key), event)

    state =
      state
      |> Watchdog.schedule_run_watchdog()
      |> maybe_monitor_gateway_run()

    if is_nil(state.gateway_run_pid) do
      Process.send_after(self(), :ensure_gateway_bound, @gateway_bind_grace_ms)
    end

    {:noreply, state}
  end

  def handle_info(%LemonCore.Event{type: :run_completed} = event, state) do
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
      run_id: state.run_id,
      session_key: state.session_key,
      engine: "lemon",
      provenance: :direct
    )

    # If we were monitoring the gateway run process, stop monitoring it before we exit so
    # we don't race a :DOWN message and emit a synthetic completion.
    state =
      state
      |> Watchdog.cancel_run_watchdog()
      |> Watchdog.cancel_run_watchdog_confirmation()
      |> maybe_demonitor_gateway_run()

    # Emit router-level completion event
    Bus.broadcast(Bus.session_topic(state.session_key), event)

    # If the engine reports a context-window overflow, clear resume state so
    # the next message can start fresh instead of immediately failing again.
    CompactionTrigger.maybe_reset_resume_on_context_overflow(state, event)
    CompactionTrigger.maybe_mark_pending_compaction_near_limit(state, event)
    retried? = RetryHandler.maybe_retry_zero_answer_failure(state, event)

    # Mark any still-running tool calls as completed so the editable "Tool calls"
    # status message (Telegram) can't get stuck at [running] if a final action
    # completion event is missed/raced.
    OutputTracker.finalize_tool_status(state, event)

    # If we never streamed deltas, make sure any tool-status output is flushed
    # before we emit a single final answer chunk.
    if state.saw_delta == false do
      OutputTracker.flush_tool_status(state)
    end

    unless retried? do
      # Telegram: StreamCoalescer finalizes by sending/editing a dedicated answer message; the
      # progress message is reserved for tool-call status + cancel UI and is never overwritten.
      OutputTracker.maybe_finalize_stream_output(state, event)

      # If no streaming deltas were emitted, emit a final output chunk so channels respond.
      OutputTracker.maybe_emit_final_output(state, event)

      # Optional fanout: forward the final answer text to additional destinations.
      OutputTracker.maybe_fanout_final_output(state, event)
    end

    {:stop, :normal, %{state | completed: true}}
  end

  def handle_info(%LemonCore.Event{type: :delta, payload: delta} = event, state) do
    state = Watchdog.touch_run_watchdog(state)

    # Forward delta to session subscribers
    Bus.broadcast(Bus.session_topic(state.session_key), event)

    # Finalize the previous tool-status segment before we start streaming a new answer chunk.
    if state.saw_delta == false do
      OutputTracker.commit_tool_status_segment(state)
    end

    # Also ingest into StreamCoalescer for channel delivery
    OutputTracker.ingest_delta_to_coalescer(state, delta)

    {:noreply, %{state | saw_delta: true}}
  end

  def handle_info(%LemonCore.Event{type: :engine_action, payload: action_ev} = event, state) do
    state = Watchdog.touch_run_watchdog(state)

    {state, tool_status_surface, capture_current_turn?} =
      OutputTracker.prepare_tool_status_action(state, action_ev)

    state =
      if state.saw_delta and is_tool_start?(action_ev) and capture_current_turn? do
        OutputTracker.handoff_stream_turn_to_tool_status(state, tool_status_surface)
        %{state | saw_delta: false}
      else
        state
      end

    # Forward engine action events to session subscribers
    Bus.broadcast(Bus.session_topic(state.session_key), event)

    # Also ingest into ToolStatusCoalescer for channel delivery
    OutputTracker.ingest_action_to_tool_status_coalescer(state, action_ev, tool_status_surface)

    state = OutputTracker.maybe_track_generated_images(state, action_ev)
    state = OutputTracker.maybe_track_requested_send_files(state, action_ev)

    {:noreply, state}
  end

  def handle_info(%LemonCore.Event{type: :task_projected_child_action, payload: action_ev}, state) do
    state = Watchdog.touch_run_watchdog(state)

    {state, tool_status_surface, _capture_current_turn?} =
      OutputTracker.prepare_tool_status_action(state, action_ev)

    OutputTracker.ingest_projected_child_action_to_tool_status_coalescer(
      state,
      action_ev,
      tool_status_surface
    )

    {:noreply, state}
  end

  def handle_info(%LemonCore.Event{} = event, state) do
    state = Watchdog.touch_run_watchdog(state)

    # Forward other events to session subscribers
    Bus.broadcast(Bus.session_topic(state.session_key), event)
    {:noreply, state}
  end

  def handle_info(:run_watchdog_timeout, state) do
    state = %{state | run_watchdog_ref: nil}

    if state.completed do
      {:noreply, state}
    else
      state = Watchdog.touch_run_watchdog_activity(state)

      cond do
        state.run_watchdog_awaiting_confirmation? ->
          {:noreply, state}

        true ->
          case Watchdog.maybe_request_watchdog_confirmation(state) do
            {:ok, next_state} -> {:noreply, next_state}
            :error -> {:noreply, Watchdog.fail_run_for_idle_timeout(state)}
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
      {:noreply, Watchdog.fail_run_for_idle_timeout(state)}
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

  def handle_info({:finalize_aborted_run, reason}, state) do
    cond do
      state.completed or not state.aborted ->
        {:noreply, state}

      gateway_run_pid(state.run_id) != nil ->
        LemonGateway.Runtime.cancel_by_run_id(state.run_id, reason)
        {:noreply, maybe_monitor_gateway_run(state)}

      true ->
        Logger.warning(
          "RunProcess finalizing aborted run without gateway pid run_id=#{inspect(state.run_id)} " <>
            "session_key=#{inspect(state.session_key)} reason=#{inspect(reason)}"
        )

        event =
          LemonCore.Event.new(
            :run_completed,
            %{
              completed: %{
                ok: false,
                error: reason,
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

  def handle_info(:ensure_gateway_bound, state) do
    cond do
      state.completed ->
        {:noreply, state}

      not is_nil(state.gateway_run_pid) ->
        {:noreply, state}

      gateway_run_pid(state.run_id) != nil ->
        {:noreply, maybe_monitor_gateway_run(state)}

      true ->
        Logger.warning(
          "RunProcess started without gateway pid; awaiting completion grace run_id=#{inspect(state.run_id)} " <>
            "session_key=#{inspect(state.session_key)}"
        )

        Process.send_after(
          self(),
          :finalize_missing_gateway_after_start,
          @gateway_missing_completion_grace_ms
        )

        {:noreply, state}
    end
  rescue
    _ -> {:noreply, state}
  end

  def handle_info(:finalize_missing_gateway_after_start, state) do
    cond do
      state.completed ->
        {:noreply, state}

      not is_nil(state.gateway_run_pid) ->
        {:noreply, state}

      gateway_run_pid(state.run_id) != nil ->
        {:noreply, maybe_monitor_gateway_run(state)}

      true ->
        Logger.warning(
          "RunProcess finalizing started run without gateway pid after completion grace " <>
            "run_id=#{inspect(state.run_id)} session_key=#{inspect(state.session_key)}"
        )

        event =
          LemonCore.Event.new(
            :run_completed,
            %{
              completed: %{
                ok: false,
                error: :gateway_run_missing_after_start,
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

      if is_nil(state.gateway_run_pid) do
        Process.send_after(self(), {:finalize_aborted_run, reason}, @abort_completion_grace_ms)
      end

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
          |> Watchdog.clear_watchdog_confirmation()
          |> Watchdog.schedule_run_watchdog()

        {:noreply, state}

      decision in [:cancel, :stop, :kill] ->
        Logger.warning(
          "RunProcess watchdog keepalive cancelled by user run_id=#{inspect(state.run_id)} " <>
            "session_key=#{inspect(state.session_key)}"
        )

        {:noreply, Watchdog.fail_run_for_user_cancel(state)}

      true ->
        {:noreply, state}
    end
  end

  @impl true
  def terminate(reason, state) do
    if is_pid(state.coordinator_pid) do
      send(state.coordinator_pid, {:run_process_terminated, state.run_id, reason})
    end

    # If not completed normally, emit failure event and attempt abort
    if reason != :normal and not state.completed do
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
    OutputTracker.flush_coalescer(state)

    # Unsubscribe control-plane EventBridge from run events
    unsubscribe_event_bridge(state.run_id)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Gateway monitoring
  # ---------------------------------------------------------------------------

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

  defp gateway_run_pid(run_id) when is_binary(run_id) do
    case Registry.lookup(LemonGateway.RunRegistry, run_id) do
      [{pid, _}] when is_pid(pid) -> pid
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp gateway_run_pid(_), do: nil

  # ---------------------------------------------------------------------------
  # Utility helpers
  # ---------------------------------------------------------------------------

  defp submit_gateway_execution(scheduler, state) do
    if is_map(state.execution_request) and function_exported?(scheduler, :submit_execution, 1) do
      scheduler.submit_execution(
        ExecutionRequest.ensure_conversation_key(state.execution_request)
      )
    else
      :ok
    end
  end

  defp normalize_execution_request(
         %ExecutionRequest{} = request,
         session_key,
         conversation_key,
         run_id
       ) do
    normalized_request = %{
      request
      | session_key: request.session_key || session_key,
        conversation_key: request.conversation_key || conversation_key
    }

    {:ok, ExecutionRequest.ensure_conversation_key(normalized_request)}
  rescue
    ArgumentError ->
      {:error, {:invalid_execution_request, run_id}}
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

  defp is_tool_start?(action_ev) when is_map(action_ev) do
    phase = Map.get(action_ev, :phase) || Map.get(action_ev, "phase")
    phase in [:started, "started"]
  end

  defp is_tool_start?(_), do: false

  @spec gateway_submit_retry_delay_ms(non_neg_integer()) :: non_neg_integer()
  defp gateway_submit_retry_delay_ms(attempt) when is_integer(attempt) and attempt >= 0 do
    exponential = @gateway_submit_retry_base_ms * :math.pow(2, attempt)
    delay_ms = round(exponential)
    min(delay_ms, @gateway_submit_retry_max_ms)
  end
end
