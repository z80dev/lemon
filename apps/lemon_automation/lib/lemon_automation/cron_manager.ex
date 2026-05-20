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

      # Abort an active cron run
      CronManager.abort_run("run_abc")

      # Get run history
      CronManager.runs("cron_abc", limit: 10)
  """

  use GenServer

  @vsn 1

  alias LemonAutomation.{
    CronCommandRunner,
    CronJob,
    CronRun,
    CronSchedule,
    CronStore,
    Events,
    RunSubmitter
  }

  alias LemonCore.{Bus, Event, RunStore, SessionKey}

  require Logger

  @tick_interval_ms 60_000
  @call_timeout_ms 10_000
  @task_supervisor LemonAutomation.TaskSupervisor
  @forwarded_summary_max_bytes 12_000

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
  - `:timezone` - Timezone for schedule (default: "UTC")
  - `:jitter_sec` - Random delay spread (default: 0)
  - `:timeout_ms` - Execution timeout (default: 300000)
  - `:meta` - Additional metadata
  """
  @spec add(map()) :: {:ok, CronJob.t()} | {:error, term()}
  def add(params) do
    GenServer.call(__MODULE__, {:add, params}, @call_timeout_ms)
  end

  @doc """
  Update an existing cron job.
  """
  @spec update(binary(), map()) ::
          {:ok, CronJob.t()} | {:error, :not_found} | {:error, {:immutable_fields, [atom()]}}
  def update(job_id, params) do
    GenServer.call(__MODULE__, {:update, job_id, params}, @call_timeout_ms)
  end

  @doc """
  Remove a cron job.
  """
  @spec remove(binary()) :: :ok | {:error, :not_found}
  def remove(job_id) do
    GenServer.call(__MODULE__, {:remove, job_id}, @call_timeout_ms)
  end

  @doc """
  Trigger a job to run immediately.
  """
  @spec run_now(binary()) :: {:ok, CronRun.t()} | {:error, :not_found}
  def run_now(job_id) do
    GenServer.call(__MODULE__, {:run_now, job_id}, @call_timeout_ms)
  end

  @doc """
  Abort an active cron run by cron run ID.
  """
  @spec abort_run(binary()) :: {:ok, CronRun.t()} | {:error, :not_found | :not_active}
  def abort_run(run_id) do
    GenServer.call(__MODULE__, {:abort_run, run_id}, @call_timeout_ms)
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
    GenServer.call(__MODULE__, {:runs, job_id, opts}, @call_timeout_ms)
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

    recover_stale_active_runs(jobs)

    # Schedule first tick
    schedule_tick()

    Logger.info("[CronManager] Started with #{length(jobs)} jobs")

    {:ok, %{jobs: Map.new(jobs, &{&1.id, &1}), state_vsn: @vsn}}
  end

  @impl true
  def code_change(old_vsn, state, _extra) do
    {:ok, migrate_state(old_vsn, state)}
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
        job = CronJob.new(params)
        next_run = CronSchedule.next_run_ms(job.schedule, job.timezone)
        job = CronJob.set_next_run(job, next_run)

        CronStore.put_job(job)

        CronStore.record_audit(:job_created, %{
          job_id: job.id,
          source: :cron_manager,
          status: if(job.enabled, do: :enabled, else: :disabled)
        })

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
        case immutable_patch_fields(params) do
          [] ->
            case prepare_update_patch(job, params) do
              {:ok, params} ->
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

                CronStore.record_audit(cron_update_action(job, updated, params), %{
                  job_id: updated.id,
                  source: :cron_manager,
                  status: if(updated.enabled, do: :enabled, else: :disabled),
                  changed_fields: mutable_patch_fields(params)
                })

                Events.emit_job_updated(updated)

                Logger.info("[CronManager] Updated job: #{job_id}")
                {:reply, {:ok, updated}, put_in(state.jobs[job_id], updated)}

              {:error, reason} ->
                {:reply, {:error, {:invalid_schedule, reason}}, state}

              {:invalid_target, reason} ->
                {:reply, {:error, {:invalid_target, reason}}, state}
            end

          fields ->
            {:reply, {:error, {:immutable_fields, fields}}, state}
        end

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:remove, job_id}, _from, state) do
    case Map.fetch(state.jobs, job_id) do
      {:ok, job} ->
        CronStore.delete_job(job_id)

        CronStore.record_audit(:job_deleted, %{
          job_id: job.id,
          source: :cron_manager,
          status: if(job.enabled, do: :enabled, else: :disabled)
        })

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
        CronStore.record_audit(:manual_run_requested, %{
          job_id: job.id,
          source: :cron_manager,
          triggered_by: :manual
        })

        run = execute_job(job, :manual)
        {:reply, {:ok, run}, state}

      :error ->
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
          abort_router_run(run)

          aborted = CronRun.abort(run, "Run aborted by operator")
          CronStore.put_run(aborted)

          CronStore.record_audit(:run_aborted, %{
            job_id: aborted.job_id,
            run_id: aborted.id,
            router_run_id: aborted.run_id,
            source: :cron_manager,
            status: aborted.status,
            triggered_by: aborted.triggered_by,
            reason: aborted.error
          })

          Events.emit_run_completed(aborted)
          maybe_forward_summary_to_base_session(aborted)

          {:reply, {:ok, aborted}, state}
        else
          {:reply, {:error, :not_active}, state}
        end
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
  def handle_info({:execute_job, job_id, triggered_by}, state) do
    state =
      case Map.get(state.jobs, job_id) do
        %CronJob{enabled: true} = job ->
          if triggered_by == :schedule do
            run_scheduled_job(job, state, LemonCore.Clock.now_ms())
          else
            execute_job(job, triggered_by)
            state
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
    with %CronJob{enabled: true} = job <- Map.get(state.jobs, job_id),
         %CronRun{status: :running} = run <- CronStore.get_run(run_id) do
      submit_claimed_run(job, run)
    else
      %CronRun{} = run ->
        Logger.debug(
          "[CronManager] Skipping claimed cron run submit for #{run.id}: status=#{inspect(run.status)}"
        )

      _ ->
        Logger.debug(
          "[CronManager] Skipping claimed cron run submit for #{inspect(run_id)}: job or run unavailable"
        )
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:retry_job, job_id, retry_opts}, state) do
    case Map.get(state.jobs, job_id) do
      %CronJob{enabled: true} = job ->
        if job_active_run_locked?(job) do
          Logger.info("[CronManager] Skipping retry for #{job.id}: active run already exists")
        else
          execute_job(job, :retry, retry_opts)
        end

      _ ->
        Logger.debug("[CronManager] Skipping retry for #{inspect(job_id)}: not found or disabled")
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:run_complete, run_id, result}, state) do
    case CronStore.get_run(run_id) do
      nil ->
        {:noreply, state}

      %CronRun{} = run ->
        if CronRun.finished?(run) do
          {:noreply, state}
        else
          updated_run =
            case result do
              {:ok, output} -> CronRun.complete(run, output)
              {:error, error} -> CronRun.fail(run, error)
              :timeout -> CronRun.timeout(run)
            end

          CronStore.put_run(updated_run)
          Events.emit_run_completed(updated_run)
          maybe_forward_summary_to_base_session(updated_run)
          maybe_schedule_retry(Map.get(state.jobs, updated_run.job_id), updated_run)
          {:noreply, state}
        end
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

  defp abort_router_run(%CronRun{run_id: router_run_id})
       when is_binary(router_run_id) and router_run_id != "" do
    case Process.whereis(LemonRouter.RunRegistry) do
      nil -> :ok
      _pid -> LemonRouter.abort_run(router_run_id, :cron_aborted)
    end
  rescue
    error ->
      Logger.warning("[CronManager] Failed to abort router run: #{Exception.message(error)}")
      :ok
  catch
    :exit, reason ->
      Logger.warning("[CronManager] Failed to abort router run: #{inspect(reason)}")
      :ok
  end

  defp abort_router_run(_run), do: :ok

  defp do_tick(state) do
    now = LemonCore.Clock.now_ms()
    Events.emit_tick(now)

    all_jobs = Map.values(state.jobs)
    recover_stale_active_runs(all_jobs)

    # Find due jobs
    due_jobs =
      all_jobs
      |> Enum.filter(&CronJob.due?/1)

    Enum.reduce(due_jobs, state, fn job, acc ->
      run_scheduled_job(job, acc, now)
    end)
  end

  defp job_active_run_locked?(%CronJob{} = job) do
    CronStore.active_runs(job.id) != []
  rescue
    error ->
      Logger.warning(
        "[CronManager] Failed to check active cron runs for #{job.id}: #{Exception.message(error)}"
      )

      false
  end

  defp recover_stale_active_runs(jobs) when is_list(jobs) do
    now = LemonCore.Clock.now_ms()
    Enum.each(jobs, &recover_stale_active_runs(&1, now))
  end

  defp recover_stale_active_runs(%CronJob{} = job, now) do
    job.id
    |> CronStore.active_runs()
    |> Enum.each(fn run ->
      if stale_run?(run, job, now) do
        timed_out = CronRun.timeout(run)
        CronStore.put_run(timed_out)

        CronStore.record_audit(:stale_run_recovered, %{
          job_id: timed_out.job_id,
          run_id: timed_out.id,
          router_run_id: timed_out.run_id,
          source: :cron_manager,
          status: timed_out.status,
          triggered_by: timed_out.triggered_by,
          reason: timed_out.error
        })

        Events.emit_run_completed(timed_out)

        Logger.warning(
          "[CronManager] Recovered stale active run #{run.id} for job #{job.id} as timeout"
        )
      end
    end)
  rescue
    error ->
      Logger.warning(
        "[CronManager] Failed to recover stale active cron runs for #{job.id}: #{Exception.message(error)}"
      )
  end

  defp stale_run?(%CronRun{started_at_ms: started_at_ms}, %CronJob{timeout_ms: timeout_ms}, now)
       when is_integer(started_at_ms) and is_integer(timeout_ms) and timeout_ms > 0 do
    now - started_at_ms >= timeout_ms
  end

  defp stale_run?(_run, _job, _now), do: false

  defp execute_job(job, triggered_by, opts \\ []) do
    run = CronRun.new(job.id, triggered_by)
    CronStore.put_run(run)

    # Start the run
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
            retry_attempt: retry_attempt,
            retry_root_id: retry_root_id
          })
    }

    run = CronRun.start(run, router_run_id)
    CronStore.put_run(run)

    CronStore.record_audit(:run_started, %{
      job_id: job.id,
      run_id: run.id,
      router_run_id: run.run_id,
      source: :cron_manager,
      status: run.status,
      triggered_by: run.triggered_by
    })

    Events.emit_run_started(run, job)

    submit_claimed_run(job, run)

    run
  end

  defp run_scheduled_job(%CronJob{} = job, state, now) do
    if job_active_run_locked?(job) do
      Logger.info("[CronManager] Skipping scheduled job #{job.id}: active run already exists")
      update_suppressed_scheduled_job(job, state)
    else
      jitter_ms = if job.jitter_sec > 0, do: :rand.uniform(job.jitter_sec * 1000), else: 0
      scheduled_for_ms = job.next_run_at_ms || now || LemonCore.Clock.now_ms()

      case execute_scheduled_job(job, scheduled_for_ms, submit_delay_ms: jitter_ms) do
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
            submit_claimed_run(job, run)
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

  defp submit_claimed_run(%CronJob{} = job, %CronRun{} = run) do
    _ =
      start_background_task(fn ->
        result =
          case CronJob.execution_mode(job) do
            :command -> command_runner().submit(job, run, run_id: run.run_id)
            :agent -> run_submitter().submit(job, run, run_id: run.run_id)
          end

        send(__MODULE__, {:run_complete, run.id, result})
      end)

    :ok
  end

  defp update_suppressed_scheduled_job(%CronJob{} = job, state) do
    CronStore.record_audit(:scheduled_run_suppressed, %{
      job_id: job.id,
      source: :cron_manager,
      triggered_by: :schedule,
      reason: :active_run_exists
    })

    next_run = CronSchedule.next_run_ms(job.schedule, job.timezone)
    updated = CronJob.set_next_run(job, next_run)
    CronStore.put_job(updated)
    put_in(state.jobs[job.id], updated)
  end

  defp mark_claimed_scheduled_job(%CronJob{} = job, state, now) do
    next_run = CronSchedule.next_run_ms(job.schedule, job.timezone)
    updated = job |> CronJob.mark_run(now) |> CronJob.set_next_run(next_run)
    CronStore.put_job(updated)
    put_in(state.jobs[job.id], updated)
  end

  defp reload_job_state(%CronJob{} = job, state) do
    case CronStore.get_job(job.id) do
      %CronJob{} = persisted -> put_in(state.jobs[job.id], persisted)
      _ -> state
    end
  end

  defp maybe_schedule_retry(%CronJob{} = job, %CronRun{} = run) do
    if retryable_run?(run) do
      current_attempt = retry_attempt(run)
      max_retries = max_retries(job)

      if current_attempt < max_retries do
        next_attempt = current_attempt + 1
        delay_ms = retry_delay_ms(job)

        retry_opts = [
          retry_attempt: next_attempt,
          retry_of: run.id,
          retry_root_id: retry_root_id(run),
          source_triggered_by: run.triggered_by
        ]

        Process.send_after(self(), {:retry_job, job.id, retry_opts}, delay_ms)

        CronStore.record_audit(:retry_scheduled, %{
          job_id: job.id,
          run_id: run.id,
          router_run_id: run.run_id,
          source: :cron_manager,
          status: run.status,
          triggered_by: run.triggered_by,
          reason: "retry #{next_attempt}/#{max_retries}"
        })

        Logger.info(
          "[CronManager] Scheduled retry #{next_attempt}/#{max_retries} for job #{job.id} after #{delay_ms}ms"
        )
      end
    end
  end

  defp maybe_schedule_retry(_job, _run), do: :ok

  defp retryable_run?(%CronRun{status: status, triggered_by: triggered_by}) do
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

  defp retry_delay_ms(%CronJob{retry_backoff_ms: value}) when is_integer(value) and value >= 0,
    do: value

  defp retry_delay_ms(_job), do: 30_000

  defp run_submitter do
    Application.get_env(:lemon_automation, :cron_run_submitter, RunSubmitter)
  end

  defp command_runner do
    Application.get_env(:lemon_automation, :cron_command_runner, CronCommandRunner)
  end

  defp router_run_id_for(%CronJob{} = job) do
    case CronJob.execution_mode(job) do
      :agent -> LemonCore.Id.run_id()
      :command -> nil
    end
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
    required = [:name, :schedule]

    missing =
      Enum.filter(required, fn key ->
        is_nil(params[key]) and is_nil(params[Atom.to_string(key)])
      end)

    case missing do
      [] ->
        with {:ok, params} <- validate_execution_target(params),
             {:ok, schedule} <- validate_schedule(params[:schedule] || params["schedule"]) do
          {:ok, Map.put(params, :schedule, schedule)}
        end

      keys ->
        {:error, {:missing_keys, keys}}
    end
  end

  defp validate_schedule(schedule) do
    case CronSchedule.normalize(schedule) do
      {:ok, schedule} ->
        case CronSchedule.parse(schedule) do
          {:ok, _} -> {:ok, schedule}
          {:error, reason} -> {:error, {:invalid_schedule, reason}}
        end

      {:error, reason} ->
        {:error, {:invalid_schedule, reason}}
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

  defp prepare_update_patch(%CronJob{} = job, params) do
    with {:ok, params} <- validate_patch_target(job, params),
         {:ok, params} <- normalize_schedule_patch(params) do
      {:ok, params}
    end
  end

  defp validate_patch_target(%CronJob{} = job, params) do
    mode = CronJob.execution_mode(job)

    cond do
      has_any_key?(params, [:command, "command", :cwd, "cwd", :env, "env"]) and mode != :command ->
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

  defp normalize_schedule_patch(params) do
    schedule = params[:schedule] || params["schedule"]

    if is_binary(schedule) do
      case CronSchedule.normalize(schedule) do
        {:ok, schedule} ->
          normalized =
            params
            |> Map.delete("schedule")
            |> Map.put(:schedule, schedule)

          {:ok, normalized}

        {:error, reason} ->
          {:error, reason}
      end
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

  defp mutable_patch_fields(_), do: []

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
        LemonCore.HeartbeatStore.delete_config(agent_id)
      end
    end
  rescue
    _ -> :ok
  end

  defp migrate_state(_old_vsn, %{jobs: jobs} = state) when is_map(jobs) do
    state
    |> Map.put_new(:jobs, %{})
    |> Map.put(:state_vsn, @vsn)
  end

  defp migrate_state(_old_vsn, _state) do
    %{jobs: %{}, state_vsn: @vsn}
  end

  # Cron runs execute in isolated sub-sessions. To make outcomes visible in the
  # originating main session chat, emit a synthetic run completion there with a
  # concise summary answer and persist it into run history.
  defp maybe_forward_summary_to_base_session(%CronRun{} = run) do
    with {:ok, base_session_key} <- main_session_from_run(run),
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
        meta: %{
          origin: :cron,
          cron_forwarded_summary: true,
          cron_job_id: run.job_id,
          cron_run_id: run.id,
          cron_router_run_id: run.run_id,
          cron_source_session_key: meta_value(run.meta, :session_key)
        }
      }

      RunStore.finalize(forwarded_run_id, summary)

      event =
        Event.new(
          :run_completed,
          %{
            completed: completed,
            duration_ms: run.duration_ms
          },
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

      # For channel_peer sessions (e.g. Telegram topics), also deliver the
      # forwarded answer directly to the channel.  The Bus broadcast above is
      # only received by processes currently subscribed to the session topic,
      # which is typically empty at cron execution time.
      maybe_deliver_summary_to_channel(base_session_key, forwarded_answer, run)
    else
      _ -> :ok
    end
  rescue
    e ->
      Logger.warning("[CronManager] Failed to forward cron summary: #{Exception.message(e)}")
      :ok
  end

  defp main_session_from_run(%CronRun{} = run) do
    base_session_from_run(run)
  end

  defp base_session_from_run(%CronRun{} = run) do
    session_key = meta_value(run.meta, :session_key)

    if is_binary(session_key) do
      case SessionKey.parse(session_key) do
        %{kind: :main} ->
          {:ok, session_key}

        %{kind: :channel_peer} = parsed ->
          base =
            SessionKey.channel_peer(%{
              agent_id: parsed.agent_id,
              channel_id: parsed.channel_id,
              account_id: parsed.account_id,
              peer_kind: parsed.peer_kind,
              peer_id: parsed.peer_id,
              thread_id: parsed.thread_id
            })

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

  defp maybe_deliver_summary_to_channel(session_key, text, %CronRun{} = run) do
    case SessionKey.parse(session_key) do
      %{kind: :channel_peer} = parsed ->
        payload_mod = Module.concat([:"Elixir.LemonChannels", :OutboundPayload])
        delivery_mod = Module.concat([:"Elixir.LemonRouter", :ChannelsDelivery])

        if Code.ensure_loaded?(payload_mod) and Code.ensure_loaded?(delivery_mod) and
             function_exported?(delivery_mod, :enqueue, 2) do
          payload =
            struct!(payload_mod,
              channel_id: parsed.channel_id,
              account_id: parsed.account_id || "default",
              peer: %{
                kind: parsed.peer_kind,
                id: parsed.peer_id,
                thread_id: parsed.thread_id
              },
              kind: :text,
              content: text,
              idempotency_key: "cron_notify_#{run.id}",
              meta: %{
                origin: :cron,
                cron_forwarded_summary: true,
                cron_run_id: run.id,
                cron_job_id: run.job_id
              }
            )

          case delivery_mod.enqueue(payload,
                 context: %{component: :cron_manager, phase: :forwarded_summary}
               ) do
            {:ok, _ref} ->
              :ok

            {:error, reason} ->
              Logger.warning(
                "[CronManager] Failed to enqueue forwarded summary: #{inspect(reason)}"
              )
          end
        end

      _ ->
        :ok
    end
  rescue
    _ -> :ok
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
