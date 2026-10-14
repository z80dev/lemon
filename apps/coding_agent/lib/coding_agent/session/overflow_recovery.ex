defmodule CodingAgent.Session.OverflowRecovery do
  @moduledoc """
  One attempt per turn to recover from a context-length error: compact in
  the background, then retry the turn. Its slot in the session state is one
  field, `overflow_recovery`, holding a
  `CodingAgent.Session.OverflowRecovery.State`.
  """

  alias CodingAgent.Session.CompactionLifecycle
  alias CodingAgent.Session.CompactionManager

  defmodule State do
    @moduledoc """
    Overflow recovery's slot in the session state: whether a recovery is
    running and whether one was already attempted this turn, the session
    signature it captured, the task it tracks, and the error it is recovering
    from (kept so the failure can be re-broadcast if the retry also fails).
    """

    @type t :: %__MODULE__{
            in_progress: boolean(),
            attempted: boolean(),
            signature: CodingAgent.Session.CompactionManager.session_signature() | nil,
            task_pid: pid() | nil,
            task_monitor_ref: reference() | nil,
            task_timeout_ref: reference() | nil,
            started_at_ms: non_neg_integer() | nil,
            error_reason: term() | nil,
            partial_state: term() | nil
          }

    defstruct in_progress: false,
              attempted: false,
              signature: nil,
              task_pid: nil,
              task_monitor_ref: nil,
              task_timeout_ref: nil,
              started_at_ms: nil,
              error_reason: nil,
              partial_state: nil
  end

  @type callbacks(state) :: %{
          required(:restore_messages_from_session) => (map() -> [map()]),
          required(:broadcast_event) => (state, LemonAgent.Types.agent_event() -> :ok),
          required(:handle_agent_event) => (LemonAgent.Types.agent_event(), state -> state)
        }

  @spec handle_task_down(map(), callbacks(map())) :: map()
  def handle_task_down(state, callbacks) do
    state = CompactionManager.clear_overflow_recovery_task_tracking(state)

    cond do
      not state.overflow_recovery.in_progress ->
        state

      true ->
        failure_reason = :overflow_recovery_task_down
        failed_state = CompactionManager.clear_overflow_recovery_task_state(state)

        CompactionManager.emit_overflow_recovery_telemetry(:failure, failed_state, %{
          duration_ms: CompactionManager.overflow_recovery_duration_ms(state),
          reason: CompactionManager.normalize_overflow_reason(failure_reason)
        })

        finalize_failure(failed_state, failure_reason, callbacks)
    end
  end

  @spec maybe_start(map(), term(), term(), pid()) :: {:ok, map()} | :no_recovery
  def maybe_start(state, reason, partial_state, session_pid) do
    failed_message = latest_failed_assistant(partial_state)
    details = if failed_message, do: Map.get(failed_message, :error_details)

    cond do
      not state.is_streaming ->
        :no_recovery

      state.overflow_recovery.in_progress ->
        :no_recovery

      state.overflow_recovery.attempted ->
        :no_recovery

      is_map(details) and
          (Map.get(details, :output_committed) == true or
             Map.get(details, "output_committed") == true) ->
        :no_recovery

      not provider_failure?(reason) ->
        :no_recovery

      not (CompactionManager.context_length_exceeded_error?(details) or
               CompactionManager.context_length_exceeded_error?(reason)) ->
        :no_recovery

      true ->
        state = discard_failed_assistant(state)
        signature = CompactionManager.session_signature(state)
        session_manager = state.session_manager
        model = state.model
        started_at_ms = System.monotonic_time(:millisecond)
        compaction_opts = CompactionManager.overflow_recovery_compaction_opts(state)

        CodingAgent.Session.Notifier.broadcast_event(
          state,
          {:compaction_start, %{reason: :overflow}}
        )

        CompactionManager.emit_overflow_recovery_telemetry(:attempt, state, %{
          reason: CompactionManager.normalize_overflow_reason(reason)
        })

        case CompactionManager.start_tracked_background_task(
               fn ->
                 result =
                   CompactionManager.overflow_recovery_compaction_task_result(
                     session_manager,
                     model,
                     compaction_opts
                   )

                 send(session_pid, {:overflow_recovery_result, signature, result})
               end,
               CompactionManager.overflow_recovery_task_timeout_ms(),
               :overflow_recovery_task_timeout
             ) do
          {:ok, task_meta} ->
            {:ok,
             %{
               state
               | overflow_recovery: %State{
                   in_progress: true,
                   attempted: true,
                   signature: signature,
                   task_pid: task_meta.pid,
                   task_monitor_ref: task_meta.monitor_ref,
                   task_timeout_ref: task_meta.timeout_ref,
                   started_at_ms: started_at_ms,
                   error_reason: reason,
                   partial_state: partial_state
                 }
             }}
        end
    end
  end

  defp latest_failed_assistant(%{new_messages: messages}), do: latest_failed_assistant(messages)
  defp latest_failed_assistant(%{messages: messages}), do: latest_failed_assistant(messages)

  defp latest_failed_assistant(messages) when is_list(messages) do
    Enum.reduce(messages, nil, fn
      %{role: :assistant, stop_reason: :error} = message, _latest -> message
      _message, latest -> latest
    end)
  end

  defp latest_failed_assistant(_partial_state), do: nil

  defp provider_failure?(reason) when reason in [:assistant_error, :context_length_exceeded],
    do: true

  defp provider_failure?({tag, _reason})
       when tag in [:assistant_error, :provider_error, :stream_error],
       do: true

  defp provider_failure?({:http_error, _status, _body}), do: true
  defp provider_failure?({:http_error, _status, _body, _headers}), do: true
  defp provider_failure?(reason) when is_binary(reason), do: true
  defp provider_failure?(%{category: _category}), do: true
  defp provider_failure?(_reason), do: false

  @spec handle_result(map(), term(), {:ok, map()} | {:error, term()}, callbacks(map())) :: map()
  def handle_result(state, signature, result, callbacks) do
    cond do
      not state.overflow_recovery.in_progress ->
        state

      state.overflow_recovery.signature != signature ->
        state

      signature != CompactionManager.session_signature(state) ->
        CompactionManager.clear_overflow_recovery_task_state(state)

      true ->
        state = CompactionManager.clear_overflow_recovery_task_state(state)

        case CompactionLifecycle.apply_result(state, result, nil, callbacks) do
          {:ok, compacted_state} ->
            case continue_after_compaction(compacted_state) do
              {:ok, resumed_state} ->
                CompactionManager.emit_overflow_recovery_telemetry(:success, resumed_state, %{
                  duration_ms: CompactionManager.overflow_recovery_duration_ms(state)
                })

                resumed_state

              {:error, reason, failed_state} ->
                CompactionManager.emit_overflow_recovery_telemetry(:failure, failed_state, %{
                  duration_ms: CompactionManager.overflow_recovery_duration_ms(state),
                  reason: CompactionManager.normalize_overflow_reason(reason)
                })

                finalize_failure(failed_state, reason, callbacks)
            end

          {:error, reason, failed_state} ->
            CompactionManager.emit_overflow_recovery_telemetry(:failure, failed_state, %{
              duration_ms: CompactionManager.overflow_recovery_duration_ms(state),
              reason: CompactionManager.normalize_overflow_reason(reason)
            })

            finalize_failure(failed_state, reason, callbacks)
        end
    end
  end

  @spec handle_timeout(map(), reference(), callbacks(map())) :: {:handled, map()} | :stale
  def handle_timeout(state, monitor_ref, callbacks) do
    if state.overflow_recovery.task_monitor_ref == monitor_ref do
      failure_reason = :overflow_recovery_timeout

      failed_state =
        state
        |> CompactionManager.maybe_kill_background_task(
          state.overflow_recovery.task_pid,
          :overflow_recovery_timeout
        )
        |> CompactionManager.clear_overflow_recovery_task_state()

      CompactionManager.emit_overflow_recovery_telemetry(:failure, failed_state, %{
        duration_ms: CompactionManager.overflow_recovery_duration_ms(state),
        reason: CompactionManager.normalize_overflow_reason(failure_reason)
      })

      {:handled, finalize_failure(failed_state, failure_reason, callbacks)}
    else
      :stale
    end
  end

  defp continue_after_compaction(state) do
    case LemonAgent.Agent.wait_for_idle(state.agent, timeout: 5_000) do
      :ok ->
        case LemonAgent.Agent.continue(state.agent) do
          :ok ->
            {:ok,
             %{
               state
               | is_streaming: true,
                 overflow_recovery: %{
                   state.overflow_recovery
                   | error_reason: nil,
                     partial_state: nil
                 }
             }}

          {:error, reason} ->
            {:error, reason, state}
        end

      {:error, :timeout} ->
        {:error, :wait_for_idle_timeout, state}
    end
  end

  defp discard_failed_assistant(state) do
    session = state.session_manager

    case CodingAgent.SessionManager.get_entry(session, session.leaf_id) do
      %{
        type: :message,
        message: %{"role" => "assistant", "stop_reason" => reason},
        parent_id: parent_id
      }
      when reason in ["error", "aborted"] ->
        session = CodingAgent.SessionManager.set_leaf_id(session, parent_id)
        messages = CodingAgent.Session.Persistence.restore_messages_from_session(session)
        :ok = LemonAgent.Agent.replace_messages(state.agent, messages)
        %{state | session_manager: session}

      _ ->
        state
    end
  end

  defp finalize_failure(state, fallback_reason, callbacks) do
    reason = state.overflow_recovery.error_reason || fallback_reason
    event = {:error, reason, state.overflow_recovery.partial_state}

    callbacks.broadcast_event.(state, event)
    state = callbacks.handle_agent_event.(event, state)
    CompactionManager.clear_overflow_recovery_state_on_terminal(event, state)
  end
end
