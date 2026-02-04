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
  - ARE logged to run history
  - ARE counted in metrics
  - Emit a `:heartbeat_suppressed` event

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

  alias LemonAutomation.{CronJob, CronRun, CronStore, CronManager, Events}
  alias LemonCore.Bus

  require Logger

  # Per parity: suppression ONLY if response equals exactly "HEARTBEAT_OK" (trimmed)
  @heartbeat_ok_exact "HEARTBEAT_OK"

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
  @spec process_response(CronRun.t(), binary() | nil) :: {:ok, boolean()}
  def process_response(%CronRun{} = run, response) do
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
  @spec update_config(String.t(), map()) :: :ok
  def update_config(agent_id, config) do
    GenServer.cast(__MODULE__, {:update_config, agent_id, config})
  end

  @doc """
  Get heartbeat configuration for an agent.
  """
  @spec get_config(String.t()) :: map() | nil
  def get_config(agent_id) do
    LemonCore.Store.get(:heartbeat_config, agent_id)
  end

  @doc """
  Get last heartbeat result for an agent.
  """
  @spec get_last(String.t()) :: map() | nil
  def get_last(agent_id) do
    LemonCore.Store.get(:heartbeat_last, agent_id)
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
      stats: %{
        total_heartbeats: 0,
        suppressed: 0,
        alerts: 0
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
    case LemonCore.Store.list(:heartbeat_config) do
      configs when is_list(configs) ->
        Enum.reduce(configs, state, fn {agent_id, config}, acc ->
          if config[:enabled] || config["enabled"] do
            schedule_heartbeat_job(agent_id, config, acc)
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
    job = CronStore.get_job(run.job_id)

    if job && heartbeat?(job) do
      # Parity: use exact match only
      suppressed = healthy_response?(response)

      # Persist heartbeat_last for last-heartbeat method to read
      agent_id = job.agent_id || "default"
      last_result = %{
        timestamp_ms: System.system_time(:millisecond),
        status: if(suppressed, do: :ok, else: :alert),
        response: response,
        suppressed: suppressed,
        run_id: run.id,
        job_id: run.job_id
      }
      LemonCore.Store.put(:heartbeat_last, agent_id, last_result)

      state =
        update_in(state.stats.total_heartbeats, &(&1 + 1))
        |> then(fn s ->
          if suppressed do
            # Mark run as suppressed
            updated_run = CronRun.suppress(run)
            CronStore.put_run(updated_run)
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
  def handle_call(:stats, _from, state) do
    {:reply, state.stats, state}
  end

  @impl true
  def handle_cast({:add_pattern, pattern}, state) do
    {:noreply, update_in(state.custom_patterns, &[pattern | &1])}
  end

  @impl true
  def handle_cast({:update_config, agent_id, config}, state) do
    # Store configuration (set-heartbeats already stores to :heartbeat_config)
    Logger.debug("[HeartbeatManager] Config updated for agent #{agent_id}: #{inspect(config)}")

    # Schedule or cancel heartbeat cron job based on enabled state
    state = schedule_heartbeat_job(agent_id, config, state)

    {:noreply, state}
  end

  # Schedule a heartbeat cron job when enabled, or remove it when disabled
  # Supports both cron-based scheduling (>=60s) and timer-based scheduling (<60s)
  defp schedule_heartbeat_job(agent_id, config, state) do
    _job_id = heartbeat_job_id(agent_id)
    enabled = config[:enabled] || config["enabled"]

    if enabled do
      # Create or update the heartbeat cron job
      interval_ms = config[:interval_ms] || config["interval_ms"] || 60_000
      prompt = config[:prompt] || config["prompt"] || "HEARTBEAT"

      # Session key for heartbeat runs
      session_key = "agent:#{agent_id}:heartbeat"

      # For sub-minute intervals, use timer-based scheduling
      # For intervals >= 60s, use cron-based scheduling with exact seconds
      if interval_ms < 60_000 do
        # Sub-minute interval - use timer-based scheduling
        schedule_timer_heartbeat(agent_id, interval_ms, prompt, session_key, state)
      else
        # Use cron-based scheduling
        schedule_cron_heartbeat(agent_id, interval_ms, prompt, session_key, state)
      end
    else
      # Disable or remove the heartbeat job and cancel any timer
      state = cancel_timer_heartbeat(agent_id, state)

      case find_heartbeat_job(agent_id) do
        nil ->
          state

        existing ->
          case CronManager.update(existing.id, %{enabled: false}) do
            {:ok, _} ->
              Logger.info("[HeartbeatManager] Disabled heartbeat job for agent #{agent_id}")

            {:error, reason} ->
              Logger.error("[HeartbeatManager] Failed to disable heartbeat job: #{inspect(reason)}")
          end

          # Remove from active heartbeats
          update_in(state, [:active_heartbeats], &Map.delete(&1 || %{}, agent_id))
      end
    end
  end

  # Schedule timer-based heartbeat for sub-minute intervals
  defp schedule_timer_heartbeat(agent_id, interval_ms, prompt, session_key, state) do
    # Cancel any existing timer for this agent
    state = cancel_timer_heartbeat(agent_id, state)

    # Store the heartbeat config for timer-based execution
    heartbeat_config = %{
      agent_id: agent_id,
      interval_ms: interval_ms,
      prompt: prompt,
      session_key: session_key
    }

    # Schedule the first timer
    timer_ref = Process.send_after(self(), {:timer_heartbeat, agent_id}, interval_ms)

    Logger.info("[HeartbeatManager] Scheduled timer-based heartbeat for agent #{agent_id} every #{interval_ms}ms")

    state
    |> put_in([:active_heartbeats, agent_id], {:timer, timer_ref})
    |> put_in([:timer_configs, agent_id], heartbeat_config)
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

  # Schedule cron-based heartbeat for intervals >= 60s
  defp schedule_cron_heartbeat(agent_id, interval_ms, prompt, session_key, state) do
    # Cancel any timer-based heartbeat first
    state = cancel_timer_heartbeat(agent_id, state)

    # Build cron schedule from interval - use exact seconds-based schedule
    schedule = build_cron_schedule_from_ms(interval_ms)

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
            Logger.info("[HeartbeatManager] Created heartbeat job for agent #{agent_id}: #{job.id}")
            put_in(state, [:active_heartbeats, agent_id], job.id)

          {:error, reason} ->
            Logger.error("[HeartbeatManager] Failed to create heartbeat job: #{inspect(reason)}")
            state
        end

      existing ->
        # Update existing job
        case CronManager.update(existing.id, job_params) do
          {:ok, job} ->
            Logger.info("[HeartbeatManager] Updated heartbeat job for agent #{agent_id}: #{job.id}")
            put_in(state, [:active_heartbeats, agent_id], job.id)

          {:error, reason} ->
            Logger.error("[HeartbeatManager] Failed to update heartbeat job: #{inspect(reason)}")
            state
        end
    end
  end

  # Find an existing heartbeat job for an agent
  defp find_heartbeat_job(agent_id) do
    job_id = heartbeat_job_id(agent_id)
    name = "heartbeat-#{agent_id}"

    CronManager.list()
    |> Enum.find(fn job ->
      job.id == job_id or job.name == name or
        (is_map(job.meta) and job.meta[:agent_id] == agent_id and job.meta[:heartbeat] == true)
    end)
  rescue
    _ -> nil
  end

  # Generate a consistent job ID for an agent's heartbeat
  defp heartbeat_job_id(agent_id) do
    "heartbeat:#{agent_id}"
  end

  # Build a cron schedule from interval in milliseconds
  # This handles exact intervals without truncation
  defp build_cron_schedule_from_ms(interval_ms) when interval_ms >= 3_600_000 do
    # Run every N hours (interval >= 1 hour)
    hours = div(interval_ms, 3_600_000)
    "0 */#{hours} * * *"
  end

  defp build_cron_schedule_from_ms(interval_ms) when interval_ms >= 60_000 do
    # Run every N minutes
    # Convert to minutes, rounding to nearest minute for cron compatibility
    minutes = div(interval_ms + 30_000, 60_000)
    minutes = max(1, minutes)
    "*/#{minutes} * * * *"
  end

  defp build_cron_schedule_from_ms(_) do
    # Sub-minute intervals shouldn't use cron, but fallback to every minute
    "* * * * *"
  end

  # Legacy function for backwards compatibility
  defp build_cron_schedule(interval_minutes) when interval_minutes >= 60 do
    # Run every N hours
    hours = div(interval_minutes, 60)
    "0 */#{hours} * * *"
  end

  defp build_cron_schedule(interval_minutes) when interval_minutes >= 1 do
    # Run every N minutes
    "*/#{interval_minutes} * * * *"
  end

  defp build_cron_schedule(_) do
    # Default to every minute
    "* * * * *"
  end

  @impl true
  def handle_info(%LemonCore.Event{type: :cron_run_completed} = event, state) do
    run = event.payload[:run]
    response = event.payload[:output]

    if run do
      # Auto-process completed runs
      Task.start(fn ->
        process_response(run, response)
      end)
    end

    {:noreply, state}
  end

  # Handle timer-based heartbeat execution
  @impl true
  def handle_info({:timer_heartbeat, agent_id}, state) do
    case get_in(state, [:timer_configs, agent_id]) do
      nil ->
        # Config was removed, don't reschedule
        {:noreply, state}

      config ->
        # Execute the heartbeat
        execute_timer_heartbeat(config)

        # Reschedule the next heartbeat
        timer_ref = Process.send_after(self(), {:timer_heartbeat, agent_id}, config.interval_ms)
        state = put_in(state, [:active_heartbeats, agent_id], {:timer, timer_ref})

        {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Execute a timer-based heartbeat by triggering a run via LemonRouter
  defp execute_timer_heartbeat(config) do
    %{agent_id: agent_id, prompt: prompt, session_key: session_key} = config

    # Create a synthetic run for this heartbeat
    synthetic_run_id = "timer-heartbeat-#{agent_id}-#{System.system_time(:millisecond)}"

    Logger.debug("[HeartbeatManager] Executing timer-based heartbeat for agent #{agent_id}")

    # Emit run start event
    Bus.broadcast("cron", %LemonCore.Event{
      type: :cron_run_started,
      ts_ms: System.system_time(:millisecond),
      payload: %{
        run: %{
          id: synthetic_run_id,
          job_id: "timer-heartbeat-#{agent_id}",
          agent_id: agent_id,
          session_key: session_key,
          prompt: prompt,
          status: :running
        },
        job: %{
          id: "timer-heartbeat-#{agent_id}",
          name: "heartbeat-#{agent_id}",
          agent_id: agent_id
        }
      }
    })

    # Submit via LemonRouter (the same path CronManager uses)
    Task.start(fn ->
      params = %{
        origin: :cron,
        session_key: session_key,
        prompt: prompt,
        agent_id: agent_id,
        meta: %{
          heartbeat: true,
          timer_based: true,
          synthetic_run_id: synthetic_run_id
        }
      }

      case LemonRouter.submit(params) do
        {:ok, run_id} ->
          # Wait for run completion via LemonCore.Bus events
          result = wait_for_heartbeat_completion(run_id, 30_000)

          case result do
            {:ok, output} ->
              Bus.broadcast("cron", %LemonCore.Event{
                type: :cron_run_completed,
                ts_ms: System.system_time(:millisecond),
                payload: %{
                  run: %{
                    id: synthetic_run_id,
                    job_id: "timer-heartbeat-#{agent_id}",
                    agent_id: agent_id,
                    status: :completed
                  },
                  output: output
                }
              })

            {:error, reason} ->
              Logger.error("[HeartbeatManager] Timer heartbeat failed for #{agent_id}: #{inspect(reason)}")

              Bus.broadcast("cron", %LemonCore.Event{
                type: :cron_run_completed,
                ts_ms: System.system_time(:millisecond),
                payload: %{
                  run: %{
                    id: synthetic_run_id,
                    job_id: "timer-heartbeat-#{agent_id}",
                    agent_id: agent_id,
                    status: :failed
                  },
                  output: "HEARTBEAT_ERROR: #{inspect(reason)}"
                }
              })
          end

        {:error, reason} ->
          Logger.error("[HeartbeatManager] Failed to submit timer heartbeat for #{agent_id}: #{inspect(reason)}")

          Bus.broadcast("cron", %LemonCore.Event{
            type: :cron_run_completed,
            ts_ms: System.system_time(:millisecond),
            payload: %{
              run: %{
                id: synthetic_run_id,
                job_id: "timer-heartbeat-#{agent_id}",
                agent_id: agent_id,
                status: :failed
              },
              output: "HEARTBEAT_ERROR: Failed to submit: #{inspect(reason)}"
            }
          })
      end
    end)
  end

  # Wait for run completion via LemonCore.Bus events
  defp wait_for_heartbeat_completion(run_id, timeout_ms) do
    topic = "run:#{run_id}"

    # Subscribe to run events
    LemonCore.Bus.subscribe(topic)

    try do
      receive do
        %LemonCore.Event{type: :run_completed, payload: payload} ->
          extract_heartbeat_output(payload)

        %LemonCore.Event{type: :run_failed, payload: payload} ->
          error = payload[:error] || payload["error"] || "unknown"
          {:error, error}
      after
        timeout_ms ->
          {:error, :timeout}
      end
    after
      LemonCore.Bus.unsubscribe(topic)
    end
  end

  # Extract output from run completion payload
  defp extract_heartbeat_output(payload) do
    output =
      payload[:output] ||
        payload["output"] ||
        payload[:answer] ||
        payload["answer"] ||
        payload[:result] ||
        payload["result"]

    {:ok, output}
  end
end
