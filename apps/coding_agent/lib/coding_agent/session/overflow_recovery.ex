defmodule CodingAgent.Session.OverflowRecovery do
  @moduledoc false

  require Logger

  alias CodingAgent.Session.CompactionLifecycle
  alias CodingAgent.Session.CompactionManager

  @type callbacks(state) :: %{
          required(:restore_messages_from_session) => (map() -> [map()]),
          required(:broadcast_event) => (state, AgentCore.Types.agent_event() -> :ok),
          required(:ui_set_working_message) => (state, String.t() | nil -> :ok),
          required(:ui_notify) => (state, String.t(), atom() -> :ok),
          required(:handle_agent_event) => (AgentCore.Types.agent_event(), state -> state)
        }

  @spec handle_task_down(map(), callbacks(map())) :: map()
  def handle_task_down(state, callbacks) do
    state = CompactionManager.clear_overflow_recovery_task_tracking(state)

    cond do
      not state.overflow_recovery_in_progress ->
        state

      true ->
        failure_reason = :overflow_recovery_task_down
        failed_state = CompactionManager.clear_overflow_recovery_task_state(state)

        callbacks.ui_notify.(
          failed_state,
          "Overflow compaction worker stopped unexpectedly",
          :error
        )

        CompactionManager.emit_overflow_recovery_telemetry(:failure, failed_state, %{
          duration_ms: CompactionManager.overflow_recovery_duration_ms(state),
          reason: CompactionManager.normalize_overflow_reason(failure_reason)
        })

        finalize_failure(failed_state, failure_reason, callbacks)
    end
  end

  @spec maybe_start(map(), term(), term(), pid(), callbacks(map())) :: {:ok, map()} | :no_recovery
  def maybe_start(state, reason, partial_state, session_pid, callbacks) do
    cond do
      not state.is_streaming ->
        :no_recovery

      state.overflow_recovery_in_progress ->
        :no_recovery

      state.overflow_recovery_attempted ->
        :no_recovery

      not CompactionManager.context_length_exceeded_error?(reason) ->
        :no_recovery

      true ->
        signature = CompactionManager.session_signature(state)
        session_manager = state.session_manager
        model = state.model
        started_at_ms = System.monotonic_time(:millisecond)
        compaction_opts = CompactionManager.overflow_recovery_compaction_opts(state)

        callbacks.ui_notify.(state, "Context window exceeded. Compacting and retrying...", :info)

        callbacks.ui_set_working_message.(
          state,
          "Context overflow detected. Compacting and retrying..."
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
               | overflow_recovery_in_progress: true,
                 overflow_recovery_attempted: true,
                 overflow_recovery_signature: signature,
                 overflow_recovery_task_pid: task_meta.pid,
                 overflow_recovery_task_monitor_ref: task_meta.monitor_ref,
                 overflow_recovery_task_timeout_ref: task_meta.timeout_ref,
                 overflow_recovery_started_at_ms: started_at_ms,
                 overflow_recovery_error_reason: reason,
                 overflow_recovery_partial_state: partial_state
             }}

          {:error, task_reason} ->
            Logger.warning(
              "Overflow recovery background task failed to start: #{inspect(task_reason)}"
            )

            :no_recovery
        end
    end
  end

  @spec handle_result(map(), term(), {:ok, map()} | {:error, term()}, callbacks(map())) :: map()
  def handle_result(state, signature, result, callbacks) do
    cond do
      not state.overflow_recovery_in_progress ->
        state

      state.overflow_recovery_signature != signature ->
        state

      signature != CompactionManager.session_signature(state) ->
        CompactionManager.clear_overflow_recovery_task_state(state)

      true ->
        state = CompactionManager.clear_overflow_recovery_task_state(state)

        case CompactionLifecycle.apply_result(state, result, nil, callbacks) do
          {:ok, compacted_state} ->
            case continue_after_compaction(compacted_state, callbacks) do
              {:ok, resumed_state} ->
                CompactionManager.emit_overflow_recovery_telemetry(:success, resumed_state, %{
                  duration_ms: CompactionManager.overflow_recovery_duration_ms(state)
                })

                resumed_state

              {:error, reason, failed_state} ->
                callbacks.ui_notify.(
                  failed_state,
                  "Auto-retry failed after compaction: #{inspect(reason)}",
                  :error
                )

                CompactionManager.emit_overflow_recovery_telemetry(:failure, failed_state, %{
                  duration_ms: CompactionManager.overflow_recovery_duration_ms(state),
                  reason: CompactionManager.normalize_overflow_reason(reason)
                })

                finalize_failure(failed_state, reason, callbacks)
            end

          {:error, reason, failed_state} ->
            callbacks.ui_notify.(
              failed_state,
              "Overflow compaction failed: #{inspect(reason)}",
              :error
            )

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
    if state.overflow_recovery_task_monitor_ref == monitor_ref do
      failure_reason = :overflow_recovery_timeout

      failed_state =
        state
        |> CompactionManager.maybe_kill_background_task(
          state.overflow_recovery_task_pid,
          :overflow_recovery_timeout
        )
        |> CompactionManager.clear_overflow_recovery_task_state()

      callbacks.ui_notify.(failed_state, "Overflow compaction timed out", :error)

      CompactionManager.emit_overflow_recovery_telemetry(:failure, failed_state, %{
        duration_ms: CompactionManager.overflow_recovery_duration_ms(state),
        reason: CompactionManager.normalize_overflow_reason(failure_reason)
      })

      {:handled, finalize_failure(failed_state, failure_reason, callbacks)}
    else
      :stale
    end
  end

  defp continue_after_compaction(state, callbacks) do
    case AgentCore.Agent.wait_for_idle(state.agent, timeout: 5_000) do
      :ok ->
        callbacks.ui_set_working_message.(state, "Retrying after compaction...")

        case AgentCore.Agent.continue(state.agent) do
          :ok ->
            {:ok,
             %{
               state
               | is_streaming: true,
                 overflow_recovery_error_reason: nil,
                 overflow_recovery_partial_state: nil
             }}

          {:error, reason} ->
            {:error, reason, state}
        end

      {:error, :timeout} ->
        {:error, :wait_for_idle_timeout, state}
    end
  end

  defp finalize_failure(state, fallback_reason, callbacks) do
    reason = state.overflow_recovery_error_reason || fallback_reason
    event = {:error, reason, state.overflow_recovery_partial_state}

    callbacks.broadcast_event.(state, event)
    state = callbacks.handle_agent_event.(event, state)
    CompactionManager.clear_overflow_recovery_state_on_terminal(event, state)
  end
end
