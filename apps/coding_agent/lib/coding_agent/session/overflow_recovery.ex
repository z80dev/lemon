defmodule CodingAgent.Session.OverflowRecovery do
  @moduledoc """
  Orchestrates context window overflow recovery for sessions.

  When the LLM reports a context length exceeded error, this module coordinates
  an automatic compaction-and-retry cycle: it starts a background compaction task,
  applies the result, and resumes the agent loop.
  """

  require Logger

  alias CodingAgent.Session.CompactionManager

  # ============================================================================
  # Overflow Recovery Initiation
  # ============================================================================

  @doc """
  Attempt to start overflow recovery when an error event is received.

  Returns `{:ok, new_state}` if recovery was initiated, or `:no_recovery` if
  the error does not qualify (not streaming, already attempted, not a context
  length error, etc.).
  """
  @spec maybe_start(map(), term(), term(), (map(), String.t() | nil -> :ok),
          (map(), String.t(), atom() -> :ok)) ::
          {:ok, map()} | :no_recovery
  def maybe_start(state, reason, partial_state, ui_set_working_fn, ui_notify_fn) do
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
        session_pid = self()
        session_manager = state.session_manager
        model = state.model
        started_at_ms = System.monotonic_time(:millisecond)
        compaction_opts = CompactionManager.overflow_recovery_compaction_opts(state)

        ui_notify_fn.(state, "Context window exceeded. Compacting and retrying...", :info)
        ui_set_working_fn.(state, "Context overflow detected. Compacting and retrying...")

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

  # ============================================================================
  # Post-Compaction Continuation
  # ============================================================================

  @doc """
  Continue the agent loop after a successful overflow compaction.

  Waits for the agent to become idle, then issues a `continue` command.
  Returns `{:ok, new_state}` or `{:error, reason, state}`.
  """
  @spec continue_after_compaction(map(), (map(), String.t() | nil -> :ok)) ::
          {:ok, map()} | {:error, term(), map()}
  def continue_after_compaction(state, ui_set_working_fn) do
    case AgentCore.Agent.wait_for_idle(state.agent, timeout: 5_000) do
      :ok ->
        ui_set_working_fn.(state, "Retrying after compaction...")

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

  # ============================================================================
  # Failure Finalization
  # ============================================================================

  @doc """
  Finalize an overflow recovery failure by broadcasting the original error event
  and transitioning to a terminal state.

  The `handle_agent_event_fn` callback is used to process the error event through
  the normal event handler pipeline.
  """
  @spec finalize_failure(map(), term(), (map(), term() -> :ok), (term(), map(), map() -> map())) ::
          map()
  def finalize_failure(state, fallback_reason, broadcast_event_fn, handle_agent_event_fn) do
    reason = state.overflow_recovery_error_reason || fallback_reason
    event = {:error, reason, state.overflow_recovery_partial_state}

    broadcast_event_fn.(state, event)
    state = handle_agent_event_fn.(event, state)
    CompactionManager.clear_overflow_recovery_state_on_terminal(event, state)
  end

  # ============================================================================
  # Task Down Handling
  # ============================================================================

  @doc """
  Handle the case when the overflow recovery background task process goes down.

  Cleans up task tracking state and finalizes the failure if recovery was in progress.
  """
  @spec handle_task_down(map(), (map(), String.t(), atom() -> :ok)) :: map()
  def handle_task_down(state, ui_notify_fn) do
    state = CompactionManager.clear_overflow_recovery_task_tracking(state)

    cond do
      not state.overflow_recovery_in_progress ->
        state

      true ->
        failure_reason = :overflow_recovery_task_down
        failed_state = CompactionManager.clear_overflow_recovery_task_state(state)

        ui_notify_fn.(failed_state, "Overflow compaction worker stopped unexpectedly", :error)

        CompactionManager.emit_overflow_recovery_telemetry(:failure, failed_state, %{
          duration_ms: CompactionManager.overflow_recovery_duration_ms(state),
          reason: CompactionManager.normalize_overflow_reason(failure_reason)
        })

        %{failed_state | overflow_recovery_error_reason: failure_reason}
    end
  end
end
