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
    {:ok, status}
  end

  defp get_cron_status do
    # Try LemonAutomation.CronManager if available
    if Code.ensure_loaded?(LemonAutomation.CronManager) do
      jobs = LemonAutomation.CronManager.list()
      all_runs = LemonAutomation.CronStore.list_all_runs(limit: 2_000)
      active_runs = Enum.filter(all_runs, &LemonAutomation.CronRun.active?/1)

      %{
        "enabled" => true,
        "jobCount" => length(jobs),
        "activeJobs" => Enum.count(jobs, & &1.enabled),
        "nextRunAtMs" => get_next_run(jobs),
        "activeRunCount" => length(active_runs),
        "recentRunCount" => length(all_runs),
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
end
