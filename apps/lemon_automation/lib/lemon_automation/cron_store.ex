defmodule LemonAutomation.CronStore do
  @moduledoc """
  Persistent storage for cron jobs and run history.

  Uses LemonCore.Store for persistence, storing jobs and runs in
  separate tables for efficient querying.

  ## Tables

  - `:cron_jobs` - CronJob definitions keyed by job ID
  - `:cron_runs` - CronRun history keyed by run ID
  - `:cron_audit_events` - Durable lifecycle audit events
  - `:cron_monitor_state` - Monitor-mode output fingerprints keyed by job ID
  - `:cron_preflight_notice_state` - Preflight-failure fingerprints keyed by job ID
  - `:cron_settings` - Scheduler-wide switches; `:global_pause` holds the durable
    pause-all marker

  Retry intent is stored on the terminal source run (`retry_due_at_ms`,
  `retry_next_attempt`, and root/source lineage). The retry run itself uses a
  deterministic ID derived from the root run and attempt number, so rebuilding
  timers after a manager restart cannot create a duplicate attempt.

  ## Examples

      # Store a job
      CronStore.put_job(job)

      # Get all jobs
      jobs = CronStore.list_jobs()

      # Get runs for a job
      runs = CronStore.list_runs("cron_abc123", limit: 10)
  """

  alias LemonAutomation.{CronJob, CronRun}

  @jobs_table :cron_jobs
  @runs_table :cron_runs
  @audit_table :cron_audit_events
  @monitor_table :cron_monitor_state
  @preflight_notice_table :cron_preflight_notice_state
  @settings_table :cron_settings
  @global_pause_key :global_pause
  @failure_alert_table :cron_failure_alert_state
  @notices_table :cron_failure_notices

  # ============================================================================
  # Job Operations
  # ============================================================================

  @doc """
  Store or update a cron job.
  """
  @spec put_job(CronJob.t()) :: :ok | {:error, term()}
  def put_job(%CronJob{} = job) do
    LemonCore.Store.put(@jobs_table, job.id, CronJob.to_storage_map(job))
  end

  @doc """
  Atomically store a cron job only when its stable ID is unused.

  Blueprint activation uses this create-once boundary so a concurrent or
  restarted activator cannot replace an unrelated job after its collision
  preview. Normal operator updates continue to use `put_job/1` through
  `CronManager.update/2`.
  """
  @spec claim_job(CronJob.t()) :: :ok | {:error, :exists} | {:error, term()}
  def claim_job(%CronJob{} = job) do
    LemonCore.Store.put_new(@jobs_table, job.id, CronJob.to_storage_map(job))
  end

  @doc """
  Get a cron job by ID.
  """
  @spec get_job(binary()) :: CronJob.t() | nil
  def get_job(job_id) do
    case LemonCore.Store.get(@jobs_table, job_id) do
      nil -> nil
      map -> CronJob.from_map(map)
    end
  end

  @doc """
  Delete a cron job by ID.
  """
  @spec delete_job(binary()) :: :ok | {:error, term()}
  def delete_job(job_id) do
    with :ok <- delete_failure_alert_state(job_id) do
      LemonCore.Store.delete(@jobs_table, job_id)
    end
  end

  @doc "Read the durable failure incident state for a job."
  def get_failure_alert_state(job_id),
    do: LemonCore.Store.get(@failure_alert_table, job_id) || %{}

  @doc "Persist bounded incident state (owned by RunNotifications)."
  def put_failure_alert_state(job_id, state),
    do: LemonCore.Store.put(@failure_alert_table, job_id, state)

  @doc "Clear incidents after recovery or job removal."
  def delete_failure_alert_state(job_id),
    do: LemonCore.Store.delete(@failure_alert_table, job_id)

  @doc "Record the latest unread undelivered failure per job, keeping at most 200 jobs."
  def record_failure_notice(job_id, notice) do
    :ok = LemonCore.Store.put(@notices_table, job_id, notice)

    @notices_table
    |> LemonCore.Store.list()
    |> Enum.sort_by(fn {_id, notice} -> notice.ts_ms end, :desc)
    |> Enum.drop(200)
    |> Enum.each(fn {id, _notice} -> clear_failure_notice(id) end)

    :ok
  end

  @doc "Read outstanding local failure notices."
  def list_failure_notices do
    @notices_table
    |> LemonCore.Store.list()
    |> Enum.map(fn {_id, notice} -> notice end)
    |> Enum.sort_by(& &1.ts_ms, :desc)
  end

  @doc "Resolve the local notice after recovery or successful alert admission."
  def clear_failure_notice(job_id), do: LemonCore.Store.delete(@notices_table, job_id)

  @doc """
  List all cron jobs.
  """
  @spec list_jobs() :: [CronJob.t()]
  def list_jobs do
    @jobs_table
    |> LemonCore.Store.list()
    |> Enum.map(fn {_id, map} -> CronJob.from_map(map) end)
    |> Enum.sort_by(& &1.created_at_ms, :desc)
  end

  @doc """
  Strictly enumerate all cron jobs. An unreadable inventory is not an empty one.
  """
  @spec list_jobs_result() :: {:ok, [CronJob.t()]} | {:error, :store_unavailable}
  def list_jobs_result do
    with {:ok, rows} <- LemonCore.Store.fetch_all(@jobs_table) do
      {:ok,
       rows
       |> Enum.map(fn {_id, map} -> CronJob.from_map(map) end)
       |> Enum.sort_by(& &1.created_at_ms, :desc)}
    end
  end

  @doc """
  List all enabled cron jobs.
  """
  @spec list_enabled_jobs() :: [CronJob.t()]
  def list_enabled_jobs do
    list_jobs()
    |> Enum.filter(& &1.enabled)
  end

  @doc """
  Get jobs that are due to run.
  """
  @spec list_due_jobs() :: [CronJob.t()]
  def list_due_jobs do
    list_enabled_jobs()
    |> Enum.filter(&CronJob.due?/1)
  end

  # ============================================================================
  # Global Pause
  # ============================================================================

  @doc """
  Read the durable pause-all marker.

  `{:ok, nil}` means the scheduler is running; an unavailable store is an error,
  never "not paused". A marker whose contents cannot be read still reports
  paused, with an unknown start time.
  """
  @spec global_pause() ::
          {:ok, %{paused_at_ms: non_neg_integer() | nil} | nil} | {:error, :store_unavailable}
  def global_pause do
    case LemonCore.Store.fetch(@settings_table, @global_pause_key) do
      {:ok, nil} -> {:ok, nil}
      {:ok, marker} -> {:ok, %{paused_at_ms: marker |> paused_at_ms() |> valid_timestamp()}}
      {:error, _} -> {:error, :store_unavailable}
    end
  end

  @doc """
  Atomically record the pause-all marker. An existing marker is never replaced,
  so the original pause time survives repeated pause requests.
  """
  @spec put_global_pause(non_neg_integer()) :: :ok | {:error, :exists} | {:error, term()}
  def put_global_pause(paused_at_ms) when is_integer(paused_at_ms) and paused_at_ms >= 0 do
    LemonCore.Store.put_new(@settings_table, @global_pause_key, %{paused_at_ms: paused_at_ms})
  end

  @doc """
  Remove the pause-all marker.
  """
  @spec clear_global_pause() :: :ok | {:error, term()}
  def clear_global_pause do
    LemonCore.Store.delete(@settings_table, @global_pause_key)
  end

  # ============================================================================
  # Run Operations
  # ============================================================================

  @doc """
  Store or update a cron run.
  """
  @spec put_run(CronRun.t()) :: :ok
  def put_run(%CronRun{} = run) do
    LemonCore.Store.put(@runs_table, run.id, CronRun.to_map(run))
  end

  @doc """
  Store a cron run only if its ID has not already been claimed.
  """
  @spec claim_run(CronRun.t()) :: :ok | {:error, :exists} | {:error, term()}
  def claim_run(%CronRun{} = run) do
    LemonCore.Store.put_new(@runs_table, run.id, CronRun.to_map(run))
  end

  @doc """
  Atomically claim the deterministic run slot for a scheduled job occurrence.
  """
  @spec claim_scheduled_run(CronJob.t(), non_neg_integer(), binary() | nil) ::
          {:ok, CronRun.t()} | {:error, :exists} | {:error, term()}
  def claim_scheduled_run(%CronJob{} = job, scheduled_for_ms, router_run_id)
      when is_integer(scheduled_for_ms) and scheduled_for_ms >= 0 do
    run_id = scheduled_run_id(job.id, scheduled_for_ms)

    run =
      job.id
      |> CronRun.new(:schedule)
      |> Map.put(:id, run_id)
      |> Map.put(:meta, %{
        mode: CronJob.execution_mode(job),
        agent_id: job.agent_id,
        session_key: job.session_key,
        job_name: job.name,
        cwd: job.cwd,
        scheduled_for_ms: scheduled_for_ms,
        retry_attempt: 0,
        retry_root_id: run_id
      })
      |> CronRun.start(router_run_id)

    case claim_run(run) do
      :ok -> {:ok, run}
      {:error, _} = error -> error
    end
  end

  @doc """
  Atomically claim one persisted retry attempt.

  The source run must contain retry intent metadata written by CronManager.
  The deterministic run ID is the uniqueness invariant for `{root, attempt}`.
  """
  @spec claim_retry_run(CronJob.t(), CronRun.t(), binary() | nil) ::
          {:ok, CronRun.t()} | {:error, :exists | :invalid_retry_intent} | {:error, term()}
  def claim_retry_run(%CronJob{} = job, %CronRun{} = source_run, router_run_id) do
    with attempt when is_integer(attempt) and attempt > 0 <-
           meta_value(source_run.meta, :retry_next_attempt),
         root_id when is_binary(root_id) and root_id != "" <-
           meta_value(source_run.meta, :retry_root_id) || source_run.id do
      run_id = retry_run_id(root_id, attempt)

      run =
        job.id
        |> CronRun.new(:retry)
        |> Map.put(:id, run_id)
        |> Map.put(:meta, %{
          mode: CronJob.execution_mode(job),
          agent_id: job.agent_id,
          session_key: job.session_key,
          job_name: job.name,
          cwd: job.cwd,
          retry_attempt: attempt,
          retry_of: source_run.id,
          retry_root_id: root_id,
          source_triggered_by: source_run.triggered_by
        })
        |> CronRun.start(router_run_id)

      case claim_run(run) do
        :ok -> {:ok, run}
        {:error, _} = error -> error
      end
    else
      _ -> {:error, :invalid_retry_intent}
    end
  end

  @doc """
  Return the deterministic run ID for a scheduled job occurrence.
  """
  @spec scheduled_run_id(binary(), non_neg_integer()) :: binary()
  def scheduled_run_id(job_id, scheduled_for_ms) when is_integer(scheduled_for_ms) do
    digest =
      :crypto.hash(:sha256, "#{job_id}:#{scheduled_for_ms}")
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 24)

    "cron_sched_#{digest}"
  end

  @doc """
  Return the deterministic ID for one retry lineage attempt.
  """
  @spec retry_run_id(binary(), pos_integer()) :: binary()
  def retry_run_id(root_run_id, attempt)
      when is_binary(root_run_id) and is_integer(attempt) and attempt > 0 do
    digest =
      :crypto.hash(:sha256, "#{root_run_id}:retry:#{attempt}")
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 24)

    "cron_retry_#{digest}"
  end

  @doc """
  Get a cron run by ID.
  """
  @spec get_run(binary()) :: CronRun.t() | nil
  def get_run(run_id) do
    case LemonCore.Store.get(@runs_table, run_id) do
      nil -> nil
      map -> CronRun.from_map(map)
    end
  end

  @doc """
  Delete a cron run by ID.
  """
  @spec delete_run(binary()) :: :ok
  def delete_run(run_id) do
    LemonCore.Store.delete(@runs_table, run_id)
  end

  @doc """
  List runs for a specific job.

  ## Options

  - `:limit` - Maximum number of runs to return (default: 100)
  - `:status` - Filter by status atom
  - `:since_ms` - Only include runs started after this timestamp
  - `:strict` - Return `{:ok, runs}` or a store error instead of collapsing failure to an empty list
  """
  @spec list_runs(binary(), keyword()) :: [CronRun.t()] | {:ok, [CronRun.t()]} | {:error, term()}
  def list_runs(job_id, opts \\ []) do
    query_runs(opts, fn run -> run.job_id == job_id end)
  end

  @doc """
  List all runs across all jobs.

  ## Options

  - `:limit` - Maximum number of runs to return (default: 100)
  - `:status` - Filter by status atom
  - `:since_ms` - Only include runs started after this timestamp
  """
  @spec list_all_runs(keyword()) :: [CronRun.t()]
  def list_all_runs(opts \\ []) do
    query_runs(opts)
  end

  @doc """
  Get all currently active runs, optionally restricted to a job.
  """
  @spec active_runs(binary() | nil) :: [CronRun.t()]
  def active_runs(job_id \\ nil) do
    {:ok, rows} = LemonCore.Store.fetch_all(@runs_table)

    rows
    |> Enum.map(fn {_id, map} -> CronRun.from_map(map) end)
    |> Enum.filter(fn run -> is_nil(job_id) or run.job_id == job_id end)
    |> Enum.filter(&CronRun.active?/1)
    |> Enum.sort_by(& &1.started_at_ms, :desc)
  end

  @doc "Strictly enumerate all active runs, failing closed when the store cannot be read."
  @spec active_runs_result() :: {:ok, [CronRun.t()]} | {:error, :store_unavailable}
  def active_runs_result do
    with {:ok, rows} <- LemonCore.Store.fetch_all(@runs_table) do
      {:ok,
       rows
       |> Enum.map(fn {_id, map} -> CronRun.from_map(map) end)
       |> Enum.filter(&CronRun.active?/1)
       |> Enum.sort_by(& &1.started_at_ms, :desc)}
    end
  end

  @doc """
  List terminal source runs with durable retry intent that has not been marked
  dispatched. The caller still atomically claims the deterministic retry run.
  """
  @spec pending_retries() :: [CronRun.t()]
  def pending_retries do
    list_all_runs(limit: 100_000)
    |> Enum.filter(&retry_pending?/1)
    |> Enum.sort_by(&meta_value(&1.meta, :retry_due_at_ms), :asc)
  end

  @doc """
  Strictly enumerate every undispatched retry intent without a history limit.
  A failed read is not an empty retry queue.
  """
  @spec pending_retries_result() :: {:ok, [CronRun.t()]} | {:error, :store_unavailable}
  def pending_retries_result do
    with {:ok, rows} <- LemonCore.Store.fetch_all(@runs_table) do
      {:ok,
       rows
       |> Enum.map(fn {_id, map} -> CronRun.from_map(map) end)
       |> Enum.filter(&retry_pending?/1)
       |> Enum.sort_by(&meta_value(&1.meta, :retry_due_at_ms), :asc)}
    end
  end

  @doc """
  Permanently skip a source run's undispatched retry. The run stays in history;
  no retry attempt is ever claimed for it.
  """
  @spec abandon_retry(CronRun.t(), atom()) :: :ok | {:error, term()}
  def abandon_retry(%CronRun{} = source_run, reason) when is_atom(reason) do
    meta = Map.put(source_run.meta || %{}, :retry_abandoned, Atom.to_string(reason))
    put_run(%{source_run | meta: meta})
  end

  @doc """
  Clean up old terminal runs, keeping the most recent N per job. Active runs
  and terminal runs with an undispatched retry are always retained.
  """
  @spec cleanup_old_runs(non_neg_integer()) :: :ok
  def cleanup_old_runs(keep_per_job \\ 100)
      when is_integer(keep_per_job) and keep_per_job >= 0 do
    {:ok, rows} = LemonCore.Store.fetch_all(@runs_table)

    rows
    |> Enum.map(fn {_id, map} -> CronRun.from_map(map) end)
    |> Enum.filter(fn run -> CronRun.finished?(run) and not retry_undispatched?(run) end)
    |> Enum.group_by(& &1.job_id)
    |> Enum.each(fn {_job_id, runs} ->
      runs
      |> Enum.sort_by(& &1.started_at_ms, :desc)
      |> Enum.drop(keep_per_job)
      |> Enum.each(&delete_run(&1.id))
    end)

    :ok
  end

  # ============================================================================
  # Audit Operations
  # ============================================================================

  @doc """
  Record a durable cron lifecycle audit event.
  """
  @spec record_audit(atom() | binary(), map()) :: map()
  def record_audit(action, attrs \\ %{}) when is_map(attrs) do
    event =
      attrs
      |> normalize_audit_attrs()
      |> Map.merge(%{
        id: "cron_audit_#{LemonCore.Id.uuid()}",
        action: normalize_audit_value(action),
        ts_ms: LemonCore.Clock.now_ms()
      })

    :ok = LemonCore.Store.put(@audit_table, event.id, event)
    LemonAutomation.Events.emit_lifecycle_action(event)
    event
  end

  @doc """
  List durable cron lifecycle audit events.

  ## Options

  - `:limit` - Maximum number of events to return (default: 100)
  - `:job_id` - Filter by job ID
  - `:run_id` - Filter by cron run ID
  - `:action` - Filter by action string/atom
  """
  @spec list_audit_events(keyword()) :: [map()]
  def list_audit_events(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    job_id = Keyword.get(opts, :job_id)
    run_id = Keyword.get(opts, :run_id)
    action = Keyword.get(opts, :action)

    @audit_table
    |> LemonCore.Store.list()
    |> Enum.map(fn {_id, map} -> normalize_audit_attrs(map) end)
    |> filter_audit(:job_id, job_id)
    |> filter_audit(:run_id, run_id)
    |> filter_audit(:action, normalize_optional_audit_value(action))
    |> Enum.sort_by(&Map.get(&1, :ts_ms, 0), :desc)
    |> Enum.take(limit)
  end

  @doc """
  Delete an audit event by ID.
  """
  @spec delete_audit_event(binary()) :: :ok
  def delete_audit_event(event_id) do
    LemonCore.Store.delete(@audit_table, event_id)
  end

  # ============================================================================
  # Monitor State Operations
  # ============================================================================

  @doc """
  Store the monitor-mode fingerprint state for a job.

  Monitor state lives in the durable cron store (not the prompt-facing cron
  memory file), so output suppression survives restarts.
  """
  @spec put_monitor_state(binary(), map()) :: :ok
  def put_monitor_state(job_id, state) when is_binary(job_id) and is_map(state) do
    LemonCore.Store.put(@monitor_table, job_id, normalize_monitor_state(state))
  end

  @doc """
  Get the monitor-mode fingerprint state for a job, or `nil` when absent.
  """
  @spec get_monitor_state(binary()) :: map() | nil
  def get_monitor_state(job_id) when is_binary(job_id) do
    case LemonCore.Store.get(@monitor_table, job_id) do
      nil -> nil
      map when is_map(map) -> normalize_monitor_state(map)
      _ -> nil
    end
  end

  @doc """
  Delete the monitor-mode fingerprint state for a job.
  """
  @spec delete_monitor_state(binary()) :: :ok
  def delete_monitor_state(job_id) when is_binary(job_id) do
    LemonCore.Store.delete(@monitor_table, job_id)
  end

  # ============================================================================
  # Preflight Notice State Operations
  # ============================================================================

  @doc """
  Store the preflight-failure notice fingerprint for a job.

  Kept in its own table rather than sharing `:cron_monitor_state`: an output
  fingerprint and a failure fingerprint must never occupy the same slot, or a
  recovery run would be compared against a failure hash.
  """
  @spec put_preflight_notice_state(binary(), map()) :: :ok
  def put_preflight_notice_state(job_id, state) when is_binary(job_id) and is_map(state) do
    LemonCore.Store.put(@preflight_notice_table, job_id, normalize_preflight_notice_state(state))
  end

  @doc """
  Get the preflight-failure notice fingerprint for a job, or `nil` when absent.
  """
  @spec get_preflight_notice_state(binary()) :: map() | nil
  def get_preflight_notice_state(job_id) when is_binary(job_id) do
    case LemonCore.Store.get(@preflight_notice_table, job_id) do
      nil -> nil
      map when is_map(map) -> normalize_preflight_notice_state(map)
      _ -> nil
    end
  end

  @doc """
  Delete the preflight-failure notice fingerprint for a job.
  """
  @spec delete_preflight_notice_state(binary()) :: :ok
  def delete_preflight_notice_state(job_id) when is_binary(job_id) do
    LemonCore.Store.delete(@preflight_notice_table, job_id)
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp normalize_preflight_notice_state(state) when is_map(state) do
    %{
      class: monitor_get(state, :class),
      detail_hash: monitor_get(state, :detail_hash),
      first_seen_at_ms: monitor_get(state, :first_seen_at_ms),
      last_notified_at_ms: monitor_get(state, :last_notified_at_ms),
      occurrences: monitor_get(state, :occurrences) || 0,
      notifications: monitor_get(state, :notifications) || 0
    }
  end

  defp normalize_monitor_state(state) when is_map(state) do
    %{
      last_hash: monitor_get(state, :last_hash),
      last_run_id: monitor_get(state, :last_run_id),
      last_changed_at_ms: monitor_get(state, :last_changed_at_ms),
      updated_at_ms: monitor_get(state, :updated_at_ms),
      runs_since_change: monitor_get(state, :runs_since_change) || 0
    }
  end

  defp monitor_get(map, key) do
    case Map.get(map, key) do
      nil -> Map.get(map, Atom.to_string(key))
      value -> value
    end
  end

  defp meta_value(meta, key) when is_map(meta) do
    case Map.fetch(meta, key) do
      {:ok, value} -> value
      :error -> Map.get(meta, Atom.to_string(key))
    end
  end

  defp meta_value(_meta, _key), do: nil

  defp retry_pending?(%CronRun{meta: meta} = run) do
    is_integer(meta_value(meta, :retry_next_attempt)) and retry_undispatched?(run)
  end

  # Intent that no retry attempt was claimed for and nobody abandoned.
  defp retry_undispatched?(%CronRun{meta: meta}) do
    is_integer(meta_value(meta, :retry_due_at_ms)) and
      is_nil(meta_value(meta, :retry_dispatched_run_id)) and
      is_nil(meta_value(meta, :retry_abandoned))
  end

  defp paused_at_ms(marker) when is_map(marker), do: monitor_get(marker, :paused_at_ms)
  defp paused_at_ms(_marker), do: nil

  defp valid_timestamp(value) when is_integer(value) and value >= 0, do: value
  defp valid_timestamp(_value), do: nil

  defp query_runs(opts, extra_filter \\ nil) do
    project = fn records ->
      records
      |> Enum.map(fn {_id, map} -> CronRun.from_map(map) end)
      |> maybe_filter(extra_filter)
      |> maybe_filter_status(Keyword.get(opts, :status))
      |> maybe_filter_since(Keyword.get(opts, :since_ms))
      |> Enum.sort_by(& &1.started_at_ms, :desc)
      |> Enum.take(Keyword.get(opts, :limit, 100))
    end

    if opts[:strict] do
      with {:ok, records} <- LemonCore.Store.fetch_all(@runs_table), do: {:ok, project.(records)}
    else
      project.(LemonCore.Store.list(@runs_table))
    end
  end

  defp maybe_filter(runs, nil), do: runs
  defp maybe_filter(runs, filter_fn), do: Enum.filter(runs, filter_fn)

  defp maybe_filter_status(runs, nil), do: runs

  defp maybe_filter_status(runs, status) do
    Enum.filter(runs, fn run -> run.status == status end)
  end

  defp maybe_filter_since(runs, nil), do: runs

  defp maybe_filter_since(runs, since_ms) do
    Enum.filter(runs, fn run ->
      run.started_at_ms != nil and run.started_at_ms >= since_ms
    end)
  end

  defp normalize_audit_attrs(attrs) when is_map(attrs) do
    %{
      id: audit_get(attrs, :id),
      action: normalize_optional_audit_value(audit_get(attrs, :action)),
      ts_ms: audit_integer(audit_get(attrs, :ts_ms)),
      job_id: audit_get(attrs, :job_id),
      run_id: audit_get(attrs, :run_id),
      router_run_id: audit_get(attrs, :router_run_id),
      source: normalize_optional_audit_value(audit_get(attrs, :source)),
      status: normalize_optional_audit_value(audit_get(attrs, :status)),
      triggered_by: normalize_optional_audit_value(audit_get(attrs, :triggered_by)),
      reason: audit_get(attrs, :reason),
      changed_fields: audit_list(audit_get(attrs, :changed_fields))
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, []] end)
    |> Map.new()
  end

  defp normalize_audit_attrs(_), do: %{}

  defp filter_audit(events, _key, nil), do: events

  defp filter_audit(events, key, expected) do
    Enum.filter(events, &(Map.get(&1, key) == expected))
  end

  defp audit_get(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp audit_integer(value) when is_integer(value), do: value

  defp audit_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp audit_integer(_), do: nil

  defp audit_list(values) when is_list(values) do
    values
    |> Enum.map(&normalize_audit_value/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.sort()
  end

  defp audit_list(value) when is_atom(value) or is_binary(value),
    do: [normalize_audit_value(value)]

  defp audit_list(_), do: []

  defp normalize_optional_audit_value(nil), do: nil
  defp normalize_optional_audit_value(value), do: normalize_audit_value(value)

  defp normalize_audit_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_audit_value(value) when is_binary(value), do: value
  defp normalize_audit_value(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_audit_value(_), do: ""
end
