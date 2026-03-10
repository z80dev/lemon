defmodule LemonRouter.SessionTransitions do
  @moduledoc """
  Pure queue/state transitions for `LemonRouter.SessionCoordinator`.
  """

  alias LemonRouter.SessionState

  @followup_debounce_ms 500

  @type effect ::
          :maybe_start_next
          | {:cancel_active, term()}
          | {:dispatch_steer, binary(), :steer | :steer_backlog, map(), :followup | :collect}
          | :noop

  @spec submit(SessionState.t(), map(), integer()) ::
          {:ok, SessionState.t(), [effect()]}
  def submit(%SessionState{} = state, submission, now_ms) when is_map(submission) do
    submission =
      submission
      |> normalize_queue_mode()
      |> maybe_promote_auto_followup(state)

    {state, effects} = enqueue_by_mode(state, submission, now_ms)
    effects = maybe_request_start_next(state, effects)

    {:ok, state, effects}
  end

  @spec cancel(SessionState.t(), term()) :: {:ok, SessionState.t(), [effect()]}
  def cancel(%SessionState{} = state, reason) do
    effects =
      if active?(state) do
        [{:cancel_active, reason}]
      else
        []
      end

    {:ok, %SessionState{state | queue: [], pending_steers: %{}}, effects}
  end

  @spec cancel_session(SessionState.t(), binary(), term()) ::
          {:ok, SessionState.t(), [effect()]}
  def cancel_session(%SessionState{} = state, session_key, reason) when is_binary(session_key) do
    effects =
      if active_session?(state.active, session_key) do
        [{:cancel_active, reason}]
      else
        []
      end

    {:ok, state, effects}
  end

  @spec abort_session(SessionState.t(), binary(), term()) ::
          {:ok, SessionState.t(), [effect()]}
  def abort_session(%SessionState{} = state, session_key, reason) when is_binary(session_key) do
    next_state =
      state
      |> drop_session_queue(session_key)
      |> drop_session_pending_steers(session_key)

    effects =
      if active_session?(state.active, session_key) do
        [{:cancel_active, reason}]
      else
        []
      end

    {:ok, next_state, effects}
  end

  @spec active_down(SessionState.t(), pid(), reference()) ::
          {:ok, SessionState.t(), [effect()]}
  def active_down(%SessionState{active: %{pid: pid, mon_ref: mon_ref}} = state, pid, mon_ref)
      when is_pid(pid) do
    active_down(state, pid, mon_ref, state.last_followup_at_ms || 0)
  end

  def active_down(%SessionState{} = state, _pid, _mon_ref), do: {:ok, state, [:noop]}

  @spec active_down(SessionState.t(), pid(), reference(), integer()) ::
          {:ok, SessionState.t(), [effect()]}
  def active_down(
        %SessionState{active: %{pid: pid, mon_ref: mon_ref}} = state,
        pid,
        mon_ref,
        now_ms
      )
      when is_pid(pid) do
    next_state =
      state
      |> flush_pending_steers_for_active(now_ms)
      |> Map.put(:active, nil)

    {:ok, next_state, maybe_request_start_next(next_state, [])}
  end

  def active_down(%SessionState{} = state, _pid, _mon_ref, _now_ms), do: {:ok, state, [:noop]}

  @spec steer_accepted(SessionState.t(), binary()) :: {:ok, SessionState.t(), [effect()]}
  def steer_accepted(%SessionState{} = state, submission_run_id)
      when is_binary(submission_run_id) do
    {:ok, clear_pending_steer(state, submission_run_id), [:noop]}
  end

  @spec steer_rejected(SessionState.t(), binary()) :: {:ok, SessionState.t(), [effect()]}
  def steer_rejected(%SessionState{} = state, submission_run_id)
      when is_binary(submission_run_id) do
    steer_rejected(state, submission_run_id, state.last_followup_at_ms || 0)
  end

  @spec steer_rejected(SessionState.t(), binary(), integer()) ::
          {:ok, SessionState.t(), [effect()]}
  def steer_rejected(%SessionState{} = state, submission_run_id, now_ms)
      when is_binary(submission_run_id) do
    next_state = fallback_pending_steer(state, submission_run_id, now_ms)
    {:ok, next_state, maybe_request_start_next(next_state, [])}
  end

  @spec dispatch_steer_failed(SessionState.t(), binary()) ::
          {:ok, SessionState.t(), [effect()]}
  def dispatch_steer_failed(%SessionState{} = state, submission_run_id)
      when is_binary(submission_run_id) do
    steer_rejected(state, submission_run_id)
  end

  @spec dispatch_steer_failed(SessionState.t(), binary(), integer()) ::
          {:ok, SessionState.t(), [effect()]}
  def dispatch_steer_failed(%SessionState{} = state, submission_run_id, now_ms)
      when is_binary(submission_run_id) do
    steer_rejected(state, submission_run_id, now_ms)
  end

  defp enqueue_by_mode(%SessionState{} = state, %{queue_mode: :collect} = submission, _now_ms) do
    {%SessionState{state | queue: state.queue ++ [submission]}, []}
  end

  defp enqueue_by_mode(%SessionState{} = state, %{queue_mode: :followup} = submission, now_ms) do
    case maybe_merge_followup(state.queue, submission, state.last_followup_at_ms, now_ms) do
      {:merged, queue} ->
        {%SessionState{state | queue: queue, last_followup_at_ms: now_ms}, []}

      :no_merge ->
        {%SessionState{state | queue: state.queue ++ [submission], last_followup_at_ms: now_ms},
         []}
    end
  end

  defp enqueue_by_mode(
         %SessionState{active: %{run_id: active_run_id}} = state,
         submission,
         _now_ms
       )
       when submission.queue_mode in [:steer, :steer_backlog] and is_binary(active_run_id) do
    {fallback_mode, steer_mode} =
      case submission.queue_mode do
        :steer -> {:followup, :steer}
        :steer_backlog -> {:collect, :steer_backlog}
      end

    pending =
      Map.get(state.pending_steers, active_run_id, []) ++ [{submission, fallback_mode}]

    next_state = %SessionState{
      state
      | pending_steers: Map.put(state.pending_steers, active_run_id, pending)
    }

    {next_state, [{:dispatch_steer, active_run_id, steer_mode, submission, fallback_mode}]}
  end

  defp enqueue_by_mode(%SessionState{} = state, %{queue_mode: :steer} = submission, now_ms) do
    enqueue_by_mode(state, %{submission | queue_mode: :followup}, now_ms)
  end

  defp enqueue_by_mode(
         %SessionState{} = state,
         %{queue_mode: :steer_backlog} = submission,
         now_ms
       ) do
    enqueue_by_mode(state, %{submission | queue_mode: :collect}, now_ms)
  end

  defp enqueue_by_mode(%SessionState{} = state, %{queue_mode: :interrupt} = submission, _now_ms) do
    next_state = %SessionState{state | queue: [submission | state.queue]}
    effects = if active?(state), do: [{:cancel_active, :interrupted}], else: []
    {next_state, effects}
  end

  defp enqueue_by_mode(%SessionState{} = state, submission, _now_ms) do
    {%SessionState{state | queue: state.queue ++ [submission]}, []}
  end

  defp maybe_request_start_next(%SessionState{active: nil, queue: [_ | _]}, effects) do
    effects ++ [:maybe_start_next]
  end

  defp maybe_request_start_next(_state, effects), do: effects

  defp maybe_promote_auto_followup(%{queue_mode: :followup, meta: meta} = submission, state)
       when not is_nil(state.active) do
    if truthy?(fetch(meta || %{}, :task_auto_followup)) or
         truthy?(fetch(meta || %{}, :delegated_auto_followup)) do
      %{submission | queue_mode: :steer_backlog}
    else
      submission
    end
  end

  defp maybe_promote_auto_followup(submission, _state), do: submission

  defp normalize_queue_mode(submission) do
    %{submission | queue_mode: normalize_queue_mode_value(submission.queue_mode)}
  end

  defp normalize_queue_mode_value(:collect), do: :collect
  defp normalize_queue_mode_value(:followup), do: :followup
  defp normalize_queue_mode_value(:steer), do: :steer
  defp normalize_queue_mode_value(:steer_backlog), do: :steer_backlog
  defp normalize_queue_mode_value(:interrupt), do: :interrupt
  defp normalize_queue_mode_value(_), do: :collect

  defp maybe_merge_followup(queue, submission, last_followup_at_ms, now_ms) do
    cond do
      is_nil(last_followup_at_ms) ->
        :no_merge

      now_ms - last_followup_at_ms > @followup_debounce_ms ->
        :no_merge

      queue == [] ->
        :no_merge

      true ->
        case List.pop_at(queue, -1) do
          {nil, _rest} ->
            :no_merge

          {%{queue_mode: :followup} = previous, rest} ->
            {:merged, rest ++ [merge_followup_submission(previous, submission)]}

          {_other, _rest} ->
            :no_merge
        end
    end
  end

  defp merge_followup_submission(previous, current) do
    merged_prompt =
      merge_prompt(previous.execution_request.prompt, current.execution_request.prompt)

    previous_request = previous.execution_request
    meta = merge_user_message_meta(previous.meta || %{}, current.meta || %{})

    %{
      previous
      | run_id: current.run_id,
        session_key: current.session_key,
        meta: meta,
        execution_request: %{
          previous_request
          | run_id: current.run_id,
            prompt: merged_prompt,
            meta:
              merge_user_message_meta(
                previous_request.meta || %{},
                current.execution_request.meta || %{}
              )
        }
    }
  end

  defp flush_pending_steers_for_active(
         %SessionState{active: %{run_id: active_run_id}} = state,
         now_ms
       )
       when is_binary(active_run_id) do
    pending = Map.get(state.pending_steers, active_run_id, [])
    pending_steers = Map.delete(state.pending_steers, active_run_id)

    Enum.reduce(pending, %SessionState{state | pending_steers: pending_steers}, fn
      {submission, fallback_mode}, acc ->
        enqueue_fallback(acc, submission, fallback_mode, now_ms)
    end)
  end

  defp flush_pending_steers_for_active(state, _now_ms), do: state

  defp clear_pending_steer(%SessionState{} = state, submission_run_id) do
    {_, updated} = take_pending_steer(state.pending_steers, submission_run_id)
    %SessionState{state | pending_steers: updated}
  end

  defp fallback_pending_steer(%SessionState{} = state, submission_run_id, now_ms) do
    case take_pending_steer(state.pending_steers, submission_run_id) do
      {nil, pending_steers} ->
        %SessionState{state | pending_steers: pending_steers}

      {{submission, fallback_mode, _active_run_id}, pending_steers} ->
        enqueue_fallback(
          %SessionState{state | pending_steers: pending_steers},
          submission,
          fallback_mode,
          now_ms
        )
    end
  end

  defp take_pending_steer(pending_steers, submission_run_id) do
    Enum.reduce(pending_steers, {nil, %{}}, fn {active_run_id, entries}, {found, acc} ->
      {matched, rest} =
        Enum.split_with(entries, fn {submission, _mode} ->
          submission.run_id == submission_run_id
        end)

      acc = if rest == [], do: acc, else: Map.put(acc, active_run_id, rest)

      case {found, matched} do
        {nil, [{submission, fallback_mode} | _]} ->
          {{submission, fallback_mode, active_run_id}, acc}

        _ ->
          {found, acc}
      end
    end)
  end

  defp enqueue_fallback(%SessionState{} = state, submission, :followup, now_ms) do
    case maybe_merge_followup(
           state.queue,
           %{submission | queue_mode: :followup},
           state.last_followup_at_ms,
           now_ms
         ) do
      {:merged, queue} ->
        %SessionState{state | queue: queue, last_followup_at_ms: now_ms}

      :no_merge ->
        %SessionState{
          state
          | queue: state.queue ++ [%{submission | queue_mode: :followup}],
            last_followup_at_ms: now_ms
        }
    end
  end

  defp enqueue_fallback(%SessionState{} = state, submission, :collect, _now_ms) do
    %SessionState{state | queue: state.queue ++ [%{submission | queue_mode: :collect}]}
  end

  defp active?(%SessionState{active: %{}}), do: true
  defp active?(_state), do: false

  defp active_session?(%{session_key: session_key}, session_key) when is_binary(session_key),
    do: true

  defp active_session?(_, _session_key), do: false

  defp drop_session_queue(%SessionState{} = state, session_key) do
    %SessionState{state | queue: Enum.reject(state.queue, &(&1.session_key == session_key))}
  end

  defp drop_session_pending_steers(%SessionState{} = state, session_key) do
    pending_steers =
      Enum.reduce(state.pending_steers, %{}, fn {active_run_id, entries}, acc ->
        kept =
          Enum.reject(entries, fn {submission, _mode} ->
            submission.session_key == session_key
          end)

        if kept == [] do
          acc
        else
          Map.put(acc, active_run_id, kept)
        end
      end)

    %SessionState{state | pending_steers: pending_steers}
  end

  defp merge_prompt(nil, right), do: right || ""
  defp merge_prompt(left, nil), do: left
  defp merge_prompt(left, right), do: left <> "\n" <> right

  defp merge_user_message_meta(left, right) when is_map(left) and is_map(right) do
    right_user_msg_id = fetch(right, :user_msg_id)

    if is_nil(right_user_msg_id) do
      Map.merge(left, right)
    else
      left
      |> Map.merge(right)
      |> Map.put(:user_msg_id, right_user_msg_id)
      |> Map.delete("user_msg_id")
    end
  end

  defp merge_user_message_meta(left, _right) when is_map(left), do: left
  defp merge_user_message_meta(_left, right) when is_map(right), do: right
  defp merge_user_message_meta(_left, _right), do: %{}

  defp fetch(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(1), do: true
  defp truthy?(_value), do: false
end
