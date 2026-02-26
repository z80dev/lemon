defmodule LemonAutomation do
  @moduledoc """
  LemonAutomation provides scheduled and triggered automation for agents.

  This app handles:

  - **Cron Jobs** - Scheduled agent runs with cron expressions
  - **Heartbeats** - Periodic health checks with smart suppression
  - **Wake** - Immediate trigger for scheduled jobs

  ## Cron Jobs

  Cron jobs allow scheduling agent prompts to run at specified intervals:

      # Create a daily status check
      {:ok, job} = LemonAutomation.CronManager.add(%{
        name: "Daily Status",
        schedule: "0 9 * * *",
        agent_id: "agent_abc",
        session_key: "agent:agent_abc:main",
        prompt: "Generate a daily status report",
        timezone: "America/New_York"
      })

  ## Heartbeats

  Heartbeats are special cron jobs that check agent health. They support
  automatic suppression when the agent responds with "HEARTBEAT_OK":

      # Responses containing "HEARTBEAT_OK" are suppressed from channels
      # but still logged for monitoring purposes

  ## Wake

  Wake allows triggering any cron job to run immediately:

      LemonAutomation.Wake.trigger("cron_abc123")

  ## Events

  All automation activities emit events on the Bus:

  - `:cron_tick` - Scheduled tick occurred
  - `:cron_run_started` - Job execution began
  - `:cron_run_completed` - Job execution finished
  - `:heartbeat_suppressed` - Heartbeat response was suppressed

  ## Architecture

  ```
  [CronManager] --tick--> [Wake] --submit--> [LemonRouter]
       |                    ^
       v                    |
  [HeartbeatManager] ------+
       |
       v
  [Events] --> [Bus]
  ```
  """

  @doc """
  List all cron jobs.
  """
  defdelegate list_jobs(), to: LemonAutomation.CronManager, as: :list

  @doc """
  Add a new cron job.
  """
  defdelegate add_job(params), to: LemonAutomation.CronManager, as: :add

  @doc """
  Update an existing cron job.
  """
  defdelegate update_job(id, params), to: LemonAutomation.CronManager, as: :update

  @doc """
  Remove a cron job.
  """
  defdelegate remove_job(id), to: LemonAutomation.CronManager, as: :remove

  @doc """
  Trigger a job to run immediately.
  """
  defdelegate run_now(id), to: LemonAutomation.CronManager

  @doc """
  Get run history for a job.
  """
  defdelegate runs(job_id, opts \\ []), to: LemonAutomation.CronManager

  @doc """
  Wake/trigger a job immediately.
  """
  defdelegate wake(job_id), to: LemonAutomation.Wake, as: :trigger
end
