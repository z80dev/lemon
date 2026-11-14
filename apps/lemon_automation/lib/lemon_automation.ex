defmodule LemonAutomation do
  @moduledoc """
  LemonAutomation provides scheduled and triggered automation for agents.

  This app handles:

  - **Cron Jobs** - Scheduled agent runs with cron expressions
  - **Heartbeats** - Cron jobs flagged `meta.heartbeat: true` whose all-clear replies are suppressed
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
        timezone: "local"
      })

  ## Delivery

  A finished run's result is sent to the originating Telegram/Discord chat, an
  explicit `deliver_to` target, or - for jobs created from the TUI, web, CLI or
  any other non-chat session - the paired owner chat. `deliver_to: "none"`
  opts out. See `LemonAutomation.CronDelivery`.

  ## Heartbeats

  A heartbeat is a cron job with `meta.heartbeat: true`. A reply of exactly
  `HEARTBEAT_OK` is suppressed (kept in run history, not delivered); anything
  else is delivered. See `LemonAutomation.Heartbeat`.

  ## Wake

  Wake allows triggering any cron job to run immediately:

      LemonAutomation.CronManager.wake("cron_abc123")

  ## Events

  All automation activities emit events on the Bus:

  - `:cron_tick` - Scheduled tick occurred
  - `:cron_run_started` - Job execution began
  - `:cron_run_completed` - Job execution finished
  - `:heartbeat_suppressed` - Heartbeat response was suppressed

  ## Architecture

  ```
  [CronManager] --tick--> [RunSubmitter] --submit--> [LemonRouter]
       |
       +--terminal run--> [Heartbeat policy] --> [CronDelivery] --> [LemonChannels]
       |
       v
  [Events] --> [Bus]
  ```
  """
end
