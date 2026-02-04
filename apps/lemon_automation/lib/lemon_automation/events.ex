defmodule LemonAutomation.Events do
  @moduledoc """
  Event emission for cron and automation activities.

  All automation events are broadcast on the "cron" topic via LemonCore.Bus.
  Events use the standard LemonCore.Event envelope.

  ## Event Types

  ### Tick Events
  - `:cron_tick` - Scheduled tick occurred (every minute)

  ### Job Lifecycle Events
  - `:cron_job_created` - New job was added
  - `:cron_job_updated` - Job configuration changed
  - `:cron_job_deleted` - Job was removed

  ### Run Lifecycle Events
  - `:cron_run_started` - Job execution began
  - `:cron_run_completed` - Job execution finished (success or failure)

  ### Heartbeat Events
  - `:heartbeat_suppressed` - Healthy heartbeat response was suppressed
  - `:heartbeat_alert` - Heartbeat returned non-OK status

  ## Subscribing

      LemonCore.Bus.subscribe("cron")

      receive do
        %LemonCore.Event{type: :cron_run_started, payload: payload} ->
          IO.puts("Run started: \#{payload.run.id}")
      end
  """

  alias LemonCore.{Bus, Event}
  alias LemonAutomation.{CronJob, CronRun}

  @topic "cron"

  # ============================================================================
  # Tick Events
  # ============================================================================

  @doc """
  Emit a cron tick event.
  """
  @spec emit_tick(non_neg_integer()) :: :ok
  def emit_tick(timestamp_ms) do
    event = Event.new(:cron_tick, %{timestamp_ms: timestamp_ms})
    Bus.broadcast(@topic, event)
  end

  # ============================================================================
  # Job Lifecycle Events
  # ============================================================================

  @doc """
  Emit event when a job is created.
  """
  @spec emit_job_created(CronJob.t()) :: :ok
  def emit_job_created(%CronJob{} = job) do
    event =
      Event.new(
        :cron_job_created,
        %{job: CronJob.to_map(job)},
        %{job_id: job.id, agent_id: job.agent_id}
      )

    Bus.broadcast(@topic, event)
  end

  @doc """
  Emit event when a job is updated.
  """
  @spec emit_job_updated(CronJob.t()) :: :ok
  def emit_job_updated(%CronJob{} = job) do
    event =
      Event.new(
        :cron_job_updated,
        %{job: CronJob.to_map(job)},
        %{job_id: job.id, agent_id: job.agent_id}
      )

    Bus.broadcast(@topic, event)
  end

  @doc """
  Emit event when a job is deleted.
  """
  @spec emit_job_deleted(CronJob.t()) :: :ok
  def emit_job_deleted(%CronJob{} = job) do
    event =
      Event.new(
        :cron_job_deleted,
        %{job_id: job.id, name: job.name},
        %{job_id: job.id, agent_id: job.agent_id}
      )

    Bus.broadcast(@topic, event)
  end

  # ============================================================================
  # Run Lifecycle Events
  # ============================================================================

  @doc """
  Emit event when a run starts.
  """
  @spec emit_run_started(CronRun.t(), CronJob.t()) :: :ok
  def emit_run_started(%CronRun{} = run, %CronJob{} = job) do
    event =
      Event.new(
        :cron_run_started,
        %{
          run: CronRun.to_map(run),
          job_name: job.name,
          agent_id: job.agent_id,
          triggered_by: run.triggered_by
        },
        %{
          job_id: job.id,
          run_id: run.id,
          agent_id: job.agent_id,
          session_key: job.session_key
        }
      )

    Bus.broadcast(@topic, event)
  end

  @doc """
  Emit event when a run completes (success or failure).
  """
  @spec emit_run_completed(CronRun.t()) :: :ok
  def emit_run_completed(%CronRun{} = run) do
    event =
      Event.new(
        :cron_run_completed,
        %{
          run: CronRun.to_map(run),
          status: run.status,
          duration_ms: run.duration_ms,
          output: run.output,
          error: run.error,
          suppressed: run.suppressed
        },
        %{
          job_id: run.job_id,
          run_id: run.id
        }
      )

    Bus.broadcast(@topic, event)
  end

  # ============================================================================
  # Heartbeat Events
  # ============================================================================

  @doc """
  Emit event when a heartbeat response is suppressed.
  """
  @spec emit_heartbeat_suppressed(CronRun.t(), CronJob.t()) :: :ok
  def emit_heartbeat_suppressed(%CronRun{} = run, %CronJob{} = job) do
    event =
      Event.new(
        :heartbeat_suppressed,
        %{
          run_id: run.id,
          job_id: job.id,
          job_name: job.name,
          agent_id: job.agent_id
        },
        %{
          job_id: job.id,
          run_id: run.id,
          agent_id: job.agent_id
        }
      )

    Bus.broadcast(@topic, event)
  end

  @doc """
  Emit alert when a heartbeat returns non-OK status.
  """
  @spec emit_heartbeat_alert(CronRun.t(), CronJob.t(), binary() | nil) :: :ok
  def emit_heartbeat_alert(%CronRun{} = run, %CronJob{} = job, response) do
    event =
      Event.new(
        :heartbeat_alert,
        %{
          run_id: run.id,
          job_id: job.id,
          job_name: job.name,
          agent_id: job.agent_id,
          response: response,
          severity: :warning
        },
        %{
          job_id: job.id,
          run_id: run.id,
          agent_id: job.agent_id
        }
      )

    Bus.broadcast(@topic, event)
  end
end
