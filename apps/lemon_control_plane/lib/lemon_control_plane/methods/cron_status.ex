defmodule LemonControlPlane.Methods.CronStatus do
  @moduledoc """
  Handler for the cron.status method.

  Returns the overall status of the cron system, including the durable global
  pause (`paused`/`pausedAtMs`) and the independent startup-restoration hold
  (`restorationPending`). Unknown state is represented by `nil`, not `false`:
  when the job list cannot be read `enabled` is `nil`, and each section the
  store cannot answer (`jobs`, `runs`, `audit`) is listed in `unavailable` with
  `nil` counters instead of zeros.
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

  # Each section is read strictly: an unreadable section reports `nil` fields
  # and is named in `unavailable`, never an empty or disabled scheduler.
  defp get_cron_status do
    if Code.ensure_loaded?(LemonAutomation.CronManager) do
      jobs = read_jobs()

      runs =
        LemonAutomation.CronStore.list_all_runs(limit: 2_000, strict: true) |> readable()

      audit =
        LemonAutomation.CronStore.list_audit_events(limit: 2_000, strict: true) |> readable()

      %{"enabled" => if(is_list(jobs), do: true)}
      |> Map.merge(job_fields(jobs))
      |> Map.merge(run_fields(runs))
      |> Map.merge(audit_fields(audit))
      |> Map.merge(pause_fields())
      |> Map.put("unavailable", unavailable_sections(jobs: jobs, runs: runs, audit: audit))
    else
      %{
        "enabled" => false,
        "jobCount" => 0,
        "activeJobs" => 0,
        "failingJobs" => 0,
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
        "lastRunAtMs" => nil,
        "paused" => nil,
        "pausedAtMs" => nil,
        "restorationPending" => nil,
        "unavailable" => []
      }
    end
  end

  defp read_jobs do
    case LemonAutomation.CronManager.list() do
      jobs when is_list(jobs) -> jobs
      _unexpected -> :unavailable
    end
  catch
    :exit, _reason -> :unavailable
  end

  defp readable({:ok, values}) when is_list(values), do: values
  defp readable(_error), do: :unavailable

  defp job_fields(:unavailable) do
    %{"jobCount" => nil, "activeJobs" => nil, "failingJobs" => nil, "nextRunAtMs" => nil}
  end

  defp job_fields(jobs) do
    %{
      "jobCount" => length(jobs),
      "activeJobs" => Enum.count(jobs, & &1.enabled),
      "failingJobs" => Enum.count(jobs, &(LemonAutomation.CronJob.failure_streak(&1) > 0)),
      "nextRunAtMs" => get_next_run(jobs)
    }
  end

  defp run_fields(:unavailable) do
    %{
      "activeRunCount" => nil,
      "recentRunCount" => nil,
      "failedRunCount" => nil,
      "retryRunCount" => nil,
      "runStatusCounts" => nil,
      "triggerCounts" => nil,
      "lastRunAtMs" => nil
    }
  end

  defp run_fields(runs) do
    %{
      "activeRunCount" => Enum.count(runs, &LemonAutomation.CronRun.active?/1),
      "recentRunCount" => length(runs),
      "failedRunCount" => Enum.count(runs, &(&1.status in [:failed, :timeout])),
      "retryRunCount" => Enum.count(runs, &retry_run?/1),
      "runStatusCounts" => count_by(runs, &to_string(&1.status)),
      "triggerCounts" => count_by(runs, &to_string(&1.triggered_by)),
      "lastRunAtMs" =>
        runs
        |> Enum.map(& &1.started_at_ms)
        |> Enum.reject(&is_nil/1)
        |> Enum.max(fn -> nil end)
    }
  end

  defp audit_fields(:unavailable) do
    %{
      "suppressedSlotCount" => nil,
      "staleRecoveryCount" => nil,
      "retryScheduledCount" => nil,
      "auditActionCounts" => nil
    }
  end

  defp audit_fields(events) do
    %{
      "suppressedSlotCount" => Enum.count(events, &(&1.action == "scheduled_run_suppressed")),
      "staleRecoveryCount" => Enum.count(events, &(&1.action == "stale_run_recovered")),
      "retryScheduledCount" => Enum.count(events, &(&1.action == "retry_scheduled")),
      "auditActionCounts" => count_by(events, & &1.action)
    }
  end

  defp unavailable_sections(sections) do
    for {name, :unavailable} <- sections, do: Atom.to_string(name)
  end

  defp pause_fields do
    case LemonAutomation.CronManager.pause_status() do
      {:ok, %{paused: paused, paused_at_ms: paused_at_ms} = status} ->
        %{
          "paused" => paused,
          "pausedAtMs" => paused_at_ms,
          "restorationPending" => Map.get(status, :restoration_pending)
        }

      _unknown ->
        %{"paused" => nil, "pausedAtMs" => nil, "restorationPending" => nil}
    end
  catch
    :exit, _reason ->
      %{"paused" => nil, "pausedAtMs" => nil, "restorationPending" => nil}
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
      "enabled" => status["enabled"],
      "paused" => status["paused"],
      "restorationPending" => status["restorationPending"],
      "jobCount" => status["jobCount"],
      "activeJobCount" => status["activeJobs"],
      "failingJobs" => status["failingJobs"],
      "activeRunCount" => status["activeRunCount"],
      "recentRunCount" => status["recentRunCount"],
      "failedRunCount" => status["failedRunCount"],
      "retryRunCount" => status["retryRunCount"],
      "suppressedSlotCount" => status["suppressedSlotCount"],
      "staleRecoveryCount" => status["staleRecoveryCount"],
      "retryScheduledCount" => status["retryScheduledCount"],
      "unavailable" => status["unavailable"],
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
