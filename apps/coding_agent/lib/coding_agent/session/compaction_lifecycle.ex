defmodule CodingAgent.Session.CompactionLifecycle do
  @moduledoc false

  require Logger

  alias CodingAgent.Session.CompactionManager

  @type callbacks(state) :: %{
          required(:restore_messages_from_session) => (map() -> [map()]),
          required(:broadcast_event) => (state, AgentCore.Types.agent_event() -> :ok),
          required(:ui_set_working_message) => (state, String.t() | nil -> :ok),
          required(:ui_notify) => (state, String.t(), atom() -> :ok)
        }

  @spec apply_result(map(), {:ok, map()} | {:error, term()}, String.t() | nil, callbacks(map())) ::
          {:ok, map()} | {:error, term(), map()}
  def apply_result(state, result, custom_summary, callbacks) do
    CompactionManager.apply_compaction_result(
      state,
      result,
      custom_summary,
      callbacks.restore_messages_from_session,
      callbacks.broadcast_event,
      callbacks.ui_set_working_message,
      callbacks.ui_notify
    )
  end

  @spec maybe_trigger(map(), pid(), callbacks(map())) :: map()
  def maybe_trigger(%{auto_compaction_in_progress: true} = state, _session_pid, _callbacks),
    do: state

  def maybe_trigger(state, session_pid, callbacks) do
    agent_state = AgentCore.Agent.get_state(state.agent)
    context_messages = agent_state.messages || []

    context_tokens =
      CodingAgent.Compaction.estimate_request_context_tokens(
        context_messages,
        Map.get(agent_state, :system_prompt),
        Map.get(agent_state, :tools, [])
      )

    context_message_count = length(context_messages)
    context_window = state.model.context_window
    compaction_settings = CompactionManager.get_compaction_settings(state.settings_manager)
    message_budget = CodingAgent.Compaction.message_budget(state.model, compaction_settings)

    should_compact_by_tokens =
      CodingAgent.Compaction.should_compact?(context_tokens, context_window, compaction_settings)

    should_compact_by_message_limit =
      CodingAgent.Compaction.should_compact_for_message_limit?(
        context_message_count,
        message_budget,
        compaction_settings
      )

    if should_compact_by_tokens or should_compact_by_message_limit do
      signature = CompactionManager.session_signature(state)
      session_manager = state.session_manager
      model = state.model
      compaction_opts = CompactionManager.normalize_compaction_opts(state, [])

      callbacks.ui_set_working_message.(state, "Compacting context...")

      case CompactionManager.start_tracked_background_task(
             fn ->
               result =
                 CompactionManager.auto_compaction_task_result(
                   session_manager,
                   model,
                   compaction_opts
                 )

               send(session_pid, {:auto_compaction_result, signature, result})
             end,
             CompactionManager.auto_compaction_task_timeout_ms(),
             :auto_compaction_task_timeout
           ) do
        {:ok, task_meta} ->
          %{
            state
            | auto_compaction_in_progress: true,
              auto_compaction_signature: signature,
              auto_compaction_task_pid: task_meta.pid,
              auto_compaction_task_monitor_ref: task_meta.monitor_ref,
              auto_compaction_task_timeout_ref: task_meta.timeout_ref
          }

        {:error, reason} ->
          Logger.warning("Auto compaction task failed to start: #{inspect(reason)}")
          callbacks.ui_set_working_message.(state, nil)
          state
      end
    else
      state
    end
  end

  @spec handle_result(map(), term(), {:ok, map()} | {:error, term()}, callbacks(map())) :: map()
  def handle_result(state, signature, result, callbacks) do
    cond do
      not state.auto_compaction_in_progress ->
        state

      state.auto_compaction_signature != signature ->
        state

      signature != CompactionManager.session_signature(state) ->
        state = CompactionManager.clear_auto_compaction_state(state)

        if not state.is_streaming do
          callbacks.ui_set_working_message.(state, nil)
        end

        state

      true ->
        state = CompactionManager.clear_auto_compaction_state(state)

        case apply_result(state, result, nil, callbacks) do
          {:ok, new_state} -> new_state
          {:error, _reason, new_state} -> new_state
        end
    end
  end

  @spec handle_timeout(map(), reference(), callbacks(map())) :: {:handled, map()} | :stale
  def handle_timeout(state, monitor_ref, callbacks) do
    if state.auto_compaction_task_monitor_ref == monitor_ref do
      state =
        state
        |> CompactionManager.maybe_kill_background_task(
          state.auto_compaction_task_pid,
          :auto_compaction_timeout
        )
        |> CompactionManager.clear_auto_compaction_state()

      if not state.is_streaming do
        callbacks.ui_set_working_message.(state, nil)
      end

      {:handled, state}
    else
      :stale
    end
  end
end
