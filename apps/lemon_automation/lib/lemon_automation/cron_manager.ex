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

  @vsn 1

  alias LemonAutomation.{CronJob, CronRun, CronStore, CronSchedule, Events, RunSubmitter}
  alias LemonCore.{Bus, Event, SessionKey, Store}

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
        case immutable_patch_fields(params) do
          [] ->
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
  def handle_info({:execute_job, job_id, triggered_by}, state) do
    case Map.get(state.jobs, job_id) do
      %CronJob{enabled: true} = job ->
        execute_job(job, triggered_by)

      _ ->
        Logger.debug(
          "[CronManager] Skipping jittered execute_job for #{inspect(job_id)}: not found or disabled"
        )
    end

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
        maybe_forward_summary_to_base_session(updated_run)
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
    router_run_id = LemonCore.Id.run_id()

    run = %{
      run
      | meta: %{agent_id: job.agent_id, session_key: job.session_key, job_name: job.name}
    }

    run = CronRun.start(run, router_run_id)
    CronStore.put_run(run)
    Events.emit_run_started(run, job)

    # Submit to router asynchronously
    _ =
      start_background_task(fn ->
        result = RunSubmitter.submit(job, run, run_id: router_run_id)
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
        LemonCore.Store.delete(:heartbeat_config, agent_id)
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

      Store.finalize_run(forwarded_run_id, summary)

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
        payload_mod = Module.concat(LemonChannels, OutboundPayload)
        delivery_mod = Module.concat(LemonRouter, ChannelsDelivery)

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
            {:ok, _ref} -> :ok
            {:error, reason} ->
              Logger.warning("[CronManager] Failed to enqueue forwarded summary: #{inspect(reason)}")
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
