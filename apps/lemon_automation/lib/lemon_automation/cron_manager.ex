defmodule LemonAutomation.CronManager do
  @moduledoc """
  GenServer that manages cron job scheduling and execution.

  The CronManager is responsible for:

  - Loading jobs from persistent storage on startup
  - Computing next run times for all jobs
  - Arming one timer for the earliest enabled job
  - Executing due jobs via LemonRouter
  - Tracking run history

  Durable startup restoration runs in a monitored supervised worker. The manager
  answers OTP status and cached `pause_status/0` during slow restoration, while
  ordinary calls and events queue until the worker finishes. This prevents a
  partial inventory or a stale restoration result from overwriting mutations.
  Failed restoration retains its dispatch hold and retries with bounded backoff.

  ## Tick Behavior

  The earliest next-run timer drives dispatch. A five-minute safety sweep
  recovers orphaned runs and wall-clock changes. Job mutations re-arm the timer.
  Tests may inject a module implementing `now_ms/0` via the `:clock` start option,
  including for startup schedule restoration.
  Each dispatch:

  1. Computes which jobs are due
  2. Applies jitter if configured
  3. Submits runs to LemonRouter
  4. Updates next run times
  5. Emits events for monitoring

  Prompt jobs use `cwd` as the native coding session's repository. Each run
  owns a fixed router ID before submission. Once its submission has started
  (`meta.submission_started`), wait timeouts, worker death, and ambiguous
  submissions or aborts retain active ownership with
  `meta.outcome_unknown: true`; ticks and restart reconcile the durable router
  result rather than scheduling another editor. A claim whose submission never
  started (a restart or worker crash before submit) is released as a retryable
  failure with a `claim_released` audit. Only confirmed terminal failures are
  retryable. Pausing prevents future scheduled runs; aborting cancels the exact
  owned router run and does not repeat an ambiguous abort.

  Scheduled retries use `LemonCore.Retry.Policy` for their shared retry budget
  and fixed, jitter-free delay. Durable lineage, claims and timers remain here.

  ## API

      # List all jobs
      CronManager.list()

      # Add a new job
      CronManager.add(%{name: "Daily", schedule: "0 9 * * *", ...})

      # Update a job
      CronManager.update("cron_abc", %{enabled: false})

      # Remove a job
      CronManager.remove("cron_abc")

      # Trigger immediate run
      CronManager.run_now("cron_abc")

      # Abort an active cron run
      CronManager.abort_run("run_abc")

      # Get run history
      CronManager.runs("cron_abc", limit: 10)

      # Accept the current global default model for an unpinned job
      CronManager.refresh_captured_model("cron_abc")

      # Pause or resume every job; the pause is durable across restarts
      CronManager.pause_all()
      CronManager.resume_all()
      CronManager.pause_status()

  ## Global Pause

  `pause_all/0` holds back every cron job at once, across all profiles:
  scheduled slots are not claimed, persisted retries wait, and `wake/2` is
  refused. The marker is stored durably (`CronStore.global_pause/0`), so a daemon
  restart keeps the pause and leaves stored schedules untouched. It is separate
  from each job's own `enabled` flag, which neither switch changes. Runs already
  in flight finish normally and an explicit `run_now/1` still works.

  `resume_all/0` never catches up. Every slot and retry that fell inside the
  pause is skipped and audited (expired one-shot jobs retire), and each job
  continues at its next scheduled time. An unreadable marker blocks dispatch.
  Startup restoration failures also hold dispatch independently of the marker;
  `pause_status/0` exposes this as `restoration_pending`. Manual runs remain
  available, and resume may clear the marker before restoration completes.

  ## Job Quality Features

  - **Monitor mode** (`monitor: true`) - completed runs whose normalized output
    is unchanged are suppressed instead of forwarded (see
    `LemonAutomation.CronMonitor`).
  - **Job chaining** (`context_from: "cron_other"`) - the source job's latest
    completed output is prepended to this job's prompt (see
    `LemonAutomation.CronContext`).
  - **Model pin / drift guard** (`model:`, `captured_default_model:`) - unpinned
    jobs fail closed when the global default model changes underneath them
    until the operator pins a model or calls `refresh_captured_model/1`.
  - **Pre-dispatch preflight** - target, session, router, and provider
    readiness are checked before any submitter runs (see
    `LemonAutomation.CronPreflight`).
  - **Delivery** (`deliver_to:`) - finished results go to the originating
    chat, an explicit target, or the paired owner chat; `"none"` opts out (see
    `LemonAutomation.CronDelivery`).
  - **One-shot jobs** (`once: true`) - disabled when the scheduled run is
    claimed, deleted once that run has finished.
  - **Heartbeats** (`meta.heartbeat: true`) - `HEARTBEAT_OK` results are
    suppressed instead of delivered (see `LemonAutomation.Heartbeat`).
  """

  use GenServer

  @impl true
  def format_status(status) do
    LemonCore.StatusRedaction.gen_server(status, [
      :restoration_pending,
      :standalone_mode,
      :state_vsn
    ])
  end

  @vsn 3

  alias LemonAutomation.{
    CronAuthority,
    CronCommandRunner,
    CronDelivery,
    CronJob,
    CronMonitor,
    CronPreflight,
    CronRun,
    CronSchedule,
    CronStore,
    Events,
    Heartbeat,
    RunSubmitter
  }

  alias LemonCore.{Bus, Event, RunStore, SessionKey}
  alias LemonCore.Config.Modular, as: Config
  alias LemonCore.Events, as: CoreEvents

  require Logger

  @tick_interval_ms 60_000
  @call_timeout_ms 10_000
  # Ceiling for every timer armed from job data (schedule recheck, retry tick);
  # a later timer simply re-arms, so no job value can reach send_after's limit.
  @max_job_timer_ms 300_000
  @not_submitted_error "cron run was never submitted"
  # Margin past a job's jitter window before an untracked, unsubmitted claim
  # counts as orphaned (its submit message can no longer be pending).
  @orphan_claim_grace_ms 5_000
  @task_supervisor LemonAutomation.TaskSupervisor
  @forwarded_summary_max_bytes 12_000

  @typedoc "Durable pause plus the manager's independent startup restoration hold."
  @type pause_status :: %{
          paused: boolean(),
          paused_at_ms: non_neg_integer() | nil,
          restoration_pending: boolean()
        }

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Start the CronManager GenServer.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  List all cron jobs.
  """
  @spec list() :: [CronJob.t()]
  def list do
    GenServer.call(__MODULE__, :list, @call_timeout_ms)
  end

  @doc """
  Add a new cron job.

  ## Required Parameters

  - `:name` - Human-readable job name
  - `:schedule` - Cron expression
  - `:agent_id` - Target agent ID
  - `:session_key` - Session key for routing
  - `:prompt` - The prompt to send

  ## Optional Parameters

  - `:enabled` - Whether job is active (default: true)
  - `:timezone` - `"UTC"` (default), `"local"` (server clock), or an available IANA name
  - `:jitter_sec` - Random delay spread (default: 0)
  - `:timeout_ms` - Execution timeout (default: 300000)
  - `:deliver_to` - `nil` (default target), `"none"`, or `"telegram:<id>[:<thread>]"`
    / `"discord:<id>[:<thread>]"`
  - `:once` - One-shot job (default: false)
  - `:meta` - Additional metadata (`heartbeat: true` marks a heartbeat)
  - `:authority` - Launcher authority of a prompt job created from an agent
    session (`LemonAutomation.CronAuthority.from_session/2`); immutable after
    creation except through `update_from_session/3`
  """
  @spec add(map()) :: {:ok, CronJob.t()} | {:error, term()}
  def add(params) do
    GenServer.call(__MODULE__, {:add, params}, @call_timeout_ms)
  end

  @doc """
  Add a cron job only when its explicit stable ID is unused.

  This is the collision-safe creation primitive for confirmed automation
  blueprints. It validates through the same path as `add/1`, claims durable
  storage before updating scheduler state, and never overwrites an existing
  job. Callers must supply a non-empty `id`.
  """
  @spec add_new(map()) :: {:ok, CronJob.t()} | {:error, term()}
  def add_new(params) do
    GenServer.call(__MODULE__, {:add_new, params}, @call_timeout_ms)
  end

  @doc """
  Update an existing cron job. `:authority` cannot be patched.
  """
  @spec update(binary(), map()) ::
          {:ok, CronJob.t()}
          | {:error, :not_found | :store_unavailable | :outcome_unknown}
          | {:error, {:immutable_fields, [atom()]}}
  def update(job_id, params) do
    GenServer.call(__MODULE__, {:update, job_id, params}, @call_timeout_ms)
  end

  @doc """
  Update a prompt job on behalf of the agent session principal
  `session_opts[:session_key]`. Only a job that principal owns
  (`CronAuthority.owned_by?/2`) is reachable; any other job, including every
  operator and command job, is `{:error, :not_found}`. The job's launcher
  authority is atomically intersected with the session's effective tool policy
  (`:tool_policy`, `:execution_context`), so the job never runs with more
  authority than the session that rewrote it.
  """
  @spec update_from_session(binary(), map(), keyword()) :: {:ok, CronJob.t()} | {:error, term()}
  def update_from_session(job_id, params, session_opts) when is_list(session_opts) do
    GenServer.call(
      __MODULE__,
      {:update_from_session, job_id, params, session_opts},
      @call_timeout_ms
    )
  end

  @doc "Update only the exact job revision inspected by an operator."
  def update(job_id, params, expected_revision) do
    GenServer.call(__MODULE__, {:update, job_id, params, expected_revision}, @call_timeout_ms)
  end

  @doc "Opaque revision for a job or run; never exposes its private content."
  def control_revision(record) do
    record
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc """
  Re-capture the current global default model for an unpinned agent job.

  This is the operator's "accept the new default" escape hatch when the model
  drift guard has started skipping a job's runs.
  """
  @spec refresh_captured_model(binary()) ::
          {:ok, CronJob.t()} | {:error, :not_found | :store_unavailable | :outcome_unknown}
  def refresh_captured_model(job_id) do
    GenServer.call(__MODULE__, {:refresh_captured_model, job_id}, @call_timeout_ms)
  end

  @doc """
  Remove a cron job.
  """
  @spec remove(binary()) :: :ok | {:error, :not_found | :store_unavailable | :outcome_unknown}
  def remove(job_id) do
    GenServer.call(__MODULE__, {:remove, job_id}, @call_timeout_ms)
  end

  @doc "Remove only the exact job revision inspected by an operator."
  @spec remove(binary(), binary()) ::
          :ok | {:error, :not_found | :stale | :store_unavailable | :outcome_unknown}
  def remove(job_id, expected_revision) do
    GenServer.call(__MODULE__, {:remove, job_id, expected_revision}, @call_timeout_ms)
  end

  @doc """
  Trigger a job to run immediately.
  """
  @spec run_now(binary()) ::
          {:ok, CronRun.t()} | {:error, :not_found | :outcome_unknown | :store_unavailable}
  def run_now(job_id) do
    GenServer.call(__MODULE__, {:run_now, job_id}, @call_timeout_ms)
  end

  @doc "Run only the exact job revision inspected by an operator."
  def run_now(job_id, expected_revision) do
    GenServer.call(__MODULE__, {:run_now, job_id, expected_revision}, @call_timeout_ms)
  end

  @doc """
  Trigger a job immediately under the caller's fixed cron run ID.

  The caller allocates `run_id` before the call, so a reply lost to a timeout
  still names the run to reconcile with `cron.runs`. The ID is claimed with
  `CronStore.claim_run/1`: an ID that already exists is `{:error, :exists}` and
  never overwrites the earlier run.
  """
  @spec run_now_with_id(binary(), binary()) ::
          {:ok, CronRun.t()}
          | {:error, :not_found | :exists | :outcome_unknown | :store_unavailable}
  def run_now_with_id(job_id, run_id) when is_binary(run_id) and run_id != "" do
    GenServer.call(__MODULE__, {:run_now_with_id, job_id, run_id}, @call_timeout_ms)
  end

  @doc """
  Trigger a job on behalf of the agent session principal
  `session_opts[:session_key]`. Only a job that principal owns is reachable
  (others are `{:error, :not_found}`), and the run also executes within the
  triggering session's effective tool policy (`:tool_policy`,
  `:execution_context`), recorded as the run's `meta.trigger_policy`.
  """
  @spec run_now_from_session(binary(), keyword()) ::
          {:ok, CronRun.t()} | {:error, :not_found | :outcome_unknown | :store_unavailable}
  def run_now_from_session(job_id, session_opts) when is_list(session_opts) do
    GenServer.call(__MODULE__, {:run_now_from_session, job_id, session_opts}, @call_timeout_ms)
  end

  @doc false
  def wake(job_id, opts \\ []) do
    GenServer.call(__MODULE__, {:wake, job_id, opts}, @call_timeout_ms)
  end

  @doc """
  Abort an active cron run by cron run ID.
  """
  @spec abort_run(binary()) ::
          {:ok, CronRun.t()}
          | {:error, :not_found | :not_active | :outcome_unknown | :store_unavailable}
  def abort_run(run_id) do
    GenServer.call(__MODULE__, {:abort_run, run_id}, @call_timeout_ms)
  end

  @doc "Abort only the exact invocation revision inspected by an operator."
  def abort_run(run_id, expected_revision) do
    GenServer.call(__MODULE__, {:abort_run, run_id, expected_revision}, @call_timeout_ms)
  end

  @doc """
  Pause every cron job until `resume_all/0`.

  The pause is durable and idempotent: pausing again keeps the original
  `paused_at_ms`.
  """
  @spec pause_all() :: {:ok, pause_status()} | {:error, :store_unavailable}
  def pause_all do
    GenServer.call(__MODULE__, :pause_all, @call_timeout_ms)
  end

  @doc """
  Lift the global pause, skipping every run missed while it was in effect.

  Returns how many jobs lost a missed slot and how many pending retries were
  dropped. Resuming a scheduler that is not paused is a no-op.
  """
  @spec resume_all() ::
          {:ok,
           %{
             resumed: boolean(),
             skipped_job_count: non_neg_integer(),
             skipped_retry_count: non_neg_integer()
           }}
          | {:error, :store_unavailable}
  def resume_all do
    GenServer.call(__MODULE__, :resume_all, @call_timeout_ms)
  end

  @doc """
  Report the durable global pause and the manager-owned startup restoration hold.
  """
  @spec pause_status() :: {:ok, pause_status()} | {:error, :store_unavailable}
  def pause_status do
    GenServer.call(__MODULE__, :pause_status, @call_timeout_ms)
  end

  @doc """
  Get run history for a job.

  ## Options

  - `:limit` - Maximum number of runs (default: 100)
  - `:status` - Filter by status
  - `:since_ms` - Filter by start time
  - `:strict` - Return `{:ok, runs}` or a store error, never false empty history
  """
  @spec runs(binary(), keyword()) :: [CronRun.t()] | {:ok, [CronRun.t()]} | {:error, term()}
  def runs(job_id, opts \\ []) do
    GenServer.call(__MODULE__, {:runs, job_id, opts}, @call_timeout_ms)
  end

  @doc """
  Recent runs of up to 100 jobs in one call (`CronStore.list_runs_for/2`):
  `{:ok, %{job_id => runs}}` or a store error, never false empty history.
  `:limit` applies per job.
  """
  @spec runs_for([binary()], keyword()) ::
          {:ok, %{binary() => [CronRun.t()]}} | {:error, term()}
  def runs_for(job_ids, opts \\ []) when is_list(job_ids) and length(job_ids) <= 100 do
    GenServer.call(__MODULE__, {:runs_for, job_ids, opts}, @call_timeout_ms)
  end

  @doc """
  Force a tick cycle (mainly for testing).
  """
  @spec tick() :: :ok
  def tick do
    GenServer.cast(__MODULE__, :tick)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    clock = Keyword.get(opts, :clock, LemonCore.Clock)

    state = %{
      jobs: %{},
      tasks: %{},
      task_refs: %{},
      retry_timer: nil,
      schedule_timer: nil,
      clock: clock,
      restoration_pending: true,
      restoration_backoff_ms: 250,
      restoration_timer: nil,
      restoration_task: nil,
      restoration_token: nil,
      restoration_initial: true,
      restoration_pause: nil,
      restoration_deferred: :queue.new(),
      catch_up_slots: %{},
      last_cleanup_at_ms: clock.now_ms(),
      run_retention_per_job: 100,
      audit_retention_max: CronStore.audit_retention_max(),
      task_supervisor:
        Keyword.get(
          opts,
          :task_supervisor,
          Application.get_env(:lemon_automation, :cron_task_supervisor, @task_supervisor)
        ),
      standalone_mode:
        Keyword.get(
          opts,
          :standalone_mode,
          Application.get_env(:lemon_automation, :cron_standalone_mode, false)
        ),
      state_vsn: @vsn
    }

    {:ok, state, {:continue, :restore_startup}}
  end

  @impl true
  def handle_continue(:restore_startup, state) do
    schedule_tick()
    {:noreply, start_restoration(state)}
  end

  def handle_continue(:drain_restoration, state) do
    case :queue.out(state.restoration_deferred) do
      {:empty, _queue} ->
        {:noreply, state}

      {{:value, message}, queue} ->
        state = %{state | restoration_deferred: queue}

        result =
          case message do
            {:call, message, from} ->
              case handle_call(message, from, state) do
                {:reply, reply, state} ->
                  GenServer.reply(from, reply)
                  {:noreply, state}

                result ->
                  result
              end

            {:cast, message} ->
              handle_cast(message, state)

            {:info, message} ->
              handle_info(message, state)
          end

        case result do
          {:noreply, %{restoration_task: nil} = state} -> restoration_replay(state)
          result -> result
        end
    end
  end

  @impl true
  def code_change(old_vsn, state, _extra) do
    {:ok, migrate_state(old_vsn, state)}
  end

  @impl true
  def handle_call(
        :pause_status,
        _from,
        %{restoration_task: task, restoration_initial: initial?} = state
      )
      when initial? or not is_nil(task) do
    result =
      case state.restoration_pause do
        {:ok, marker} -> {:ok, pause_status(marker, state)}
        _ -> {:error, :store_unavailable}
      end

    {:reply, result, state}
  end

  def handle_call(
        message,
        from,
        %{restoration_task: task, restoration_initial: initial?} = state
      )
      when initial? or not is_nil(task) do
    {:noreply, defer_restoration(state, {:call, message, from})}
  end

  @impl true
  def handle_call(:list, _from, state) do
    jobs = Map.values(state.jobs) |> Enum.sort_by(& &1.created_at_ms, :desc)
    {:reply, jobs, state}
  end

  @impl true
  def handle_call({:add, params}, _from, state) do
    case validate_params(params) do
      {:ok, params} ->
        job = params |> CronJob.new() |> capture_default_model()
        next_run = next_run(job, state)
        job = CronJob.set_next_run(job, next_run)

        case CronStore.put_job(job) do
          :ok ->
            CronStore.record_audit(:job_created, %{
              job_id: job.id,
              source: :cron_manager,
              status: if(job.enabled, do: :enabled, else: :disabled)
            })

            Events.emit_job_created(job)

            # Names may originate in untrusted portable manifests. Keep routine
            # lifecycle logs identifier-only; operators can inspect authorized
            # structured job state when they need the display name.
            Logger.info("[CronManager] Added job: #{job.id}")
            {:reply, {:ok, job}, schedule_next_run(put_in(state.jobs[job.id], job))}

          {:error, _} = error ->
            {:reply, {:error, store_error(error)}, state}
        end

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:add_new, params}, _from, state) do
    id = params[:id] || params["id"]

    cond do
      not is_binary(id) or String.trim(id) == "" ->
        {:reply, {:error, {:missing_keys, [:id]}}, state}

      Map.has_key?(state.jobs, id) ->
        {:reply, {:error, :already_exists}, state}

      true ->
        case validate_params(params) do
          {:ok, params} ->
            job = params |> CronJob.new() |> capture_default_model()
            next_run = next_run(job, state)
            job = CronJob.set_next_run(job, next_run)

            case CronStore.claim_job(job) do
              :ok ->
                CronStore.record_audit(:job_created, %{
                  job_id: job.id,
                  source: :automation_blueprint,
                  status: if(job.enabled, do: :enabled, else: :disabled)
                })

                Events.emit_job_created(job)
                Logger.info("[CronManager] Added claimed job: #{job.id}")
                {:reply, {:ok, job}, schedule_next_run(put_in(state.jobs[job.id], job))}

              {:error, :exists} ->
                {:reply, {:error, :already_exists}, state}

              {:error, _} = error ->
                {:reply, error, state}
            end

          {:error, _} = error ->
            {:reply, error, state}
        end
    end
  end

  def handle_call({:update, job_id, params, expected}, from, state) do
    case Map.fetch(state.jobs, job_id) do
      {:ok, job} ->
        if expected == control_revision(job) do
          handle_call({:update, job_id, params}, from, state)
        else
          {:reply, {:error, :stale}, state}
        end

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:update, job_id, params}, _from, state),
    do: update_job(job_id, params, nil, state)

  def handle_call({:update_from_session, job_id, params, session_opts}, _from, state),
    do: update_job(job_id, params, session_opts, state)

  @impl true
  def handle_call({:refresh_captured_model, job_id}, _from, state) do
    case Map.fetch(state.jobs, job_id) do
      {:ok, job} ->
        updated = capture_default_model(job)

        case CronStore.put_job(updated) do
          :ok ->
            CronStore.record_audit(:model_recaptured, %{
              job_id: updated.id,
              source: :cron_manager,
              reason:
                "captured_default_model refreshed to #{updated.captured_default_model || "(unset)"}"
            })

            Events.emit_job_updated(updated)

            Logger.info("[CronManager] Refreshed captured default model for job: #{job_id}")
            {:reply, {:ok, updated}, put_in(state.jobs[job_id], updated)}

          {:error, _} = error ->
            {:reply, {:error, store_error(error)}, state}
        end

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:remove, job_id}, _from, state) do
    case Map.fetch(state.jobs, job_id) do
      {:ok, job} ->
        case delete_job(state, job) do
          {:ok, state} ->
            Logger.info("[CronManager] Removed job: #{job_id}")
            {:reply, :ok, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:remove, job_id, expected}, from, state) do
    case Map.fetch(state.jobs, job_id) do
      {:ok, job} ->
        if expected == control_revision(job) do
          handle_call({:remove, job_id}, from, state)
        else
          {:reply, {:error, :stale}, state}
        end

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:run_now, job_id, expected}, from, state) do
    case Map.fetch(state.jobs, job_id) do
      {:ok, job} ->
        if expected == control_revision(job) do
          handle_call({:run_now, job_id}, from, state)
        else
          {:reply, {:error, :stale}, state}
        end

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:run_now, job_id}, _from, state) do
    case Map.fetch(state.jobs, job_id) do
      {:ok, job} -> run_now_job(job, [], state)
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:run_now_with_id, job_id, run_id}, _from, state) do
    case Map.fetch(state.jobs, job_id) do
      {:ok, job} -> run_now_job(job, [run_id: run_id], state)
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:run_now_from_session, job_id, session_opts}, _from, state) do
    with {:ok, job} <- Map.fetch(state.jobs, job_id),
         true <- CronAuthority.owned_by?(job.authority, Keyword.get(session_opts, :session_key)) do
      run_now_job(job, [trigger_policy: CronAuthority.trigger_policy(session_opts)], state)
    else
      _ -> {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:wake, job_id, opts}, _from, state) do
    case CronStore.get_job(job_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %CronJob{enabled: false} ->
        {:reply, {:error, :job_disabled}, state}

      job ->
        cond do
          dispatch_held?(state) ->
            {:reply, {:error, :cron_paused}, state}

          unknown_run_locked?(job) or
              (Keyword.get(opts, :skip_if_running, false) and job_active_run_locked?(job)) ->
            {:reply, {:error, :already_running}, state}

          true ->
            state = put_in(state.jobs[job.id], job)
            reply_execute(execute_job(job, :wake, opts, state))
        end
    end
  end

  @impl true
  def handle_call({:claim_submission, cron_id, router_id, session_key}, _from, state) do
    case CronStore.get_run(cron_id) do
      %CronRun{status: :running, run_id: ^router_id} = run ->
        cond do
          meta_value(run.meta, :abort_requested) ->
            {:reply, {:error, :aborted}, state}

          run.triggered_by in [:schedule, :retry] and
            meta_value(run.meta, :submission_started) != true and dispatch_held?(state) ->
            {:reply, {:error, :aborted}, state}

          true ->
            meta =
              (run.meta || %{})
              |> Map.put(:submission_started, true)
              |> Map.put(:router_session_key, session_key)

            result = CronStore.put_run(%{run | meta: meta})
            {:reply, result, state}
        end

      _ ->
        {:reply, {:error, :not_active}, state}
    end
  end

  def handle_call({:abort_run, run_id, expected}, from, state) do
    case CronStore.get_run(run_id) do
      %CronRun{} = run ->
        if expected == control_revision(run) do
          handle_call({:abort_run, run_id}, from, state)
        else
          {:reply, {:error, :stale}, state}
        end

      _ ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:abort_run, run_id}, _from, state) do
    case CronStore.get_run(run_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %CronRun{} = run ->
        if CronRun.active?(run) do
          if meta_value(run.meta, :abort_requested) do
            {:reply, {:error, :outcome_unknown}, state}
          else
            run = %{run | meta: Map.put(run.meta || %{}, :abort_requested, true)}

            with {:persisted, :ok} <- {:persisted, CronStore.put_run(run)},
                 :ok <- abort_unsubmitted_or_router(run) do
              {aborted, state} =
                terminalize_run(state, run, {:aborted, "Run aborted by operator"},
                  audit_action: :run_aborted
                )

              # A terminal write that failed is not reported as an abort. The
              # persisted `abort_requested` lets recovery finish the run later.
              reply =
                if CronRun.finished?(aborted),
                  do: {:ok, aborted},
                  else: {:error, :outcome_unknown}

              {:reply, reply, stop_tracked_task(state, run.id)}
            else
              {:persisted, {:error, _} = error} ->
                {:reply, {:error, store_error(error)}, state}

              _ ->
                {_run, state} = retain_unknown_run(state, run, :abort_outcome_unknown)
                {:reply, {:error, :outcome_unknown}, stop_tracked_task(state, run.id)}
            end
          end
        else
          {:reply, {:error, :not_active}, state}
        end
    end
  end

  @impl true
  def handle_call(:pause_status, _from, state) do
    {:reply, read_pause_status(state), state}
  end

  @impl true
  def handle_call(:pause_all, _from, state) do
    now = LemonCore.Clock.now_ms()

    case CronStore.put_global_pause(now) do
      :ok ->
        case invalidate_paused_claims(state) do
          {:ok, state} ->
            CronStore.record_audit(:all_jobs_paused, %{source: :cron_manager, status: :paused})
            Logger.info("[CronManager] All cron jobs paused")
            {:reply, {:ok, pause_status(%{paused_at_ms: now}, state)}, state}

          {:error, state} ->
            {:reply, {:error, :store_unavailable}, state}
        end

      {:error, :exists} ->
        case invalidate_paused_claims(state) do
          {:ok, state} -> {:reply, read_pause_status(state), state}
          {:error, state} -> {:reply, {:error, :store_unavailable}, state}
        end

      {:error, _} ->
        {:reply, {:error, :store_unavailable}, state}
    end
  end

  @impl true
  def handle_call(:resume_all, _from, state) do
    case CronStore.global_pause() do
      {:ok, nil} ->
        {:reply, {:ok, %{resumed: false, skipped_job_count: 0, skipped_retry_count: 0}}, state}

      {:ok, %{paused_at_ms: paused_at_ms}} ->
        now = LemonCore.Clock.now_ms()
        # A paused restart may have loaded an empty inventory during a read
        # failure. Reload it strictly for both slot skipping and retry eligibility.
        # Keep the marker until every durable skip is confirmed; partial failures
        # only repeat idempotent mutations on the next resume attempt.
        with {:ok, jobs} <- CronStore.list_jobs_result(),
             state = %{state | jobs: Map.new(jobs, &{&1.id, &1})},
             {:ok, state} <- invalidate_paused_claims(state),
             {:ok, state, skipped_jobs} <- skip_paused_slots(state, now) do
          finish_resume(state, paused_at_ms, now, skipped_jobs)
        else
          {:error, failed_state} when is_map(failed_state) ->
            {:reply, {:error, :store_unavailable}, failed_state}

          {:error, :store_unavailable} ->
            {:reply, {:error, :store_unavailable}, state}
        end

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:runs, job_id, opts}, _from, state) do
    runs = CronStore.list_runs(job_id, opts)
    {:reply, runs, state}
  end

  def handle_call({:runs_for, job_ids, opts}, _from, state) do
    {:reply, CronStore.list_runs_for(job_ids, opts), state}
  end

  @impl true
  def handle_cast(message, %{restoration_task: task, restoration_initial: initial?} = state)
      when initial? or not is_nil(task) do
    {:noreply, defer_restoration(state, {:cast, message})}
  end

  @impl true
  def handle_cast(:tick, state) do
    state = do_tick(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:restoration_pause, token, result}, %{restoration_token: token} = state) do
    {:noreply, %{state | restoration_pause: result}}
  end

  def handle_info({ref, result}, %{restoration_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    finish_restoration(state, result)
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{restoration_task: %Task{ref: ref}} = state
      ) do
    finish_restoration(state, {:failed, nil})
  end

  def handle_info(message, %{restoration_task: %Task{}} = state) do
    {:noreply, defer_restoration(state, {:info, message})}
  end

  def handle_info(message, %{restoration_initial: true} = state)
      when message != :restore_schedules do
    {:noreply, defer_restoration(state, {:info, message})}
  end

  def handle_info(:restore_schedules, %{restoration_pending: true} = state) do
    if state.restoration_timer, do: Process.cancel_timer(state.restoration_timer)
    {:noreply, start_restoration(%{state | restoration_timer: nil})}
  end

  @impl true
  def handle_info({:scheduled_tick, token}, %{schedule_timer: {_timer, token}} = state) do
    {:noreply, do_tick(%{state | schedule_timer: nil})}
  end

  def handle_info({:scheduled_tick, _stale_token}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    state = do_tick(state)
    schedule_tick()
    {:noreply, state}
  end

  @impl true
  def handle_info({:execute_job, job_id, triggered_by}, state) do
    state =
      case Map.get(state.jobs, job_id) do
        %CronJob{enabled: true} = job ->
          if triggered_by == :schedule do
            run_scheduled_job(job, state, LemonCore.Clock.now_ms())
          else
            job |> execute_job(triggered_by, [], state) |> elem(2)
          end

        _ ->
          Logger.debug(
            "[CronManager] Skipping jittered execute_job for #{inspect(job_id)}: not found or disabled"
          )

          state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({:submit_claimed_run, job_id, run_id}, state) do
    state =
      with %CronJob{} = job <- Map.get(state.jobs, job_id),
           %CronRun{status: :running} = run <- CronStore.get_run(run_id) do
        cond do
          run.triggered_by in [:schedule, :retry] and dispatch_held?(state) ->
            {_run, state} =
              terminalize_run(state, run, {:aborted, "Cron paused before submission"}, [])

            state

          job.enabled or (job.once and run.triggered_by == :schedule) ->
            submit_claimed_run(job, run, state)

          true ->
            {_run, state} =
              terminalize_run(state, run, {:aborted, "Job paused before submission"}, [])

            state
        end
      else
        %CronRun{} = run ->
          Logger.debug(
            "[CronManager] Skipping claimed cron run submit for #{run.id}: status=#{inspect(run.status)}"
          )

          state

        _ ->
          Logger.debug(
            "[CronManager] Skipping claimed cron run submit for #{inspect(run_id)}: job or run unavailable"
          )

          state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info(:retry_tick, state) do
    state = %{state | retry_timer: nil}
    state = state |> dispatch_due_retries() |> schedule_retry_tick()
    {:noreply, state}
  end

  @impl true
  def handle_info({:run_complete, run_id, result}, state) do
    {_run, state} = terminalize_run_id(state, run_id, result)
    {:noreply, stop_tracked_task(state, run_id)}
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.get(state.task_refs, ref) do
      nil ->
        {:noreply, state}

      run_id ->
        Process.demonitor(ref, [:flush])
        state = remove_tracked_task(state, run_id, ref)
        {_run, state} = terminalize_run_id(state, run_id, result)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.get(state.task_refs, ref) do
      nil ->
        {:noreply, state}

      run_id ->
        state = remove_tracked_task(state, run_id, ref)

        {_run, state} =
          terminalize_run_id(
            state,
            run_id,
            {:worker_down, :worker_exited},
            audit_action: :worker_down
          )

        {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if task = Map.get(state, :restoration_task), do: Process.exit(task.pid, :kill)
    :ok
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  # A five-minute safety sweep recovers orphaned runs and wall-clock jumps;
  # normal dispatch is driven by the earliest persisted next-run instant.
  defp schedule_tick do
    Process.send_after(self(), :tick, 300_000)
  end

  defp schedule_next_run(state, held? \\ nil) do
    if timer = Map.get(state, :schedule_timer), do: Process.cancel_timer(elem(timer, 0))
    now = clock_now(state)
    held? = if is_nil(held?), do: dispatch_held?(state), else: held?

    next =
      if held? do
        nil
      else
        state.jobs
        |> Map.values()
        |> Enum.filter(&(&1.enabled and is_integer(&1.next_run_at_ms)))
        |> Enum.map(& &1.next_run_at_ms)
        |> Enum.min(fn -> nil end)
      end

    timer =
      if next do
        token = make_ref()
        # Bound rechecks after a failed claim; never busy-loop on an overdue slot.
        delay = min(max(next - now, 100), @max_job_timer_ms)
        {Process.send_after(self(), {:scheduled_tick, token}, delay), token}
      end

    Map.put(state, :schedule_timer, timer)
  end

  defp clock_now(state) do
    clock = Map.get(state, :clock, LemonCore.Clock)
    clock.now_ms()
  end

  defp next_run(job, state) do
    CronSchedule.next_run_ms(job.schedule, job.timezone,
      from: DateTime.from_unix!(clock_now(state), :millisecond)
    )
  end

  defp abort_router_run(%CronRun{run_id: router_run_id})
       when is_binary(router_run_id) and router_run_id != "" do
    router = Application.get_env(:lemon_automation, :cron_router_mod, LemonRouter)
    router.abort_run(router_run_id, :cron_aborted)
  rescue
    _ -> {:error, :outcome_unknown}
  catch
    _, _ -> {:error, :outcome_unknown}
  end

  defp abort_router_run(_run), do: :ok

  # `abort_requested` is already persisted, so `claim_submission` refuses this
  # run: a run that never started submission is definitely not at the router.
  defp abort_unsubmitted_or_router(%CronRun{} = run) do
    if submission_started?(run), do: abort_router_run(run), else: :ok
  end

  defp submission_started?(%CronRun{meta: meta}),
    do: meta_value(meta || %{}, :submission_started) == true

  defp start_restoration(state) do
    manager = self()
    token = make_ref()
    initial? = state.restoration_initial
    clock = Map.get(state, :clock, LemonCore.Clock)

    work = fn ->
      try do
        restore_startup_schedules(manager, token, initial?, clock)
      rescue
        _ -> {:failed, nil}
      catch
        _, _ -> {:failed, nil}
      end
    end

    case start_monitored_task(work, state) do
      {:ok, task} ->
        %{state | restoration_task: task, restoration_token: token, restoration_pause: nil}

      {:error, _} ->
        schedule_restoration(state)
    end
  end

  defp restore_startup_schedules(manager, token, initial?, clock) do
    config = Config.load().automation
    marker = CronStore.global_pause()
    send(manager, {:restoration_pause, token, marker})

    result =
      with {:ok, marker} <- marker,
           {:ok, jobs} <- CronStore.list_jobs_result(),
           {:ok, jobs, slots} <-
             restore_schedules(
               jobs,
               clock.now_ms(),
               config.catch_up_missed,
               marker != nil
             ),
           {:ok, active_runs} <- CronStore.active_runs_result(),
           {:ok, retries} <- CronStore.pending_retries_result() do
        {:ok, jobs, slots, recovery_results(active_runs), retries, marker != nil}
      end

    fallback = if initial? and match?({:error, _}, result), do: CronStore.list_jobs()
    {result, fallback, config.run_retention_per_job}
  end

  defp finish_restoration(state, {result, fallback, retention}) do
    initial? = state.restoration_initial

    state = %{
      state
      | restoration_task: nil,
        restoration_token: nil,
        restoration_initial: false,
        run_retention_per_job: retention
    }

    state =
      case result do
        {:ok, jobs, slots, active_runs, retries, paused?} ->
          %{
            state
            | jobs: Map.new(jobs, &{&1.id, &1}),
              catch_up_slots: slots,
              restoration_pending: false,
              restoration_backoff_ms: 250
          }
          |> recover_stale_active_runs(LemonCore.Clock.now_ms(), active_runs, initial?)
          |> schedule_restored_retries(retries, paused?)
          |> schedule_next_run(paused?)

        {:error, _} ->
          state =
            if is_list(fallback),
              do: %{state | jobs: Map.new(fallback, &{&1.id, &1})},
              else: state

          schedule_restoration(state)
      end

    restoration_replay(state)
  end

  defp finish_restoration(state, {:failed, _reason}) do
    state = %{state | restoration_task: nil, restoration_token: nil}
    restoration_replay(schedule_restoration(state))
  end

  defp schedule_restored_retries(%{retry_timer: nil} = state, retries, paused?) do
    schedule_retry_tick(state, retries, paused?)
  end

  defp schedule_restored_retries(state, _retries, _paused?), do: state

  defp defer_restoration(state, message) do
    %{state | restoration_deferred: :queue.in(message, state.restoration_deferred)}
  end

  defp restoration_replay(%{restoration_initial: true} = state), do: {:noreply, state}

  defp restoration_replay(state) do
    if :queue.is_empty(state.restoration_deferred),
      do: {:noreply, state},
      else: {:noreply, state, {:continue, :drain_restoration}}
  end

  defp schedule_restoration(%{restoration_pending: true, restoration_timer: nil} = state) do
    timer = Process.send_after(self(), :restore_schedules, state.restoration_backoff_ms)

    %{
      state
      | restoration_timer: timer,
        restoration_backoff_ms: min(state.restoration_backoff_ms * 2, 5_000)
    }
  end

  defp schedule_restoration(state), do: state

  defp dispatch_held?(state), do: Map.get(state, :restoration_pending, false) or paused?()

  defp restore_schedules(jobs, now, catch_up, paused) do
    Enum.reduce_while(jobs, {:ok, [], %{}}, fn job, {:ok, jobs, slots} ->
      result = if paused, do: {:keep, job, false}, else: restore_schedule(job, now, catch_up)

      case result do
        {:keep, job, true} ->
          {:cont, {:ok, [job | jobs], Map.put(slots, job.id, job.next_run_at_ms)}}

        {:keep, job, false} ->
          {:cont, {:ok, [job | jobs], slots}}

        :retired ->
          {:cont, {:ok, jobs, slots}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp restore_schedule(%CronJob{enabled: false} = job, _now, _catch_up),
    do: {:keep, job, false}

  defp restore_schedule(%CronJob{next_run_at_ms: due} = job, now, catch_up)
       when is_integer(due) and due < now do
    following =
      CronSchedule.next_run_ms(job.schedule, job.timezone,
        from: DateTime.from_unix!(due, :millisecond)
      )

    # Sparse schedules (for example leap day) may have no following slot within
    # the scheduler's 366-day search horizon; their grace is already at the cap.
    period = if is_integer(following), do: following - due, else: 14_400_000
    grace = period |> div(2) |> max(120_000) |> min(7_200_000)

    if catch_up and now - due <= grace do
      {:keep, job, true}
    else
      skip_missed_slot(job, if(catch_up, do: :outside_grace, else: :catch_up_disabled))
    end
  end

  defp restore_schedule(%CronJob{next_run_at_ms: due} = job, _now, _catch_up)
       when is_integer(due),
       do: {:keep, job, false}

  defp restore_schedule(job, _now, _catch_up), do: reanchor_schedule(job)

  defp reanchor_schedule(job) do
    next_run = CronSchedule.next_run_ms(job.schedule, job.timezone)
    job = CronJob.set_next_run(job, next_run)

    case CronStore.put_job(job) do
      :ok -> {:keep, job, false}
      {:error, _} = error -> error
    end
  end

  # Audit a slot that will never run and move the job on to its next occurrence.
  # One-shot jobs have no next occurrence and retire instead.
  defp skip_missed_slot(%CronJob{} = job, reason) do
    result =
      if job.once do
        with :ok <- CronStore.delete_monitor_state(job.id),
             :ok <- CronStore.delete_preflight_notice_state(job.id),
             :ok <- CronStore.delete_job(job.id) do
          :retired
        end
      else
        reanchor_schedule(job)
      end

    unless match?({:error, _}, result) do
      Logger.info("[CronManager] Skipping missed slot for #{job.id}")

      CronStore.record_audit(:missed_slot_skipped, %{
        job_id: job.id,
        source: :cron_manager,
        triggered_by: :schedule,
        reason: reason
      })
    end

    result
  end

  # Resume: jobs whose slot fell inside the pause are re-anchored without
  # running; slots still in the future, and jobs paused on their own, are kept.
  defp skip_paused_slots(state, now) do
    Enum.reduce_while(Map.values(state.jobs), {:ok, state, 0}, fn job, {:ok, state, skipped} ->
      if job.enabled and is_integer(job.next_run_at_ms) and job.next_run_at_ms < now do
        case skip_missed_slot(job, :global_pause) do
          {:keep, job, _catch_up} ->
            {:cont, {:ok, put_in(state.jobs[job.id], job), skipped + 1}}

          :retired ->
            Events.emit_job_deleted(job)
            {:cont, {:ok, %{state | jobs: Map.delete(state.jobs, job.id)}, skipped + 1}}

          {:error, _} ->
            {:halt, {:error, state}}
        end
      else
        {:cont, {:ok, state, skipped}}
      end
    end)
  end

  # A retry that came due while paused is a missed run like any other slot.
  # Retries of individually paused jobs keep waiting for their own resume.
  defp abandon_paused_retries(state, paused_at_ms, now) do
    with {:ok, retries} <- CronStore.pending_retries_result() do
      Enum.reduce_while(retries, {:ok, 0}, fn source_run, {:ok, skipped} ->
        due_at_ms = meta_value(source_run.meta, :retry_due_at_ms)
        job = Map.get(state.jobs, source_run.job_id)

        if match?(%CronJob{enabled: true}, job) and due_at_ms <= now and
             (is_nil(paused_at_ms) or due_at_ms >= paused_at_ms) do
          case CronStore.abandon_retry(source_run, :global_pause) do
            :ok ->
              CronStore.record_audit(:retry_skipped, %{
                job_id: source_run.job_id,
                run_id: source_run.id,
                source: :cron_manager,
                triggered_by: :retry,
                reason: :global_pause
              })

              {:cont, {:ok, skipped + 1}}

            {:error, _} = error ->
              {:halt, error}
          end
        else
          {:cont, {:ok, skipped}}
        end
      end)
    end
  end

  defp finish_resume(state, paused_at_ms, now, skipped_jobs) do
    with {:ok, skipped_retries} <- abandon_paused_retries(state, paused_at_ms, now),
         :ok <- CronStore.clear_global_pause() do
      CronStore.record_audit(:all_jobs_resumed, %{
        source: :cron_manager,
        status: :resumed,
        reason: "skipped #{skipped_jobs} missed slot(s) and #{skipped_retries} retry(ies)"
      })

      Logger.info(
        "[CronManager] All cron jobs resumed; skipped #{skipped_jobs} missed slot(s) " <>
          "and #{skipped_retries} retry(ies)"
      )

      {:reply,
       {:ok,
        %{
          resumed: true,
          skipped_job_count: skipped_jobs,
          skipped_retry_count: skipped_retries
        }}, state |> schedule_retry_tick() |> schedule_next_run()}
    else
      {:error, _} ->
        {:reply, {:error, :store_unavailable}, state}
    end
  end

  # Persist invalidation before acknowledging pause, even for claims whose
  # jitter timer has not fired. A later resume must never revive these claims.
  defp invalidate_paused_claims(state) do
    case CronStore.active_runs_result() do
      {:ok, runs} ->
        Enum.reduce_while(runs, {:ok, state}, fn run, {:ok, state} ->
          if run.triggered_by in [:schedule, :retry] and
               meta_value(run.meta, :submission_started) != true do
            run = %{run | meta: Map.put(run.meta || %{}, :abort_requested, true)}

            case CronStore.put_run(run) do
              :ok ->
                {_run, state} =
                  terminalize_run(state, run, {:aborted, "Cron paused before submission"}, [])

                {:cont, {:ok, state}}

              {:error, _} ->
                {:halt, {:error, state}}
            end
          else
            {:cont, {:ok, state}}
          end
        end)

      {:error, _} ->
        {:error, state}
    end
  end

  # An unreadable marker fails closed: never launch scheduled work while the
  # switch's state is unknown.
  defp paused? do
    case CronStore.global_pause() do
      {:ok, nil} -> false
      _paused_or_unknown -> true
    end
  end

  defp read_pause_status(state) do
    with {:ok, marker} <- CronStore.global_pause() do
      {:ok, pause_status(marker, state)}
    end
  end

  defp pause_status(marker, state) do
    %{
      paused: not is_nil(marker),
      paused_at_ms: if(marker, do: marker.paused_at_ms),
      restoration_pending: state.restoration_pending
    }
  end

  defp do_tick(state) do
    now = clock_now(state)
    Events.emit_tick(now)

    all_jobs = Map.values(state.jobs)
    LemonCore.Telemetry.cron_tick(length(all_jobs))
    state = recover_stale_active_runs(state, now, nil)

    state =
      if now - Map.get(state, :last_cleanup_at_ms, 0) >= 3_600_000 do
        CronStore.cleanup_old_runs(Map.get(state, :run_retention_per_job, 100))

        CronStore.cleanup_audit_events(
          Map.get(state, :audit_retention_max, CronStore.audit_retention_max())
        )

        Map.put(state, :last_cleanup_at_ms, now)
      else
        state
      end

    # Find due jobs. A global pause claims nothing and leaves slots untouched
    # for `resume_all/0` to skip.
    state =
      if dispatch_held?(state) do
        state
      else
        all_jobs
        |> Enum.filter(
          &(&1.enabled and is_integer(&1.next_run_at_ms) and &1.next_run_at_ms <= now)
        )
        |> Enum.reduce(state, fn job, acc -> run_scheduled_job(job, acc, now) end)
      end

    state
    |> dispatch_due_retries()
    |> schedule_retry_tick()
    |> schedule_next_run()
  end

  defp unknown_run_locked?(job) do
    Enum.any?(CronStore.active_runs(job.id), &meta_value(&1.meta, :outcome_unknown))
  rescue
    _ -> true
  catch
    _, _ -> true
  end

  defp job_active_run_locked?(%CronJob{} = job) do
    CronStore.active_runs(job.id) != []
  rescue
    error ->
      Logger.warning(
        "[CronManager] Failed to check active cron runs for #{job.id}: #{Exception.message(error)}"
      )

      true
  end

  # `startup?` is the first restoration after boot: no jitter timer or worker
  # from before the restart can still submit a claim, so every unsubmitted claim
  # is orphaned. Later passes wait out the job's jitter window first.
  defp recover_stale_active_runs(state, now, results, startup? \\ false) do
    # Include orphaned runs: removing a job must not drop ownership of its editor.
    results = results || recovery_results(CronStore.active_runs())

    Enum.reduce(results, state, fn {run, outcome}, state ->
      job = Map.get(state.jobs, run.job_id)

      cond do
        not CronRun.active?(run) ->
          state

        is_binary(run.run_id) ->
          case outcome do
            {:terminal, result} ->
              result =
                if meta_value(run.meta, :abort_requested),
                  do: {:aborted, "Run stopped by operator"},
                  else: result

              {_run, state} = terminalize_run(state, run, result, audit_action: :run_reconciled)
              stop_tracked_task(state, run.id)

            :unknown ->
              cond do
                orphaned_claim?(run, job, state, now, startup?) ->
                  {_run, state} = release_unsubmitted_claim(state, run, [])
                  state

                meta_value(run.meta, :outcome_unknown) == true or stale_run?(run, job, now) ->
                  {_run, state} = retain_unknown_run(state, run, :completion_outcome_unknown)
                  state

                true ->
                  state
              end
          end

        stale_run?(run, job, now) ->
          {_run, state} =
            terminalize_run(state, run, :timeout, audit_action: :stale_run_recovered)

          stop_tracked_task(state, run.id)

        true ->
          state
      end
    end)
  rescue
    _ ->
      Logger.warning("[CronManager] Active run reconciliation unavailable")
      state
  end

  defp recovery_results(runs) do
    Enum.map(runs, fn run ->
      outcome = if is_binary(run.run_id), do: durable_result(run.run_id), else: :unknown
      {run, outcome}
    end)
  end

  defp durable_result(run_id) do
    case RunStore.fetch(run_id) do
      {:ok, %{summary: summary}} when is_map(summary) ->
        completed = Map.get(summary, :completed) || Map.get(summary, "completed")

        if is_map(completed) do
          {:terminal,
           LemonAutomation.RunCompletionWaiter.extract_output_from_completion(completed)}
        else
          :unknown
        end

      _ ->
        :unknown
    end
  rescue
    _ -> :unknown
  catch
    _, _ -> :unknown
  end

  defp stale_run?(%CronRun{started_at_ms: started_at_ms}, %CronJob{timeout_ms: timeout_ms}, now)
       when is_integer(started_at_ms) and is_integer(timeout_ms) and timeout_ms > 0 do
    now - started_at_ms >= timeout_ms
  end

  defp stale_run?(_run, _job, _now), do: false

  defp reply_execute({:ok, run, state}), do: {:reply, {:ok, run}, state}
  defp reply_execute({:error, reason, state}), do: {:reply, {:error, reason}, state}

  # The started run is written once; it is neither announced nor submitted
  # unless that write is confirmed. A write whose outcome is unknown may leave
  # an unsubmitted claim, which recovery releases like any orphaned claim. A
  # caller-fixed `:run_id` is claimed, never overwritten.
  defp execute_job(job, triggered_by, opts, state) do
    run = fixed_run_id(CronRun.new(job.id, triggered_by), Keyword.get(opts, :run_id))
    router_run_id = router_run_id_for(job)
    retry_attempt = Keyword.get(opts, :retry_attempt, 0)
    retry_root_id = Keyword.get(opts, :retry_root_id, run.id)

    run = %{
      run
      | meta:
          retry_meta(opts, %{
            mode: CronJob.execution_mode(job),
            agent_id: job.agent_id,
            session_key: job.session_key,
            job_name: job.name,
            cwd: job.cwd,
            wake_context: Keyword.get(opts, :context),
            retry_attempt: retry_attempt,
            retry_root_id: retry_root_id
          })
          |> maybe_put_retry_meta(:trigger_policy, Keyword.get(opts, :trigger_policy))
    }

    run = CronRun.start(run, router_run_id)

    case persist_started_run(run, Keyword.has_key?(opts, :run_id)) do
      :ok ->
        CronStore.record_audit(:run_started, %{
          job_id: job.id,
          run_id: run.id,
          router_run_id: run.run_id,
          source: :cron_manager,
          status: run.status,
          triggered_by: run.triggered_by
        })

        Events.emit_run_started(run, job)
        {:ok, run, submit_claimed_run(job, run, state)}

      {:error, :exists} ->
        {:error, :exists, state}

      {:error, _} = error ->
        Logger.warning("[CronManager] Failed to persist run start for job #{job.id}")
        {:error, store_error(error), state}
    end
  end

  defp fixed_run_id(run, nil), do: run
  defp fixed_run_id(run, run_id), do: %{run | id: run_id}

  defp persist_started_run(run, true = _fixed_id?), do: CronStore.claim_run(run)
  defp persist_started_run(run, false), do: CronStore.put_run(run)

  defp run_scheduled_job(_job, %{restoration_pending: true} = state, _now), do: state

  defp run_scheduled_job(%CronJob{} = job, state, now) do
    if job_active_run_locked?(job) do
      Logger.info("[CronManager] Skipping scheduled job #{job.id}: active run already exists")
      update_suppressed_scheduled_job(job, state)
    else
      jitter_ms = jitter_delay_ms(job)
      scheduled_for_ms = job.next_run_at_ms || now || LemonCore.Clock.now_ms()

      catch_up = get_in(state, [:catch_up_slots, job.id]) == scheduled_for_ms

      case execute_scheduled_job(job, scheduled_for_ms,
             submit_delay_ms: jitter_ms,
             catch_up: catch_up
           ) do
        {:ok, _run} ->
          mark_claimed_scheduled_job(job, state, now || LemonCore.Clock.now_ms())

        {:error, :exists} ->
          Logger.info(
            "[CronManager] Skipping scheduled job #{job.id}: scheduled slot already claimed"
          )

          reload_job_state(job, state)

        {:error, reason} ->
          Logger.warning(
            "[CronManager] Failed to claim scheduled job #{job.id}: #{inspect(reason)}"
          )

          state
      end
    end
  end

  defp execute_scheduled_job(%CronJob{} = job, scheduled_for_ms, opts) do
    router_run_id = router_run_id_for(job)

    case CronStore.claim_scheduled_run(job, scheduled_for_ms, router_run_id) do
      {:ok, run} ->
        run =
          if Keyword.get(opts, :catch_up, false) do
            marked = %{run | meta: Map.put(run.meta || %{}, :catch_up, true)}

            # The catch-up marker is informational; the claim itself is durable.
            if CronStore.put_run(marked) == :ok, do: marked, else: run
          else
            run
          end

        CronStore.record_audit(:scheduled_run_claimed, %{
          job_id: job.id,
          run_id: run.id,
          router_run_id: run.run_id,
          source: :cron_manager,
          status: run.status,
          triggered_by: run.triggered_by
        })

        Events.emit_run_started(run, job)

        case Keyword.get(opts, :submit_delay_ms, 0) do
          delay when is_integer(delay) and delay > 0 ->
            Process.send_after(self(), {:submit_claimed_run, job.id, run.id}, delay)

          _ ->
            send(self(), {:submit_claimed_run, job.id, run.id})
        end

        {:ok, run}

      {:error, :exists} ->
        CronStore.record_audit(:scheduled_run_suppressed, %{
          job_id: job.id,
          source: :cron_manager,
          triggered_by: :schedule,
          reason: :slot_already_claimed
        })

        {:error, :exists}

      {:error, _} = error ->
        error
    end
  end

  defp submit_claimed_run(%CronJob{} = job, %CronRun{} = run, state) do
    manager = self()

    fun = fn ->
      case check_admission(job, run) do
        :ok ->
          submit_preflighted_run(job, run, manager)

        {:ok, invocation} ->
          submit_preflighted_run(job, run, manager, admission_invocation: invocation)

        {:error, outcome} ->
          CronStore.record_audit(:admission_failed, %{
            job_id: job.id,
            run_id: run.id,
            router_run_id: run.run_id,
            source: :cron_manager,
            triggered_by: run.triggered_by,
            reason: outcome
          })

          {:admission_failed, outcome}
      end
    end

    case start_monitored_task(fun, state) do
      {:ok, task} ->
        state
        |> put_in([:tasks, run.id], task)
        |> put_in([:task_refs, task.ref], run.id)

      {:error, reason} ->
        {_failed, state} =
          terminalize_run(
            state,
            run,
            {:error, "failed to start cron worker: #{inspect(reason, limit: 120)}"},
            audit_action: :worker_start_failed
          )

        state
    end
  end

  defp check_admission(%CronJob{admission: nil}, _run), do: :ok

  defp check_admission(job, run) do
    admission =
      Application.get_env(:lemon_automation, :cron_admission_mod, LemonAutomation.CronAdmission)

    case admission.check(job, run) do
      :ok -> :ok
      {:ok, invocation} when is_map(invocation) -> {:ok, invocation}
      {:error, :denied} -> {:error, :denied}
      _ -> {:error, :admission_unavailable}
    end
  rescue
    _ -> {:error, :admission_unavailable}
  catch
    _, _ -> {:error, :admission_unavailable}
  end

  defp submit_preflighted_run(job, run, manager, invocation_opts \\ []) do
    case preflight_mod().check(job) do
      :ok ->
        case CronJob.execution_mode(job) do
          :command ->
            with :ok <-
                   GenServer.call(
                     manager,
                     {:claim_submission, run.id, run.run_id, job.session_key},
                     @call_timeout_ms
                   ) do
              command_runner().submit(job, run)
            end

          :agent ->
            opts =
              Keyword.merge(invocation_opts,
                run_id: run.run_id,
                append_memory: false,
                on_submitting: fn router_id, session_key ->
                  GenServer.call(
                    manager,
                    {:claim_submission, run.id, router_id, session_key},
                    @call_timeout_ms
                  )
                end
              )

            run_submitter().submit(job, run, opts)
        end

      {:skip, failure} ->
        CronStore.record_audit(:preflight_failed, %{
          job_id: job.id,
          run_id: run.id,
          router_run_id: run.run_id,
          source: :cron_manager,
          triggered_by: run.triggered_by,
          reason: CronPreflight.format_failure(failure)
        })

        {:preflight_skip, failure}
    end
  end

  # Record the global default model at creation time so the drift guard has a
  # baseline. Only unpinned agent jobs need one.
  defp capture_default_model(%CronJob{} = job) do
    if CronJob.execution_mode(job) == :agent and is_nil(job.model) do
      case preflight_mod().current_default_model() do
        {:ok, model} when is_binary(model) -> %{job | captured_default_model: model}
        _ -> job
      end
    else
      job
    end
  end

  # Clearing a model pin returns the job to the global default, so it needs a
  # drift baseline from that moment on. Without this, a job created pinned (and
  # therefore never captured) would silently follow every future default change
  # after being unpinned — `captured_default_model` is immutable via `update/2`,
  # so the manager is the only place this transition can be observed.
  defp recapture_on_unpin(%CronJob{model: nil} = updated, %CronJob{model: previous})
       when is_binary(previous) do
    capture_default_model(updated)
  end

  defp recapture_on_unpin(%CronJob{} = updated, %CronJob{}), do: updated

  defp update_suppressed_scheduled_job(%CronJob{} = job, state) do
    CronStore.record_audit(:scheduled_run_suppressed, %{
      job_id: job.id,
      source: :cron_manager,
      triggered_by: :schedule,
      reason: :active_run_exists
    })

    next_run = next_run(job, state)
    updated = CronJob.set_next_run(job, next_run)
    put_job_state(state, updated)
  end

  # A one-shot job stops being due the moment its scheduled run is claimed, so
  # a restart or a slow run can never fire it twice.
  defp mark_claimed_scheduled_job(%CronJob{once: true} = job, state, now) do
    updated = %{CronJob.mark_run(job, now) | enabled: false, next_run_at_ms: nil}
    put_job_state(state, updated)
  end

  defp mark_claimed_scheduled_job(%CronJob{} = job, state, now) do
    next_run = next_run(job, state)
    updated = job |> CronJob.mark_run(now) |> CronJob.set_next_run(next_run)
    put_job_state(state, updated)
  end

  # In-memory job state only follows a persisted write. On failure the old
  # state stays; the claimed slot's deterministic run id prevents a re-fire.
  defp put_job_state(state, %CronJob{} = updated) do
    case CronStore.put_job(updated) do
      :ok ->
        put_in(state.jobs[updated.id], updated)

      {:error, _} ->
        Logger.warning("[CronManager] Failed to persist job state for #{updated.id}")
        state
    end
  end

  # Once its scheduled run has finished and been delivered, with no retry
  # pending, a one-shot job has nothing left to do and is deleted.
  defp maybe_retire_one_shot(state, %CronJob{once: true} = job, %CronRun{triggered_by: by}, :none)
       when by in [:schedule, :retry] do
    with {:ok, current} <- Map.fetch(state.jobs, job.id),
         {:ok, state} <- delete_job(state, current) do
      Logger.info("[CronManager] Retired one-shot job: #{job.id}")
      state
    else
      :error ->
        state

      {:error, _} ->
        Logger.warning("[CronManager] Failed to retire one-shot job: #{job.id}")
        state
    end
  end

  defp maybe_retire_one_shot(state, _job, _run, _retry_intent), do: state

  # The job row goes last, so a failed delete leaves the job in place to retry.
  # Nothing is announced or dropped from memory until every delete succeeded.
  defp delete_job(state, %CronJob{} = job) do
    with :ok <- CronStore.delete_monitor_state(job.id),
         :ok <- CronStore.delete_preflight_notice_state(job.id),
         :ok <- CronStore.delete_job(job.id) do
      CronStore.record_audit(:job_deleted, %{
        job_id: job.id,
        source: :cron_manager,
        status: if(job.enabled, do: :enabled, else: :disabled)
      })

      Events.emit_job_deleted(job)
      {:ok, schedule_next_run(%{state | jobs: Map.delete(state.jobs, job.id)})}
    else
      {:error, _} = error -> {:error, store_error(error)}
    end
  end

  defp store_error({:error, :outcome_unknown}), do: :outcome_unknown
  defp store_error({:error, _}), do: :store_unavailable

  defp reload_job_state(%CronJob{} = job, state) do
    case CronStore.get_job(job.id) do
      %CronJob{} = persisted -> put_in(state.jobs[job.id], persisted)
      _ -> state
    end
  end

  # Every terminal path enters here: normal task replies, task start failures,
  # monitored `:DOWN`, operator aborts, wake completions, and stale recovery.
  # The persisted terminal status is the idempotency boundary; late messages
  # observe a finished run and cannot re-apply monitor, delivery, or retry policy.
  defp terminalize_run_id(state, run_id, result, opts \\ []) do
    case CronStore.get_run(run_id) do
      %CronRun{} = run -> terminalize_run(state, run, result, opts)
      nil -> {nil, state}
    end
  end

  defp terminalize_run(state, %CronRun{run_id: run_id} = run, result, opts)
       when is_binary(run_id) and
              (result == :timeout or elem(result, 0) == :worker_down) do
    retain_unknown_run(state, run, :completion_outcome_unknown, opts)
  end

  defp terminalize_run(state, run, {:error, {:outcome_unknown, _run_id}}, opts) do
    retain_unknown_run(state, run, :completion_outcome_unknown, opts)
  end

  defp terminalize_run(state, %CronRun{} = run, result, opts) do
    if CronRun.finished?(run) do
      {run, state}
    else
      job = Map.get(state.jobs, run.job_id) || CronStore.get_job(run.job_id)
      updated_run = terminal_result(run, result)
      {updated_run, deliver?} = CronMonitor.apply_policy(job, updated_run)

      {updated_run, deliver?} =
        case CronMonitor.apply_preflight_policy(job, updated_run) do
          {policy_run, true} -> {policy_run, deliver?}
          {policy_run, false} -> {policy_run, false}
        end

      {updated_run, heartbeat_deliver?} = Heartbeat.apply_policy(job, updated_run)
      deliver? = deliver? and heartbeat_deliver?

      {updated_run, retry_intent} = persist_retry_intent(job, updated_run)

      updated_run =
        %{
          updated_run
          | error: if(updated_run.status == :completed, do: nil, else: updated_run.error)
        }

      updated_run =
        %{
          updated_run
          | meta:
              (updated_run.meta || %{})
              |> Map.put(:terminalization_applied, true)
              |> Map.put(:outcome_unknown, false)
        }

      case CronStore.put_run(updated_run) do
        :ok ->
          announce_terminal_run(state, run, updated_run, job, deliver?, retry_intent, opts)

        {:error, _} ->
          # Only a confirmed terminal is announced, delivered or acted on. After
          # a failed write the row stays active for recovery; after an
          # outcome-unknown write that landed, the stored row is the record.
          Logger.warning("[CronManager] Failed to persist terminal state for #{run.id}")
          {run, state}
      end
    end
  end

  defp announce_terminal_run(state, run, updated_run, job, deliver?, retry_intent, opts) do
    {job, state} = update_job_outcome(job, updated_run, state)

    if job && CronJob.execution_mode(job) == :agent do
      memory_result =
        if updated_run.status == :completed,
          do: {:ok, updated_run.output},
          else: {:error, updated_run.error}

      LemonAutomation.CronMemory.append_run(
        job,
        updated_run,
        meta_value(run.meta, :router_session_key) || job.session_key,
        memory_result
      )
    end

    maybe_record_terminal_audit(Keyword.get(opts, :audit_action), updated_run)
    maybe_record_retry_audit(job, updated_run, retry_intent)
    Events.emit_run_completed(updated_run)
    notification_result = deliver_to_channel(updated_run, job)

    if deliver? and notification_result != :suppressed,
      do: forward_summary_to_base_session(updated_run)

    state =
      state
      |> maybe_retire_one_shot(job, updated_run, retry_intent)
      |> dispatch_due_retries()
      |> schedule_retry_tick()

    {updated_run, state}
  end

  defp update_job_outcome(nil, _run, state), do: {nil, state}

  defp update_job_outcome(job, run, state) do
    updated = CronJob.terminalize(job, run.status)

    case CronStore.put_job(updated) do
      :ok ->
        {updated, %{state | jobs: Map.put(state.jobs, updated.id, updated)}}

      {:error, _} ->
        Logger.warning("[CronManager] Failed to persist outcome for job #{job.id}")
        {job, state}
    end
  end

  # `outcome_unknown` is only for a run whose submission may have reached the
  # router. `claim_submission` persists `submission_started` before the worker
  # may submit, so without it the run definitely never left this node: release
  # it as a retryable failure instead of locking the job.
  defp retain_unknown_run(state, run, reason, opts \\ []) do
    run = CronStore.get_run(run.id) || run

    cond do
      CronRun.finished?(run) ->
        {run, state}

      not submission_started?(run) ->
        release_unsubmitted_claim(state, run, opts)

      true ->
        meta = Map.put(run.meta || %{}, :outcome_unknown, true)
        updated = %{run | status: :running, error: Atom.to_string(reason), meta: meta}

        case CronStore.put_run(updated) do
          :ok ->
            maybe_record_terminal_audit(Keyword.get(opts, :audit_action), updated)
            {updated, state}

          {:error, _} ->
            # The row is still active and owned; recovery retries the marker.
            {run, state}
        end
    end
  end

  defp release_unsubmitted_claim(state, run, opts) do
    result =
      if meta_value(run.meta || %{}, :abort_requested),
        do: {:aborted, "Run stopped before submission"},
        else: {:not_submitted, @not_submitted_error}

    {released, state} =
      terminalize_run(state, run, result, Keyword.put(opts, :audit_action, :claim_released))

    {released, stop_tracked_task(state, run.id)}
  end

  defp orphaned_claim?(run, job, state, now, startup?) do
    not submission_started?(run) and not Map.has_key?(Map.get(state, :tasks, %{}), run.id) and
      (startup? or orphan_window_elapsed?(run, job, now))
  end

  defp orphan_window_elapsed?(%CronRun{started_at_ms: started}, job, now)
       when is_integer(started) and is_integer(now) do
    now - started > jitter_window_ms(job) + @orphan_claim_grace_ms
  end

  defp orphan_window_elapsed?(_run, _job, _now), do: false

  # Jitter is validated against `CronJob.numeric_bounds/0` on add and update; a
  # stored value outside them is clamped instead of raising in `:rand.uniform/1`
  # or `Process.send_after/3`.
  defp jitter_window_ms(%CronJob{jitter_sec: sec}) when is_integer(sec) and sec > 0 do
    {_min, max} = CronJob.numeric_bounds().jitter_sec
    min(sec, max) * 1000
  end

  defp jitter_window_ms(_job), do: 0

  defp jitter_delay_ms(job) do
    case jitter_window_ms(job) do
      0 -> 0
      window_ms -> :rand.uniform(window_ms)
    end
  end

  defp terminal_result(run, {:not_submitted, reason}), do: CronRun.fail(run, reason)

  defp terminal_result(run, {:worker_down, _reason}), do: CronRun.fail(run, "cron worker exited")

  defp terminal_result(run, {:ok, output}), do: CronRun.complete(run, output)
  defp terminal_result(run, :timeout), do: CronRun.timeout(run)
  defp terminal_result(run, {:aborted, reason}), do: CronRun.abort(run, to_error(reason))

  defp terminal_result(run, {:preflight_skip, failure}) do
    run
    |> CronRun.fail(CronPreflight.format_failure(failure))
    |> then(&%{&1 | meta: Map.put(&1.meta || %{}, :preflight_failure, failure)})
  end

  defp terminal_result(run, {:admission_failed, outcome})
       when outcome in [:denied, :admission_unavailable] do
    run
    |> CronRun.fail(Atom.to_string(outcome))
    |> then(&%{&1 | meta: Map.put(&1.meta || %{}, :admission_outcome, outcome)})
  end

  defp terminal_result(run, {:error, :admission_unavailable}),
    do: terminal_result(run, {:admission_failed, :admission_unavailable})

  defp terminal_result(run, {:error, error}), do: CronRun.fail(run, to_error(error))

  defp terminal_result(run, other),
    do: CronRun.fail(run, "unexpected cron result: #{inspect(other)}")

  defp to_error(error) when is_binary(error), do: error
  defp to_error(error), do: inspect(error, limit: 120)

  defp maybe_record_terminal_audit(nil, _run), do: :ok

  defp maybe_record_terminal_audit(action, run) do
    CronStore.record_audit(action, %{
      job_id: run.job_id,
      run_id: run.id,
      router_run_id: run.run_id,
      source: :cron_manager,
      status: run.status,
      triggered_by: run.triggered_by,
      reason: run.error
    })
  end

  defp maybe_record_retry_audit(_job, _run, :none), do: :ok

  defp maybe_record_retry_audit(job, run, {:scheduled, next_attempt, due_at_ms}) do
    CronStore.record_audit(:retry_scheduled, %{
      job_id: run.job_id,
      run_id: run.id,
      router_run_id: run.run_id,
      source: :cron_manager,
      status: run.status,
      triggered_by: run.triggered_by,
      reason: "retry #{next_attempt}/#{max_retries(job)} due at #{due_at_ms}"
    })

    Logger.info(
      "[CronManager] Persisted retry #{next_attempt}/#{max_retries(job)} for job #{job.id}"
    )
  end

  defp stop_tracked_task(state, run_id) do
    case Map.get(state.tasks, run_id) do
      %Task{} = task ->
        _ = Task.shutdown(task, :brutal_kill)
        remove_tracked_task(state, run_id, task.ref)

      _ ->
        state
    end
  end

  defp remove_tracked_task(state, run_id, ref) do
    state
    |> update_in([:tasks], &Map.delete(&1 || %{}, run_id))
    |> update_in([:task_refs], &Map.delete(&1 || %{}, ref))
  end

  defp persist_retry_intent(%CronJob{} = job, %CronRun{} = run) do
    current_attempt = retry_attempt(run)
    policy = retry_policy(job)

    if retryable_run?(run) and LemonCore.Retry.retry_allowed?(current_attempt, policy) do
      next_attempt = current_attempt + 1
      due_at_ms = LemonCore.Clock.now_ms() + LemonCore.Retry.delay(policy, current_attempt)

      meta =
        (run.meta || %{})
        |> Map.put(:retry_due_at_ms, due_at_ms)
        |> Map.put(:retry_next_attempt, next_attempt)
        |> Map.put(:retry_root_id, retry_root_id(run))

      {%{run | meta: meta}, {:scheduled, next_attempt, due_at_ms}}
    else
      {run, :none}
    end
  end

  defp persist_retry_intent(_job, run), do: {run, :none}

  defp dispatch_due_retries(state) do
    if dispatch_held?(state), do: state, else: dispatch_unpaused_retries(state)
  end

  defp dispatch_unpaused_retries(state) do
    now = LemonCore.Clock.now_ms()

    Enum.reduce(CronStore.pending_retries(), state, fn source_run, state ->
      due_at_ms = meta_value(source_run.meta, :retry_due_at_ms)
      job = Map.get(state.jobs, source_run.job_id)

      cond do
        not is_integer(due_at_ms) or due_at_ms > now ->
          state

        not match?(%CronJob{enabled: true}, job) ->
          state

        retry_blocked_by_other_active_run?(job, source_run) ->
          state

        true ->
          claim_and_submit_retry(job, source_run, state)
      end
    end)
  rescue
    error ->
      Logger.warning(
        "[CronManager] Failed to dispatch durable retries: #{Exception.message(error)}"
      )

      state
  end

  defp retry_blocked_by_other_active_run?(job, source_run) do
    expected_retry_id =
      CronStore.retry_run_id(
        retry_root_id(source_run),
        meta_value(source_run.meta, :retry_next_attempt)
      )

    Enum.any?(CronStore.active_runs(job.id), &(&1.id != expected_retry_id))
  end

  defp claim_and_submit_retry(%CronJob{} = job, %CronRun{} = source_run, state) do
    router_run_id = router_run_id_for(job)

    case CronStore.claim_retry_run(job, source_run, router_run_id) do
      {:ok, retry_run} ->
        mark_retry_dispatched(source_run, retry_run.id)

        CronStore.record_audit(:retry_started, %{
          job_id: job.id,
          run_id: retry_run.id,
          router_run_id: retry_run.run_id,
          source: :cron_manager,
          status: retry_run.status,
          triggered_by: :retry,
          reason: "retry #{retry_attempt(retry_run)}/#{max_retries(job)}"
        })

        Events.emit_run_started(retry_run, job)
        submit_claimed_run(job, retry_run, state)

      {:error, :exists} ->
        retry_run_id =
          CronStore.retry_run_id(
            retry_root_id(source_run),
            meta_value(source_run.meta, :retry_next_attempt)
          )

        mark_retry_dispatched(source_run, retry_run_id)
        state

      {:error, reason} ->
        Logger.warning(
          "[CronManager] Failed to claim retry for #{source_run.id}: #{inspect(reason)}"
        )

        state
    end
  end

  defp mark_retry_dispatched(source_run, retry_run_id) do
    meta =
      (source_run.meta || %{})
      |> Map.put(:retry_dispatched_run_id, retry_run_id)

    # A failed mark is self-healing: the retry run is claimed durably, and the
    # next dispatch pass sees `:exists` and marks the source again.
    with {:error, _} <- CronStore.put_run(%{source_run | meta: meta}) do
      Logger.warning("[CronManager] Failed to mark retry dispatched for #{source_run.id}")
    end
  end

  defp schedule_retry_tick(state, retries \\ nil, held? \\ nil) do
    if state.retry_timer, do: Process.cancel_timer(state.retry_timer)
    startup? = not is_nil(retries)

    case retries || CronStore.pending_retries() do
      [] ->
        %{state | retry_timer: nil}

      retries ->
        now = LemonCore.Clock.now_ms()

        due_at_ms =
          retries
          |> Enum.map(&meta_value(&1.meta, :retry_due_at_ms))
          |> Enum.filter(&is_integer/1)
          |> Enum.min(fn -> now + @tick_interval_ms end)

        # A past-due retry may be waiting for another active run. Poll gently;
        # the persisted due time remains the authority across restarts. Nothing
        # dispatches while paused, so only re-check at the normal tick cadence.
        held? = if is_nil(held?), do: dispatch_held?(state), else: held?

        delay_ms =
          cond do
            held? -> @tick_interval_ms
            due_at_ms <= now -> if(startup?, do: 0, else: 1_000)
            true -> min(due_at_ms - now, @max_job_timer_ms)
          end

        %{state | retry_timer: Process.send_after(self(), :retry_tick, delay_ms)}
    end
  end

  # Preflight skips are configuration problems, not transient failures: retrying
  # within one backoff window is pure noise. The next scheduled occurrence
  # re-checks.
  defp retryable_run?(%CronRun{status: status, triggered_by: triggered_by} = run) do
    is_nil(meta_value(run.meta, :preflight_failure)) and
      is_nil(meta_value(run.meta, :admission_outcome)) and
      meta_value(run.meta, :abort_requested) != true and
      status in [:failed, :timeout] and triggered_by in [:schedule, :retry]
  end

  defp retry_attempt(%CronRun{meta: meta}) do
    case meta_value(meta, :retry_attempt) do
      value when is_integer(value) and value >= 0 -> value
      _ -> 0
    end
  end

  defp retry_root_id(%CronRun{} = run) do
    case meta_value(run.meta, :retry_root_id) do
      value when is_binary(value) and value != "" -> value
      _ -> run.id
    end
  end

  defp retry_meta(opts, meta) do
    meta
    |> maybe_put_retry_meta(:retry_of, Keyword.get(opts, :retry_of))
    |> maybe_put_retry_meta(:source_triggered_by, Keyword.get(opts, :source_triggered_by))
  end

  defp maybe_put_retry_meta(meta, _key, nil), do: meta
  defp maybe_put_retry_meta(meta, key, value), do: Map.put(meta, key, value)

  defp max_retries(%CronJob{max_retries: value}) when is_integer(value) and value > 0, do: value
  defp max_retries(_job), do: 0

  defp retry_policy(job) do
    delay = retry_delay_ms(job)

    LemonCore.Retry.policy(
      max_attempts: max_retries(job) + 1,
      base_delay_ms: delay,
      max_delay_ms: delay,
      jitter: :none
    )
  end

  defp retry_delay_ms(%CronJob{retry_backoff_ms: value}) when is_integer(value) and value >= 0,
    do: value

  defp retry_delay_ms(_job), do: 30_000

  defp run_submitter do
    Application.get_env(:lemon_automation, :cron_run_submitter, RunSubmitter)
  end

  defp command_runner do
    Application.get_env(:lemon_automation, :cron_command_runner, CronCommandRunner)
  end

  defp preflight_mod do
    Application.get_env(:lemon_automation, :cron_preflight_mod, CronPreflight)
  end

  defp router_run_id_for(%CronJob{} = job) do
    case CronJob.execution_mode(job) do
      :agent -> LemonCore.Id.run_id()
      :command -> nil
    end
  end

  defp start_monitored_task(fun, state) when is_function(fun, 0) do
    supervisor = state.task_supervisor

    if state.standalone_mode and not supervisor_alive?(supervisor) do
      {:ok, Task.async(fun)}
    else
      LemonCore.TaskSupervisor.async_nolink(supervisor, fun)
    end
  rescue
    error -> {:error, {:task_start_exception, error}}
  catch
    :exit, reason -> {:error, {:task_start_exit, reason}}
  end

  defp supervisor_alive?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp supervisor_alive?(name) when is_atom(name), do: is_pid(Process.whereis(name))
  defp supervisor_alive?(_), do: false

  defp validate_params(params) do
    required = [:name, :schedule]

    missing =
      Enum.filter(required, fn key ->
        is_nil(params[key]) and is_nil(params[Atom.to_string(key)])
      end)

    case missing do
      [] ->
        with {:ok, params} <- validate_execution_target(params),
             {:ok, params} <- validate_add_feature_fields(params),
             {:ok, params} <- normalize_schedule_patch(params) do
          {:ok, params}
        else
          {:error, reason} when is_binary(reason) -> {:error, {:invalid_schedule, reason}}
          error -> error
        end

      keys ->
        {:error, {:missing_keys, keys}}
    end
  end

  defp prepare_schedule(params, schedule, timezone) do
    case CronSchedule.prepare(schedule, timezone) do
      {:ok, schedule, once} ->
        params = params |> Map.delete("schedule") |> Map.put(:schedule, schedule)
        params = if once, do: params |> Map.delete("once") |> Map.put(:once, true), else: params
        {:ok, params}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_execution_target(params) do
    prompt = params[:prompt] || params["prompt"]
    command = params[:command] || params["command"]

    cond do
      present?(prompt) and present?(command) ->
        {:error, {:invalid_target, "Set either prompt or command, not both"}}

      present?(command) ->
        {:ok, Map.put(params, :command, String.trim(command))}

      present?(prompt) ->
        required = [:agent_id, :session_key, :prompt]

        missing =
          Enum.filter(required, fn key ->
            not present?(params[key] || params[Atom.to_string(key)])
          end)

        case missing do
          [] -> {:ok, params}
          keys -> {:error, {:missing_keys, keys}}
        end

      true ->
        {:error, {:missing_keys, [:prompt_or_command]}}
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(_), do: true

  defp run_now_job(job, opts, state) do
    CronStore.record_audit(:manual_run_requested, %{
      job_id: job.id,
      source: :cron_manager,
      triggered_by: :manual
    })

    if unknown_run_locked?(job) do
      {:reply, {:error, :outcome_unknown}, state}
    else
      reply_execute(execute_job(job, :manual, opts, state))
    end
  end

  # `session_opts` is nil for operator updates (authority unchanged) or the
  # updating agent session's principal and tool options (owned jobs only;
  # authority narrowed atomically). A job the session does not own is
  # `:not_found` before any other validation, so nothing about it leaks.
  defp update_job(job_id, params, session_opts, state) do
    case Map.fetch(state.jobs, job_id) do
      {:ok, job} ->
        case {immutable_patch_fields(params), session_authority(job, session_opts)} do
          {[], {:ok, authority}} ->
            case prepare_update_patch(job, params) do
              {:ok, params} ->
                updated =
                  %{CronJob.update(job, params) | authority: authority}
                  |> recapture_on_unpin(job)

                # Both schedule and timezone determine the next wall-clock slot.
                updated =
                  if has_any_key?(params, [:schedule, "schedule", :timezone, "timezone"]) do
                    next_run = next_run(updated, state)
                    CronJob.set_next_run(updated, next_run)
                  else
                    updated
                  end

                case CronStore.put_job(updated) do
                  :ok ->
                    CronStore.record_audit(cron_update_action(job, updated, params), %{
                      job_id: updated.id,
                      source: :cron_manager,
                      status: if(updated.enabled, do: :enabled, else: :disabled),
                      changed_fields: changed_fields(params, job.authority != authority)
                    })

                    Events.emit_job_updated(updated)

                    Logger.info("[CronManager] Updated job: #{job_id}")

                    {:reply, {:ok, updated},
                     schedule_next_run(put_in(state.jobs[job_id], updated))}

                  {:error, _} = error ->
                    {:reply, {:error, store_error(error)}, state}
                end

              {:error, reason} ->
                {:reply, {:error, {:invalid_schedule, reason}}, state}

              {:invalid_target, reason} ->
                {:reply, {:error, {:invalid_target, reason}}, state}
            end

          {_fields, {:error, reason}} ->
            {:reply, {:error, reason}, state}

          {fields, {:ok, _authority}} ->
            {:reply, {:error, {:immutable_fields, fields}}, state}
        end

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  defp session_authority(job, nil), do: {:ok, job.authority}

  defp session_authority(job, session_opts) do
    if CronAuthority.owned_by?(job.authority, Keyword.get(session_opts, :session_key)),
      do: CronAuthority.restrict(job.authority, session_opts),
      else: {:error, :not_found}
  end

  defp changed_fields(params, false), do: mutable_patch_fields(params)

  defp changed_fields(params, true),
    do: Enum.sort(Enum.uniq([:authority | mutable_patch_fields(params)]))

  defp prepare_update_patch(%CronJob{} = job, params) do
    with {:ok, params} <- validate_patch_target(job, params),
         {:ok, params} <-
           validate_feature_fields(params, CronJob.execution_mode(job), job.id, job.timezone),
         {:ok, params} <-
           validate_admission_field(
             params,
             CronJob.execution_mode(job),
             job.profile_id,
             job.admission
           ),
         {:ok, params} <- normalize_schedule_patch(params, job.timezone) do
      {:ok, preserve_timestamp_one_shot(job, params)}
    end
  end

  defp preserve_timestamp_one_shot(job, params) do
    if fetch_param(params, :schedule) == :error and fetch_param(params, :once) == {:ok, false} and
         match?({:ok, {:once_at, _}}, CronSchedule.parse(job.schedule, job.timezone)) do
      params |> Map.delete("once") |> Map.put(:once, true)
    else
      params
    end
  end

  defp validate_add_feature_fields(params) do
    mode = if present?(params[:command] || params["command"]), do: :command, else: :agent
    job_id = params[:id] || params["id"]

    with {:ok, params} <- validate_feature_fields(params, mode, job_id),
         {:ok, params} <- validate_admission_field(params, mode, nil, nil),
         {:ok, params} <- validate_authority_field(params, mode) do
      {:ok, params}
    else
      {:invalid_target, reason} -> {:error, {:invalid_target, reason}}
    end
  end

  # Launcher authority bounds prompt jobs only. A malformed record is refused,
  # never stored as an unrestricted job.
  defp validate_authority_field(params, mode) do
    case fetch_param(params, :authority) do
      :error ->
        {:ok, params}

      {:ok, value} ->
        case {CronAuthority.validate(value), mode} do
          {{:ok, nil}, _mode} ->
            {:ok, params}

          {{:ok, authority}, :agent} ->
            {:ok, params |> Map.delete("authority") |> Map.put(:authority, authority)}

          {{:ok, _authority}, :command} ->
            {:invalid_target, "Launcher authority requires a prompt job"}

          {{:error, _reason}, _mode} ->
            {:invalid_target, "Invalid launcher authority"}
        end
    end
  end

  # Shared validation for the job-quality and delivery fields. Returns the
  # normalized params (atom keys, trimmed values) or an `{:invalid_target,
  # reason}` tuple that each caller maps onto its own error shape.
  defp validate_feature_fields(params, mode, job_id, default_timezone \\ "UTC") do
    with {:ok, params} <- validate_timezone_field(params, default_timezone),
         {:ok, params} <- validate_cwd(params),
         {:ok, params} <- validate_monitor_flags(params),
         {:ok, params} <- validate_numeric_fields(params),
         {:ok, params} <- validate_profile_field(params, mode),
         {:ok, params} <- validate_model_field(params, mode),
         {:ok, params} <- validate_context_from(params, mode, job_id),
         {:ok, params} <- validate_deliver_to(params) do
      validate_once(params)
    end
  end

  defp validate_timezone_field(params, default_timezone) do
    timezone =
      case fetch_param(params, :timezone) do
        :error -> default_timezone
        {:ok, value} -> value
      end

    case CronSchedule.validate_timezone(timezone) do
      :ok ->
        {:ok, params}

      {:error, :invalid_timezone} ->
        {:invalid_target, "Invalid timezone"}

      {:error, :timezone_unavailable} ->
        {:invalid_target, "Timezone database is unavailable"}
    end
  end

  defp validate_admission_field(params, mode, default_profile, default_admission) do
    profile =
      case fetch_param(params, :profile_id) do
        :error -> default_profile
        {:ok, value} -> value
      end

    admission =
      case fetch_param(params, :admission) do
        :error -> default_admission
        {:ok, value} -> value
      end

    if not is_nil(admission) and mode != :agent do
      {:invalid_target, "Admission callbacks require a profile agent job"}
    else
      case LemonAutomation.CronAdmission.validate(admission, profile) do
        {:ok, canonical} ->
          if fetch_param(params, :admission) == :error,
            do: {:ok, params},
            else: {:ok, params |> Map.delete("admission") |> Map.put(:admission, canonical)}

        {:error, reason} ->
          {:invalid_target, reason}
      end
    end
  end

  defp validate_profile_field(params, mode) do
    case fetch_param(params, :profile_id) do
      :error ->
        {:ok, params}

      {:ok, nil} ->
        {:ok, params}

      {:ok, id} when is_binary(id) and id != "" and mode == :agent ->
        case LemonCore.ProfileStore.get(id) do
          {:ok, _profile} -> {:ok, params}
          {:error, :not_found} -> {:invalid_target, "Unknown profile"}
          {:error, _} -> {:invalid_target, "Profile is unavailable"}
        end

      _ ->
        {:invalid_target, "profile_id must name a profile for an agent job"}
    end
  end

  defp validate_cwd(params) do
    case fetch_param(params, :cwd) do
      :error ->
        {:ok, params}

      {:ok, nil} ->
        {:ok, params}

      {:ok, cwd} when is_binary(cwd) ->
        if String.trim(cwd) != "" do
          {:ok, params |> Map.delete("cwd") |> Map.put(:cwd, Path.expand(cwd))}
        else
          {:invalid_target, "cwd must be a non-empty directory path"}
        end

      _ ->
        {:invalid_target, "cwd must be a directory path"}
    end
  end

  defp validate_deliver_to(params) do
    case fetch_param(params, :deliver_to) do
      :error ->
        {:ok, params}

      {:ok, value} ->
        case CronDelivery.validate(value) do
          {:ok, normalized} ->
            {:ok, params |> Map.delete("deliver_to") |> Map.put(:deliver_to, normalized)}

          {:error, reason} ->
            {:invalid_target, reason}
        end
    end
  end

  defp validate_once(params) do
    case fetch_param(params, :once) do
      :error ->
        {:ok, params}

      {:ok, nil} ->
        {:ok, params |> Map.delete("once") |> Map.put(:once, false)}

      {:ok, value} when is_boolean(value) ->
        {:ok, params |> Map.delete("once") |> Map.put(:once, value)}

      {:ok, _value} ->
        {:invalid_target, "once must be a boolean"}
    end
  end

  defp validate_numeric_fields(params) do
    CronJob.numeric_bounds()
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, params}, fn field, acc ->
      with {:ok, value} <- fetch_param(params, field),
           {:error, reason} <- CronJob.validate_numeric(field, value) do
        {:halt, {:invalid_target, reason}}
      else
        _ -> {:cont, acc}
      end
    end)
  end

  defp validate_monitor_flags(params) do
    invalid =
      [:monitor, :monitor_notify_first_run]
      |> Enum.filter(fn key ->
        case fetch_param(params, key) do
          {:ok, value} -> not is_boolean(value)
          :error -> false
        end
      end)

    if invalid == [] do
      {:ok, params}
    else
      {:invalid_target, "monitor flags must be booleans"}
    end
  end

  defp validate_model_field(params, mode) do
    case fetch_param(params, :model) do
      :error ->
        {:ok, params}

      {:ok, value} ->
        params = Map.delete(params, "model")

        cond do
          mode != :agent ->
            {:invalid_target, "model can only be set on prompt cron jobs"}

          is_nil(value) ->
            {:ok, Map.put(params, :model, nil)}

          is_binary(value) and String.trim(value) == "" ->
            {:ok, Map.put(params, :model, nil)}

          is_binary(value) ->
            {:ok, Map.put(params, :model, String.trim(value))}

          true ->
            {:invalid_target, "model must be a string"}
        end
    end
  end

  defp validate_context_from(params, mode, job_id) do
    case fetch_param(params, :context_from) do
      :error ->
        {:ok, params}

      {:ok, value} ->
        params = Map.delete(params, "context_from")

        cond do
          is_nil(value) ->
            {:ok, Map.put(params, :context_from, nil)}

          mode != :agent ->
            {:invalid_target, "context_from can only be set on prompt cron jobs"}

          not is_binary(value) or String.trim(value) == "" ->
            {:invalid_target, "context_from must be a non-empty job id"}

          String.trim(value) == job_id ->
            {:invalid_target, "context_from cannot reference the job itself"}

          is_nil(CronStore.get_job(String.trim(value))) ->
            {:invalid_target, "context_from references unknown job #{String.trim(value)}"}

          true ->
            {:ok, Map.put(params, :context_from, String.trim(value))}
        end
    end
  end

  # Fetches a param under its atom key, falling back to the string key, so an
  # explicit `false`/`nil` value is distinguishable from an absent key.
  defp fetch_param(params, key) when is_map(params) do
    case Map.fetch(params, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(params, Atom.to_string(key))
    end
  end

  defp validate_patch_target(%CronJob{} = job, params) do
    mode = CronJob.execution_mode(job)

    cond do
      has_any_key?(params, [:command, "command", :env, "env"]) and mode != :command ->
        {:invalid_target, "Command fields can only update command cron jobs"}

      has_any_key?(params, [:prompt, "prompt"]) and mode != :agent ->
        {:invalid_target, "Prompt can only update prompt cron jobs"}

      has_any_key?(params, [:command, "command"]) ->
        validate_command_patch(params)

      has_any_key?(params, [:env, "env"]) ->
        validate_env_patch(params)

      true ->
        {:ok, params}
    end
  end

  defp validate_command_patch(params) do
    command = params[:command] || params["command"]

    if is_binary(command) and String.trim(command) != "" do
      params =
        params
        |> Map.delete("command")
        |> Map.put(:command, String.trim(command))

      validate_env_patch(params)
    else
      {:invalid_target, "Command cron jobs require a non-empty command"}
    end
  end

  defp validate_env_patch(params) do
    env = params[:env] || params["env"]

    if is_nil(env) or is_map(env) do
      {:ok, params}
    else
      {:invalid_target, "Command cron env must be a map"}
    end
  end

  defp has_any_key?(params, keys), do: Enum.any?(keys, &Map.has_key?(params, &1))

  defp normalize_schedule_patch(params, default_timezone \\ "UTC") do
    schedule = params[:schedule] || params["schedule"]
    timezone = params[:timezone] || params["timezone"] || default_timezone

    if is_binary(schedule) do
      prepare_schedule(params, schedule, timezone)
    else
      {:ok, params}
    end
  end

  defp immutable_patch_fields(params) when is_map(params) do
    []
    |> maybe_add_immutable(:agent_id, [:agent_id, "agent_id", :agentId, "agentId"], params)
    |> maybe_add_immutable(
      :session_key,
      [:session_key, "session_key", :sessionKey, "sessionKey"],
      params
    )
    |> maybe_add_immutable(
      :captured_default_model,
      [:captured_default_model, "captured_default_model", "capturedDefaultModel"],
      params
    )
    |> maybe_add_immutable(:authority, [:authority, "authority"], params)
  end

  defp immutable_patch_fields(_), do: []

  defp mutable_patch_fields(params) when is_map(params) do
    params
    |> Map.keys()
    |> Enum.map(&normalize_patch_field/1)
    |> Enum.reject(&(&1 in [:agent_id, :session_key, :unknown]))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp cron_update_action(%CronJob{enabled: true}, %CronJob{enabled: false}, params)
       when is_map(params),
       do: :job_paused

  defp cron_update_action(%CronJob{enabled: false}, %CronJob{enabled: true}, params)
       when is_map(params),
       do: :job_resumed

  defp cron_update_action(_old, _new, _params), do: :job_updated

  defp normalize_patch_field(field) when is_atom(field), do: field
  defp normalize_patch_field("jitterSec"), do: :jitter_sec
  defp normalize_patch_field("timeoutMs"), do: :timeout_ms
  defp normalize_patch_field("maxRetries"), do: :max_retries
  defp normalize_patch_field("retryBackoffMs"), do: :retry_backoff_ms

  defp normalize_patch_field(field) when is_binary(field) do
    field
    |> Macro.underscore()
    |> String.to_existing_atom()
  rescue
    _ -> :unknown
  end

  defp normalize_patch_field(_), do: :unknown

  defp maybe_add_immutable(fields, field, keys, params) do
    if Enum.any?(keys, &Map.has_key?(params, &1)) do
      fields ++ [field]
    else
      fields
    end
  end

  defp migrate_state(_old_vsn, %{jobs: jobs} = state) when is_map(jobs) do
    state
    |> Map.put_new(:jobs, %{})
    |> Map.put_new(:tasks, %{})
    |> Map.put_new(:task_refs, %{})
    |> Map.put_new(:retry_timer, nil)
    |> Map.put_new(:task_supervisor, @task_supervisor)
    |> Map.put_new(:standalone_mode, false)
    |> Map.put_new(:restoration_task, nil)
    |> Map.put_new(:restoration_token, nil)
    |> Map.put_new(:restoration_initial, false)
    |> Map.put_new(:restoration_pause, nil)
    |> Map.put_new(:restoration_deferred, :queue.new())
    |> Map.put(:state_vsn, @vsn)
  end

  defp migrate_state(_old_vsn, _state) do
    %{
      jobs: %{},
      tasks: %{},
      task_refs: %{},
      retry_timer: nil,
      task_supervisor: @task_supervisor,
      standalone_mode: false,
      restoration_task: nil,
      restoration_token: nil,
      restoration_initial: false,
      restoration_pause: nil,
      restoration_deferred: :queue.new(),
      state_vsn: @vsn
    }
  end

  defp forward_summary_to_base_session(%CronRun{} = run) do
    with {:ok, base_session_key} <- base_session_from_run(run),
         forwarded_answer when is_binary(forwarded_answer) and forwarded_answer != "" <-
           build_forwarded_answer(run) do
      forwarded_run_id = "cron_notify_" <> run.id

      completed = %{
        ok: run.status == :completed,
        answer: forwarded_answer,
        error: forwarded_error(run)
      }

      summary = %{
        completed: completed,
        session_key: base_session_key,
        run_id: forwarded_run_id,
        prompt: forwarded_prompt(run),
        duration_ms: run.duration_ms,
        engine: "cron",
        # A notification-only duplicate of a run already ingested under its own
        # admitted owner: never ingest it, and never let it read as legacy.
        meta: %{
          origin: :cron,
          cron_forwarded_summary: true,
          memory_ingest: false,
          memory_scope: :unproven,
          cron_job_id: run.job_id,
          cron_run_id: run.id,
          cron_router_run_id: run.run_id,
          cron_source_session_key: meta_value(run.meta, :session_key)
        }
      }

      RunStore.finalize(forwarded_run_id, summary)

      # The run-store summary keeps `completed` as a plain map — that is the shape its readers
      # expect — while the bus event carries the typed payload every `:run_completed`
      # subscriber now pattern-matches.
      event =
        Event.new(
          :run_completed,
          CoreEvents.RunCompleted.new(%{
            completed: CoreEvents.Completion.from_map(completed),
            duration_ms: run.duration_ms
          }),
          %{
            run_id: forwarded_run_id,
            session_key: base_session_key,
            origin: :cron,
            cron_forwarded_summary: true,
            cron_job_id: run.job_id,
            cron_run_id: run.id,
            cron_router_run_id: run.run_id
          }
        )

      Bus.broadcast(Bus.session_topic(base_session_key), event)
    else
      _ -> :ok
    end
  rescue
    e ->
      Logger.warning("[CronManager] Failed to forward cron summary: #{Exception.message(e)}")
      :ok
  end

  # The bus broadcast above only reaches processes subscribed at that moment
  # (usually none), so the chat delivery is what actually notifies the user.
  defp deliver_to_channel(%CronRun{} = run, job) do
    summary = extract_summary_body(run.output, run.status, run.error)
    LemonAutomation.RunNotifications.cron_finished(job, run, summary)
  rescue
    e ->
      Logger.warning("[CronManager] Failed to deliver cron result: #{Exception.message(e)}")
      :ok
  end

  defp base_session_from_run(%CronRun{} = run) do
    session_key = meta_value(run.meta, :session_key)

    if is_binary(session_key) do
      case SessionKey.parse(session_key) do
        %{kind: :main} ->
          {:ok, session_key}

        %{kind: :channel_peer} = parsed ->
          # Keep the serialized components verbatim (a digest is never re-hashed).
          base = SessionKey.rebuild(%{parsed | sub_id: nil})

          {:ok, base}

        _ ->
          :skip
      end
    else
      :skip
    end
  rescue
    _ -> :skip
  end

  defp build_forwarded_answer(%CronRun{} = run) do
    body = extract_summary_body(run.output, run.status, run.error)

    if is_binary(body) and body != "" do
      message =
        [
          "Cron summary: #{meta_value(run.meta, :job_name) || run.job_id}",
          "triggered_by: #{run.triggered_by}",
          "status: #{run.status}",
          "cron_run_id: #{run.id}",
          if(is_binary(run.run_id), do: "router_run_id: #{run.run_id}", else: nil),
          "",
          body
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")

      truncate_to_bytes(message, @forwarded_summary_max_bytes)
    else
      ""
    end
  end

  defp extract_summary_body(output, _status, _error) when is_binary(output) do
    trimmed = String.trim(output)

    cond do
      trimmed == "" ->
        nil

      true ->
        case Regex.run(~r/RUN SUMMARY[\s\S]*/u, trimmed) do
          [summary] when is_binary(summary) and summary != "" -> String.trim(summary)
          _ -> trimmed
        end
    end
  end

  defp extract_summary_body(_output, status, error) do
    "Cron run completed with status=#{status}. #{format_forward_error(error)}"
  end

  defp forwarded_error(%CronRun{status: :completed}), do: nil
  defp forwarded_error(%CronRun{error: error}) when is_binary(error) and error != "", do: error
  defp forwarded_error(%CronRun{status: status}), do: to_string(status)

  defp forwarded_prompt(%CronRun{} = run) do
    "Forwarded cron summary for #{meta_value(run.meta, :job_name) || run.job_id}"
  end

  defp format_forward_error(error) when is_binary(error), do: error
  defp format_forward_error(error) when is_atom(error), do: Atom.to_string(error)
  defp format_forward_error(error), do: inspect(error)

  defp meta_value(meta, key) when is_map(meta) do
    Map.get(meta, key) || Map.get(meta, Atom.to_string(key))
  rescue
    _ -> nil
  end

  defp meta_value(_meta, _key), do: nil

  defp truncate_to_bytes(text, max_bytes) when is_binary(text) and byte_size(text) <= max_bytes,
    do: text

  defp truncate_to_bytes(text, max_bytes) when is_binary(text) do
    text
    |> binary_part(0, max_bytes)
    |> trim_to_valid_utf8()
  end

  defp truncate_to_bytes(_text, _max_bytes), do: ""

  defp trim_to_valid_utf8(<<>>), do: ""

  defp trim_to_valid_utf8(binary) when is_binary(binary) do
    if String.valid?(binary) do
      binary
    else
      binary
      |> binary_part(0, byte_size(binary) - 1)
      |> trim_to_valid_utf8()
    end
  end
end
