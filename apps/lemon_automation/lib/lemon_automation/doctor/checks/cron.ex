defmodule LemonAutomation.Doctor.Checks.Cron do
  @moduledoc "Reports unread cron failures that could not reach a chat."

  alias LemonCore.Doctor.{Check, CronDiagnostics}

  @spec run(keyword()) :: [Check.t()]
  def run(opts \\ []) do
    status = CronDiagnostics.status(opts)
    count = status.unread_failing_job_count

    if count > 0 do
      [
        Check.warn(
          "automation.cron_failures",
          "#{count} failing cron job(s) have unread, undelivered alerts.",
          "Inspect jobs with the cron tool's failing filter, then run `lemon cron runs --job <id>`. " <>
            "Pair an owner chat with `lemon gateway setup` to receive future alerts."
        )
      ]
    else
      [Check.pass("automation.cron_failures", "No unread, undelivered cron failures.")]
    end
  end
end
