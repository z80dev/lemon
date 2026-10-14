defmodule LemonRouter.SessionCoordinator do
  @moduledoc """
  Router-owned owner of per-conversation queue semantics.

  Queue mode behavior is implemented here so gateway remains execution-only.
  Reducer state changes live in `LemonRouter.SessionTransitions`; this module
  interprets reducer effects, owns registry/process IO, and emits router phases.

  The internal LemonRouter.RunOrchestrator remains responsible for the initial
  `LemonCore.EventBridge.subscribe_run/1` call on accepted router submissions.
  This coordinator only cleans up event bridge subscriptions when queued or
  pending submissions are later dropped from reducer state.

  If a queued submission cannot start, the coordinator emits one synthetic
  structured completion before dropping its bridge subscription and advances
  to the next queued submission. A child found in `RunRegistry` after an
  ambiguous supervisor error is adopted instead, avoiding double completion.
  """

  use GenServer

  require Logger

  alias LemonCore.{Events, MapHelpers}

  alias LemonRouter.{
    PhasePublisher,
    QueueEffect,
    RunStarter,
    RunReceiptStore,
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

  def submit(conversation_key, submission, opts) do
    case submit_with_receipt(conversation_key, submission, opts) do
      {:ok, _receipt} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Admit a fixed run ID and return its durable, content-free queue disposition.

  The receipt is written after transition effects and before acknowledgement.
  Steering casts return a pending mode until the invocation accepts them.
  Replaying an existing receipt never dispatches work again, including for
  merged follower IDs, but requires a successful storage durability barrier.
  A write or replay barrier failure returns `{:error, :outcome_unknown}`; retain
  the run ID and reconcile, do not resubmit it under a fresh ID.
  `:receipt_store` optionally selects a Store instance.
  """
  @spec submit_with_receipt(term(), Submission.t() | map() | keyword(), keyword()) ::
          {:ok, RunReceiptStore.receipt()} | {:error, term()}
  def submit_with_receipt(conversation_key, submission, opts \\ [])

  def submit_with_receipt(conversation_key, %Submission{} = submission, opts) do
    store = Keyword.get(opts, :receipt_store, LemonCore.Store)

    case RunReceiptStore.fetch(store, submission.run_id) do
      {:ok, %{} = receipt} ->
        replay_receipt(submission, receipt)

      {:ok, nil} ->
        with {:ok, pid} <- ensure_coordinator(conversation_key, opts) do
          GenServer.call(pid, {:submit_with_receipt, submission}, 15_000)
        end

      {:error, {:sync_failed, _reason}} ->
        {:error, :outcome_unknown}

      {:error, _reason} = error ->
        error
    end
  catch
    :exit, _reason -> {:error, :outcome_unknown}
  end

  def submit_with_receipt(conversation_key, submission, opts)
      when is_map(submission) or is_list(submission) do
    submit_with_receipt(conversation_key, Submission.new!(submission), opts)
  end

  @spec cancel(binary() | term(), term()) :: :ok | {:error, :unavailable}
  def cancel(conversation_or_session, reason \\ :user_requested)
  def cancel({_, _} = conversation_key, reason), do: cancel_conversation(conversation_key, reason)

  def cancel({_, _, _} = conversation_key, reason),
    do: cancel_conversation(conversation_key, reason)

  def cancel(session_key, reason) when is_binary(session_key) do
    with {:ok, entries} <- coordinator_entries() do
      Enum.each(entries, fn {_conversation_key, pid, _meta} ->
        if is_pid(pid) do
          GenServer.cast(pid, {:cancel_session, session_key, reason})
        end
      end)

      :ok
    end
  end

  @spec abort_session(binary(), term()) :: :ok | {:error, :unavailable}
  def abort_session(session_key, reason \\ :user_requested) when is_binary(session_key) do
    with {:ok, entries} <- coordinator_entries() do
      Enum.each(entries, fn {_conversation_key, pid, _meta} ->
        if is_pid(pid) do
          GenServer.cast(pid, {:abort_session, session_key, reason})
        end
      end)

      maybe_cancel_resume_conversation(session_key, reason)
      :ok
    end
  end

  @spec abort_run(binary(), term()) :: :ok | {:error, :unavailable}
  def abort_run(run_id, reason \\ :user_requested) when is_binary(run_id) do
    with {:ok, entries} <- coordinator_entries() do
      Enum.each(entries, fn {_conversation_key, pid, _meta} ->
        if is_pid(pid) do
          GenServer.cast(pid, {:abort_run, run_id, reason})
        end
      end)

      :ok
    end
  end

  @spec active_run(term()) :: {:ok, binary()} | :none
  def active_run(conversation_key) do
    case whereis(conversation_key) do
      {:ok, pid} ->
        GenServer.call(pid, :active_run)

      _ ->
        :none
    end
  end

  @spec active_run_for_session(binary()) :: {:ok, binary()} | :none | {:error, :unavailable}
  def active_run_for_session(session_key) when is_binary(session_key) and session_key != "" do
    with {:ok, sessions} <- authoritative_active_sessions() do
      case Enum.find(sessions, &(&1.session_key == session_key)) do
        %{run_id: run_id} -> {:ok, run_id}
        nil -> :none
      end
    end
  end

  def active_run_for_session(_), do: :none

  @spec busy?(binary()) :: boolean() | {:error, :unavailable}
  def busy?(session_key) when is_binary(session_key) and session_key != "" do
    case active_run_for_session(session_key) do
      {:ok, _run_id} -> true
      :none -> false
      {:error, _reason} = error -> error
    end
  end

  def busy?(_), do: false

  @spec list_active_sessions() ::
          [%{session_key: binary(), run_id: binary()}] | {:error, :unavailable}
  def list_active_sessions, do: authoritative_active_sessions_unwrapped()

  defp authoritative_active_sessions_unwrapped do
    case authoritative_active_sessions() do
      {:ok, sessions} -> sessions
      {:error, :unavailable} = error -> error
    end
  end

  defp authoritative_active_sessions do
    with registry_sessions when is_list(registry_sessions) <-
           Registry.select(LemonRouter.SessionRegistry, [
             {{:"$1", :"$2", %{run_id: :"$3"}}, [], [%{session_key: :"$1", run_id: :"$3"}]}
           ]),
         children when is_list(children) <-
           DynamicSupervisor.which_children(LemonRouter.SessionCoordinatorSupervisor),
         {:ok, runtime_sessions} <- runtime_active_sessions() do
      initial_sessions = Enum.uniq_by(runtime_sessions ++ registry_sessions, & &1.session_key)

      Enum.reduce_while(children, {:ok, initial_sessions}, fn {_id, pid, _type, _modules},
                                                              {:ok, sessions} ->
        case GenServer.call(pid, :active_submission) do
          {:ok, %{session_key: session_key, run_id: run_id}}
          when is_binary(session_key) and session_key != "" and is_binary(run_id) and
                 run_id != "" ->
            sessions =
              [%{session_key: session_key, run_id: run_id} | sessions]
              |> Enum.uniq_by(& &1.session_key)

            {:cont, {:ok, sessions}}

          :none ->
            {:cont, {:ok, sessions}}

          {:error, :unavailable} ->
            {:halt, {:error, :unavailable}}

          _unexpected ->
            {:halt, {:error, :unavailable}}
        end
      end)
      |> case do
        {:ok, sessions} -> {:ok, Enum.reverse(sessions)}
        error -> error
      end
    end
  rescue
    ArgumentError -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp runtime_active_sessions do
    {:ok,
     Registry.select(LemonRouter.RunRegistry, [
       {{:"$1", :"$2", %{session_key: :"$3"}},
        [{:andalso, {:is_binary, :"$1"}, {:is_binary, :"$3"}}],
        [%{run_id: :"$1", session_key: :"$3"}]}
     ])}
  rescue
    ArgumentError -> {:error, :unavailable}
  end

  @doc false
  def pending_count do
    DynamicSupervisor.which_children(LemonRouter.SessionCoordinatorSupervisor)
    |> Enum.reduce(0, fn {_id, pid, _type, _modules}, count ->
      count + GenServer.call(pid, :pending_count)
    end)
  end

  @doc false
  def presence_entries do
    children = DynamicSupervisor.which_children(LemonRouter.SessionCoordinatorSupervisor)

    entries =
      Enum.flat_map(children, fn {_id, pid, _type, _modules} ->
        GenServer.call(pid, :presence_entries)
      end)

    {:ok, entries}
  rescue
    ArgumentError -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
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

  # Live coordinators reconstruct the ephemeral read model after
  # SessionRegistry restarts without restarting or losing their runs.
  def handle_call(:active_submission, _from, state) do
    case state.active do
      %{session_key: session_key, run_id: run_id} = active
      when is_binary(session_key) and is_binary(run_id) ->
        case put_active_session_registry(active) do
          :ok ->
            {:reply, {:ok, %{session_key: session_key, run_id: run_id}}, state}

          {:error, :unavailable} ->
            {:reply, {:error, :unavailable}, state}
        end

      _ ->
        {:reply, :none, state}
    end
  end

  def handle_call(:pending_count, _from, state) do
    pending_steers =
      Enum.reduce(state.pending_steers, 0, fn {_id, entries}, n -> n + length(entries) end)

    {:reply, length(state.queue) + pending_steers, state}
  end

  def handle_call(:presence_entries, _from, state) do
    active = if state.active, do: [presence_entry(state.active, :active)], else: []
    queued = Enum.map(state.queue, &presence_entry(&1, :queued))
    pending =
      Enum.flat_map(state.pending_steers, fn {_target, entries} ->
        Enum.map(entries, fn {submission, _mode} -> presence_entry(submission, :queued) end)
      end)
    unresolved =
      Enum.map(state.unpersisted_receipts, fn {run_id, receipt} ->
        Map.merge(receipt, %{run_id: run_id, status: :unknown})
      end)

    {:reply, active ++ queued ++ pending ++ unresolved, state}
  end


  def handle_call({:submit_with_receipt, submission}, _from, state) do
    case RunReceiptStore.fetch(state.receipt_store, submission.run_id) do
      {:ok, %{} = receipt} ->
        {:reply, replay_receipt(submission, receipt), state}

      {:ok, nil} ->
        if Map.has_key?(state.unpersisted_receipts, submission.run_id) do
          {:reply, {:error, :outcome_unknown}, state}
        else
          admit_submission(state, submission)
        end

      {:error, {:sync_failed, _reason}} ->
        {:reply, {:error, :outcome_unknown}, state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  defp admit_submission(state, submission) do
    case recover_surviving_session_run(state, submission.session_key) do
      {:ok, recovered_state} ->
        {:reply, reply, next_state} =
          apply_transition(
            SessionTransitions.submit(
              recovered_state,
              submission,
              System.monotonic_time(:millisecond)
            ),
            recovered_state,
            reply?: true
          )

        next_state = maybe_emit_submit_phases(recovered_state, submission, next_state)

        case disposition(recovered_state, submission, next_state) do
          nil ->
            {:reply, reply, next_state}

          changes ->
            scope = presence_entry(submission, :unknown)
            receipt =
              changes
              |> Map.merge(%{
                run_id: submission.run_id,
                session_key: submission.session_key,
                agent_id: scope.agent_id,
                profile_id: scope.profile_id,
                state: :accepted
              })
              |> put_request_identity(submission)

            receipt =
              if reply == :ok do
                receipt
              else
                %{receipt | state: :outcome_unknown, effective_mode: nil, target_run_id: nil}
              end

            case RunReceiptStore.put(next_state.receipt_store, receipt) do
              :ok ->
                ack = if reply == :ok, do: {:ok, receipt}, else: {:error, :outcome_unknown}
                {:reply, ack, next_state}

              {:error, _reason} ->
                %SessionState{} = next_state
                next_state = %SessionState{
                  next_state
                  | unpersisted_receipts:
                      Map.put(next_state.unpersisted_receipts, submission.run_id, receipt)
                }

                {:reply, {:error, :outcome_unknown}, next_state}
            end
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:cancel, reason}, state) do
    {:noreply, next_state} =
      apply_transition(SessionTransitions.cancel(state, reason), state, dropped_reason: reason)

    {:noreply, next_state}
  end

  def handle_cast({:cancel_session, session_key, reason}, state) do
    {:noreply, next_state} =
      apply_transition(SessionTransitions.cancel_session(state, session_key, reason), state)

    {:noreply, next_state}
  end

  def handle_cast({:abort_session, session_key, reason}, state) do
    {:noreply, next_state} =
      apply_transition(SessionTransitions.abort_session(state, session_key, reason), state,
        dropped_reason: reason
      )

    {:noreply, next_state}
  end

  def handle_cast({:abort_run, run_id, reason}, state) do
    {:noreply, next_state} =
      apply_transition(SessionTransitions.abort_run(state, run_id, reason), state,
        dropped_reason: reason
      )

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

  def handle_info({:steer_accepted, submission_run_id}, state)
      when is_binary(submission_run_id) do
    {:noreply, next_state} =
      apply_transition(SessionTransitions.steer_accepted(state, submission_run_id), state,
        steered_into: pending_target_run_id(state, submission_run_id)
      )

    {:noreply, next_state}
  end

  def handle_info({:steer_backlog_accepted, submission_run_id}, state)
      when is_binary(submission_run_id) do
    {:noreply, next_state} =
      apply_transition(SessionTransitions.steer_accepted(state, submission_run_id), state,
        steered_into: pending_target_run_id(state, submission_run_id)
      )

    {:noreply, next_state}
  end

  def handle_info({:steer_rejected, submission_run_id}, state)
      when is_binary(submission_run_id) do
    {:noreply, next_state} =
      apply_transition(
        SessionTransitions.steer_rejected(
          state,
          submission_run_id,
          System.monotonic_time(:millisecond)
        ),
        state
      )

    {:noreply, next_state}
  end

  def handle_info({:steer_backlog_rejected, submission_run_id}, state)
      when is_binary(submission_run_id) do
    {:noreply, next_state} =
      apply_transition(
        SessionTransitions.steer_rejected(
          state,
          submission_run_id,
          System.monotonic_time(:millisecond)
        ),
        state
      )

    {:noreply, next_state}
  end

  def handle_info({:redirect_accepted, submission_run_id}, state)
      when is_binary(submission_run_id) do
    {:noreply, next_state} =
      apply_transition(SessionTransitions.steer_accepted(state, submission_run_id), state,
        steered_into: pending_target_run_id(state, submission_run_id)
      )

    {:noreply, next_state}
  end

  def handle_info({:redirect_rejected, submission_run_id}, state)
      when is_binary(submission_run_id) do
    notify_redirect_fallback(pending_submission(state, submission_run_id))

    {:noreply, next_state} =
      apply_transition(
        SessionTransitions.steer_rejected(
          state,
          submission_run_id,
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

  defp presence_entry(%{submission: %Submission{} = submission}, status),
    do: presence_entry(submission, status)

  defp presence_entry(submission, status) do
    request = Map.get(submission, :execution_request) || %{}
    meta = Map.get(request, :meta) || %{}
    agent_id = MapHelpers.get_key(meta, :agent_id)
    %{
      run_id: submission.run_id,
      session_key: submission.session_key,
      agent_id: agent_id,
      profile_id: MapHelpers.get_key(meta, :profile_id),
      status: status
    }
  end

  defp submission_identity(submission) do
    MapHelpers.get_key(submission.meta || %{}, :router_request_identity) ||
      MapHelpers.get_key(submission.execution_request.meta || %{}, :router_request_identity)
  end

  defp put_request_identity(receipt, submission) do
    identity = submission_identity(submission)
    if is_nil(identity), do: receipt, else: Map.put(receipt, :request_identity, identity)
  end

  defp replay_receipt(_submission, %{state: :outcome_unknown}),
    do: {:error, :outcome_unknown}

  defp replay_receipt(submission, receipt) do
    case {submission_identity(submission), Map.get(receipt, :request_identity)} do
      {nil, _stored} -> {:ok, receipt}
      {identity, identity} -> {:ok, receipt}
      {_identity, nil} -> {:error, :outcome_unknown}
      {_identity, _different} -> {:error, :run_id_conflict}
    end
  end

  defp disposition(original_state, submission, state) do
    run_id = submission.run_id

    case pending_entry(state, run_id) do
      {target, pending} ->
        mode =
          case pending.queue_mode do
            :steer -> :steer_pending
            :steer_backlog -> :steer_backlog_pending
            :redirect -> :redirect_pending
          end

        %{effective_mode: mode, target_run_id: target}

      nil ->
        queued = Enum.find(state.queue, &(&1.run_id == run_id))

        merged_target =
          Enum.find_value(state.merged_run_ids, fn {target, followers} ->
            if target == run_id or run_id in followers, do: target
          end)

        cond do
          queued && queued.queue_mode == :interrupt && original_state.active != nil ->
            %{effective_mode: :interrupt, target_run_id: original_state.active.run_id}

          merged_target != nil ->
            %{effective_mode: :merged, target_run_id: merged_target}

          active_submission_run_id(state) == run_id ->
            %{effective_mode: :new_run, target_run_id: run_id}

          queued != nil ->
            %{effective_mode: :queued, target_run_id: run_id}

          true ->
            nil
        end
    end
  end

  defp pending_entry(state, run_id) do
    Enum.find_value(state.pending_steers, fn {target, entries} ->
      case Enum.find(entries, fn {submission, _mode} -> submission.run_id == run_id end) do
        {submission, _mode} -> {target, submission}
        nil -> nil
      end
    end)
  end

  defp pending_target_run_id(state, run_id) do
    case pending_entry(state, run_id) do
      {target, _submission} -> target
      nil -> nil
    end
  end

  defp persist_receipt_updates(original_state, state, opts) do
    changes =
      Enum.reduce(original_state.pending_steers, %{}, fn {target, entries}, acc ->
        Enum.reduce(entries, acc, fn {submission, _fallback}, acc ->
          if pending_entry(state, submission.run_id) == nil do
            disposition =
              if is_binary(opts[:steered_into]) do
                %{effective_mode: submission.queue_mode, target_run_id: target}
              else
                disposition(original_state, submission, state)
              end

            if disposition, do: Map.put(acc, submission.run_id, disposition), else: acc
          else
            acc
          end
        end)
      end)

    changes =
      Enum.reduce(state.merged_run_ids, changes, fn {target, followers}, acc ->
        if Map.get(original_state.merged_run_ids, target) == followers do
          acc
        else
          Enum.reduce([target | followers], acc, fn run_id, acc ->
            Map.put(acc, run_id, %{effective_mode: :merged, target_run_id: target})
          end)
        end
      end)

    Enum.reduce(changes, :ok, fn {run_id, changes}, result ->
      case RunReceiptStore.update(state.receipt_store, run_id, changes) do
        :ok ->
          result

        {:error, _reason} ->
          Logger.warning("SessionCoordinator receipt persistence failed")
          {:error, :outcome_unknown}
      end
    end)
  end

  defp fence_merge_receipts(original_state, state) do
    Enum.reduce_while(state.merged_run_ids, :ok, fn {target, followers}, :ok ->
      if Map.get(original_state.merged_run_ids, target) == followers do
        {:cont, :ok}
      else
        result =
          Enum.reduce_while([target | followers], :ok, fn run_id, :ok ->
            case RunReceiptStore.mark_unknown(state.receipt_store, run_id) do
              :ok -> {:cont, :ok}
              {:error, _reason} = error -> {:halt, error}
            end
          end)

        if result == :ok, do: {:cont, :ok}, else: {:halt, result}
      end
    end)
  end

  defp apply_transition(transition, original_state, opts \\ [])

  defp apply_transition({:ok, transitioned_state, effects}, original_state, opts) do
    case fence_merge_receipts(original_state, transitioned_state) do
      :ok ->
        complete_dropped_submissions(original_state, transitioned_state, opts)
        {next_state, reply} = apply_effects(transitioned_state, effects, opts)
        maybe_cleanup_event_bridge_runs(original_state, next_state)
        persistence = persist_receipt_updates(original_state, next_state, opts)
        retained = retained_run_ids(next_state)

        next_state = %SessionState{
          next_state
          | merged_run_ids:
              Map.filter(next_state.merged_run_ids, fn {run_id, _followers} ->
                MapSet.member?(retained, run_id)
              end)
        }

        reply = if persistence == :ok, do: reply, else: {:error, :outcome_unknown}
        if opts[:reply?], do: {:reply, reply, next_state}, else: {:noreply, next_state}

      {:error, _reason} ->
        if opts[:reply?] do
          {:reply, {:error, :outcome_unknown}, original_state}
        else
          raise "SessionCoordinator merge receipt fence unavailable"
        end
    end
  end

  defp apply_transition({:error, reason}, original_state, _opts) do
    {:reply, {:error, reason}, original_state}
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
    case dispatch_steer(
           active_run_id,
           steer_mode,
           submission.run_id,
           prepare_steering_prompt(state, submission.execution_request)
         ) do
      :ok ->
        {state, reply_acc}

      :error ->
        if steer_mode == :redirect do
          notify_redirect_fallback(submission)
        end

        {:ok, next_state, extra_effects} =
          SessionTransitions.dispatch_steer_failed(
            state,
            submission.run_id,
            System.monotonic_time(:millisecond)
          )

        case fence_merge_receipts(state, next_state) do
          :ok ->
            {resolved_state, result} = apply_effects(next_state, extra_effects, opts)
            {resolved_state, merge_reply(reply_acc, result)}

          {:error, _reason} ->
            {state, {:error, :outcome_unknown}}
        end
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
    next = refresh_queued_resume(next)

    start_result =
      with :ok <- LemonRouter.NativeLineage.validate_activation(next.execution_request),
           :ok <- LemonRouter.ResumeResolver.bind_run(next.execution_request) do
        RunStarter.start(next, self(), state.conversation_key)
      end

    case start_result do
      {:ok, pid} when is_pid(pid) ->
        next_state = activate_submission(state, next, rest, pid, opts)

        if opts[:return_result?], do: {next_state, :started}, else: {next_state, :ok}

      {:error, reason} ->
        case partially_started_run_pid(next.run_id) do
          pid when is_pid(pid) ->
            Logger.warning(
              "SessionCoordinator adopting partially started run run_id=#{inspect(next.run_id)} " <>
                "key=#{inspect(state.conversation_key)} start_error=#{inspect(reason)}"
            )

            next_state = activate_submission(state, next, rest, pid, opts)
            if opts[:return_result?], do: {next_state, :started}, else: {next_state, :ok}

          nil ->
            Logger.warning(
              "SessionCoordinator failed to start run run_id=#{inspect(next.run_id)} key=#{inspect(state.conversation_key)} reason=#{inspect(reason)}"
            )

            emit_start_failure(next, reason)
            if rest != [], do: send(self(), :maybe_start_next)

            next_state = %SessionState{state | queue: rest}

            if opts[:return_result?],
              do: {next_state, {:error, reason}},
              else: {next_state, :ok}
        end
    end
  end

  defp maybe_start_next(state, _opts), do: {state, :noop}

  defp refresh_queued_resume(%Submission{} = submission) do
    request = submission.execution_request
    source = MapHelpers.get_key(request.meta || %{}, :resume_source)

    explicit =
      if source == :explicit or (is_nil(source) and not is_nil(request.resume)),
        do: request.resume,
        else: nil

    case LemonRouter.ResumeResolver.resolve(
           explicit,
           submission.session_key,
           request.meta || %{},
           request.tool_policy,
           LemonCore.Store,
           request.run_id
         ) do
      {:ok, resume, resume_source} ->
        request = %{
          request
          | resume: resume,
            meta: Map.put(request.meta || %{}, :resume_source, resume_source)
        }

        %{submission | execution_request: request}

      {:error, _reason} ->
        submission
    end
  end

  # SessionRegistry is an ephemeral read model. A registry restart can remove
  # its row while the independently supervised RunProcess survives. Before an
  # idle coordinator accepts new work, adopt that authoritative process so the
  # new submission stays queued behind it and its DOWN signal advances the
  # queue normally.
  defp recover_surviving_session_run(%SessionState{active: %{} = _active} = state, _session_key),
    do: {:ok, state}

  defp recover_surviving_session_run(%SessionState{} = state, session_key)
       when is_binary(session_key) do
    case Registry.lookup(LemonRouter.SessionRegistry, session_key) do
      [] ->
        adopt_surviving_session_run(state, session_key)

      [{_owner, %{run_id: run_id}} | _] when is_binary(run_id) ->
        case Registry.lookup(LemonRouter.RunRegistry, run_id) do
          [{pid, _} | _] when is_pid(pid) ->
            if Process.alive?(pid),
              do: adopt_run(state, session_key, run_id, pid),
              else: {:error, :session_busy}

          _ ->
            {:error, :session_busy}
        end

      _registered ->
        {:error, :session_busy}
    end
  rescue
    ArgumentError -> {:error, :router_not_ready}
  catch
    :exit, _ -> {:error, :router_not_ready}
  end

  defp recover_surviving_session_run(state, _session_key), do: {:ok, state}

  defp adopt_surviving_session_run(state, session_key) do
    case surviving_session_runs(session_key) do
      [] ->
        {:ok, state}

      [{run_id, pid}] ->
        adopt_run(state, session_key, run_id, pid)

      _multiple ->
        {:error, :session_single_flight_violated}
    end
  end

  defp adopt_run(%SessionState{} = state, session_key, run_id, pid) do
    active = %{
      pid: pid,
      mon_ref: Process.monitor(pid),
      run_id: run_id,
      session_key: session_key
    }

    case put_active_session_registry(active) do
      :ok -> {:ok, %SessionState{state | active: active}}
      {:error, :unavailable} -> {:error, :router_not_ready}
    end
  end

  defp surviving_session_runs(session_key) do
    Registry.select(LemonRouter.RunRegistry, [
      {{:"$1", :"$2", %{session_key: session_key}},
       [{:andalso, {:is_binary, :"$1"}, {:is_pid, :"$2"}}], [{{:"$1", :"$2"}}]}
    ])
    |> Enum.filter(fn {_run_id, pid} -> Process.alive?(pid) end)
  end

  defp activate_submission(%SessionState{} = state, next, rest, pid, opts) do
    mon_ref = Process.monitor(pid)

    started_submission =
      maybe_emit_waiting_for_slot(next, Keyword.get(opts, :emit_phase?, true))

    put_active_session_registry(started_submission)

    %SessionState{
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
  end

  defp partially_started_run_pid(run_id) when is_binary(run_id) do
    case Registry.lookup(LemonRouter.RunRegistry, run_id) do
      [{pid, _} | _] when is_pid(pid) -> if Process.alive?(pid), do: pid
      _ -> nil
    end
  end

  defp partially_started_run_pid(_run_id), do: nil

  defp emit_start_failure(%Submission{} = submission, reason) do
    safe_reason = start_failure_reason(reason)

    event =
      LemonCore.Event.new(
        :run_completed,
        Events.RunCompleted.new(%{
          completed:
            Events.Completion.new(%{
              ok: false,
              error: %{type: :run_start_failed, reason: safe_reason},
              answer: ""
            }),
          duration_ms: 0
        }),
        %{
          run_id: submission.run_id,
          session_key: submission.session_key,
          synthetic: true,
          failure_stage: :run_start
        }
      )

    LemonRouter.RunCompletion.publish(submission.execution_request, event)
  end

  defp start_failure_reason(reason)
       when is_atom(reason) or is_binary(reason) or is_number(reason),
       do: reason

  defp start_failure_reason(reason), do: inspect(reason, limit: 20, printable_limit: 1_000)

  defp maybe_emit_waiting_for_slot(%Submission{} = submission, true) do
    if phase_emission_enabled?(submission) do
      previous_phase = submission.current_phase || :accepted
      PhasePublisher.emit(submission, :waiting_for_slot, previous_phase)
    else
      submission
    end
  end

  defp maybe_emit_waiting_for_slot(%Submission{} = submission, false), do: submission

  defp complete_dropped_submissions(original_state, next_state, opts) do
    retained = retained_run_ids(next_state)
    replacement = List.last(next_state.queue)

    submissions =
      original_state.queue ++
        Enum.flat_map(original_state.pending_steers, fn {_run_id, entries} ->
          Enum.map(entries, fn {submission, _mode} -> submission end)
        end)

    Enum.each(submissions, fn submission ->
      unless MapSet.member?(retained, submission.run_id) do
        {ok?, error, meta} =
          cond do
            Keyword.has_key?(opts, :dropped_reason) ->
              {false, opts[:dropped_reason], %{disposition: :cancelled, cancelled: true}}

            is_binary(opts[:steered_into]) ->
              {true, nil, %{disposition: :steered, active_run_id: opts[:steered_into]}}

            match?(%Submission{}, replacement) ->
              {false, %{type: :superseded, replacement_run_id: replacement.run_id},
               %{disposition: :merged, replacement_run_id: replacement.run_id}}
          end

        event =
          LemonCore.Event.new(
            :run_completed,
            Events.RunCompleted.new(%{
              completed: Events.Completion.new(%{ok: ok?, error: error, answer: "", meta: meta}),
              duration_ms: 0
            }),
            %{run_id: submission.run_id, session_key: submission.session_key, synthetic: true}
          )

        LemonRouter.RunCompletion.publish(submission.execution_request, event)

        if not ok? and phase_emission_enabled?(submission) do
          _ =
            PhasePublisher.emit(
              submission,
              :aborted,
              submission.current_phase || :queued_in_session
            )
        end
      end
    end)
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
  end

  defp maybe_cancel_active(state, _reason), do: state

  # Origin comes from the incoming command; cwd/placement come from the active
  # run. Never discover controller-local files for a remote active invocation.
  defp prepare_steering_prompt(state, request) do
    prompt = request.prompt || ""

    case active_submission(state) do
      %Submission{execution_request: active} ->
        incoming_meta = request.meta || %{}

        node =
          MapHelpers.get_key(active.meta || %{}, :node) ||
            MapHelpers.get_key(incoming_meta, :node)

        meta = incoming_meta |> Map.delete("node") |> Map.put(:node, node)
        args = [active.cwd, prompt, meta]

        case LemonCore.AgentRuntime.call(:prepare_prompt, args, prompt) do
          prepared when is_binary(prepared) -> prepared
          _ -> prompt
        end

      nil ->
        prompt
    end
  end

  defp dispatch_steer(active_run_id, steer_mode, submission_run_id, prompt)
       when steer_mode in [:steer, :steer_backlog, :redirect] and is_binary(submission_run_id) do
    case runtime_run_pid(active_run_id) do
      nil ->
        :error

      run_pid ->
        GenServer.cast(run_pid, {steer_mode, submission_run_id, prompt || "", self()})
        :ok
    end
  end

  # Redirect degrades to a queued follow-up when the run cannot accept it. The
  # correction is not lost, but the user asked to change an in-flight request,
  # so tell them what actually happened.
  defp notify_redirect_fallback(%Submission{run_id: run_id, session_key: session_key}) do
    parsed = LemonRouter.ChannelContext.parse_session_key(session_key)

    with :channel_peer <- parsed.kind,
         peer_kind when peer_kind in [:dm, :group, :channel] <- parsed.peer_kind,
         peer_id when is_binary(peer_id) and peer_id != "" <- parsed.peer_id do
      route = %LemonCore.DeliveryRoute{
        channel_id: parsed.channel_id,
        account_id: parsed.account_id || "default",
        peer_kind: peer_kind,
        peer_id: peer_id,
        thread_id: parsed.thread_id
      }

      intent = %LemonCore.DeliveryIntent{
        intent_id: "#{run_id}:redirect:fallback",
        run_id: run_id,
        session_key: session_key,
        route: route,
        kind: :notice,
        body: %{
          text:
            "Redirect isn't available for this run — queued your correction as a follow-up instead.",
          seq: 0
        },
        meta: %{surface: :status, user_msg_id: nil}
      }

      _ = dispatcher().dispatch(intent)
      :ok
    else
      _ -> :ok
    end
  end

  defp notify_redirect_fallback(_submission), do: :ok

  defp pending_submission(%SessionState{pending_steers: pending_steers}, submission_run_id) do
    Enum.find_value(pending_steers, fn {_active_run_id, entries} ->
      case Enum.find(entries, fn {submission, _fallback_mode} ->
             submission.run_id == submission_run_id
           end) do
        {submission, _fallback_mode} -> submission
        nil -> nil
      end
    end)
  end

  defp dispatcher do
    Application.get_env(:lemon_router, :dispatcher, LemonChannels.Dispatcher)
  end

  defp put_active_session_registry(%{session_key: session_key, run_id: run_id}) do
    if is_binary(session_key) do
      _ = Registry.unregister(LemonRouter.SessionRegistry, session_key)

      case Registry.register(LemonRouter.SessionRegistry, session_key, %{run_id: run_id}) do
        {:ok, _owner} -> :ok
        {:error, _reason} -> {:error, :unavailable}
      end
    else
      :ok
    end
  rescue
    ArgumentError -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
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
    ArgumentError -> state
  end

  defp clear_active_session_registry(state), do: state

  defp runtime_run_pid(run_id) when is_binary(run_id) do
    runtime = configured_engine_runtime()

    if Code.ensure_loaded?(runtime) and function_exported?(runtime, :run_pid, 1) do
      runtime.run_pid(run_id)
    end
  rescue
    error in ArgumentError ->
      # Registry metadata can disappear or be incomplete during a restart.
      # ArgumentErrors from the runtime callback itself must still surface.
      case __STACKTRACE__ do
        [{Registry, :key_info!, _, _} | _] ->
          nil

        [{:ets, :lookup_element, [_registry, 0, 2], _}, {Registry, :key_ets!, _, _} | _] ->
          nil

        stacktrace ->
          reraise error, stacktrace
      end
  catch
    :exit, {:noproc, {GenServer, :call, _}} -> nil
  end

  defp runtime_run_pid(_), do: nil

  defp configured_engine_runtime do
    Application.get_env(:lemon_router, :engine_runtime)
  end

  defp coordinator_entries do
    {:ok,
     Registry.select(LemonRouter.ConversationRegistry, [
       {{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}
     ])}
  rescue
    ArgumentError -> {:error, :unavailable}
  end

  defp maybe_cancel_resume_conversation(session_key, reason) do
    case resume_conversation_key(session_key) do
      nil -> :ok
      conversation_key -> cancel_conversation(conversation_key, reason)
    end
  end

  defp resume_conversation_key(session_key) when is_binary(session_key) do
    case LemonCore.ChatStateStore.get(session_key) do
      %LemonCore.ChatState{last_engine: engine, last_resume_token: token}
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
