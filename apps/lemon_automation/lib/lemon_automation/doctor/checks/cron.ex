defmodule LemonAutomation.Doctor.Checks.Cron do
  @moduledoc "Reports undelivered cron failures, a global pause, and pending schedule restoration."

  alias LemonAutomation.CronManager
  alias LemonCore.Doctor.{Check, CronDiagnostics}

  @spec run(keyword()) :: [Check.t()]
  def run(opts \\ []) do
    failure_check(opts) ++ pause_check(Keyword.get(opts, :runtime, :local))
  end

  defp failure_check(opts) do
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

  # A pause is deliberate, but forgetting it silently stops every reminder and
  # heartbeat, so it is always surfaced. A standalone CLI has no CronManager of
  # its own; there an absent manager says nothing about the runtime's.
  defp pause_check(runtime) when runtime in [:external, :absent] do
    if GenServer.whereis(CronManager) do
      pause_check(:local)
    else
      [Check.outside_runtime("automation.cron_paused", "the cron pause state", runtime)]
    end
  end

  defp pause_check(:local) do
    case pause_status() do
      {:ok, %{restoration_pending: true}} ->
        [
          Check.warn(
            "automation.cron_paused",
            "Cron schedule restoration is pending; scheduled runs, retries, and wake triggers are held back.",
            "Check the runtime store's health; dispatch resumes after schedule restoration succeeds."
          )
        ]

      {:ok, %{paused: false}} ->
        []

      {:ok, %{paused: true}} ->
        [
          Check.warn(
            "automation.cron_paused",
            "All cron jobs are paused; no scheduled run will start.",
            "Run `lemon cron resume --all` to resume. Runs missed during the pause are skipped."
          )
        ]

      {:error, _reason} ->
        [
          Check.warn(
            "automation.cron_paused",
            "The cron pause state could not be read; scheduled runs are held back.",
            "Check the runtime store's health, then run `lemon doctor` again."
          )
        ]
    end
  end

  defp pause_status do
    CronManager.pause_status()
  catch
    :exit, _reason -> {:error, :unavailable}
  end
end
