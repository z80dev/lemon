defmodule LemonAutomation.CronStore do
  @moduledoc """
  Persistent storage for cron jobs and run history.

  Uses LemonCore.Store for persistence, storing jobs and runs in
  separate tables for efficient querying.

  ## Tables

  - `:cron_jobs` - CronJob definitions keyed by job ID
  - `:cron_runs` - CronRun history keyed by run ID

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

  # ============================================================================
  # Job Operations
  # ============================================================================

  @doc """
  Store or update a cron job.
  """
  @spec put_job(CronJob.t()) :: :ok
  def put_job(%CronJob{} = job) do
    LemonCore.Store.put(@jobs_table, job.id, CronJob.to_map(job))
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
  @spec delete_job(binary()) :: :ok
  def delete_job(job_id) do
    LemonCore.Store.delete(@jobs_table, job_id)
  end

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
  """
  @spec list_runs(binary(), keyword()) :: [CronRun.t()]
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
  Get currently active runs for a job.
  """
  @spec active_runs(binary()) :: [CronRun.t()]
  def active_runs(job_id) do
    list_runs(job_id, limit: 1000)
    |> Enum.filter(&CronRun.active?/1)
  end

  @doc """
  Clean up old runs, keeping only the most recent N runs per job.
  """
  @spec cleanup_old_runs(non_neg_integer()) :: :ok
  def cleanup_old_runs(keep_per_job \\ 100) do
    jobs = list_jobs()

    Enum.each(jobs, fn job ->
      runs = list_runs(job.id, limit: 10_000)
      to_delete = Enum.drop(runs, keep_per_job)

      Enum.each(to_delete, fn run ->
        delete_run(run.id)
      end)
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
  # Private Helpers
  # ============================================================================

  defp query_runs(opts, extra_filter \\ nil) do
    limit = Keyword.get(opts, :limit, 100)
    status_filter = Keyword.get(opts, :status)
    since_ms = Keyword.get(opts, :since_ms)

    @runs_table
    |> LemonCore.Store.list()
    |> Enum.map(fn {_id, map} -> CronRun.from_map(map) end)
    |> maybe_filter(extra_filter)
    |> maybe_filter_status(status_filter)
    |> maybe_filter_since(since_ms)
    |> Enum.sort_by(& &1.started_at_ms, :desc)
    |> Enum.take(limit)
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
  defp normalize_audit_value(value) when is_boolean(value), do: to_string(value)
  defp normalize_audit_value(_), do: ""
end
