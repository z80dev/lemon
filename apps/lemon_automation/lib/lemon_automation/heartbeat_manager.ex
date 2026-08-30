defmodule LemonAutomation.HeartbeatManager do
  @moduledoc """
  Manages heartbeat cron jobs with smart response suppression.

  Heartbeats are special cron jobs that check agent health. When an agent
  responds with "HEARTBEAT_OK", the response is suppressed from channels
  but still logged for monitoring.

  ## Suppression Rules (Parity Requirement)

  Responses are suppressed ONLY when they equal exactly "HEARTBEAT_OK" (trimmed).
  This is a strict requirement per parity contract. Any other response
  (including variations like "HEARTBEAT: OK", "Status: OK", etc.) will
  NOT be suppressed and will trigger an alert.

  Suppressed responses:
  - Are NOT broadcast to channels
  - ARE persisted in cron history or the timer heartbeat store
  - ARE counted in metrics
  - Emit a `:heartbeat_suppressed` event

  ## Scheduling and lifecycle

  Intervals that a five-field cron expression can represent exactly use a cron
  job. Other intervals use an Erlang timer even when they are longer than one
  minute; for example, 90 minutes and 5 hours remain exact instead of being
  rounded or converted to uneven cron steps. Reconfiguration disables the old
  mechanism before enabling the new one.

  Timer heartbeats allow at most one in-flight run per agent. Overlapping timer
  ticks are skipped, counted in `stats/0`, logged, and reported through telemetry.
  Every timer terminal result is processed through
  the same suppression path as cron heartbeats and persisted in
  `LemonAgent.Workspace.HeartbeatStore`.

  ## Usage

      # Check if a job is a heartbeat
      HeartbeatManager.heartbeat?(job)

      # Process a response for suppression
      {:ok, suppressed?} = HeartbeatManager.process_response(run, response)

  ## Events

  - `:heartbeat_suppressed` - When a response is suppressed
  - `:heartbeat_alert` - When a heartbeat returns non-OK status
  """

  use GenServer

  alias LemonAutomation.{CronJob, CronManager, CronRun, CronStore, Events, RunCompletionWaiter}
  alias LemonAgent.Workspace.HeartbeatStore
  alias LemonCore.Bus

  require Logger

  # Per parity: suppression ONLY if response equals exactly "HEARTBEAT_OK" (trimmed)
  @heartbeat_ok_exact "HEARTBEAT_OK"
  @task_supervisor LemonAutomation.TaskSupervisor

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Start the HeartbeatManager GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Check if a cron job is configured as a heartbeat.

  A job is a heartbeat if:
  - Its name contains "heartbeat" (case-insensitive)
  - Its meta has `heartbeat: true`
  """
  @spec heartbeat?(CronJob.t()) :: boolean()
  def heartbeat?(%CronJob{} = job) do
    name_match = is_binary(job.name) && String.contains?(String.downcase(job.name), "heartbeat")
    meta_match = is_map(job.meta) && job.meta[:heartbeat] == true

    name_match or meta_match
  end

  @doc """
  Process a heartbeat response to determine if it should be suppressed.

  Returns `{:ok, suppressed?}` where `suppressed?` indicates if the
  response was a healthy heartbeat that should be suppressed.
  """
  @spec process_response(CronRun.t() | map(), binary() | nil) :: {:ok, boolean()}
  def process_response(run, response) when is_map(run) do
    GenServer.call(__MODULE__, {:process_response, run, response})
  end

  @doc """
  Check if a response text indicates a healthy heartbeat.

  Per parity requirement, suppression ONLY happens if the trimmed response
  equals exactly "HEARTBEAT_OK".
  """
  @spec healthy_response?(binary() | nil) :: boolean()
  def healthy_response?(nil), do: false
  def healthy_response?(""), do: false

  def healthy_response?(response) when is_binary(response) do
    # Parity requirement: exact match only (trimmed)
    String.trim(response) == @heartbeat_ok_exact
  end

  @doc """
  Register a custom suppression pattern.
  """
  @spec add_pattern(Regex.t()) :: :ok
  def add_pattern(pattern) do
    GenServer.cast(__MODULE__, {:add_pattern, pattern})
  end

  @doc """
  Get suppression statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Update heartbeat configuration for an agent.

  Called by set-heartbeats control plane method to update config.
  """
  @spec update_config(String.t(), map()) :: :ok | {:error, term()}
  def update_config(agent_id, config) do
    GenServer.call(__MODULE__, {:update_config, agent_id, config})
  end

  @doc false
  @spec scheduling_mode(integer()) :: {:cron, binary()} | :timer | {:error, :invalid_interval}
  def scheduling_mode(interval_ms) when not is_integer(interval_ms) or interval_ms <= 0,
    do: {:error, :invalid_interval}

  def scheduling_mode(interval_ms) when rem(interval_ms, 60_000) != 0, do: :timer

  def scheduling_mode(interval_ms) do
    minutes = div(interval_ms, 60_000)

    cond do
      minutes < 60 and rem(60, minutes) == 0 ->
        {:cron, "*/#{minutes} * * * *"}

      rem(minutes, 60) != 0 ->
        :timer

      div(minutes, 60) == 24 ->
        {:cron, "0 0 * * *"}

      div(minutes, 60) < 24 and rem(24, div(minutes, 60)) == 0 ->
        {:cron, "0 */#{div(minutes, 60)} * * *"}

      true ->
        :timer
    end
  end

  @doc """
  Get heartbeat configuration for an agent.
  """
  @spec get_config(String.t()) :: map() | nil
  def get_config(agent_id) do
    HeartbeatStore.get_config(agent_id)
  end

  @doc """
  Get last heartbeat result for an agent.
  """
  @spec get_last(String.t()) :: map() | nil
  def get_last(agent_id) do
    HeartbeatStore.get_last(agent_id)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    # Subscribe to cron run events
    Bus.subscribe("cron")

    state = %{
      custom_patterns: [],
      active_heartbeats: %{},
      timer_configs: %{},
      in_flight: %{},
      stats: %{
        total_heartbeats: 0,
        suppressed: 0,
        alerts: 0,
        skipped_overlap: 0
      }
    }

    # Restore active heartbeats from stored config
    state = restore_heartbeat_jobs(state)

    Logger.info("[HeartbeatManager] Started")
    {:ok, state}
  end

  # Restore heartbeat jobs from stored configuration on startup
  defp restore_heartbeat_jobs(state) do
    # Get all heartbeat configs from store and schedule jobs
    case HeartbeatStore.list_configs() do
      configs when is_list(configs) ->
        Enum.reduce(configs, state, fn {agent_id, config}, acc ->
          if config[:enabled] || config["enabled"] do
            case schedule_heartbeat_job(agent_id, config, acc) do
              {:ok, next_state} -> next_state
              {:error, _reason, next_state} -> next_state
            end
          else
            acc
          end
        end)

      _ ->
        state
    end
  rescue
    _ -> state
  end

  @impl true
  def handle_call({:process_response, run, response}, _from, state) do
    job_id = Map.get(run, :job_id) || Map.get(run, "job_id")
    run_id = Map.get(run, :id) || Map.get(run, "id")

    job = heartbeat_job(run, job_id)

    if job do
      # Parity: use exact match only
      suppressed = healthy_response?(response)

      # Persist heartbeat_last for last-heartbeat method to read
      agent_id = job.agent_id || "default"

      last_result = %{
        timestamp_ms: System.system_time(:millisecond),
        status: heartbeat_status(run, suppressed),
        terminal_status: run_value(run, :status),
        response: response,
        suppressed: suppressed,
        run_id: run_id,
        router_run_id: run_value(run, :run_id),
        job_id: job_id
      }

      HeartbeatStore.put_last(agent_id, last_result)

      state =
        update_in(state.stats.total_heartbeats, &(&1 + 1))
        |> then(fn s ->
          if suppressed do
            # Mark run as suppressed
            updated_run =
              case run do
                %CronRun{} = r -> CronRun.suppress(r)
                %{} = m -> m |> CronRun.from_map() |> CronRun.suppress()
              end

            if not timer_heartbeat_run?(run), do: CronStore.put_run(updated_run)
            Events.emit_heartbeat_suppressed(updated_run, job)

            update_in(s.stats.suppressed, &(&1 + 1))
          else
            # Non-OK response - emit alert
            Events.emit_heartbeat_alert(run, job, response)
            update_in(s.stats.alerts, &(&1 + 1))
          end
        end)

      {:reply, {:ok, suppressed}, state}
    else
      {:reply, {:ok, false}, state}
    end
  end

  @impl true
  def handle_call({:update_config, agent_id, config}, _from, state) do
    config = merge_heartbeat_config(agent_id, config)
    Logger.debug("[HeartbeatManager] Config updated for agent #{agent_id}: #{inspect(config)}")

    case schedule_heartbeat_job(agent_id, config, state) do
      {:ok, state} ->
        HeartbeatStore.put_config(agent_id, config)
        {:reply, :ok, state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, state.stats, state}
  end

  @impl true
  def handle_cast({:add_pattern, pattern}, state) do
    {:noreply, update_in(state.custom_patterns, &[pattern | &1])}
  end

  # Schedule a heartbeat using cron when the interval maps exactly to the cron
  # grammar, otherwise preserve the exact interval with an OTP timer.
  defp schedule_heartbeat_job(agent_id, config, state) do
    enabled = config[:enabled] || config["enabled"]

    if enabled do
      interval_ms = config[:interval_ms] || config["interval_ms"] || 60_000
      prompt = config[:prompt] || config["prompt"] || "HEARTBEAT"
      session_key = "agent:#{agent_id}:heartbeat"

      case scheduling_mode(interval_ms) do
        :timer ->
          schedule_timer_heartbeat(agent_id, interval_ms, prompt, session_key, state)

        {:cron, schedule} ->
          schedule_cron_heartbeat(
            agent_id,
            interval_ms,
            prompt,
            session_key,
            schedule,
            state
          )

        {:error, reason} ->
          {:error, reason, state}
      end
    else
      state = cancel_timer_heartbeat(agent_id, state)
      disable_cron_heartbeat(agent_id, state)
    end
  end

  defp merge_heartbeat_config(agent_id, config) do
    existing = HeartbeatStore.get_config(agent_id) || %{}
    Map.merge(existing, config)
  rescue
    _ -> config
  end

  # Schedule timer-based heartbeat when cron cannot express the interval exactly.
  defp schedule_timer_heartbeat(agent_id, interval_ms, prompt, session_key, state) do
    state = cancel_timer_heartbeat(agent_id, state)

    case disable_cron_heartbeat(agent_id, state) do
      {:ok, state} ->
        heartbeat_config = %{
          agent_id: agent_id,
          interval_ms: interval_ms,
          prompt: prompt,
          session_key: session_key
        }

        timer_ref = Process.send_after(self(), {:timer_heartbeat, agent_id}, interval_ms)

        Logger.info(
          "[HeartbeatManager] Scheduled timer-based heartbeat for agent #{agent_id} every #{interval_ms}ms"
        )

        state =
          state
          |> put_in([:active_heartbeats, agent_id], {:timer, timer_ref})
          |> put_in([:timer_configs, agent_id], heartbeat_config)

        {:ok, state}

      {:error, reason, state} ->
        {:error, reason, state}
    end
  end

  # Cancel timer-based heartbeat
  defp cancel_timer_heartbeat(agent_id, state) do
    case get_in(state, [:active_heartbeats, agent_id]) do
      {:timer, timer_ref} when is_reference(timer_ref) ->
        Process.cancel_timer(timer_ref)

        state
        |> update_in([:active_heartbeats], &Map.delete(&1 || %{}, agent_id))
        |> update_in([:timer_configs], &Map.delete(&1 || %{}, agent_id))

      _ ->
        state
    end
  end

  # Schedule cron-based heartbeat for exactly representable minute/hour intervals.
  defp schedule_cron_heartbeat(agent_id, interval_ms, prompt, session_key, schedule, state) do
    state = cancel_timer_heartbeat(agent_id, state)

    job_params = %{
      name: "heartbeat-#{agent_id}",
      schedule: schedule,
      enabled: true,
      agent_id: agent_id,
      session_key: session_key,
      prompt: prompt,
      timezone: "UTC",
      jitter_sec: 0,
      timeout_ms: 30_000,
      meta: %{heartbeat: true, agent_id: agent_id, interval_ms: interval_ms}
    }

    # Check if job exists and update, or create new
    existing_job = find_heartbeat_job(agent_id)

    case existing_job do
      nil ->
        # Create new job
        case CronManager.add(job_params) do
          {:ok, job} ->
            Logger.info(
              "[HeartbeatManager] Created heartbeat job for agent #{agent_id}: #{job.id}"
            )

            {:ok, put_in(state, [:active_heartbeats, agent_id], job.id)}

          {:error, reason} ->
            Logger.error("[HeartbeatManager] Failed to create heartbeat job: #{inspect(reason)}")
            {:error, reason, state}
        end

      existing ->
        update_params = %{
          schedule: schedule,
          enabled: true,
          prompt: prompt,
          timezone: "UTC",
          jitter_sec: 0,
          timeout_ms: 30_000,
          meta: %{heartbeat: true, agent_id: agent_id, interval_ms: interval_ms}
        }

        case CronManager.update(existing.id, update_params) do
          {:ok, job} ->
            Logger.info(
              "[HeartbeatManager] Updated heartbeat job for agent #{agent_id}: #{job.id}"
            )

            {:ok, put_in(state, [:active_heartbeats, agent_id], job.id)}

          {:error, reason} ->
            Logger.error("[HeartbeatManager] Failed to update heartbeat job: #{inspect(reason)}")
            {:error, reason, state}
        end
    end
  end

  defp disable_cron_heartbeat(agent_id, state) do
    case find_heartbeat_job(agent_id) do
      %CronJob{enabled: true} = existing ->
        case CronManager.update(existing.id, %{enabled: false}) do
          {:ok, _} ->
            Logger.info("[HeartbeatManager] Disabled heartbeat job for agent #{agent_id}")

            {:ok, update_in(state, [:active_heartbeats], &Map.delete(&1 || %{}, agent_id))}

          {:error, reason} ->
            Logger.error("[HeartbeatManager] Failed to disable heartbeat job: #{inspect(reason)}")
            {:error, {:disable_cron_failed, reason}, state}
        end

      _ ->
        {:ok, update_in(state, [:active_heartbeats], &Map.delete(&1 || %{}, agent_id))}
    end
  end

  # Find an existing heartbeat job for an agent
  defp find_heartbeat_job(agent_id) do
    name = "heartbeat-#{agent_id}"

    CronManager.list()
    |> Enum.find(fn job ->
      # Match by name (most reliable)
      # Match by meta - handle both atom and string keys (JSONL round-trip)
      job.name == name or
        (is_map(job.meta) and
           (job.meta[:heartbeat] == true or job.meta["heartbeat"] == true) and
           (job.meta[:agent_id] == agent_id or job.meta["agent_id"] == agent_id))
    end)
  rescue
    _ -> nil
  end

  @impl true
  def handle_info(%LemonCore.Event{type: :cron_run_completed, payload: payload}, state) do
    case LemonCore.Events.coerce(:cron_run_completed, payload) do
      %LemonCore.Events.CronRunCompleted{run: run, output: response} when not is_nil(run) ->
        # Auto-process completed runs
        _ = start_background_task(fn -> process_response(run, response) end)
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  # Handle timer-based heartbeat execution
  @impl true
  def handle_info({:timer_heartbeat, agent_id}, state) do
    case get_in(state, [:timer_configs, agent_id]) do
      nil ->
        {:noreply, state}

      config ->
        timer_ref = Process.send_after(self(), {:timer_heartbeat, agent_id}, config.interval_ms)
        state = put_in(state, [:active_heartbeats, agent_id], {:timer, timer_ref})

        case get_in(state, [:in_flight, agent_id]) do
          nil ->
            case execute_timer_heartbeat(config) do
              {:ok, pid, synthetic_run_id} ->
                monitor_ref = Process.monitor(pid)

                in_flight = %{
                  pid: pid,
                  monitor_ref: monitor_ref,
                  synthetic_run_id: synthetic_run_id
                }

                {:noreply, put_in(state, [:in_flight, agent_id], in_flight)}

              {:error, reason, synthetic_run} ->
                Logger.error(
                  "[HeartbeatManager] Failed to start timer heartbeat for #{agent_id}: #{inspect(reason)}"
                )

                Events.emit_run_completed(synthetic_run)
                {:noreply, state}
            end

          _in_flight ->
            :telemetry.execute(
              [:lemon, :heartbeat, :skipped],
              %{count: 1},
              %{agent_id: agent_id, reason: :overlap}
            )

            Logger.warning(
              "[HeartbeatManager] Skipped timer heartbeat for #{agent_id}: previous run still in flight"
            )

            {:noreply, update_in(state.stats.skipped_overlap, &(&1 + 1))}
        end
    end
  end

  @impl true
  def handle_info({:timer_heartbeat_finished, agent_id, pid}, state) do
    {:noreply, clear_in_flight(state, agent_id, pid)}
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, pid, _reason}, state) do
    case Enum.find(state.in_flight, fn {_agent_id, run} ->
           run.pid == pid and run.monitor_ref == monitor_ref
         end) do
      {agent_id, _run} -> {:noreply, clear_in_flight(state, agent_id, pid)}
      nil -> {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp execute_timer_heartbeat(config) do
    %{agent_id: agent_id, prompt: prompt, session_key: session_key} = config
    synthetic_run_id = "timer-heartbeat-#{agent_id}-#{System.system_time(:millisecond)}"
    router_run_id = LemonCore.Id.run_id()
    started_at_ms = System.system_time(:millisecond)

    Logger.debug("[HeartbeatManager] Executing timer-based heartbeat for agent #{agent_id}")

    job = timer_heartbeat_job(agent_id, session_key, prompt)

    started_run =
      timer_heartbeat_run(job, synthetic_run_id, :running,
        run_id: router_run_id,
        started_at_ms: started_at_ms
      )

    Events.emit_run_started(started_run, job)
    manager = self()

    case start_background_task(fn ->
           try do
             params = %{
               origin: :cron,
               run_id: router_run_id,
               session_key: session_key,
               prompt: prompt,
               agent_id: agent_id,
               meta: %{
                 heartbeat: true,
                 timer_based: true,
                 synthetic_run_id: synthetic_run_id
               }
             }

             params
             |> RunCompletionWaiter.submit_and_wait(
               router_mod:
                 Application.get_env(:lemon_automation, :heartbeat_router_mod, LemonRouter),
               waiter_mod:
                 Application.get_env(
                   :lemon_automation,
                   :heartbeat_waiter_mod,
                   RunCompletionWaiter
                 ),
               bus_mod: Application.get_env(:lemon_automation, :heartbeat_bus_mod, LemonCore.Bus),
               timeout_ms: 30_000
             )
             |> timer_terminal_run(started_run)
             |> Events.emit_run_completed()
           rescue
             error ->
               started_run
               |> timer_failed_run({:exception, error})
               |> Events.emit_run_completed()
           catch
             :exit, reason ->
               started_run
               |> timer_failed_run({:exit, reason})
               |> Events.emit_run_completed()
           after
             send(manager, {:timer_heartbeat_finished, agent_id, self()})
           end
         end) do
      {:ok, pid} ->
        {:ok, pid, synthetic_run_id}

      {:error, reason} ->
        {:error, reason, timer_failed_run(started_run, {:task_start_failed, reason})}
    end
  end

  defp timer_terminal_run({:ok, run_id, output}, started_run) do
    started_run
    |> Map.put(:run_id, run_id)
    |> CronRun.complete(output)
  end

  defp timer_terminal_run({:error, {:timeout, run_id}}, started_run) do
    started_run
    |> Map.put(:run_id, run_id)
    |> CronRun.timeout()
  end

  defp timer_terminal_run({:error, {:run_failed, run_id, reason}}, started_run) do
    started_run
    |> Map.put(:run_id, run_id)
    |> timer_failed_run(reason)
  end

  defp timer_terminal_run({:error, reason}, started_run),
    do: timer_failed_run(started_run, reason)

  defp timer_failed_run(started_run, reason) do
    error = inspect(reason)

    started_run
    |> CronRun.fail(error)
    |> Map.put(:output, "HEARTBEAT_ERROR: #{error}")
  end

  defp clear_in_flight(state, agent_id, pid) do
    case get_in(state, [:in_flight, agent_id]) do
      %{pid: ^pid, monitor_ref: monitor_ref} ->
        Process.demonitor(monitor_ref, [:flush])
        update_in(state, [:in_flight], &Map.delete(&1 || %{}, agent_id))

      _ ->
        state
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
          "[HeartbeatManager] Failed to start supervised task: #{inspect(reason)}; falling back to Task.start/1"
        )

        Task.start(fun)
    end
  end

  # Timer heartbeats have no CronStore-backed job or run, but they publish on the same
  # "cron" topic as scheduled jobs. Building the same structs the scheduled path uses keeps
  # both emitters on one payload shape instead of two that consumers must guess between.
  defp timer_heartbeat_job(agent_id, session_key, prompt) do
    %CronJob{
      id: "timer-heartbeat-#{agent_id}",
      name: "heartbeat-#{agent_id}",
      schedule: "@timer",
      agent_id: agent_id,
      session_key: session_key,
      prompt: prompt,
      meta: %{heartbeat: true, timer_based: true}
    }
  end

  defp timer_heartbeat_run(%CronJob{} = job, synthetic_run_id, status, attrs) do
    %CronRun{
      id: synthetic_run_id,
      job_id: job.id,
      run_id: Keyword.get(attrs, :run_id),
      status: status,
      started_at_ms: Keyword.get(attrs, :started_at_ms, System.system_time(:millisecond)),
      triggered_by: :schedule,
      output: Keyword.get(attrs, :output),
      error: Keyword.get(attrs, :error),
      meta: %{
        session_key: job.session_key,
        agent_id: job.agent_id,
        heartbeat: true,
        timer_based: true
      }
    }
  end

  defp heartbeat_job(run, job_id) do
    case if(job_id, do: CronStore.get_job(job_id)) do
      %CronJob{} = job ->
        if heartbeat?(job), do: job

      nil ->
        if timer_heartbeat_run?(run) do
          agent_id = run_meta_value(run, :agent_id) || "default"
          session_key = run_meta_value(run, :session_key) || "agent:#{agent_id}:heartbeat"
          timer_heartbeat_job(agent_id, session_key, nil)
        end
    end
  rescue
    _ -> nil
  end

  defp timer_heartbeat_run?(run) do
    run_meta_value(run, :timer_based) == true and run_meta_value(run, :heartbeat) == true
  end

  defp heartbeat_status(run, suppressed) do
    case run_value(run, :status) do
      status when status in [:failed, "failed"] -> :failed
      status when status in [:timeout, "timeout"] -> :timeout
      status when status in [:aborted, "aborted"] -> :aborted
      _ -> if(suppressed, do: :ok, else: :alert)
    end
  end

  defp run_meta_value(run, key), do: run |> run_value(:meta) |> map_value(key)
  defp run_value(run, key), do: map_value(run, key)

  defp map_value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp map_value(_map, _key), do: nil
end
