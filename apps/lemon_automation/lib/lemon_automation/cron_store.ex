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
    limit = Keyword.get(opts, :limit, 100)
    status_filter = Keyword.get(opts, :status)
    since_ms = Keyword.get(opts, :since_ms)

    @runs_table
    |> LemonCore.Store.list()
    |> Enum.map(fn {_id, map} -> CronRun.from_map(map) end)
    |> Enum.filter(fn run -> run.job_id == job_id end)
    |> maybe_filter_status(status_filter)
    |> maybe_filter_since(since_ms)
    |> Enum.sort_by(& &1.started_at_ms, :desc)
    |> Enum.take(limit)
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
    limit = Keyword.get(opts, :limit, 100)
    status_filter = Keyword.get(opts, :status)
    since_ms = Keyword.get(opts, :since_ms)

    @runs_table
    |> LemonCore.Store.list()
    |> Enum.map(fn {_id, map} -> CronRun.from_map(map) end)
    |> maybe_filter_status(status_filter)
    |> maybe_filter_since(since_ms)
    |> Enum.sort_by(& &1.started_at_ms, :desc)
    |> Enum.take(limit)
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
  # Private Helpers
  # ============================================================================

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
end
