defmodule LemonRouter.RunOrchestrator do
  @moduledoc false

  # Router internal: reached through the `LemonRouter` facade, not directly.
  #
  # Orchestrates run submission and lifecycle.
  #
  # The orchestrator is responsible for:
  # - Normalizing router-facing `RunRequest` input
  # - Recording orchestration lifecycle introspection
  # - Building a router-owned `Submission` plus core `ExecutionCommand`
  # - Delegating run-start mechanics to `LemonRouter.RunStarter`
  # - Subscribing external event bridges before coordinator handoff
  # - Consuming prepared compaction markers only after coordinator acceptance

  use GenServer

  require Logger

  alias LemonCore.{Introspection, MapHelpers, RunRequest, RunStore, SessionKey, Store}

  alias LemonRouter.{
    PendingCompaction,
    RunProcess,
    RunStarter,
    SessionCoordinator,
    Submission,
    SubmissionBuilder
  }

  @abort_tombstone_ttl_ms 300_000
  @serialized_mutation_timeout_ms 20_000
  @run_admission_table :router_run_admissions
  @abort_tombstone_table :router_abort_tombstones
  @request_identity_meta_key :router_request_identity
  @replay_identity_meta_key :router_replay_identity
  @replay_content_identity_meta_key :router_replay_content_identity
  @run_admission_retention_ms 86_400_000
  @receipt_cleanup_interval_ms 60_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc false
  def admission_table, do: @run_admission_table

  @doc false
  def abort_tombstone_table, do: @abort_tombstone_table

  @doc """
  Submit a run request.

  ## Parameters

  Accepts a `%LemonCore.RunRequest{}` with these fields:

  - `:origin` - Source of the request (:channel, :control_plane, :cron, :node)
  - `:session_key` - Session key for routing
  - `:agent_id` - Agent identifier
  - `:prompt` - User prompt text
  - `:queue_mode` - Queue mode (:collect, :followup, :steer, :steer_backlog, :redirect,
    :interrupt)
  - `:model` - Optional model override (independent of profile binding)
  - `:meta` - Additional metadata
  - `:cwd` - Optional cwd override
  - `:tool_policy` - Optional tool policy override

  ## Returns

  `{:ok, run_id}` on success, `{:error, reason}` on failure.
  """
  @spec submit(RunRequest.t() | map() | keyword()) :: {:ok, binary()} | {:error, term()}
  def submit(%RunRequest{} = request), do: submit(__MODULE__, request)

  def submit(request) when is_map(request) or is_list(request) do
    normalized = RunRequest.new(request)
    submit(__MODULE__, normalized)
  end

  @doc """
  Submit a run request to a specific orchestrator server.
  """
  @spec submit(GenServer.server(), RunRequest.t() | map() | keyword()) ::
          {:ok, binary()} | {:error, term()}
  def submit(server, %RunRequest{} = request), do: GenServer.call(server, {:submit, request})

  def submit(server, request) when is_map(request) or is_list(request) do
    normalized = RunRequest.new(request)
    submit(server, normalized)
  end

  @doc false
  @spec register_abort(binary(), term()) :: :ok
  def register_abort(run_id, reason) when is_binary(run_id) do
    register_abort(__MODULE__, run_id, reason)
  end

  @doc false
  @spec register_abort(GenServer.server(), binary(), term()) :: :ok
  def register_abort(server, run_id, reason) when is_binary(run_id) do
    # Submit handling may spend up to 15 seconds inside coordinator admission.
    # This call must wait past that serialized window: timing out earlier does
    # not dequeue a GenServer call and would let a tombstone commit after its
    # caller had already reported failure without dispatching cancellation.
    register_abort(server, run_id, reason, @serialized_mutation_timeout_ms)
  end

  @doc false
  @spec register_abort(GenServer.server(), binary(), term(), timeout()) :: :ok
  def register_abort(server, run_id, reason, timeout_ms)
      when is_binary(run_id) and is_integer(timeout_ms) and timeout_ms > 0 do
    GenServer.call(server, {:register_abort, run_id, reason}, timeout_ms)
  end

  @doc """
  Start a run process from a prepared submission.

  This entrypoint is used by `LemonRouter.SessionCoordinator`, which owns
  queue semantics and decides when a submission should become an active run.
  Orchestrator defaults fill only missing start fields; caller-supplied
  `run_supervisor`, `run_process_module`, and `run_process_opts` are preserved.
  """
  @spec start_run_process(GenServer.server(), Submission.t() | map(), pid(), term()) ::
          {:ok, pid()} | {:error, term()}
  def start_run_process(server, submission, coordinator_pid, conversation_key)
      when is_map(submission) and is_pid(coordinator_pid) do
    GenServer.call(
      server,
      {:start_run_process, submission, coordinator_pid, conversation_key},
      15_000
    )
  end

  @doc """
  Lightweight run counts for status UIs.

  `active` reflects current supervised run processes.
  `queued` and `completed_today` are derived from telemetry counters
  maintained by `LemonRouter.RunCountTracker`.
  """
  @spec counts() :: %{
          active: non_neg_integer(),
          queued: non_neg_integer(),
          completed_today: non_neg_integer()
        }
  def counts do
    # Both sources are processes that may not be running, and calling a process
    # that is not there *exits* rather than raising — so `rescue` alone left
    # this function propagating the very failure it was written to absorb.
    active =
      try do
        %{active: n} = DynamicSupervisor.count_children(LemonRouter.RunSupervisor)
        n
      rescue
        _ -> 0
      catch
        _kind, _reason -> 0
      end

    {queued, completed_today} =
      try do
        {LemonRouter.RunCountTracker.queued(), LemonRouter.RunCountTracker.completed_today()}
      rescue
        _ -> {0, 0}
      catch
        _kind, _reason -> {0, 0}
      end

    %{active: active, queued: queued, completed_today: completed_today}
  end

  @impl true
  def init(opts) do
    run_process_opts =
      opts
      |> Keyword.get(:run_process_opts, %{})
      |> normalize_run_process_opts()

    state = %{
      run_supervisor: Keyword.get(opts, :run_supervisor, LemonRouter.RunSupervisor),
      run_process_module: Keyword.get(opts, :run_process_module, RunProcess),
      run_process_opts: run_process_opts,
      abort_tombstone_ttl_ms: Keyword.get(opts, :abort_tombstone_ttl_ms, @abort_tombstone_ttl_ms),
      run_admission_retention_ms:
        Keyword.get(opts, :run_admission_retention_ms, @run_admission_retention_ms),
      receipt_cleanup_interval_ms:
        Keyword.get(opts, :receipt_cleanup_interval_ms, @receipt_cleanup_interval_ms),
      last_receipt_cleanup_ms: 0,
      abort_tombstones: %{},
      accepted_run_ids: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:submit, %RunRequest{} = params}, _from, state) do
    state = maybe_cleanup_durable_receipts(state)
    params = ensure_run_id(params)

    {result, state} =
      case fetch_abort_tombstone(params.run_id, state) do
        {:active, %{reason: reason}, state} ->
          {reject_tombstoned_submission(params, reason), state}

        {:none, state} ->
          submit_idempotently(params, state)

        {:error, state} ->
          {{:error, :outcome_unknown}, state}
      end

    {:reply, result, state}
  end

  def handle_call({:register_abort, run_id, reason}, _from, state) do
    state = maybe_cleanup_durable_receipts(state)

    reason_code = normalize_abort_reason(reason)

    tombstone = %{
      state: "aborted",
      reason_code: reason_code,
      expires_at_ms: System.system_time(:millisecond) + state.abort_tombstone_ttl_ms
    }

    case persist_abort_tombstone(run_id, tombstone) do
      :ok ->
        emit_abort_tombstone_telemetry(:registered, reason_code)
        result = dispatch_registered_abort(run_id, reason)
        state = %{state | abort_tombstones: Map.put(state.abort_tombstones, run_id, tombstone)}
        {:reply, result, state}

      {:error, _reason} ->
        {:reply, {:error, :outcome_unknown}, state}
    end
  end

  def handle_call(
        {:start_run_process, submission, coordinator_pid, conversation_key},
        _from,
        state
      ) do
    result = do_start_run_process(submission, coordinator_pid, conversation_key, state)
    {:reply, result, state}
  end

  def handle_call({:submit, _invalid}, _from, state) do
    {:reply, {:error, :invalid_run_request}, state}
  end

  defp do_submit(%RunRequest{} = params, orchestrator_state) do
    origin = params.origin || :unknown
    session_key = params.session_key
    agent_id = params.agent_id || SessionKey.agent_id(session_key) || "default"
    queue_mode = params.queue_mode || :collect

    # The serialized submit boundary fixes the ID before checking abort tombstones.
    run_id = params.run_id
    request = params

    # Emit introspection event for orchestration start
    Introspection.record(
      :orchestration_started,
      %{
        origin: origin,
        agent_id: agent_id,
        queue_mode: queue_mode
      },
      run_id: run_id,
      session_key: session_key,
      agent_id: agent_id,
      engine: "lemon",
      provenance: :direct
    )

    case SubmissionBuilder.build(request, orchestrator_state) do
      {:ok, %Submission{} = submission} ->
        LemonCore.EventBridge.subscribe_run(run_id)

        case session_coordinator_mod().submit(submission.conversation_key, submission) do
          :ok ->
            execution_request = submission.execution_request
            meta = submission.meta || %{}

            PendingCompaction.consume(
              submission.session_key,
              submission.pending_compaction_marker
            )

            Introspection.record(
              :orchestration_resolved,
              %{
                model: meta[:model],
                conversation_key: inspect(execution_request.conversation_key)
              },
              run_id: run_id,
              session_key: submission.session_key,
              agent_id: meta[:agent_id] || agent_id,
              engine: "lemon",
              provenance: :direct
            )

            LemonCore.Telemetry.run_submit(
              submission.session_key,
              origin,
              "lemon"
            )

            {:ok, run_id}

          {:error, reason} ->
            LemonCore.EventBridge.unsubscribe_run(run_id)

            Introspection.record(
              :orchestration_failed,
              %{
                reason: safe_error_label(reason)
              },
              run_id: run_id,
              session_key: session_key,
              agent_id: agent_id,
              engine: "lemon",
              provenance: :direct
            )

            Logger.error("Failed to submit run to session coordinator: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Introspection.record(
          :orchestration_failed,
          %{
            reason: safe_error_label(reason)
          },
          run_id: run_id,
          session_key: session_key,
          agent_id: agent_id,
          engine: "lemon",
          provenance: :direct
        )

        {:error, reason}
    end
  end

  defp submit_idempotently(%RunRequest{} = params, state) do
    state = prune_accepted_run_ids(state)
    identity = request_identity(params)

    case Map.get(state.accepted_run_ids, params.run_id) do
      %{identity: ^identity} ->
        {{:ok, params.run_id}, state}

      %{} ->
        {{:error, :run_id_conflict}, state}

      nil ->
        case claim_admission(params, identity, state.run_admission_retention_ms) do
          {:ok, admission, ownership} ->
            continue_admission(params, identity, admission, ownership, state)

          {:error, :run_id_conflict} ->
            {{:error, :run_id_conflict}, state}

          {:error, _reason} ->
            {{:error, :outcome_unknown}, state}
        end
    end
  end

  defp claim_admission(params, identity, retention_ms) do
    claimed_at_ms = System.system_time(:millisecond)

    entry = %{
      identity: identity,
      state: "claimed",
      claimed_at_ms: claimed_at_ms,
      expires_at_ms: claimed_at_ms + retention_ms,
      retention_ms: retention_ms
    }

    case Store.put_new(@run_admission_table, params.run_id, entry) do
      :ok -> {:ok, entry, :new}
      {:error, :exists} -> existing_admission(params.run_id, identity)
      {:error, _reason} -> {:error, :admission_store_unavailable}
      _ -> {:error, :admission_store_unavailable}
    end
  rescue
    _ -> {:error, :admission_store_unavailable}
  catch
    _, _ -> {:error, :admission_store_unavailable}
  end

  defp existing_admission(run_id, identity) do
    case Store.fetch(@run_admission_table, run_id) do
      {:ok, %{} = entry} ->
        if MapHelpers.get_key(entry, :identity) == identity,
          do: {:ok, entry, :existing},
          else: {:error, :run_id_conflict}

      {:ok, nil} ->
        {:error, :admission_store_unavailable}

      {:error, _reason} ->
        {:error, :admission_store_unavailable}

      _unexpected ->
        {:error, :admission_store_unavailable}
    end
  rescue
    _ -> {:error, :admission_store_unavailable}
  catch
    _, _ -> {:error, :admission_store_unavailable}
  end

  defp continue_admission(params, identity, admission, ownership, state) do
    case MapHelpers.get_key(admission, :state) do
      "accepted" ->
        continue_accepted_admission(params, identity, admission, state)

      _pending_or_legacy ->
        continue_pending_admission(params, identity, admission, ownership, state)
    end
  end

  defp continue_accepted_admission(params, identity, admission, state) do
    _ = admission
    cache_until_ms = System.system_time(:millisecond) + state.run_admission_retention_ms

    {{:ok, params.run_id},
     cache_accepted_admission(state, params.run_id, identity, cache_until_ms)}
  end

  # A durable terminal run is evidence that an earlier owner crossed the
  # external enqueue boundary only when the terminal summary carries this exact
  # request identity. A bare run ID cannot acknowledge a different session or
  # payload, and an unavailable read cannot prove that no terminal run exists.
  defp continue_pending_admission(params, identity, admission, ownership, state) do
    admission_state = MapHelpers.get_key(admission, :state)

    case terminal_run_status(params, identity) do
      :matching_terminal ->
        accept_terminal_replay(params.run_id, identity, admission, state)

      :not_terminal
      when ownership == :new or
             (ownership == :existing and admission_state == "claimed") ->
        submit_new_admission(params, identity, admission, state)

      :not_terminal ->
        # An existing nonterminal claim may already have crossed the volatile
        # enqueue boundary. Re-executing it merely because processes or the run
        # summary disappeared would turn a crash into duplicate side effects.
        {{:error, :outcome_unknown}, state}

      :conflicting_terminal ->
        {{:error, :run_id_conflict}, state}

      :terminal_outcome_unknown ->
        {{:error, :outcome_unknown}, state}
    end
  end

  defp submit_new_admission(params, identity, admission, state) do
    # Once the external-enqueue boundary becomes ambiguous, retain only the
    # permanent idempotency fence. Delivery/session metadata and diagnostic
    # timestamps are not needed to reject a replay and must not live forever.
    submitting = compact_admission("submitting", identity)

    case Store.compare_and_swap(@run_admission_table, params.run_id, admission, submitting) do
      :ok ->
        case do_submit(attach_request_identity(params, identity), state) do
          {:ok, run_id} ->
            case persist_accepted_admission(
                   run_id,
                   identity,
                   submitting,
                   state.run_admission_retention_ms
                 ) do
              {:ok, expires_at_ms} ->
                {{:ok, run_id}, cache_accepted_admission(state, run_id, identity, expires_at_ms)}

              {:error, _reason} ->
                {{:error, :outcome_unknown}, state}
            end

          {:error, :outcome_unknown} ->
            {{:error, :outcome_unknown}, state}

          {:error, _reason} = error ->
            # No enqueue acknowledgement was returned, so this is the one
            # safe point at which the durable claim can be made retryable.
            # If that rollback cannot itself be durably recorded, the caller
            # must treat the mutation as ambiguous.
            case Store.compare_and_swap(
                   @run_admission_table,
                   params.run_id,
                   submitting,
                   admission
                 ) do
              :ok -> {error, state}
              _failure -> {{:error, :outcome_unknown}, state}
            end

          _malformed_acknowledgement ->
            {{:error, :outcome_unknown}, state}
        end

      _failure ->
        {{:error, :outcome_unknown}, state}
    end
  rescue
    _ -> {{:error, :outcome_unknown}, state}
  catch
    _, _ -> {{:error, :outcome_unknown}, state}
  end

  defp accept_terminal_replay(run_id, identity, admission, state) do
    case persist_accepted_admission(
           run_id,
           identity,
           admission,
           state.run_admission_retention_ms
         ) do
      {:ok, expires_at_ms} ->
        {{:ok, run_id}, cache_accepted_admission(state, run_id, identity, expires_at_ms)}

      {:error, _reason} ->
        {{:error, :outcome_unknown}, state}
    end
  end

  defp terminal_run_status(params, identity) do
    case run_store_module().fetch(params.run_id) do
      {:ok, nil} ->
        :not_terminal

      {:ok, record} when is_map(record) ->
        classify_terminal_record(record, params.session_key, identity)

      {:error, _reason} ->
        :terminal_outcome_unknown

      _unexpected ->
        :terminal_outcome_unknown
    end
  rescue
    _ -> :terminal_outcome_unknown
  catch
    _, _ -> :terminal_outcome_unknown
  end

  defp classify_terminal_record(record, session_key, identity) do
    case MapHelpers.get_key(record, :summary) do
      nil ->
        # A durable run record without a terminal summary proves that this ID
        # has already crossed into execution, but cannot prove its outcome.
        :terminal_outcome_unknown

      summary when is_map(summary) ->
        terminal_session_key = MapHelpers.get_key(summary, :session_key)

        terminal_identity =
          case MapHelpers.get_key(summary, :meta) do
            meta when is_map(meta) -> MapHelpers.get_key(meta, @request_identity_meta_key)
            _ -> nil
          end

        cond do
          terminal_session_key != session_key -> :conflicting_terminal
          is_binary(terminal_identity) and terminal_identity != identity -> :conflicting_terminal
          terminal_identity == identity -> :matching_terminal
          true -> :terminal_outcome_unknown
        end

      _unexpected_summary ->
        :terminal_outcome_unknown
    end
  end

  defp attach_request_identity(%RunRequest{} = params, identity) do
    meta = Map.put(params.meta || %{}, @request_identity_meta_key, identity)
    %RunRequest{params | meta: meta}
  end

  defp run_store_module do
    Application.get_env(:lemon_router, :run_store, RunStore)
  end

  defp persist_accepted_admission(run_id, identity, expected, retention_ms, attempts_left \\ 3) do
    expires_at_ms = System.system_time(:millisecond) + retention_ms
    replacement = compact_admission("accepted", identity)

    case Store.compare_and_swap(@run_admission_table, run_id, expected, replacement) do
      :ok ->
        {:ok, expires_at_ms}

      {:error, :mismatch} when attempts_left > 0 ->
        case existing_admission(run_id, identity) do
          {:ok, current, :existing} ->
            if MapHelpers.get_key(current, :state) == "accepted",
              do: {:ok, admission_expires_at_ms(current, retention_ms)},
              else:
                persist_accepted_admission(
                  run_id,
                  identity,
                  current,
                  retention_ms,
                  attempts_left - 1
                )

          error ->
            error
        end

      {:error, _reason} ->
        {:error, :admission_store_unavailable}

      _ ->
        {:error, :admission_store_unavailable}
    end
  rescue
    _ -> {:error, :admission_store_unavailable}
  catch
    _, _ -> {:error, :admission_store_unavailable}
  end

  defp cache_accepted_admission(state, run_id, identity, expires_at_ms) do
    put_in(state.accepted_run_ids[run_id], %{identity: identity, expires_at_ms: expires_at_ms})
  end

  defp prune_accepted_run_ids(state) do
    now_ms = System.system_time(:millisecond)

    accepted_run_ids =
      Enum.reduce(state.accepted_run_ids, %{}, fn
        {run_id, %{expires_at_ms: expires_at_ms} = entry}, acc when expires_at_ms > now_ms ->
          Map.put(acc, run_id, entry)

        _expired, acc ->
          acc
      end)

    %{state | accepted_run_ids: accepted_run_ids}
  end

  defp admission_expires_at_ms(admission, retention_ms) do
    case MapHelpers.get_key(admission, :expires_at_ms) do
      expires_at_ms when is_integer(expires_at_ms) ->
        expires_at_ms

      _ ->
        base_ms =
          MapHelpers.get_key(admission, :accepted_at_ms) ||
            MapHelpers.get_key(admission, :claimed_at_ms) || 0

        stored_retention_ms = MapHelpers.get_key(admission, :retention_ms)

        effective_retention_ms =
          if is_integer(stored_retention_ms), do: stored_retention_ms, else: retention_ms

        base_ms + effective_retention_ms
    end
  end

  defp compact_admission(state, identity) when state in ["submitting", "accepted"] do
    %{state: state, identity: identity}
  end

  defp request_identity(%RunRequest{} = params) do
    replay_identity = MapHelpers.get_key(params.meta || %{}, @replay_identity_meta_key)

    replay_content_identity =
      MapHelpers.get_key(params.meta || %{}, @replay_content_identity_meta_key)

    semantic_request =
      if is_binary(replay_identity) and replay_identity != "" do
        # Transport retries deliberately bind their stable delivery identity
        # to the user content and logical target, while excluding retry-local
        # material such as request IDs, temporary attachment paths and a
        # freshly-resolved allow-tools snapshot. Those values may change while
        # replaying the same delivery and are not a new user request.
        %{
          origin: params.origin,
          session_key: params.session_key,
          agent_id: params.agent_id,
          replay_identity: replay_identity,
          content: replay_content_identity || params.prompt,
          resume: params.resume
        }
      else
        # Direct callers have no independent delivery identity, so every
        # execution-changing field is part of admission identity. Only the
        # run ID and the derived identity itself are excluded.
        params
        |> Map.from_struct()
        |> Map.delete(:run_id)
        |> Map.update!(:meta, fn meta ->
          meta
          |> Map.delete(@request_identity_meta_key)
          |> Map.delete(Atom.to_string(@request_identity_meta_key))
        end)
      end

    semantic_request
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp dispatch_registered_abort(run_id, reason) do
    coordinator_result = session_coordinator_mod().abort_run(run_id, reason)

    run_result =
      case Registry.lookup(LemonRouter.RunRegistry, run_id) do
        [{pid, _} | _] when is_pid(pid) -> RunProcess.abort(pid, reason)
        _ -> :ok
      end

    if coordinator_result == :ok and run_result == :ok,
      do: :ok,
      else: {:error, :outcome_unknown}
  rescue
    _ -> {:error, :outcome_unknown}
  catch
    _, _ -> {:error, :outcome_unknown}
  end

  defp session_coordinator_mod do
    Application.get_env(:lemon_router, :session_coordinator, SessionCoordinator)
  end

  defp do_start_run_process(submission, coordinator_pid, conversation_key, state)
       when is_map(submission) do
    submission =
      submission
      |> enrich_submission_defaults(state)
      |> Submission.new!()

    RunStarter.start(submission, coordinator_pid, conversation_key)
  end

  defp ensure_run_id(%RunRequest{run_id: run_id} = request)
       when is_binary(run_id) and run_id != "",
       do: request

  defp ensure_run_id(%RunRequest{} = request) do
    %RunRequest{request | run_id: LemonCore.Id.run_id()}
  end

  defp reject_tombstoned_submission(%RunRequest{} = request, reason) do
    agent_id = request.agent_id || SessionKey.agent_id(request.session_key) || "default"

    Introspection.record(
      :orchestration_failed,
      %{reason: "run_aborted_before_submission"},
      run_id: request.run_id,
      session_key: request.session_key,
      agent_id: agent_id,
      engine: "lemon",
      provenance: :direct
    )

    emit_abort_tombstone_telemetry(:submission_rejected, reason)
    {:error, {:run_aborted, reason}}
  end

  defp fetch_abort_tombstone(run_id, state) do
    case Store.fetch(@abort_tombstone_table, run_id) do
      {:ok, nil} ->
        {:none, %{state | abort_tombstones: Map.delete(state.abort_tombstones, run_id)}}

      {:ok, tombstone} when is_map(tombstone) ->
        expires_at_ms = MapHelpers.get_key(tombstone, :expires_at_ms)

        reason_code =
          tombstone
          |> MapHelpers.get_key(:reason_code)
          |> then(fn stored -> stored || MapHelpers.get_key(tombstone, :reason) end)
          |> normalize_abort_reason()

        expired? =
          not is_integer(expires_at_ms) or
            expires_at_ms <= System.system_time(:millisecond)

        normalized =
          if expired?,
            do: %{state: "aborted", reason_code: :aborted},
            else: %{state: "aborted", reason_code: reason_code, expires_at_ms: expires_at_ms}

        if expired? do
          _ = Store.compare_and_swap(@abort_tombstone_table, run_id, tombstone, normalized)
        end

        next_state =
          if expired? do
            %{state | abort_tombstones: Map.delete(state.abort_tombstones, run_id)}
          else
            %{state | abort_tombstones: Map.put(state.abort_tombstones, run_id, normalized)}
          end

        {:active, %{reason: Map.fetch!(normalized, :reason_code)}, next_state}

      {:error, _reason} ->
        {:error, state}

      _unexpected ->
        {:error, state}
    end
  rescue
    _ -> {:error, state}
  catch
    _, _ -> {:error, state}
  end

  defp persist_abort_tombstone(run_id, tombstone) do
    case Store.put(@abort_tombstone_table, run_id, tombstone) do
      :ok -> :ok
      {:error, _reason} = error -> error
      _unexpected -> {:error, :store_unavailable}
    end
  rescue
    _ -> {:error, :store_unavailable}
  catch
    _, _ -> {:error, :store_unavailable}
  end

  defp maybe_cleanup_durable_receipts(state) do
    now_ms = System.system_time(:millisecond)

    if now_ms - state.last_receipt_cleanup_ms >= state.receipt_cleanup_interval_ms do
      cleanup_expired_rows(@run_admission_table, now_ms, fn entry ->
        state = MapHelpers.get_key(entry, :state)

        state == "claimed" and
          expired_at?(admission_expires_at_ms(entry, @run_admission_retention_ms), now_ms)
      end)

      %{
        state
        | last_receipt_cleanup_ms: now_ms,
          accepted_run_ids: prune_expired_cache(state.accepted_run_ids, now_ms),
          abort_tombstones: prune_expired_cache(state.abort_tombstones, now_ms)
      }
    else
      state
    end
  rescue
    _ -> %{state | last_receipt_cleanup_ms: System.system_time(:millisecond)}
  catch
    _, _ -> %{state | last_receipt_cleanup_ms: System.system_time(:millisecond)}
  end

  defp cleanup_expired_rows(table, now_ms, expired?) do
    table
    |> Store.list()
    |> Enum.each(fn
      {key, entry} when is_map(entry) ->
        if expired?.(entry), do: Store.compare_and_delete(table, key, entry)

      _invalid ->
        :ok
    end)

    now_ms
  end

  defp expired_at?(expires_at_ms, now_ms),
    do: is_integer(expires_at_ms) and expires_at_ms <= now_ms

  defp prune_expired_cache(cache, now_ms) do
    Map.reject(cache, fn {_key, entry} ->
      expired_at?(MapHelpers.get_key(entry, :expires_at_ms), now_ms)
    end)
  end

  defp emit_abort_tombstone_telemetry(event, reason) do
    LemonCore.Telemetry.emit(
      [:lemon, :router, :run_abort_tombstone, event],
      %{count: 1},
      %{reason: safe_error_label(reason)}
    )
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp normalize_abort_reason(reason)
       when reason in [
              :user_requested,
              :hard_stop,
              :goal_loop_hard_stop,
              :cron_aborted,
              :a2a_peer_canceled,
              :aborted
            ],
       do: reason

  defp normalize_abort_reason(_reason), do: :aborted

  defp normalize_run_process_opts(opts) when is_map(opts), do: opts
  defp normalize_run_process_opts(opts) when is_list(opts), do: Map.new(opts)
  defp normalize_run_process_opts(_), do: %{}

  defp enrich_submission_defaults(%Submission{} = submission, state) do
    submission
    |> Map.from_struct()
    |> enrich_submission_defaults(state)
  end

  defp enrich_submission_defaults(attrs, state) when is_map(attrs) do
    attrs
    |> put_default(:run_supervisor, state.run_supervisor)
    |> put_default(:run_process_module, state.run_process_module)
    |> put_default(:run_process_opts, state.run_process_opts)
  end

  defp put_default(attrs, key, value) do
    if is_nil(MapHelpers.get_key(attrs, key)) do
      Map.put(attrs, key, value)
    else
      attrs
    end
  end

  # Produce a safe, bounded label for introspection error payloads.
  defp safe_error_label(nil), do: nil
  defp safe_error_label(err) when is_atom(err), do: Atom.to_string(err)
  defp safe_error_label(err) when is_binary(err), do: String.slice(err, 0, 80)

  defp safe_error_label(%{__exception__: true} = err),
    do: err.__struct__ |> Module.split() |> Enum.join(".") |> String.slice(0, 80)

  defp safe_error_label({tag, _detail}) when is_atom(tag), do: Atom.to_string(tag)
  defp safe_error_label(_), do: "unknown_error"
end
