defmodule LemonRouter.SessionCoordinator do
  @moduledoc """
  Router-owned owner of per-conversation queue semantics.

  Queue mode behavior is implemented here so gateway remains execution-only.
  Reducer state changes live in `LemonRouter.SessionTransitions`; this module
  interprets reducer effects, owns registry/process IO, and emits router phases.

  `LemonRouter.RunOrchestrator` remains responsible for the initial
  `LemonCore.EventBridge.subscribe_run/1` call on accepted router submissions.
  This coordinator only cleans up event bridge subscriptions when queued or
  pending submissions are later dropped from reducer state.
  """

  use GenServer

  require Logger

  alias LemonCore.MapHelpers
  alias LemonGateway.ExecutionRequest

  alias LemonRouter.{
    PhasePublisher,
    QueueEffect,
    RunStarter,
    SessionState,
    SessionTransitions,
    Submission
  }

  @doc """
  Submit a prepared router submission into the per-conversation coordinator.

  Orchestrator-facing code is expected to subscribe the run on
  `LemonCore.EventBridge` before calling this function. The coordinator keeps
  later queue cleanup consistent, but it does not claim initial subscription
  ownership from the orchestrator boundary.
  """
  @spec submit(term(), Submission.t() | map() | keyword(), keyword()) :: :ok | {:error, term()}
  def submit(conversation_key, submission, opts \\ [])

  def submit(conversation_key, %Submission{} = submission, opts) do
    with {:ok, pid} <- ensure_coordinator(conversation_key, opts) do
      GenServer.call(pid, {:submit, submission}, 15_000)
    end
  end

  def submit(conversation_key, submission, opts) when is_map(submission) or is_list(submission) do
    submit(conversation_key, Submission.new!(submission), opts)
  end

  @spec cancel(binary() | term(), term()) :: :ok
  def cancel(conversation_or_session, reason \\ :user_requested)
  def cancel({_, _} = conversation_key, reason), do: cancel_conversation(conversation_key, reason)

  def cancel({_, _, _} = conversation_key, reason),
    do: cancel_conversation(conversation_key, reason)

  def cancel(session_key, reason) when is_binary(session_key) do
    coordinator_entries()
    |> Enum.each(fn {_conversation_key, pid, _meta} ->
      if is_pid(pid) do
        GenServer.cast(pid, {:cancel_session, session_key, reason})
      end
    end)

    :ok
  end

  @spec abort_session(binary(), term()) :: :ok
  def abort_session(session_key, reason \\ :user_requested) when is_binary(session_key) do
    coordinator_entries()
    |> Enum.each(fn {_conversation_key, pid, _meta} ->
      if is_pid(pid) do
        GenServer.cast(pid, {:abort_session, session_key, reason})
      end
    end)

    maybe_cancel_resume_conversation(session_key, reason)
    :ok
  end

  @spec active_run(term()) :: {:ok, binary()} | :none
  def active_run(conversation_key) do
    with {:ok, pid} <- whereis(conversation_key) do
      GenServer.call(pid, :active_run)
    else
      _ -> :none
    end
  end

  @spec active_run_for_session(binary()) :: {:ok, binary()} | :none
  def active_run_for_session(session_key) when is_binary(session_key) and session_key != "" do
    case Registry.lookup(LemonRouter.SessionRegistry, session_key) do
      [{_pid, %{run_id: run_id}} | _] when is_binary(run_id) and run_id != "" -> {:ok, run_id}
      _ -> :none
    end
  rescue
    _ -> :none
  end

  def active_run_for_session(_), do: :none

  @spec busy?(binary()) :: boolean()
  def busy?(session_key) when is_binary(session_key) and session_key != "" do
    active_run_for_session(session_key) != :none
  end

  def busy?(_), do: false

  @spec list_active_sessions() :: [%{session_key: binary(), run_id: binary()}]
  def list_active_sessions do
    Registry.select(LemonRouter.SessionRegistry, [
      {{:"$1", :"$2", %{run_id: :"$3"}}, [], [%{session_key: :"$1", run_id: :"$3"}]}
    ])
  rescue
    _ -> []
  end

  def start_link(opts) do
    key = Keyword.fetch!(opts, :conversation_key)
    name = {:via, Registry, {LemonRouter.ConversationRegistry, key}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    {:ok, SessionState.new(opts)}
  end

  @impl true
  def handle_call(:active_run, _from, state) do
    reply =
      case state.active do
        %{run_id: run_id} when is_binary(run_id) -> {:ok, run_id}
        _ -> :none
      end

    {:reply, reply, state}
  end

  def handle_call({:submit, submission}, _from, state) do
    {:reply, reply, next_state} =
      apply_transition(
        SessionTransitions.submit(state, submission, System.monotonic_time(:millisecond)),
        state,
        reply?: true
      )

    {:reply, reply, maybe_emit_submit_phases(state, submission, next_state)}
  end

  @impl true
  def handle_cast({:cancel, reason}, state) do
    {:noreply, next_state} =
      apply_transition(SessionTransitions.cancel(state, reason), state)

    {:noreply, next_state}
  end

  def handle_cast({:cancel_session, session_key, reason}, state) do
    {:noreply, next_state} =
      apply_transition(SessionTransitions.cancel_session(state, session_key, reason), state)

    {:noreply, next_state}
  end

  def handle_cast({:abort_session, session_key, reason}, state) do
    {:noreply, next_state} =
      apply_transition(SessionTransitions.abort_session(state, session_key, reason), state)

    {:noreply, next_state}
  end

  @impl true
  def handle_info(
        {:DOWN, mon_ref, :process, pid, _reason},
        %SessionState{active: %{pid: pid, mon_ref: mon_ref}} = state
      ) do
    state = clear_active_session_registry(state)

    {:noreply, next_state} =
      apply_transition(
        SessionTransitions.active_down(state, pid, mon_ref, System.monotonic_time(:millisecond)),
        state
      )

    {:noreply, next_state}
  end

  def handle_info({:steer_accepted, %ExecutionRequest{} = request}, state) do
    {:noreply, next_state} =
      apply_transition(SessionTransitions.steer_accepted(state, request.run_id), state)

    {:noreply, next_state}
  end

  def handle_info({:steer_backlog_accepted, %ExecutionRequest{} = request}, state) do
    {:noreply, next_state} =
      apply_transition(SessionTransitions.steer_accepted(state, request.run_id), state)

    {:noreply, next_state}
  end

  def handle_info({:steer_rejected, %ExecutionRequest{} = request}, state) do
    {:noreply, next_state} =
      apply_transition(
        SessionTransitions.steer_rejected(
          state,
          request.run_id,
          System.monotonic_time(:millisecond)
        ),
        state
      )

    {:noreply, next_state}
  end

  def handle_info({:steer_backlog_rejected, %ExecutionRequest{} = request}, state) do
    {:noreply, next_state} =
      apply_transition(
        SessionTransitions.steer_rejected(
          state,
          request.run_id,
          System.monotonic_time(:millisecond)
        ),
        state
      )

    {:noreply, next_state}
  end

  def handle_info(:maybe_start_next, state) do
    {next_state, _result} = maybe_start_next(state, return_result?: false, emit_phase?: true)
    {:noreply, next_state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp ensure_coordinator(conversation_key, opts) do
    case whereis(conversation_key) do
      {:ok, pid} ->
        {:ok, pid}

      :error ->
        LemonRouter.SessionCoordinatorSupervisor.ensure_started(conversation_key, opts)
    end
  end

  defp whereis(conversation_key) do
    case Registry.lookup(LemonRouter.ConversationRegistry, conversation_key) do
      [{pid, _}] when is_pid(pid) -> {:ok, pid}
      _ -> :error
    end
  end

  defp cancel_conversation(conversation_key, reason) do
    with {:ok, pid} <- whereis(conversation_key) do
      GenServer.cast(pid, {:cancel, reason})
    end

    :ok
  end

  defp apply_transition({:ok, transitioned_state, effects}, original_state, opts \\ []) do
    {next_state, reply} = apply_effects(transitioned_state, effects, opts)
    maybe_emit_superseded_queue_phase(original_state, next_state)
    maybe_cleanup_event_bridge_runs(original_state, next_state)

    if opts[:reply?] do
      {:reply, reply, next_state}
    else
      {:noreply, next_state}
    end
  end

  @spec apply_effects(SessionState.t(), [QueueEffect.t()], keyword()) ::
          {SessionState.t(), :ok | :started | :noop | {:error, term()}}
  defp apply_effects(state, effects, opts) do
    Enum.reduce(effects, {state, :ok}, fn effect, {state_acc, reply_acc} ->
      apply_effect(effect, state_acc, reply_acc, opts)
    end)
  end

  defp apply_effect(:maybe_start_next, state, reply_acc, opts) do
    {next_state, start_result} =
      maybe_start_next(
        state,
        return_result?: Keyword.get(opts, :reply?, false),
        emit_phase?: not Keyword.get(opts, :reply?, false)
      )

    {next_state, merge_reply(reply_acc, start_result)}
  end

  defp apply_effect({:cancel_active, reason}, state, reply_acc, _opts) do
    {maybe_cancel_active(state, reason), reply_acc}
  end

  defp apply_effect(
         {:dispatch_steer, active_run_id, steer_mode, %Submission{} = submission, _fallback_mode},
         state,
         reply_acc,
         opts
       ) do
    case dispatch_steer(active_run_id, steer_mode, submission.execution_request) do
      :ok ->
        {state, reply_acc}

      :error ->
        {:ok, next_state, extra_effects} =
          SessionTransitions.dispatch_steer_failed(
            state,
            submission.run_id,
            System.monotonic_time(:millisecond)
          )

        apply_effects(next_state, extra_effects, opts)
        |> then(fn {resolved_state, _} -> {resolved_state, reply_acc} end)
    end
  end

  defp apply_effect(:noop, state, reply_acc, _opts), do: {state, reply_acc}

  defp merge_reply(:ok, :noop), do: :ok
  defp merge_reply(:ok, :started), do: :ok
  defp merge_reply(:ok, {:error, reason}), do: {:error, reason}
  defp merge_reply(reply, :ok), do: reply
  defp merge_reply(reply, :noop), do: reply
  defp merge_reply(reply, :started), do: reply
  defp merge_reply(reply, {:error, _reason}), do: reply

  defp maybe_emit_submit_phases(
         _original_state,
         %Submission{} = submission,
         %SessionState{} = state
       ) do
    active_submission = active_submission(state)

    cond do
      active_submission_run_id(state) == submission.run_id and
          phase_emission_enabled?(active_submission || submission) ->
        active_submission =
          (active_submission || submission)
          |> PhasePublisher.emit(:accepted, nil)
          |> PhasePublisher.emit(:waiting_for_slot, :accepted)

        put_active_submission_phase(state, submission.run_id, active_submission.current_phase)

      queued_submission?(state, submission.run_id) ->
        queued_submission =
          Enum.find(state.queue, &(&1.run_id == submission.run_id)) || submission

        if phase_emission_enabled?(queued_submission) do
          queued_submission =
            queued_submission
            |> PhasePublisher.emit(:accepted, nil)
            |> PhasePublisher.emit(:queued_in_session, :accepted)

          put_queued_submission_phase(state, submission.run_id, queued_submission.current_phase)
        else
          state
        end

      true ->
        state
    end
  end

  defp active_submission_run_id(%SessionState{
         active: %{submission: %Submission{run_id: run_id}}
       }),
       do: run_id

  defp active_submission_run_id(%SessionState{active: %{run_id: run_id}}), do: run_id
  defp active_submission_run_id(_state), do: nil

  defp active_submission(%SessionState{active: %{submission: %Submission{} = submission}}),
    do: submission

  defp active_submission(_state), do: nil

  defp queued_submission?(%SessionState{queue: queue}, run_id) when is_binary(run_id) do
    Enum.any?(queue, &(&1.run_id == run_id))
  end

  defp queued_submission?(_state, _run_id), do: false

  defp put_queued_submission_phase(%SessionState{queue: queue} = state, run_id, phase)
       when is_binary(run_id) do
    %SessionState{
      state
      | queue:
          Enum.map(queue, fn
            %Submission{run_id: ^run_id} = submission -> Submission.put_phase(submission, phase)
            submission -> submission
          end)
    }
  end

  defp put_queued_submission_phase(state, _run_id, _phase), do: state

  defp put_active_submission_phase(
         %SessionState{active: %{run_id: run_id, submission: %Submission{} = submission} = active} =
           state,
         run_id,
         phase
       ) do
    %SessionState{state | active: %{active | submission: Submission.put_phase(submission, phase)}}
  end

  defp put_active_submission_phase(state, _run_id, _phase), do: state

  defp maybe_start_next(%SessionState{active: nil, queue: [next | rest]} = state, opts) do
    case RunStarter.start(next, self(), state.conversation_key) do
      {:ok, pid} when is_pid(pid) ->
        mon_ref = Process.monitor(pid)

        started_submission =
          maybe_emit_waiting_for_slot(next, Keyword.get(opts, :emit_phase?, true))

        put_active_session_registry(started_submission)

        next_state = %SessionState{
          state
          | active: %{
              pid: pid,
              mon_ref: mon_ref,
              run_id: started_submission.run_id,
              session_key: started_submission.session_key,
              submission: started_submission
            },
            queue: rest
        }

        if opts[:return_result?], do: {next_state, :started}, else: {next_state, :ok}

      {:error, reason} ->
        Logger.warning(
          "SessionCoordinator failed to start run run_id=#{inspect(next.run_id)} key=#{inspect(state.conversation_key)} reason=#{inspect(reason)}"
        )

        next_state = %SessionState{state | queue: rest}

        if opts[:return_result?], do: {next_state, {:error, reason}}, else: {next_state, :ok}
    end
  end

  defp maybe_start_next(state, _opts), do: {state, :noop}

  defp maybe_emit_waiting_for_slot(%Submission{} = submission, true) do
    if phase_emission_enabled?(submission) do
      previous_phase = submission.current_phase || :accepted
      PhasePublisher.emit(submission, :waiting_for_slot, previous_phase)
    else
      submission
    end
  end

  defp maybe_emit_waiting_for_slot(%Submission{} = submission, false), do: submission

  defp maybe_emit_superseded_queue_phase(
         %SessionState{queue: original_queue},
         %SessionState{queue: next_queue}
       ) do
    case {List.last(original_queue), List.last(next_queue)} do
      {%Submission{queue_mode: :followup} = previous,
       %Submission{queue_mode: :followup} = current}
      when previous.run_id != current.run_id and length(original_queue) == length(next_queue) ->
        if same_queue_prefix?(original_queue, next_queue) and phase_emission_enabled?(previous) do
          previous_phase = previous.current_phase || :queued_in_session
          _ = PhasePublisher.emit(previous, :aborted, previous_phase)
        end

        :ok

      _ ->
        :ok
    end
  end

  defp maybe_emit_superseded_queue_phase(_original_state, _next_state), do: :ok

  defp same_queue_prefix?(original_queue, next_queue) do
    original_prefix = Enum.drop(original_queue, -1)
    next_prefix = Enum.drop(next_queue, -1)

    Enum.map(original_prefix, & &1.run_id) == Enum.map(next_prefix, & &1.run_id)
  end

  defp phase_emission_enabled?(%Submission{} = submission) do
    not truthy?(MapHelpers.get_key(submission.meta || %{}, :suppress_router_phase_events))
  end

  defp maybe_cleanup_event_bridge_runs(
         %SessionState{} = original_state,
         %SessionState{} = next_state
       ) do
    dropped_run_ids =
      original_state
      |> queued_or_pending_run_ids()
      |> MapSet.difference(retained_run_ids(next_state))

    Enum.each(dropped_run_ids, &LemonCore.EventBridge.unsubscribe_run/1)
  end

  defp retained_run_ids(%SessionState{} = state) do
    state
    |> queued_or_pending_run_ids()
    |> maybe_put_active_run_id(active_submission_run_id(state))
  end

  defp queued_or_pending_run_ids(%SessionState{} = state) do
    queue_run_ids = Enum.map(state.queue, & &1.run_id)

    pending_run_ids =
      state.pending_steers
      |> Map.values()
      |> List.flatten()
      |> Enum.map(fn
        {%Submission{run_id: run_id}, _fallback_mode} -> run_id
      end)

    (queue_run_ids ++ pending_run_ids)
    |> Enum.reduce(MapSet.new(), fn
      run_id, acc when is_binary(run_id) and run_id != "" -> MapSet.put(acc, run_id)
      _run_id, acc -> acc
    end)
  end

  defp maybe_put_active_run_id(run_ids, run_id) when is_binary(run_id) and run_id != "",
    do: MapSet.put(run_ids, run_id)

  defp maybe_put_active_run_id(run_ids, _run_id), do: run_ids

  defp maybe_cancel_active(%SessionState{active: %{pid: pid}} = state, reason) when is_pid(pid) do
    LemonRouter.RunProcess.abort(pid, reason)
    state
  rescue
    _ -> state
  end

  defp maybe_cancel_active(state, _reason), do: state

  defp dispatch_steer(active_run_id, steer_mode, %ExecutionRequest{} = request)
       when steer_mode in [:steer, :steer_backlog] do
    case gateway_run_pid(active_run_id) do
      nil ->
        :error

      run_pid ->
        GenServer.cast(run_pid, {steer_mode, request, self()})
        :ok
    end
  rescue
    _ -> :error
  end

  defp put_active_session_registry(%Submission{session_key: session_key, run_id: run_id}) do
    if is_binary(session_key) do
      _ = Registry.unregister(LemonRouter.SessionRegistry, session_key)
      _ = Registry.register(LemonRouter.SessionRegistry, session_key, %{run_id: run_id})
    end

    :ok
  rescue
    _ -> :ok
  end

  defp clear_active_session_registry(
         %SessionState{active: %{session_key: session_key, run_id: run_id}} = state
       )
       when is_binary(session_key) do
    case Registry.lookup(LemonRouter.SessionRegistry, session_key) do
      [{_pid, %{run_id: ^run_id}}] ->
        Registry.unregister(LemonRouter.SessionRegistry, session_key)

      _ ->
        :ok
    end

    state
  rescue
    _ -> state
  end

  defp clear_active_session_registry(state), do: state

  defp gateway_run_pid(run_id) when is_binary(run_id) do
    case Registry.lookup(LemonGateway.RunRegistry, run_id) do
      [{pid, _}] when is_pid(pid) -> pid
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp gateway_run_pid(_), do: nil

  defp coordinator_entries do
    Registry.select(LemonRouter.ConversationRegistry, [
      {{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}
    ])
  rescue
    _ -> []
  end

  defp maybe_cancel_resume_conversation(session_key, reason) do
    case resume_conversation_key(session_key) do
      nil -> :ok
      conversation_key -> cancel_conversation(conversation_key, reason)
    end
  rescue
    _ -> :ok
  end

  defp resume_conversation_key(session_key) when is_binary(session_key) do
    case LemonCore.ChatStateStore.get(session_key) do
      %LemonGateway.ChatState{last_engine: engine, last_resume_token: token}
      when is_binary(engine) and is_binary(token) ->
        {:resume, engine, token}

      %{} = state ->
        engine = MapHelpers.get_key(state, :last_engine)
        token = MapHelpers.get_key(state, :last_resume_token)

        if is_binary(engine) and is_binary(token), do: {:resume, engine, token}, else: nil

      _ ->
        nil
    end
  end

  defp resume_conversation_key(_), do: nil

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(1), do: true
  defp truthy?(_value), do: false
end
