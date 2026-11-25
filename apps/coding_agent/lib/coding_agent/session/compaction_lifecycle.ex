defmodule CodingAgent.Session.CompactionLifecycle do
  @moduledoc """
  Owns the CodingAgent session's background auto-compaction lifecycle.

  Auto-compaction runs only against the session signature it captured. If a
  new prompt arrives while that background snapshot is being compacted, the
  worker is canceled and demonitoring/timer cleanup happens synchronously
  before the prompt is deferred. This keeps prompt latency independent of the
  stale worker and prevents its late result from mutating the new turn.

  Its slot in the session state is one field, `auto_compaction`, holding a
  `CodingAgent.Session.CompactionLifecycle.State`.
  """

  alias CodingAgent.Session.CompactionManager

  defmodule State do
    @moduledoc """
    Auto-compaction's slot in the session state: whether a background
    compaction is running, the session signature it captured, and the task
    it tracks (pid, monitor, timeout timer).
    """

    @type t :: %__MODULE__{
            in_progress: boolean(),
            signature: CodingAgent.Session.CompactionManager.session_signature() | nil,
            task_pid: pid() | nil,
            task_monitor_ref: reference() | nil,
            task_timeout_ref: reference() | nil,
            pending_prompt: tuple() | nil,
            blocked_signature: term()
          }

    defstruct in_progress: false,
              signature: nil,
              task_pid: nil,
              task_monitor_ref: nil,
              task_timeout_ref: nil,
              pending_prompt: nil,
              blocked_signature: nil
  end

  @type callbacks(state) :: %{
          required(:restore_messages_from_session) => (map() -> [map()]),
          required(:broadcast_event) => (state, LemonAgent.Types.agent_event() -> :ok),
          required(:terminalize) => (state, LemonAgent.Types.agent_event() -> state)
        }

  @spec apply_result(map(), {:ok, map()} | {:error, term()}, String.t() | nil, callbacks(map())) ::
          {:ok, map()} | {:error, term(), map()}
  def apply_result(state, result, custom_summary, callbacks) do
    CompactionManager.apply_compaction_result(
      state,
      result,
      custom_summary,
      callbacks.restore_messages_from_session,
      callbacks.broadcast_event
    )
  end

  @spec cancel_for_new_prompt(map()) :: map()
  def cancel_for_new_prompt(%{auto_compaction: %State{in_progress: false}} = state), do: state

  def cancel_for_new_prompt(state) do
    state = if state.pending_prompt_timer_ref, do: resume_pending_prompt(state), else: state

    state
    |> CompactionManager.maybe_kill_background_task(
      state.auto_compaction.task_pid,
      :superseded_by_prompt
    )
    |> CompactionManager.clear_auto_compaction_state()
  end

  @doc false
  def before_prompt(state, message, system_prompt, callbacks) do
    if state.auto_compaction.blocked_signature == {:blocked, state.session_manager.leaf_id} do
      callbacks.terminalize.(state, {:error, :compaction_recovery_band, nil})
    else
      state = maybe_trigger(state, self(), {message, system_prompt})

      if not state.auto_compaction.in_progress do
        send(self(), {:dispatch_prompt, state.pending_prompt_timer_ref, message, system_prompt})
      end

      state
    end
  end

  @doc false
  def resume_pending_prompt(state) do
    case state.auto_compaction.pending_prompt do
      {message, system_prompt} ->
        send(self(), {:dispatch_prompt, state.pending_prompt_timer_ref, message, system_prompt})

      nil ->
        :ok
    end

    state
  end

  @spec maybe_trigger(map(), pid()) :: map()
  def maybe_trigger(state, session_pid), do: maybe_trigger(state, session_pid, nil)

  defp maybe_trigger(
         %{
           auto_compaction: %State{blocked_signature: {:blocked, leaf}},
           session_manager: %{leaf_id: leaf}
         } = state,
         _session_pid,
         _prompt
       ),
       do: state

  defp maybe_trigger(
         %{auto_compaction: %State{in_progress: true}} = state,
         _session_pid,
         _prompt
       ),
       do: state

  defp maybe_trigger(state, session_pid, pending_prompt) do
    agent_state = LemonAgent.Agent.get_state(state.agent)

    context_messages =
      (agent_state.messages || []) ++
        case pending_prompt do
          {message, _system_prompt} -> [message]
          nil -> []
        end

    context_budget =
      CodingAgent.Session.ContextBudget.measure(state, agent_state, context_messages)

    context_tokens = context_budget.tokens

    context_message_count = length(context_messages)
    context_window = state.model.context_window
    compaction_settings = CompactionManager.get_compaction_settings(state.settings_manager)
    message_budget = CodingAgent.Compaction.message_budget(state.model)

    should_compact_by_tokens =
      CodingAgent.Compaction.should_compact?(context_tokens, context_window, compaction_settings)

    should_compact_by_message_limit =
      CodingAgent.Compaction.should_compact_for_message_limit?(
        context_message_count,
        message_budget,
        compaction_settings
      )

    if (should_compact_by_tokens or should_compact_by_message_limit) and
         state.auto_compaction.blocked_signature != {:blocked, state.session_manager.leaf_id} do
      signature = CompactionManager.session_signature(state)
      session_manager = state.session_manager
      compaction_opts = CompactionManager.normalize_compaction_opts(state, force: true)

      overhead =
        CodingAgent.Compaction.estimate_request_context_tokens(
          [],
          agent_state.system_prompt,
          agent_state.tools
        ) +
          case pending_prompt do
            {message, _} -> CodingAgent.Compaction.estimate_message_tokens(message)
            nil -> 0
          end

      compaction_opts =
        compaction_opts
        |> Keyword.put(
          :recovery_target,
          CodingAgent.Compaction.recovery_threshold(context_window, compaction_settings)
        )
        |> Keyword.put(:request_overhead_tokens, overhead)

      model = Keyword.fetch!(compaction_opts, :model)

      CodingAgent.Session.Notifier.broadcast_event(
        state,
        {:compaction_start, %{reason: :threshold}}
      )

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
            | auto_compaction: %State{
                in_progress: true,
                signature: signature,
                task_pid: task_meta.pid,
                task_monitor_ref: task_meta.monitor_ref,
                task_timeout_ref: task_meta.timeout_ref,
                pending_prompt: pending_prompt
              }
          }
      end
    else
      state
    end
  end

  @spec handle_result(map(), term(), {:ok, map()} | {:error, term()}, callbacks(map())) :: map()
  def handle_result(state, signature, result, callbacks) do
    cond do
      not state.auto_compaction.in_progress ->
        state

      state.auto_compaction.signature != signature ->
        state

      signature != CompactionManager.session_signature(state) ->
        state |> resume_pending_prompt() |> CompactionManager.clear_auto_compaction_state()

      true ->
        pending_prompt = state.auto_compaction.pending_prompt
        state = CompactionManager.clear_auto_compaction_state(state)

        case apply_result(state, result, nil, callbacks) do
          {:ok, new_state} ->
            resume_pending_prompt(%{
              new_state
              | auto_compaction: %{new_state.auto_compaction | pending_prompt: pending_prompt}
            })
            |> CompactionManager.clear_auto_compaction_state()

          {:error, :compaction_recovery_band, new_state} ->
            new_state =
              callbacks.terminalize.(new_state, {:error, :compaction_recovery_band, nil})

            %{
              new_state
              | auto_compaction: %{
                  new_state.auto_compaction
                  | blocked_signature: {:blocked, new_state.session_manager.leaf_id}
                }
            }

          {:error, _reason, new_state} ->
            resume_pending_prompt(%{
              new_state
              | auto_compaction: %{new_state.auto_compaction | pending_prompt: pending_prompt}
            })
            |> CompactionManager.clear_auto_compaction_state()
        end
    end
  end

  @spec handle_timeout(map(), reference()) :: {:handled, map()} | :stale
  def handle_timeout(state, monitor_ref) do
    if state.auto_compaction.task_monitor_ref == monitor_ref do
      state =
        state
        |> CompactionManager.maybe_kill_background_task(
          state.auto_compaction.task_pid,
          :auto_compaction_timeout
        )
        |> resume_pending_prompt()
        |> CompactionManager.clear_auto_compaction_state()

      {:handled, state}
    else
      :stale
    end
  end
end
