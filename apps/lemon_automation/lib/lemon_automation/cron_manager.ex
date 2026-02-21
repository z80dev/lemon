defmodule LemonAutomation.CronManager do
  @moduledoc """
  GenServer that manages cron job scheduling and execution.

  The CronManager is responsible for:

  - Loading jobs from persistent storage on startup
  - Computing next run times for all jobs
  - Ticking every minute to check for due jobs
  - Executing due jobs via LemonRouter
  - Tracking run history

  ## Tick Behavior

  The manager ticks every minute (configurable) and:

  1. Computes which jobs are due
  2. Applies jitter if configured
  3. Submits runs to LemonRouter
  4. Updates next run times
  5. Emits events for monitoring

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

      # Get run history
      CronManager.runs("cron_abc", limit: 10)
  """

  use GenServer

  alias LemonAutomation.{CronJob, CronRun, CronStore, CronSchedule, Events, RunSubmitter}

  require Logger

  @tick_interval_ms 60_000
  @task_supervisor LemonAutomation.TaskSupervisor

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Start the CronManager GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  List all cron jobs.
  """
  @spec list() :: [CronJob.t()]
  def list do
    GenServer.call(__MODULE__, :list)
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
  - `:timezone` - Timezone for schedule (default: "UTC")
  - `:jitter_sec` - Random delay spread (default: 0)
  - `:timeout_ms` - Execution timeout (default: 300000)
  - `:meta` - Additional metadata
  """
  @spec add(map()) :: {:ok, CronJob.t()} | {:error, term()}
  def add(params) do
    GenServer.call(__MODULE__, {:add, params})
  end

  @doc """
  Update an existing cron job.
  """
  @spec update(binary(), map()) :: {:ok, CronJob.t()} | {:error, :not_found}
  def update(job_id, params) do
    GenServer.call(__MODULE__, {:update, job_id, params})
  end

  @doc """
  Remove a cron job.
  """
  @spec remove(binary()) :: :ok | {:error, :not_found}
  def remove(job_id) do
    GenServer.call(__MODULE__, {:remove, job_id})
  end

  @doc """
  Trigger a job to run immediately.
  """
  @spec run_now(binary()) :: {:ok, CronRun.t()} | {:error, :not_found}
  def run_now(job_id) do
    GenServer.call(__MODULE__, {:run_now, job_id})
  end

  @doc """
  Get run history for a job.

  ## Options

  - `:limit` - Maximum number of runs (default: 100)
  - `:status` - Filter by status
  - `:since_ms` - Filter by start time
  """
  @spec runs(binary(), keyword()) :: [CronRun.t()]
  def runs(job_id, opts \\ []) do
    GenServer.call(__MODULE__, {:runs, job_id, opts})
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
  def init(_opts) do
    # Load existing jobs from storage
    jobs = CronStore.list_jobs()

    # Compute next run times for all jobs
    jobs =
      Enum.map(jobs, fn job ->
        next_run = CronSchedule.next_run_ms(job.schedule, job.timezone)
        job = CronJob.set_next_run(job, next_run)
        CronStore.put_job(job)
        job
      end)

    # Schedule first tick
    schedule_tick()

    Logger.info("[CronManager] Started with #{length(jobs)} jobs")

    {:ok, %{jobs: Map.new(jobs, &{&1.id, &1})}}
  end

  @impl true
  def handle_call(:list, _from, state) do
    jobs = Map.values(state.jobs) |> Enum.sort_by(& &1.created_at_ms, :desc)
    {:reply, jobs, state}
  end

  @impl true
  def handle_call({:add, params}, _from, state) do
    case validate_params(params) do
      :ok ->
        job = CronJob.new(params)
        next_run = CronSchedule.next_run_ms(job.schedule, job.timezone)
        job = CronJob.set_next_run(job, next_run)

        CronStore.put_job(job)
        Events.emit_job_created(job)

        Logger.info("[CronManager] Added job: #{job.id} (#{job.name})")
        {:reply, {:ok, job}, put_in(state.jobs[job.id], job)}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:update, job_id, params}, _from, state) do
    case Map.fetch(state.jobs, job_id) do
      {:ok, job} ->
        updated = CronJob.update(job, params)

        # Recompute next run if schedule changed
        updated =
          if params[:schedule] || params["schedule"] do
            next_run = CronSchedule.next_run_ms(updated.schedule, updated.timezone)
            CronJob.set_next_run(updated, next_run)
          else
            updated
          end

        CronStore.put_job(updated)
        Events.emit_job_updated(updated)

        Logger.info("[CronManager] Updated job: #{job_id}")
        {:reply, {:ok, updated}, put_in(state.jobs[job_id], updated)}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:remove, job_id}, _from, state) do
    case Map.fetch(state.jobs, job_id) do
      {:ok, job} ->
        CronStore.delete_job(job_id)
        Events.emit_job_deleted(job)

        # If this is a heartbeat job, also clear the heartbeat config
        # to prevent it from being recreated on restart
        maybe_clear_heartbeat_config(job)

        Logger.info("[CronManager] Removed job: #{job_id}")
        {:reply, :ok, %{state | jobs: Map.delete(state.jobs, job_id)}}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:run_now, job_id}, _from, state) do
    case Map.fetch(state.jobs, job_id) do
      {:ok, job} ->
        run = execute_job(job, :manual)
        {:reply, {:ok, run}, state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:runs, job_id, opts}, _from, state) do
    runs = CronStore.list_runs(job_id, opts)
    {:reply, runs, state}
  end

  @impl true
  def handle_cast(:tick, state) do
    state = do_tick(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, state) do
    state = do_tick(state)
    schedule_tick()
    {:noreply, state}
  end

  @impl true
  def handle_info({:run_complete, run_id, result}, state) do
    case CronStore.get_run(run_id) do
      nil ->
        {:noreply, state}

      run ->
        updated_run =
          case result do
            {:ok, output} -> CronRun.complete(run, output)
            {:error, error} -> CronRun.fail(run, error)
            :timeout -> CronRun.timeout(run)
          end

        CronStore.put_run(updated_run)
        Events.emit_run_completed(updated_run)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp schedule_tick do
    Process.send_after(self(), :tick, @tick_interval_ms)
  end

  defp do_tick(state) do
    now = LemonCore.Clock.now_ms()
    Events.emit_tick(now)

    # Find due jobs
    due_jobs =
      state.jobs
      |> Map.values()
      |> Enum.filter(&CronJob.due?/1)

    # Execute each due job
    Enum.each(due_jobs, fn job ->
      # Apply jitter if configured
      jitter_ms = if job.jitter_sec > 0, do: :rand.uniform(job.jitter_sec * 1000), else: 0

      if jitter_ms > 0 do
        Process.send_after(self(), {:execute_job, job.id, :schedule}, jitter_ms)
      else
        execute_job(job, :schedule)
      end
    end)

    # Update next run times for executed jobs
    updated_jobs =
      Enum.reduce(due_jobs, state.jobs, fn job, jobs ->
        next_run = CronSchedule.next_run_ms(job.schedule, job.timezone)
        updated = job |> CronJob.mark_run(now) |> CronJob.set_next_run(next_run)
        CronStore.put_job(updated)
        Map.put(jobs, job.id, updated)
      end)

    %{state | jobs: updated_jobs}
  end

  defp execute_job(job, triggered_by) do
    run = CronRun.new(job.id, triggered_by)
    CronStore.put_run(run)

    # Start the run
    run = CronRun.start(run)
    CronStore.put_run(run)
    Events.emit_run_started(run, job)

    # Submit to router asynchronously
    _ =
      start_background_task(fn ->
        result = RunSubmitter.submit(job, run)
        send(__MODULE__, {:run_complete, run.id, result})
      end)

    run
  end

  defp start_background_task(fun) when is_function(fun, 0) do
    case Task.Supervisor.start_child(@task_supervisor, fun) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:noproc, _}} ->
        Task.start(fun)

      {:error, :noproc} ->
        Task.start(fun)

      {:error, reason} ->
        Logger.warning(
          "[CronManager] Failed to start supervised task: #{inspect(reason)}; falling back to Task.start/1"
        )

        Task.start(fun)
    end
  end

  defp validate_params(params) do
    required = [:name, :schedule, :agent_id, :session_key, :prompt]

    missing =
      Enum.filter(required, fn key ->
        is_nil(params[key]) and is_nil(params[Atom.to_string(key)])
      end)

    case missing do
      [] ->
        schedule = params[:schedule] || params["schedule"]

        case CronSchedule.parse(schedule) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, {:invalid_schedule, reason}}
        end

      keys ->
        {:error, {:missing_keys, keys}}
    end
  end

  # If removing a heartbeat job, also clear the heartbeat config
  # to prevent it from being recreated on restart
  defp maybe_clear_heartbeat_config(%CronJob{} = job) do
    # Check if this is a heartbeat job by looking at meta
    is_heartbeat =
      is_map(job.meta) and
        (job.meta[:heartbeat] == true or job.meta["heartbeat"] == true)

    if is_heartbeat do
      agent_id = job.meta[:agent_id] || job.meta["agent_id"] || job.agent_id

      if agent_id do
        Logger.info("[CronManager] Clearing heartbeat config for agent: #{agent_id}")
        LemonCore.Store.delete(:heartbeat_config, agent_id)
      end
    end
  rescue
    _ -> :ok
  end
end
