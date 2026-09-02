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

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc false
  def admission_table, do: @run_admission_table

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
      abort_tombstones: %{},
      accepted_run_ids: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:submit, %RunRequest{} = params}, _from, state) do
    state = prune_abort_tombstones(state)
    params = ensure_run_id(params)

    {result, state} =
      case Map.get(state.abort_tombstones, params.run_id) do
        %{reason: reason} ->
          {reject_tombstoned_submission(params, reason), state}

        nil ->
          submit_idempotently(params, state)
      end

    {:reply, result, state}
  end

  def handle_call({:register_abort, run_id, reason}, _from, state) do
    state = prune_abort_tombstones(state)

    tombstone = %{
      reason: reason,
      inserted_at_ms: System.monotonic_time(:millisecond)
    }

    emit_abort_tombstone_telemetry(:registered, reason)

    result = dispatch_registered_abort(run_id, reason)
    state = %{state | abort_tombstones: Map.put(state.abort_tombstones, run_id, tombstone)}

    {:reply, result, state}
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

        case SessionCoordinator.submit(submission.conversation_key, submission) do
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
    identity = request_identity(params)

    case Map.get(state.accepted_run_ids, params.run_id) do
      %{identity: ^identity} ->
        {{:ok, params.run_id}, state}

      %{} ->
        {{:error, :run_id_conflict}, state}

      nil ->
        case claim_admission(params, identity) do
          {:ok, admission} -> continue_admission(params, identity, admission, state)
          {:error, :run_id_conflict} -> {{:error, :run_id_conflict}, state}
          {:error, _reason} -> {{:error, :outcome_unknown}, state}
        end
    end
  end

  defp claim_admission(params, identity) do
    entry = %{
      run_id: params.run_id,
      session_key: params.session_key,
      identity: identity,
      state: "pending",
      claimed_at_ms: System.system_time(:millisecond)
    }

    case Store.put_new(@run_admission_table, params.run_id, entry) do
      :ok -> {:ok, entry}
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
    case Store.get(@run_admission_table, run_id) do
      %{} = entry ->
        if MapHelpers.get_key(entry, :identity) == identity,
          do: {:ok, entry},
          else: {:error, :run_id_conflict}

      _ ->
        {:error, :admission_store_unavailable}
    end
  rescue
    _ -> {:error, :admission_store_unavailable}
  catch
    _, _ -> {:error, :admission_store_unavailable}
  end

  defp continue_admission(params, identity, admission, state) do
    case MapHelpers.get_key(admission, :state) do
      "accepted" ->
        {{:ok, params.run_id}, cache_accepted_admission(state, params.run_id, identity)}

      _pending_or_legacy ->
        continue_pending_admission(params, identity, admission, state)
    end
  end

  # A durable terminal run is authoritative evidence that an earlier owner
  # crossed the external enqueue boundary, even if it crashed before changing
  # the admission receipt from pending to accepted. Re-enqueuing at that point
  # would duplicate a completed run after all in-memory coordinator state has
  # disappeared.
  defp continue_pending_admission(params, identity, admission, state) do
    if terminal_run?(params.run_id) do
      case persist_accepted_admission(params.run_id, identity, admission) do
        :ok ->
          {{:ok, params.run_id}, cache_accepted_admission(state, params.run_id, identity)}

        {:error, _reason} ->
          {{:error, :outcome_unknown}, state}
      end
    else
      case do_submit(params, state) do
        {:ok, run_id} ->
          case persist_accepted_admission(run_id, identity, admission) do
            :ok ->
              {{:ok, run_id}, cache_accepted_admission(state, run_id, identity)}

            {:error, _reason} ->
              {{:error, :outcome_unknown}, state}
          end

        error ->
          {error, state}
      end
    end
  end

  defp terminal_run?(run_id) do
    case RunStore.get(run_id) do
      %{summary: summary} when not is_nil(summary) -> true
      %{"summary" => summary} when not is_nil(summary) -> true
      _ -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp persist_accepted_admission(run_id, identity, expected, attempts_left \\ 3) do
    replacement =
      expected
      |> Map.put(:state, "accepted")
      |> Map.put(:accepted_at_ms, System.system_time(:millisecond))

    case Store.compare_and_swap(@run_admission_table, run_id, expected, replacement) do
      :ok ->
        :ok

      {:error, :mismatch} when attempts_left > 0 ->
        case existing_admission(run_id, identity) do
          {:ok, current} ->
            if MapHelpers.get_key(current, :state) == "accepted",
              do: :ok,
              else: persist_accepted_admission(run_id, identity, current, attempts_left - 1)

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

  defp cache_accepted_admission(state, run_id, identity) do
    put_in(state.accepted_run_ids[run_id], %{identity: identity})
  end

  defp request_identity(%RunRequest{} = params) do
    params
    |> Map.from_struct()
    |> Map.delete(:run_id)
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

  defp prune_abort_tombstones(state) do
    cutoff = System.monotonic_time(:millisecond) - @abort_tombstone_ttl_ms

    tombstones =
      Enum.reduce(state.abort_tombstones, %{}, fn
        {run_id, %{inserted_at_ms: inserted_at_ms} = tombstone}, acc
        when is_integer(inserted_at_ms) and inserted_at_ms >= cutoff ->
          Map.put(acc, run_id, tombstone)

        _expired, acc ->
          acc
      end)

    %{state | abort_tombstones: tombstones}
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
