defmodule LemonControlPlane.Methods.RunsRecentList do
  @moduledoc """
  Handler for the `runs.recent.list` method.

  Lists recent completed/error/aborted runs using `LemonCore.Introspection.list/1`.
  """

  @behaviour LemonControlPlane.Method

  @default_limit 50
  @max_limit 200

  @impl true
  def name, do: "runs.recent.list"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}

    agent_id = get_param(params, "agentId")
    session_key = get_param(params, "sessionKey")
    limit = normalize_limit(get_param(params, "limit"), @default_limit, @max_limit)
    status_filter = get_param(params, "status")

    runs = fetch_recent_runs(agent_id, session_key, limit, status_filter)

    filters = %{
      "agentId" => agent_id,
      "sessionKey" => session_key,
      "limit" => limit,
      "status" => status_filter
    }

    {:ok, response(runs, filters)}
  rescue
    _ ->
      filters = %{
        "agentId" => nil,
        "sessionKey" => nil,
        "limit" => @default_limit,
        "status" => nil
      }

      {:ok, response([], filters)}
  end

  defp response(runs, filters) do
    %{
      "runs" => runs,
      "total" => length(runs),
      "filters" => filters,
      "summary" => summary(runs, filters)
    }
  end

  defp summary(runs, filters) do
    durations =
      runs
      |> Enum.map(& &1["durationMs"])
      |> Enum.filter(&(is_integer(&1) and &1 >= 0))

    %{
      "count" => length(runs),
      "statusCounts" => count_by(runs, "status"),
      "engineCounts" => count_by(runs, "engine"),
      "agentCount" => unique_count(runs, "agentId"),
      "sessionCount" => unique_count(runs, "sessionKey"),
      "okCount" => Enum.count(runs, &(&1["ok"] == true)),
      "errorCount" => Enum.count(runs, &(&1["status"] == "error")),
      "abortedCount" => Enum.count(runs, &(&1["status"] == "aborted")),
      "averageDurationMs" => average_or_nil(durations),
      "filtersApplied" => filters_applied(filters),
      "cleanup" => %{
        "includesRunEvents" => false,
        "includesRunRecords" => false,
        "includesMessageBodies" => false,
        "includesCredentials" => false,
        "includesSecretValues" => false
      }
    }
  end

  defp fetch_recent_runs(agent_id, session_key, limit, status_filter) do
    if Code.ensure_loaded?(LemonCore.Introspection) do
      query_opts =
        [event_type: :run_completed, limit: limit]
        |> maybe_add_opt(:agent_id, agent_id)
        |> maybe_add_opt(:session_key, session_key)

      LemonCore.Introspection.list(query_opts)
      |> Enum.map(&format_run_event/1)
      |> Enum.filter(&filter_by_status(&1, status_filter))
    else
      []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp format_run_event(event) when is_map(event) do
    payload = event[:payload] || event["payload"] || %{}
    ok = payload[:ok] || payload["ok"]
    error = payload[:error] || payload["error"]
    duration_ms = payload[:duration_ms] || payload["duration_ms"]

    status =
      cond do
        ok == true -> "completed"
        error in [:user_requested, :interrupted, :aborted] -> "aborted"
        error == :aborted -> "aborted"
        true -> "error"
      end

    %{
      "runId" => event[:run_id] || event["run_id"],
      "sessionKey" => event[:session_key] || event["session_key"],
      "agentId" => event[:agent_id] || event["agent_id"],
      "engine" => event[:engine] || event["engine"],
      "startedAtMs" => started_at_ms(event, duration_ms),
      "completedAtMs" => event[:ts_ms] || event["ts_ms"],
      "status" => status,
      "durationMs" => duration_ms,
      "ok" => ok == true
    }
  end

  defp format_run_event(_), do: nil

  defp started_at_ms(event, duration_ms) do
    ts_ms = event[:ts_ms] || event["ts_ms"]

    if is_integer(ts_ms) and is_integer(duration_ms) and duration_ms >= 0 do
      ts_ms - duration_ms
    else
      nil
    end
  end

  defp filter_by_status(_run, nil), do: true
  defp filter_by_status(nil, _filter), do: false
  defp filter_by_status(%{"status" => status}, filter), do: status == filter
  defp filter_by_status(_, _), do: false

  defp count_by(rows, key) do
    rows
    |> Enum.map(& &1[key])
    |> Enum.reject(&blank?/1)
    |> Enum.frequencies()
  end

  defp unique_count(rows, key) do
    rows
    |> Enum.map(& &1[key])
    |> Enum.reject(&blank?/1)
    |> MapSet.new()
    |> MapSet.size()
  end

  defp filters_applied(filters) do
    filters
    |> Enum.reject(fn {key, value} -> key == "limit" or blank?(value) end)
    |> Enum.map(fn {key, _value} -> key end)
    |> Enum.sort()
  end

  defp average_or_nil([]), do: nil
  defp average_or_nil(values), do: div(Enum.sum(values), length(values))

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp normalize_limit(limit, _default, max) when is_integer(limit) and limit > 0,
    do: min(limit, max)

  defp normalize_limit(limit, default, max) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, _} when parsed > 0 -> min(parsed, max)
      _ -> default
    end
  end

  defp normalize_limit(_, default, _), do: default

  defp get_param(params, key) when is_map(params) and is_binary(key) do
    underscored = Macro.underscore(key)

    cond do
      Map.has_key?(params, key) -> Map.get(params, key)
      Map.has_key?(params, underscored) -> Map.get(params, underscored)
      true -> nil
    end
  end

  defp get_param(_params, _key), do: nil
end
