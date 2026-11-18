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

  alias LemonCore.{
    Introspection,
    LifecycleFenceStore,
    MapHelpers,
    RunRequest,
    RunStore,
    SessionKey,
    Store
  }

  alias LemonRouter.{
    PendingCompaction,
    RunProcess,
    RunStarter,
    SessionCoordinator,
    Submission,
    SubmissionBuilder
  }

  alias LemonRouter.RestartCarryover.CrashRecovery

  @abort_tombstone_ttl_ms 300_000
  @serialized_mutation_timeout_ms 20_000
  @run_admission_table :router_run_admissions
  @abort_tombstone_table :router_abort_tombstones
  @request_identity_meta_key :router_request_identity
  @replay_identity_meta_key :router_replay_identity
  @replay_content_identity_meta_key :router_replay_content_identity
  @run_admission_retention_ms 86_400_000
  @receipt_cleanup_interval_ms 60_000
  @lifecycle_retry_ms 1_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc false
  def admission_table, do: @run_admission_table

  @doc false
  def abort_tombstone_table, do: @abort_tombstone_table

  # This barrier only reads durable state. Never call coordinators from the
  # orchestrator: they may be waiting for a serialized start/admission.
  @doc false
  def presence_snapshot do
    GenServer.call(__MODULE__, :presence_snapshot, @serialized_mutation_timeout_ms)
  end

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

  @doc "Admit a fixed-ID fresh native execution from immutable local tool provenance."
  def submit_native_followup(source, %RunRequest{} = request) do
    submit_native_followup(__MODULE__, source, request)
  end

  def submit_native_followup(server, source, %RunRequest{} = request) do
    GenServer.call(
      server,
      {:native_followup, source, request, :local},
      @serialized_mutation_timeout_ms
    )
  end

  @doc false
  def submit_native_followup_from_node(source, %RunRequest{} = request, authenticated_session) do
    submit_native_followup_from_node(__MODULE__, source, request, authenticated_session)
  end

  @doc false
  def submit_native_followup_from_node(
        server,
        source,
        %RunRequest{} = request,
        authenticated_session
      ) do
    GenServer.call(
      server,
      {:native_followup, source, request, authenticated_session},
      @serialized_mutation_timeout_ms
    )
  end

  @doc "Seal immutable executing-host native startup policy before native execution begins."
  def register_native_source_floor(source, actual_policy) do
    LemonRouter.NativeLineage.register_source_floor(source, actual_policy, :local)
  end

  @doc false
  def register_native_resume(run_id, resume), do: CrashRecovery.bind_resume(run_id, resume)

  @doc false
  def recover_orphan(run_id, admission), do: recover_orphan(__MODULE__, run_id, admission)

  @doc false
  def recover_orphan(server, run_id, admission) do
    GenServer.call(server, {:recover_orphan, run_id, admission}, @serialized_mutation_timeout_ms)
  end

  @doc false
  def abandon_orphan(run_id, admission, :graceful_carryover) do
    GenServer.call(
      __MODULE__,
      {:recover_orphan, run_id, admission, :graceful_carryover},
      @serialized_mutation_timeout_ms
    )
  end

  @doc false
  def register_native_source_floor_from_node(source, actual_policy, authenticated_session) do
    LemonRouter.NativeLineage.register_source_floor(source, actual_policy, authenticated_session)
  end

  @doc "Submit once and return the owning queue's durable disposition."
  def submit_with_receipt(request), do: submit_with_receipt(__MODULE__, request)

  def submit_with_receipt(server, %RunRequest{} = request) do
    GenServer.call(server, {:submit_with_receipt, request}, @serialized_mutation_timeout_ms)
  end

  def submit_with_receipt(server, request) when is_map(request) or is_list(request) do
    submit_with_receipt(server, RunRequest.new(request))
  end

  @doc """
  Read a fixed-ID admission receipt without dispatching work.

  A run ID fenced by an abort tombstone before it crossed dispatch reports
  `state: :aborted`: it never executed and can never execute.
  """
  def run_receipt(run_id) when is_binary(run_id) and run_id != "" do
    case LemonRouter.RunReceiptStore.fetch(run_id) do
      {:ok, %{} = receipt} ->
        {:ok, receipt}

      {:ok, nil} ->
        # Read the permanent tombstone before the admission; see aborted_before_dispatch?/2.
        with {:ok, tombstone} <- Store.fetch(@abort_tombstone_table, run_id),
             {:ok, admission} <- Store.fetch(@run_admission_table, run_id) do
          cond do
            aborted_before_dispatch?(admission, tombstone) ->
              {:ok, unresolved_receipt(run_id, admission_session_key(admission), :aborted)}

            is_map(admission) ->
              {:ok, unresolved_receipt(run_id, nil, :outcome_unknown)}

            true ->
              {:error, :not_found}
          end
        else
          _ -> {:error, :unavailable}
        end

      _ ->
        {:error, :unavailable}
    end
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc """
  Whether an abort tombstone fenced a run ID before dispatch.

  Tombstones are permanent and refuse every later submission of their run ID,
  and dispatch first moves a claim to `submitting`. An admission still claimed
  (or absent) when read after its tombstone therefore never executed and never
  will. Callers must read the tombstone first or bracket both reads with an
  unchanged admission snapshot.
  """
  @spec aborted_before_dispatch?(map() | nil, map() | nil) :: boolean()
  def aborted_before_dispatch?(admission, tombstone) do
    is_map(tombstone) and
      (is_nil(admission) or
         (is_map(admission) and MapHelpers.get_key(admission, :state) in ["claimed", "rejected"]))
  end

  defp unresolved_receipt(run_id, session_key, state) do
    %{
      run_id: run_id,
      session_key: session_key,
      state: state,
      effective_mode: nil,
      target_run_id: nil
    }
  end

  defp admission_session_key(%{} = admission) do
    case MapHelpers.get_key(admission, :scope) do
      %{} = scope -> MapHelpers.get_key(scope, :session_key)
      _ -> nil
    end
  end

  defp admission_session_key(_admission), do: nil

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

  @doc false
  # Take the durable lifecycle fence for `session_key` for the calling process
  # (see `LemonRouter.with_session_lifecycle_fence/3`), tagged with
  # `acquisition_id`. The call is serialized with submissions, so every
  # admission that preceded it has already reached its coordinator. Waits past
  # the serialized admission window for the same reason as `register_abort/2`.
  @spec fence_session_lifecycle(GenServer.server(), binary(), :reset | :delete, String.t()) ::
          {:ok, String.t()} | {:error, :fenced | :unavailable}
  def fence_session_lifecycle(server \\ __MODULE__, session_key, operation, acquisition_id)
      when is_binary(session_key) and is_binary(acquisition_id) do
    GenServer.call(
      server,
      {:fence_session_lifecycle, session_key, self(), operation, acquisition_id},
      @serialized_mutation_timeout_ms
    )
  end

  @doc false
  # The caller gave up on `acquisition_id` (its acquire timed out). A fence that
  # acquisition took is released at once: no operation ran under it.
  @spec cancel_session_lifecycle(GenServer.server(), binary(), String.t()) :: :ok
  def cancel_session_lifecycle(server \\ __MODULE__, session_key, acquisition_id) do
    GenServer.cast(server, {:cancel_session_lifecycle, session_key, acquisition_id})
  end

  @doc false
  @spec release_session_lifecycle(GenServer.server(), binary(), String.t()) ::
          :ok | {:error, :unavailable}
  def release_session_lifecycle(server \\ __MODULE__, session_key, generation)
      when is_binary(session_key) and is_binary(generation) do
    GenServer.call(
      server,
      {:release_session_lifecycle, session_key, generation},
      @serialized_mutation_timeout_ms
    )
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
  `queued` is read from authoritative coordinator backlogs. Daily terminal counts
  are maintained by `LemonRouter.RunCountTracker`. Unavailable fields are nil.
  """
  @spec counts() :: %{
          active: non_neg_integer() | nil,
          queued: non_neg_integer() | nil,
          completed_today: non_neg_integer() | nil,
          failed_today: non_neg_integer() | nil
        }
  def counts do
    %{
      active:
        count_or_unavailable(fn ->
          %{active: n} = DynamicSupervisor.count_children(LemonRouter.RunSupervisor)
          n
        end),
      queued: count_or_unavailable(&LemonRouter.RunCountTracker.queued/0),
      completed_today: count_or_unavailable(&LemonRouter.RunCountTracker.completed_today/0),
      failed_today: count_or_unavailable(&LemonRouter.RunCountTracker.failed_today/0)
    }
  end

  defp count_or_unavailable(fun) do
    fun.()
  catch
    :exit, _reason -> nil
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
      lifecycle_watches: %{},
      restart_boot_id: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
      accepted_run_ids: %{}
    }

    {:ok, state, {:continue, :watch_lifecycle_fences}}
  end

  # Fences are durable rows, so admission refuses fenced sessions from the first
  # call after a restart. Reloading here only re-monitors their owners, so a
  # fence whose owner died (including in a previous VM) gets reconciled.
  @impl true
  def handle_continue(:watch_lifecycle_fences, state) do
    {:noreply, watch_lifecycle_fences(state)}
  end

  @impl true
  def handle_call(:presence_snapshot, _from, state) do
    result =
      with {:ok, admissions} <- Store.fetch_all(@run_admission_table),
           {:ok, receipts} <- LemonRouter.RunReceiptStore.fetch_all() do
        {:ok, %{admissions: Map.new(admissions), receipts: Map.new(receipts)}}
      else
        _ -> {:error, :query_failed}
      end

    {:reply, result, state}
  end

  def handle_call(:presence_barrier, _from, state), do: {:reply, :ok, state}

  def handle_call({:recover_orphan, run_id, admission}, _from, state) do
    {result, state} = recover_crashed_admission(run_id, admission, state)
    {:reply, result, state}
  end

  def handle_call({:recover_orphan, run_id, admission, reason}, _from, state) do
    {result, state} = recover_crashed_admission(run_id, admission, state, reason)
    {:reply, result, state}
  end

  def handle_call({:submit_with_receipt, %RunRequest{} = params}, from, state) do
    {:reply, result, next_state} = handle_call({:submit, params}, from, state)

    receipt_result =
      case result do
        {:ok, run_id} ->
          case run_receipt(run_id) do
            {:ok, %{state: :accepted} = receipt} -> {:ok, receipt}
            _ -> {:error, :outcome_unknown}
          end

        error ->
          error
      end

    {:reply, receipt_result, next_state}
  end

  def handle_call({:submit, %RunRequest{} = params}, _from, state) do
    state = maybe_cleanup_durable_receipts(state)
    params = ensure_run_id(params)

    {result, state} = submit_idempotently(params, state)

    {:reply, result, state}
  end

  def handle_call({:native_followup, captured, %RunRequest{} = request, transport}, _from, state) do
    result =
      with :ok <- RunRequest.validate_invocation_context_key(request.run_id),
           {:ok, source} <- LemonRouter.NativeLineage.authenticate(captured, transport) do
        identity =
          request_identity(%{
            request
            | meta: LemonRouter.NativeLineage.semantic_meta(request.meta || %{}, source.run_id)
          })

        native_followup_once(
          Map.put(source, :authenticated_transport, transport),
          request,
          identity,
          state
        )
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

  def handle_call(
        {:fence_session_lifecycle, session_key, owner, operation, acquisition_id},
        _from,
        state
      ) do
    case LifecycleFenceStore.acquire(session_key, owner, operation, acquisition_id) do
      {:ok, fence} ->
        {:reply, {:ok, fence.generation}, watch_fence(state, session_key, fence)}

      {:error, :held} ->
        {:reply, {:error, :fenced}, state}

      {:error, _unavailable_or_unknown} ->
        # An unknown write may have stored a held row for this owner: watch every
        # held row, so the owner's exit reconciles it.
        {:reply, {:error, :unavailable}, watch_lifecycle_fences(state)}
    end
  end

  def handle_call({:release_session_lifecycle, session_key, generation}, _from, state) do
    case LifecycleFenceStore.release(session_key, generation) do
      :ok -> {:reply, :ok, unwatch_fence(state, session_key, generation)}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:submit, _invalid}, _from, state) do
    {:reply, {:error, :invalid_run_request}, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _owner, reason}, state)
      when is_map_key(state.lifecycle_watches, ref) do
    {watch, watches} = Map.pop(state.lifecycle_watches, ref)

    # An unreachable node does not prove its owner dead: keep the fence.
    if reason == :noconnection,
      do: Process.send_after(self(), :watch_lifecycle_fences, @lifecycle_retry_ms),
      else: reconcile_lifecycle_fence(watch.session_key, watch.generation)

    {:noreply, %{state | lifecycle_watches: watches}}
  end

  def handle_info(:watch_lifecycle_fences, state) do
    {:noreply, watch_lifecycle_fences(state)}
  end

  def handle_info({:reconcile_lifecycle_fence, session_key, generation}, state) do
    reconcile_lifecycle_fence(session_key, generation)
    {:noreply, state}
  end

  def handle_info({:lifecycle_fence_reconciled, session_key, generation, :ok}, state) do
    case LifecycleFenceStore.release_reconciled(session_key, generation) do
      {:ok, :finished} ->
        :ok

      {:ok, :outcome_unknown} ->
        Logger.warning(
          "Session lifecycle owner exited holding the fence; the operation's outcome is " <>
            "unknown and the fence is released session_key=#{inspect(session_key)}"
        )

      {:error, _} ->
        retry_reconcile(session_key, generation)
    end

    {:noreply, state}
  end

  def handle_info({:lifecycle_fence_reconciled, session_key, generation, :error}, state) do
    retry_reconcile(session_key, generation)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_cast({:cancel_session_lifecycle, session_key, acquisition_id}, state) do
    case LifecycleFenceStore.fetch(session_key) do
      {:ok, %{state: "held", acquisition_id: ^acquisition_id, generation: generation}} ->
        case LifecycleFenceStore.release(session_key, generation) do
          :ok -> {:noreply, unwatch_fence(state, session_key, generation)}
          # Still watched: the owner's exit reconciles it.
          {:error, _} -> {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  defp watch_lifecycle_fences(state) do
    case LifecycleFenceStore.held() do
      {:ok, rows} ->
        Enum.reduce(rows, state, fn {session_key, fence}, acc ->
          watch_fence(acc, session_key, fence)
        end)

      {:error, _} ->
        Process.send_after(self(), :watch_lifecycle_fences, @lifecycle_retry_ms)
        state
    end
  end

  # Monitoring a pid from a previous VM, or one already dead, delivers DOWN at once.
  defp watch_fence(state, session_key, %{generation: generation} = fence) do
    watched? =
      Enum.any?(state.lifecycle_watches, fn {_ref, watch} ->
        watch.session_key == session_key and watch.generation == generation
      end)

    cond do
      watched? ->
        state

      is_pid(Map.get(fence, :owner_pid)) ->
        ref = Process.monitor(fence.owner_pid)
        watch = %{session_key: session_key, generation: generation}
        %{state | lifecycle_watches: Map.put(state.lifecycle_watches, ref, watch)}

      true ->
        reconcile_lifecycle_fence(session_key, generation)
        state
    end
  end

  defp unwatch_fence(state, session_key, generation) do
    {released, kept} =
      Map.split_with(state.lifecycle_watches, fn {_ref, watch} ->
        watch.session_key == session_key and watch.generation == generation
      end)

    Enum.each(released, fn {ref, _watch} -> Process.demonitor(ref, [:flush]) end)
    %{state | lifecycle_watches: kept}
  end

  # A dead owner's fence is released only once nothing it started can still
  # write. Every lifecycle write is a call to the Store or the run-history owner,
  # and the dead owner's last call was enqueued before its DOWN reached this
  # node; a later call answered by each owner is therefore ordered after it.
  # The barrier runs off the orchestrator so a stalled owner cannot block admission.
  defp reconcile_lifecycle_fence(session_key, generation) do
    orchestrator = self()

    started =
      LemonCore.TaskSupervisor.start_child(LemonRouter.LifecycleTaskSupervisor, fn ->
        result =
          with :ok <- Store.ping(),
               true <-
                 LemonCore.RunHistoryStore.fetch(session_key, limit: 1) !=
                   {:error, :unavailable} do
            :ok
          else
            _ -> :error
          end

        send(orchestrator, {:lifecycle_fence_reconciled, session_key, generation, result})
      end)

    case started do
      {:ok, _pid} -> :ok
      {:error, _not_started} -> retry_reconcile(session_key, generation)
    end
  end

  defp retry_reconcile(session_key, generation) do
    Process.send_after(
      self(),
      {:reconcile_lifecycle_fence, session_key, generation},
      @lifecycle_retry_ms
    )
  end

  defp do_submit(%RunRequest{} = params, orchestrator_state, mode \\ :new) do
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

    case build_unfenced_submission(request, orchestrator_state) do
      {:ok, %Submission{} = submission} ->
        LemonCore.EventBridge.subscribe_run(run_id)

        coordinator = session_coordinator_mod()

        submitted =
          if mode == :recovery,
            do: coordinator.submit_recovered(submission.conversation_key, submission),
            else: coordinator.submit(submission.conversation_key, submission)

        case submitted do
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

            case LemonRouter.AgentMessagingSessions.capture_admission(execution_request) do
              :ok -> {:ok, run_id}
              {:error, _} -> {:error, :outcome_unknown}
            end

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

          _malformed_acknowledgement ->
            # The callback may have enqueued work without returning its receipt.
            # Keep the submitting fence; this is not a retryable rejection.
            {:error, :outcome_unknown}
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

  defp recover_crashed_admission(run_id, expected, state, disposition \\ nil) do
    with {:ok, tombstone} <- Store.fetch(@abort_tombstone_table, run_id),
         {:ok, current} <- Store.fetch(@run_admission_table, run_id),
         {:ok, run} <- RunStore.fetch(run_id),
         {:ok, receipt} <- LemonRouter.RunReceiptStore.fetch(run_id) do
      cond do
        not is_map(current) or current != expected ->
          {{:ok, :skipped}, state}

        MapHelpers.get_key(current, :terminal) == true or terminal_summary?(run) ->
          with :ok <- LemonRouter.RunReceiptStore.retain_terminal_evidence(run_id),
               :ok <- CrashRecovery.settle(Store, run_id) do
            {{:ok, :skipped}, state}
          else
            _ -> {{:error, :outcome_unknown}, state}
          end

        recovery_live?(run_id, state) ->
          {{:ok, :skipped}, state}

        is_map(tombstone) ->
          abandon_crashed_admission(run_id, current, :aborted, state)

        disposition == :graceful_carryover ->
          abandon_crashed_admission(run_id, current, :graceful_carryover, state)

        is_map(receipt) and receipt[:target_run_id] not in [nil, run_id] ->
          abandon_crashed_admission(run_id, current, :joined_run, state)

        MapHelpers.get_key(current, :state) == "claimed" ->
          abandon_crashed_admission(run_id, current, :not_started, state)

        not CrashRecovery.enabled?() ->
          abandon_crashed_admission(run_id, current, :disabled, state)

        Map.get(current, :restart_attempt, 0) >= CrashRecovery.max_attempts() ->
          abandon_crashed_admission(run_id, current, :attempt_limit, state)

        current[:restart_boot_id] == state.restart_boot_id ->
          {{:ok, :skipped}, state}

        true ->
          resume_crashed_admission(run_id, current, state)
      end
    else
      _ -> {{:error, :outcome_unknown}, state}
    end
  end

  defp terminal_summary?(%{} = run), do: is_map(MapHelpers.get_key(run, :summary))
  defp terminal_summary?(_run), do: false

  defp recovery_live?(run_id, state) do
    Map.has_key?(state.accepted_run_ids, run_id) or
      Registry.lookup(LemonRouter.RunRegistry, run_id) != []
  end

  defp resume_crashed_admission(run_id, current, state) do
    attempt = Map.get(current, :restart_attempt, 0) + 1

    case CrashRecovery.continuation(run_id, attempt) do
      {:ok, request} ->
        dispatch_crash_continuation(request, current, attempt, state)

      {:error, :unavailable} ->
        {{:error, :outcome_unknown}, state}

      {:error, _reason} ->
        abandon_crashed_admission(run_id, current, :unresumable, state)
    end
  end

  defp dispatch_crash_continuation(request, current, attempt, state) do
    claimed =
      current
      |> Map.put(:restart_attempt, attempt)
      |> Map.put(:restart_boot_id, state.restart_boot_id)

    # This durable CAS consumes the attempt before any coordinator/executor I/O.
    # The original admission identity is retained: external replay is still an
    # acknowledgement, never permission to dispatch a continuation.
    with :ok <-
           Store.compare_and_swap(Store, @run_admission_table, request.run_id, current, claimed,
             durable: true
           ),
         :ok <- CrashRecovery.record(request.run_id, :resumed, :hard_crash, attempt) do
      identity = Map.fetch!(current, :identity)
      result = do_submit(attach_request_identity(request, identity), state, :recovery)

      case result do
        {:ok, run_id} ->
          expires = System.system_time(:millisecond) + state.run_admission_retention_ms
          {{:ok, :resumed}, cache_accepted_admission(state, run_id, identity, expires)}

        {:error, :outcome_unknown} ->
          {{:error, :outcome_unknown}, state}

        {:error, _reason} ->
          abandon_crashed_admission(request.run_id, claimed, :rejected, state)
      end
    else
      _ ->
        {{:error, :outcome_unknown}, state}
    end
  end

  defp abandon_crashed_admission(run_id, admission, reason, state) do
    scope = MapHelpers.get_key(admission, :scope) || %{}
    session_key = MapHelpers.get_key(scope, :session_key)
    attempts = Map.get(admission, :restart_attempt, 0)

    summary = %{
      run_id: run_id,
      session_key: session_key,
      engine: "lemon",
      duration_ms: nil,
      meta: %{router_request_identity: Map.get(admission, :identity)},
      completed: %{
        run_id: run_id,
        session_key: session_key,
        engine: "lemon",
        ok: false,
        answer: "",
        error: if(reason in [:aborted, :not_started], do: reason, else: :outcome_unknown),
        interrupted: true,
        outcome: if(reason == :not_started, do: :not_started, else: :unknown)
      }
    }

    case RunStore.finalize(run_id, summary) do
      :ok ->
        with :ok <- LemonRouter.RunReceiptStore.retain_terminal_evidence(run_id),
             :ok <- CrashRecovery.record(run_id, :abandoned, reason, attempts) do
          {{:ok, :abandoned}, state}
        else
          _ -> {{:error, :outcome_unknown}, state}
        end

      {:error, {:already_finalized, ^run_id}} ->
        {{:ok, :skipped}, state}

      _ ->
        {{:error, :outcome_unknown}, state}
    end
  end

  # Every admission mode passes here before reading session state, so a reset or
  # delete in flight can neither race nor feed stale history, chat state or policy.
  # The fence is a durable row: an orchestrator restart cannot reopen admission.
  defp build_unfenced_submission(%{session_key: session_key} = request, state)
       when is_binary(session_key) do
    with :ok <- LifecycleFenceStore.check_admission(session_key) do
      build_native_submission(request, state)
    end
  end

  defp build_unfenced_submission(request, state), do: build_native_submission(request, state)

  defp build_native_submission(request, state) do
    with {:ok, submission} <- SubmissionBuilder.build(request, state),
         {:ok, submission} <- LemonRouter.NativeLineage.capture_submission(submission),
         :ok <- CrashRecovery.capture(submission) do
      {:ok, submission}
    end
  end

  defp native_followup_once(source, request, identity, state) do
    case Store.fetch(@run_admission_table, request.run_id) do
      {:ok, nil} ->
        reserve_native_followup(source, request, identity, state)

      {:ok, %{identity: ^identity, native_followup: %{status: :accepted}}} ->
        {:ok, request.run_id}

      {:ok, %{identity: ^identity, native_followup: %{status: status}}}
      when status in [:denied, :admission_unavailable, :aborted, :rejected] ->
        {:error, status}

      {:ok, %{identity: ^identity, native_failure: status}} ->
        {:error, status}

      {:ok, %{identity: ^identity}} ->
        {:error, :outcome_unknown}

      {:ok, %{}} ->
        {:error, :run_id_conflict}

      _ ->
        {:error, :outcome_unknown}
    end
  end

  defp reserve_native_followup(source, request, identity, state) do
    case LemonRouter.NativeLineage.prepare_request(source, request) do
      {:ok, prepared, destination} ->
        case LemonRouter.NativeLineage.reserve(source, prepared, identity, destination) do
          {:ok, entry, :new} ->
            issue_native_followup(source, prepared, identity, entry, destination, state)

          {:ok, _, :existing} ->
            {:error, :outcome_unknown}

          {:error, :admission_unavailable} ->
            reject_native_preparation(request, identity, :admission_unavailable)

          error ->
            error
        end

      {:error, reason} ->
        reject_native_preparation(request, identity, reason)
    end
  end

  defp reject_native_preparation(request, identity, reason) do
    entry = %{
      state: "native_rejected",
      identity: identity,
      native_failure: reason,
      terminal: true,
      scope: %{profile_id: nil, agent_id: request.agent_id, session_key: request.session_key}
    }

    case Store.put_new(Store, @run_admission_table, request.run_id, entry, durable: true) do
      :ok -> {:error, reason}
      _ -> {:error, :outcome_unknown}
    end
  end

  defp issue_native_followup(source, request, identity, entry, destination, state) do
    result =
      try do
        with :ok <- native_abort_preflight(request.run_id, state),
             :ok <- LemonRouter.NativeLineage.current_source(source),
             :ok <- LemonRouter.NativeLineage.current_target(request, destination),
             {:ok, admitted} <- LemonRouter.NativeLineage.admit(source, request, entry),
             :ok <- LemonRouter.NativeLineage.current_source(source),
             :ok <- LemonRouter.NativeLineage.current_target(admitted, destination),
             :ok <- LemonRouter.NativeLineage.record_outcome(request.run_id, :dispatch_pending),
             {:ok, run_id} <- submit_native_followup_request(admitted, identity, state),
             {:ok, current} <- Store.fetch(@run_admission_table, run_id),
             {:ok, _} <-
               persist_accepted_admission(
                 run_id,
                 identity,
                 current,
                 state.run_admission_retention_ms
               ) do
          {:ok, run_id}
        end
      rescue
        _ -> {:error, :outcome_unknown}
      catch
        _, _ -> {:error, :outcome_unknown}
      end

    status =
      case result do
        {:ok, _} -> :accepted
        {:error, :denied} -> :denied
        {:error, :admission_unavailable} -> :admission_unavailable
        {:error, :aborted} -> :aborted
        {:error, {:rejected, _reason}} -> :rejected
        _ -> :outcome_unknown
      end

    case LemonRouter.NativeLineage.record_outcome(request.run_id, status) do
      :ok ->
        with {:error, {:rejected, reason}} <- result, do: {:error, reason}

      _ ->
        {:error, :outcome_unknown}
    end
  end

  # do_submit refuses definitively (lifecycle fence, invalid request,
  # coordinator rejection) before anything is enqueued: that follow-up never
  # executed, so its record is a terminal rejection rather than unknown.
  defp submit_native_followup_request(request, identity, state) do
    case do_submit(attach_request_identity(request, identity), state) do
      {:ok, run_id} -> {:ok, run_id}
      {:error, :outcome_unknown} -> {:error, :outcome_unknown}
      {:error, reason} -> {:error, {:rejected, reason}}
    end
  end

  defp native_abort_preflight(run_id, state) do
    case fetch_abort_tombstone(run_id, state) do
      {:none, _} -> :ok
      {:active, _, _} -> {:error, :aborted}
      _ -> {:error, :outcome_unknown}
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
      retention_ms: retention_ms,
      scope: admission_scope(params)
    }

    case Store.put_new(Store, @run_admission_table, params.run_id, entry, durable: true) do
      :ok -> {:ok, entry, :new}
      {:error, :exists} -> existing_admission(params.run_id, identity)
      {:error, :outcome_unknown} -> {:error, :outcome_unknown}
      {:error, _reason} -> {:error, :admission_store_unavailable}
      _ -> {:error, :admission_store_unavailable}
    end
  catch
    :exit, _ -> {:error, :admission_store_unavailable}
  end

  defp existing_admission(run_id, identity) do
    case Store.fetch(@run_admission_table, run_id) do
      {:ok, %{} = entry} ->
        if MapHelpers.get_key(entry, :identity) == identity do
          case compact_existing_admission(run_id, entry, identity) do
            {:ok, compacted} -> {:ok, compacted, :existing}
            {:error, _reason} -> {:error, :admission_store_unavailable}
          end
        else
          {:error, :run_id_conflict}
        end

      {:ok, nil} ->
        {:error, :admission_store_unavailable}

      {:error, _reason} ->
        {:error, :admission_store_unavailable}

      _unexpected ->
        {:error, :admission_store_unavailable}
    end
  catch
    :exit, _ -> {:error, :admission_store_unavailable}
  end

  defp continue_admission(params, identity, admission, ownership, state) do
    case MapHelpers.get_key(admission, :state) do
      "accepted" ->
        continue_accepted_admission(params, identity, admission, state)

      _pending_or_legacy ->
        continue_pending_admission(params, identity, admission, ownership, state)
    end
  end

  defp continue_accepted_admission(params, identity, _admission, state) do
    case Store.confirm_durable() do
      :ok ->
        cache_until_ms = System.system_time(:millisecond) + state.run_admission_retention_ms

        {{:ok, params.run_id},
         cache_accepted_admission(state, params.run_id, identity, cache_until_ms)}

      _ ->
        {{:error, :outcome_unknown}, state}
    end
  end

  # A durable terminal run is evidence that an earlier owner crossed the
  # external enqueue boundary only when the terminal summary carries this exact
  # request identity. A bare run ID cannot acknowledge a different session or
  # payload, and an unavailable read cannot prove that no terminal run exists.
  defp continue_pending_admission(params, identity, admission, ownership, state) do
    admission_state = MapHelpers.get_key(admission, :state)

    case admission_status(params, identity) do
      :matching_terminal ->
        accept_terminal_replay(params.run_id, identity, admission, state)

      :not_terminal
      when ownership == :new or
             (ownership == :existing and admission_state in ["claimed", "rejected"]) ->
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

  defp admission_status(params, identity) do
    case LemonRouter.RunReceiptStore.fetch(params.run_id) do
      {:ok, %{session_key: session_key, state: :accepted, request_identity: ^identity}}
      when session_key == params.session_key ->
        :matching_terminal

      {:ok, %{request_identity: ^identity, state: :outcome_unknown}} ->
        :terminal_outcome_unknown

      {:ok, %{request_identity: receipt_identity}}
      when is_binary(receipt_identity) and receipt_identity != identity ->
        :conflicting_terminal

      {:ok, %{}} ->
        case terminal_run_status(params, identity) do
          :not_terminal -> :terminal_outcome_unknown
          status -> status
        end

      {:ok, nil} ->
        terminal_run_status(params, identity)

      _ ->
        :terminal_outcome_unknown
    end
  catch
    :exit, _ -> :terminal_outcome_unknown
  end

  defp submit_new_admission(params, identity, admission, state) do
    case fetch_abort_tombstone(params.run_id, state) do
      {:active, %{reason: reason}, state} ->
        {reject_tombstoned_submission(params, reason), state}

      {:none, state} ->
        dispatch_new_admission(params, identity, admission, state)

      {:error, state} ->
        {{:error, :outcome_unknown}, state}
    end
  end

  defp dispatch_new_admission(params, identity, admission, state) do
    # Preserve only content-free attribution alongside the permanent replay
    # fence, including when dispatch's outcome cannot be established.
    submitting = compact_admission("submitting", identity, reopen_rejected(admission))

    case Store.compare_and_swap(
           Store,
           @run_admission_table,
           params.run_id,
           admission,
           submitting,
           durable: true
         ) do
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

          {:error, reason} = error ->
            # A synchronous start rejection may already have persisted terminal
            # evidence. Never erase that evidence or reopen its fixed-ID fence.
            # Otherwise, only an unchanged pre-enqueue claim records the definite
            # rejection: terminal, never executed, so it proves nothing is running
            # while still allowing the same request to be resubmitted.
            case Store.compare_and_swap(
                   Store,
                   @run_admission_table,
                   params.run_id,
                   submitting,
                   rejected_admission(admission, reason),
                   durable: true
                 ) do
              :ok ->
                if CrashRecovery.enabled?(), do: CrashRecovery.settle(Store, params.run_id)
                {error, state}

              {:error, :mismatch} ->
                case terminal_run_status(params, identity) do
                  :matching_terminal ->
                    {error, state}

                  _ ->
                    {{:error, :outcome_unknown}, state}
                end

              _failure ->
                {{:error, :outcome_unknown}, state}
            end
        end

      _failure ->
        {{:error, :outcome_unknown}, state}
    end
  catch
    :exit, _ -> {{:error, :outcome_unknown}, state}
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
  catch
    :exit, _ -> :terminal_outcome_unknown
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
    replacement = compact_admission("accepted", identity, expected)

    case Store.compare_and_swap(Store, @run_admission_table, run_id, expected, replacement,
           durable: true
         ) do
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
  catch
    :exit, _ -> {:error, :admission_store_unavailable}
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

  defp compact_admission(state, identity, entry) when state in ["submitting", "accepted"] do
    %{state: state, identity: identity}
    |> Map.merge(
      Map.take(entry, [
        :scope,
        :terminal,
        :native_source,
        :native_followup,
        :native_root_binding,
        :restart_attempt,
        :restart_boot_id,
        :native_failure
      ])
    )
  end

  # A definite pre-dispatch rejection (lifecycle fence, unknown agent, invalid
  # request, coordinator refusal) keeps the claim's identity and expiry but is
  # terminal: presence never counts it as unresolved work.
  defp rejected_admission(admission, reason) do
    admission
    |> reopen_rejected()
    |> Map.merge(%{state: "rejected", terminal: true, rejection: safe_error_label(reason)})
  end

  # Resubmitting the same request reopens its rejected claim.
  defp reopen_rejected(admission) do
    if MapHelpers.get_key(admission, :state) == "rejected",
      do: admission |> Map.drop([:terminal, :rejection]) |> Map.put(:state, "claimed"),
      else: admission
  end

  defp admission_scope(%RunRequest{} = params) do
    agent_id = params.agent_id || SessionKey.agent_id(params.session_key) || "default"

    %{
      session_key: params.session_key,
      agent_id: agent_id,
      profile_id: MapHelpers.get_key(params.meta || %{}, :profile_id)
    }
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
    ArgumentError -> {:error, :outcome_unknown}
  catch
    :exit, _ -> {:error, :outcome_unknown}
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

    with :ok <- LemonRouter.NativeLineage.validate_activation(submission.execution_request) do
      RunStarter.start(submission, coordinator_pid, conversation_key)
    end
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
          _ =
            Store.compare_and_swap(Store, @abort_tombstone_table, run_id, tombstone, normalized,
              durable: true
            )
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
  catch
    :exit, _ -> {:error, state}
  end

  defp persist_abort_tombstone(run_id, tombstone) do
    case Store.put(Store, @abort_tombstone_table, run_id, tombstone, durable: true) do
      :ok -> :ok
      {:error, _reason} = error -> error
      _unexpected -> {:error, :store_unavailable}
    end
  catch
    :exit, _ -> {:error, :store_unavailable}
  end

  defp maybe_cleanup_durable_receipts(state) do
    now_ms = System.system_time(:millisecond)

    if now_ms - state.last_receipt_cleanup_ms >= state.receipt_cleanup_interval_ms do
      compact_durable_admissions(now_ms)
      compact_abort_tombstones(now_ms)

      %{
        state
        | last_receipt_cleanup_ms: now_ms,
          accepted_run_ids: prune_expired_cache(state.accepted_run_ids, now_ms),
          abort_tombstones: prune_expired_cache(state.abort_tombstones, now_ms)
      }
    else
      state
    end
  catch
    :exit, _ -> %{state | last_receipt_cleanup_ms: System.system_time(:millisecond)}
  end

  defp compact_existing_admission(run_id, entry, identity) do
    case MapHelpers.get_key(entry, :state) do
      state when state in ["accepted", "submitting"] ->
        compacted = compact_admission(state, identity, entry)

        if entry == compacted do
          {:ok, entry}
        else
          case Store.compare_and_swap(Store, @run_admission_table, run_id, entry, compacted,
                 durable: true
               ) do
            :ok -> {:ok, compacted}
            {:error, :mismatch} -> {:error, :concurrent_change}
            {:error, reason} -> {:error, reason}
            _unexpected -> {:error, :store_unavailable}
          end
        end

      _state ->
        {:ok, entry}
    end
  end

  defp compact_durable_admissions(now_ms) do
    @run_admission_table
    |> Store.list()
    |> Enum.each(fn
      {run_id, entry} when is_map(entry) ->
        case MapHelpers.get_key(entry, :state) do
          claim when claim in ["claimed", "rejected"] ->
            if expired_at?(
                 admission_expires_at_ms(entry, @run_admission_retention_ms),
                 now_ms
               ) do
              _ =
                Store.compare_and_delete(Store, @run_admission_table, run_id, entry,
                  durable: true
                )
            end

          state when state in ["accepted", "submitting"] ->
            identity = MapHelpers.get_key(entry, :identity)
            compacted = compact_admission(state, identity, entry)

            if entry != compacted,
              do:
                Store.compare_and_swap(Store, @run_admission_table, run_id, entry, compacted,
                  durable: true
                )

          _state ->
            :ok
        end

      _invalid ->
        :ok
    end)
  end

  defp compact_abort_tombstones(now_ms) do
    @abort_tombstone_table
    |> Store.list()
    |> Enum.each(fn
      {run_id, tombstone} when is_map(tombstone) ->
        expires_at_ms = MapHelpers.get_key(tombstone, :expires_at_ms)

        reason_code =
          tombstone
          |> MapHelpers.get_key(:reason_code)
          |> then(fn stored -> stored || MapHelpers.get_key(tombstone, :reason) end)
          |> normalize_abort_reason()

        compacted =
          if expired_at?(expires_at_ms, now_ms),
            do: %{state: "aborted", reason_code: :aborted},
            else: %{state: "aborted", reason_code: reason_code, expires_at_ms: expires_at_ms}

        if tombstone != compacted do
          _ =
            Store.compare_and_swap(Store, @abort_tombstone_table, run_id, tombstone, compacted,
              durable: true
            )
        end

      _invalid ->
        :ok
    end)
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
