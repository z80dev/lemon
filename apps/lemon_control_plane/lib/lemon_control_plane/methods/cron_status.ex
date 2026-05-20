defmodule LemonControlPlane.Methods.CronStatus do
  @moduledoc """
  Handler for the cron.status method.

  Returns the overall status of the cron system.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "cron.status"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(_params, _ctx) do
    status = get_cron_status()
    {:ok, Map.put(status, "summary", summary(status))}
  end

  defp get_cron_status do
    # Try LemonAutomation.CronManager if available
    if Code.ensure_loaded?(LemonAutomation.CronManager) do
      jobs = LemonAutomation.CronManager.list()
      all_runs = LemonAutomation.CronStore.list_all_runs(limit: 2_000)
      active_runs = Enum.filter(all_runs, &LemonAutomation.CronRun.active?/1)
      audit_events = LemonAutomation.CronStore.list_audit_events(limit: 2_000)

      %{
        "enabled" => true,
        "jobCount" => length(jobs),
        "activeJobs" => Enum.count(jobs, & &1.enabled),
        "nextRunAtMs" => get_next_run(jobs),
        "activeRunCount" => length(active_runs),
        "recentRunCount" => length(all_runs),
        "failedRunCount" => Enum.count(all_runs, &(&1.status in [:failed, :timeout])),
        "retryRunCount" => Enum.count(all_runs, &retry_run?/1),
        "suppressedSlotCount" =>
          Enum.count(audit_events, &(&1.action == "scheduled_run_suppressed")),
        "staleRecoveryCount" => Enum.count(audit_events, &(&1.action == "stale_run_recovered")),
        "retryScheduledCount" => Enum.count(audit_events, &(&1.action == "retry_scheduled")),
        "runStatusCounts" => count_by(all_runs, &to_string(&1.status)),
        "triggerCounts" => count_by(all_runs, &to_string(&1.triggered_by)),
        "auditActionCounts" => count_by(audit_events, & &1.action),
        "lastRunAtMs" =>
          all_runs
          |> Enum.map(& &1.started_at_ms)
          |> Enum.reject(&is_nil/1)
          |> Enum.max(fn -> nil end)
      }
    else
      %{
        "enabled" => false,
        "jobCount" => 0,
        "activeJobs" => 0,
        "nextRunAtMs" => nil,
        "activeRunCount" => 0,
        "recentRunCount" => 0,
        "failedRunCount" => 0,
        "retryRunCount" => 0,
        "suppressedSlotCount" => 0,
        "staleRecoveryCount" => 0,
        "retryScheduledCount" => 0,
        "runStatusCounts" => %{},
        "triggerCounts" => %{},
        "auditActionCounts" => %{},
        "lastRunAtMs" => nil
      }
    end
  rescue
    _ ->
      %{
        "enabled" => false,
        "jobCount" => 0,
        "activeJobs" => 0,
        "nextRunAtMs" => nil,
        "activeRunCount" => 0,
        "recentRunCount" => 0,
        "failedRunCount" => 0,
        "retryRunCount" => 0,
        "suppressedSlotCount" => 0,
        "staleRecoveryCount" => 0,
        "retryScheduledCount" => 0,
        "runStatusCounts" => %{},
        "triggerCounts" => %{},
        "auditActionCounts" => %{},
        "lastRunAtMs" => nil
      }
  end

  defp get_next_run(jobs) do
    jobs
    |> Enum.filter(& &1.enabled)
    |> Enum.map(& &1.next_run_at_ms)
    |> Enum.reject(&is_nil/1)
    |> Enum.min(fn -> nil end)
  end

  defp retry_run?(%LemonAutomation.CronRun{triggered_by: :retry}), do: true

  defp retry_run?(%LemonAutomation.CronRun{meta: meta}) when is_map(meta) do
    case Map.get(meta, :retry_attempt) || Map.get(meta, "retry_attempt") do
      value when is_integer(value) and value > 0 -> true
      _ -> false
    end
  end

  defp retry_run?(_run), do: false

  defp count_by(values, fun) do
    values
    |> Enum.map(fun)
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
  end

  defp summary(status) do
    %{
      "enabled" => status["enabled"] == true,
      "jobCount" => status["jobCount"] || 0,
      "activeJobCount" => status["activeJobs"] || 0,
      "activeRunCount" => status["activeRunCount"] || 0,
      "recentRunCount" => status["recentRunCount"] || 0,
      "failedRunCount" => status["failedRunCount"] || 0,
      "retryRunCount" => status["retryRunCount"] || 0,
      "suppressedSlotCount" => status["suppressedSlotCount"] || 0,
      "staleRecoveryCount" => status["staleRecoveryCount"] || 0,
      "retryScheduledCount" => status["retryScheduledCount"] || 0,
      "cleanup" => %{
        "includesPromptText" => false,
        "includesCommandText" => false,
        "includesOutputText" => false,
        "includesErrorText" => false,
        "includesMessageBodies" => false,
        "includesCredentials" => false,
        "includesSecretValues" => false
      }
    }
  end
end
