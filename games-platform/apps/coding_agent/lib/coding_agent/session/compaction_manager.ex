defmodule CodingAgent.Session.CompactionManager do
  @moduledoc """
  Manages auto-compaction and overflow recovery logic for sessions.

  Handles context window overflow detection, background compaction tasks,
  overflow recovery state transitions, and compaction result application.
  The GenServer delegates to these pure/side-effect-limited functions and
  applies the returned state changes.
  """

  require Logger

  alias CodingAgent.SessionManager
  alias CodingAgent.SessionManager.Session
  alias LemonCore.Introspection

  @default_auto_compaction_task_timeout_ms 120_000
  @default_overflow_recovery_task_timeout_ms 120_000
  @task_supervisor CodingAgent.TaskSupervisor

  # ============================================================================
  # Session Signature
  # ============================================================================

  @type session_signature ::
          {String.t(), String.t() | nil, non_neg_integer(), non_neg_integer(), term(), term()}

  @spec session_signature(map()) :: session_signature()
  def session_signature(state) do
    {
      state.session_manager.header.id,
      state.session_manager.leaf_id,
      SessionManager.entry_count(state.session_manager),
      state.turn_index,
      state.model.provider,
      state.model.id
    }
  end

  # ============================================================================
  # Auto Compaction State Management
  # ============================================================================

  @spec clear_auto_compaction_state(map()) :: map()
  def clear_auto_compaction_state(state) do
    state = clear_auto_compaction_task_tracking(state)
    %{state | auto_compaction_in_progress: false, auto_compaction_signature: nil}
  end

  @spec clear_auto_compaction_task_tracking(map()) :: map()
  def clear_auto_compaction_task_tracking(state) do
    maybe_cancel_timer(state.auto_compaction_task_timeout_ref)
    maybe_demonitor(state.auto_compaction_task_monitor_ref)

    %{
      state
      | auto_compaction_task_pid: nil,
        auto_compaction_task_monitor_ref: nil,
        auto_compaction_task_timeout_ref: nil
    }
  end

  @spec handle_auto_compaction_task_down(map()) :: map()
  def handle_auto_compaction_task_down(state) do
    state = clear_auto_compaction_task_tracking(state)

    cond do
      not state.auto_compaction_in_progress ->
        state

      true ->
        clear_auto_compaction_state(state)
    end
  end

  # ============================================================================
  # Overflow Recovery State Management
  # ============================================================================

  @spec clear_overflow_recovery_task_state(map()) :: map()
  def clear_overflow_recovery_task_state(state) do
    state = clear_overflow_recovery_task_tracking(state)

    %{
      state
      | overflow_recovery_in_progress: false,
        overflow_recovery_signature: nil,
        overflow_recovery_started_at_ms: nil
    }
  end

  @spec clear_overflow_recovery_state(map()) :: map()
  def clear_overflow_recovery_state(state) do
    %{
      clear_overflow_recovery_task_state(state)
      | overflow_recovery_attempted: false,
        overflow_recovery_error_reason: nil,
        overflow_recovery_partial_state: nil
    }
  end

  @spec clear_overflow_recovery_task_tracking(map()) :: map()
  def clear_overflow_recovery_task_tracking(state) do
    maybe_cancel_timer(state.overflow_recovery_task_timeout_ref)
    maybe_demonitor(state.overflow_recovery_task_monitor_ref)

    %{
      state
      | overflow_recovery_task_pid: nil,
        overflow_recovery_task_monitor_ref: nil,
        overflow_recovery_task_timeout_ref: nil
    }
  end

  @spec handle_overflow_recovery_task_down(map(), (map(), String.t(), atom() -> :ok)) :: map()
  def handle_overflow_recovery_task_down(state, ui_notify_fn) do
    state = clear_overflow_recovery_task_tracking(state)

    cond do
      not state.overflow_recovery_in_progress ->
        state

      true ->
        failure_reason = :overflow_recovery_task_down
        failed_state = clear_overflow_recovery_task_state(state)

        ui_notify_fn.(failed_state, "Overflow compaction worker stopped unexpectedly", :error)

        emit_overflow_recovery_telemetry(:failure, failed_state, %{
          duration_ms: overflow_recovery_duration_ms(state),
          reason: normalize_overflow_reason(failure_reason)
        })

        # Return the failed state; the caller should call finalize_overflow_recovery_failure
        # with the appropriate event handling callbacks
        %{failed_state | overflow_recovery_error_reason: failure_reason}
    end
  end

  @spec clear_overflow_recovery_state_on_terminal(AgentCore.Types.agent_event(), map()) :: map()
  def clear_overflow_recovery_state_on_terminal(event, state) do
    case event do
      {:agent_end, _messages} -> clear_overflow_recovery_state(state)
      {:canceled, _reason} -> clear_overflow_recovery_state(state)
      {:error, _reason, _partial_state} -> clear_overflow_recovery_state(state)
      _ -> state
    end
  end

  # ============================================================================
  # Overflow Recovery Logic
  # ============================================================================

  @spec context_length_exceeded_error?(term()) :: boolean()
  def context_length_exceeded_error?(reason) do
    text =
      cond do
        is_binary(reason) ->
          reason

        is_atom(reason) ->
          Atom.to_string(reason)

        true ->
          inspect(reason, limit: 200, printable_limit: 8_000)
      end
      |> String.downcase()

    String.contains?(text, "context_length_exceeded") or
      String.contains?(text, "context length exceeded") or
      String.contains?(text, "context window") or
      String.contains?(text, "maximum context length") or
      String.contains?(text, "上下文长度超过限制") or
      String.contains?(text, "令牌数量超出") or
      String.contains?(text, "输入过长") or
      String.contains?(text, "超出最大长度") or
      String.contains?(text, "上下文窗口已满")
  rescue
    _ -> false
  end

  @spec overflow_recovery_duration_ms(map()) :: non_neg_integer() | nil
  def overflow_recovery_duration_ms(state) do
    case state.overflow_recovery_started_at_ms do
      started when is_integer(started) and started > 0 ->
        max(System.monotonic_time(:millisecond) - started, 0)

      _ ->
        nil
    end
  end

  @spec normalize_overflow_reason(term()) :: String.t()
  def normalize_overflow_reason(reason) when is_binary(reason), do: reason
  def normalize_overflow_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  def normalize_overflow_reason(reason), do: inspect(reason)

  @spec emit_overflow_recovery_telemetry(:attempt | :success | :failure, map(), map()) :: :ok
  def emit_overflow_recovery_telemetry(stage, state, extra_meta)
      when stage in [:attempt, :success, :failure] and is_map(extra_meta) do
    metadata =
      %{
        session_id: state.session_manager.header.id,
        provider: state.model.provider,
        model: state.model.id
      }
      |> Map.merge(extra_meta)

    LemonCore.Telemetry.emit(
      [:coding_agent, :session, :overflow_recovery, stage],
      %{count: 1},
      metadata
    )
  rescue
    _ -> :ok
  end

  # ============================================================================
  # Compaction Opts & Settings
  # ============================================================================

  @spec normalize_compaction_opts(map(), keyword()) :: keyword()
  def normalize_compaction_opts(state, opts) do
    compaction_settings = get_compaction_settings(state.settings_manager)
    message_budget = CodingAgent.Compaction.message_budget(state.model, compaction_settings)

    opts
    |> maybe_put_keep_recent_tokens(compaction_settings)
    |> maybe_put_keep_recent_messages(message_budget)
  end

  @spec get_compaction_settings(CodingAgent.SettingsManager.t() | nil) :: map()
  def get_compaction_settings(nil), do: %{}

  def get_compaction_settings(%CodingAgent.SettingsManager{} = settings) do
    CodingAgent.SettingsManager.get_compaction_settings(settings)
  end

  # ============================================================================
  # Compaction Result Application
  # ============================================================================

  @spec apply_compaction_result(
          map(),
          {:ok, map()} | {:error, term()},
          String.t() | nil,
          (map() -> [map()]),
          (map(), AgentCore.Types.agent_event() -> :ok),
          (map(), String.t() | nil -> :ok),
          (map(), String.t(), atom() -> :ok)
        ) ::
          {:ok, map()} | {:error, term(), map()}
  def apply_compaction_result(
        state,
        result,
        custom_summary,
        restore_messages_fn,
        broadcast_event_fn,
        ui_set_working_message_fn,
        ui_notify_fn
      ) do
    case result do
      {:ok, compaction_result} ->
        # Use custom summary if provided, otherwise use generated one
        summary = custom_summary || compaction_result.summary

        # Append compaction entry to session manager
        session_manager =
          SessionManager.append_compaction(
            state.session_manager,
            summary,
            compaction_result.first_kept_entry_id,
            compaction_result.tokens_before,
            compaction_result.details
          )

        # Rebuild messages from the new position and update agent
        messages = restore_messages_fn.(session_manager)
        :ok = AgentCore.Agent.replace_messages(state.agent, messages)

        # Emit introspection event for compaction
        Introspection.record(
          :compaction_triggered,
          %{
            tokens_before: compaction_result.tokens_before,
            first_kept_entry_id: compaction_result.first_kept_entry_id
          },
          engine: "lemon",
          provenance: :direct
        )

        # Broadcast compaction event to listeners
        compaction_event =
          {:compaction_complete,
           %{
             summary: summary,
             first_kept_entry_id: compaction_result.first_kept_entry_id,
             tokens_before: compaction_result.tokens_before
           }}

        broadcast_event_fn.(state, compaction_event)

        # Clear working message and notify success
        ui_set_working_message_fn.(state, nil)
        ui_notify_fn.(state, "Context compacted", :info)

        {:ok, %{state | session_manager: session_manager}}

      {:error, :cannot_compact} ->
        ui_set_working_message_fn.(state, nil)
        {:error, :cannot_compact, state}

      {:error, reason} ->
        ui_set_working_message_fn.(state, nil)
        ui_notify_fn.(state, "Compaction failed: #{inspect(reason)}", :error)
        {:error, reason, state}
    end
  end

  # ============================================================================
  # Compaction Task Helpers
  # ============================================================================

  @spec auto_compaction_task_result(Session.t(), Ai.Types.Model.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def auto_compaction_task_result(session_manager, model, opts) do
    try do
      CodingAgent.Compaction.compact(session_manager, model, opts)
    rescue
      exception ->
        {:error, {:exception, exception}}
    catch
      kind, reason ->
        {:error, {kind, reason}}
    end
  end

  @spec overflow_recovery_compaction_opts(map()) :: keyword()
  def overflow_recovery_compaction_opts(state) do
    normalize_compaction_opts(state, force: true)
  end

  @spec overflow_recovery_compaction_task_result(Session.t(), Ai.Types.Model.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def overflow_recovery_compaction_task_result(session_manager, model, opts) do
    try do
      CodingAgent.Compaction.compact(session_manager, model, opts)
    rescue
      exception ->
        {:error, {:exception, exception}}
    catch
      kind, reason ->
        {:error, {kind, reason}}
    end
  end

  # ============================================================================
  # Task Timeout Helpers
  # ============================================================================

  @spec auto_compaction_task_timeout_ms() :: non_neg_integer()
  def auto_compaction_task_timeout_ms do
    read_session_task_timeout(
      :auto_compaction_task_timeout_ms,
      @default_auto_compaction_task_timeout_ms
    )
  end

  @spec overflow_recovery_task_timeout_ms() :: non_neg_integer()
  def overflow_recovery_task_timeout_ms do
    read_session_task_timeout(
      :overflow_recovery_task_timeout_ms,
      @default_overflow_recovery_task_timeout_ms
    )
  end

  # ============================================================================
  # Background Task Helpers
  # ============================================================================

  @spec start_background_task((-> any())) :: {:ok, pid()} | {:error, term()}
  def start_background_task(fun) when is_function(fun, 0) do
    case Task.Supervisor.start_child(@task_supervisor, fun) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:noproc, _}} ->
        Task.start(fun)

      {:error, :noproc} ->
        Task.start(fun)

      {:error, reason} ->
        Logger.warning(
          "Failed to start supervised session task: #{inspect(reason)}; falling back to Task.start/1"
        )

        Task.start(fun)
    end
  end

  @spec start_tracked_background_task((-> any()), non_neg_integer(), atom()) ::
          {:ok, %{pid: pid(), monitor_ref: reference(), timeout_ref: reference() | nil}}
          | {:error, term()}
  def start_tracked_background_task(fun, timeout_ms, timeout_event)
      when is_function(fun, 0) and is_atom(timeout_event) do
    with {:ok, pid} <- start_background_task(fun) do
      monitor_ref = Process.monitor(pid)
      timeout_ref = schedule_background_task_timeout(timeout_event, monitor_ref, timeout_ms)
      {:ok, %{pid: pid, monitor_ref: monitor_ref, timeout_ref: timeout_ref}}
    end
  end

  @spec maybe_cancel_timer(reference() | nil) :: :ok
  def maybe_cancel_timer(nil), do: :ok

  def maybe_cancel_timer(timer_ref) when is_reference(timer_ref) do
    _ = Process.cancel_timer(timer_ref, async: false, info: false)
    :ok
  rescue
    _ -> :ok
  end

  @spec maybe_demonitor(reference() | nil) :: :ok
  def maybe_demonitor(nil), do: :ok

  def maybe_demonitor(monitor_ref) when is_reference(monitor_ref) do
    Process.demonitor(monitor_ref, [:flush])
    :ok
  rescue
    _ -> :ok
  end

  @spec maybe_kill_background_task(map(), pid() | nil, term()) :: map()
  def maybe_kill_background_task(state, pid, reason) when is_pid(pid) do
    if Process.alive?(pid) do
      Process.exit(pid, {:shutdown, reason})
    end

    state
  rescue
    _ -> state
  end

  def maybe_kill_background_task(state, _pid, _reason), do: state

  # ---- Private helpers ----

  defp maybe_put_keep_recent_tokens(opts, compaction_settings) do
    keep_recent_tokens = Map.get(compaction_settings, :keep_recent_tokens)

    cond do
      Keyword.has_key?(opts, :keep_recent_tokens) ->
        opts

      is_integer(keep_recent_tokens) and keep_recent_tokens > 0 ->
        Keyword.put(opts, :keep_recent_tokens, keep_recent_tokens)

      true ->
        opts
    end
  end

  defp maybe_put_keep_recent_messages(opts, nil), do: opts

  defp maybe_put_keep_recent_messages(opts, %{keep_recent_messages: keep_recent_messages}) do
    cond do
      Keyword.has_key?(opts, :keep_recent_messages) ->
        opts

      is_integer(keep_recent_messages) and keep_recent_messages > 0 ->
        Keyword.put(opts, :keep_recent_messages, keep_recent_messages)

      true ->
        opts
    end
  end

  defp read_session_task_timeout(key, default_timeout_ms) do
    case Application.get_env(:coding_agent, CodingAgent.Session, [])
         |> Keyword.get(key, default_timeout_ms) do
      value when is_integer(value) and value > 0 -> value
      _ -> default_timeout_ms
    end
  end

  defp schedule_background_task_timeout(timeout_event, monitor_ref, timeout_ms)
       when is_atom(timeout_event) and is_reference(monitor_ref) do
    if is_integer(timeout_ms) and timeout_ms > 0 do
      Process.send_after(self(), {timeout_event, monitor_ref}, timeout_ms)
    else
      nil
    end
  end
end
