defmodule LemonControlPlane.Methods.CronAudit do
  @moduledoc """
  Handler for the cron.audit method.

  Returns durable cron lifecycle/audit history.
  """

  @behaviour LemonControlPlane.Method

  @default_limit 100
  @max_limit 1_000

  @impl true
  def name, do: "cron.audit"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}
    limit = normalize_limit(params["limit"])

    filters = [
      limit: limit,
      job_id: normalize_string(params["jobId"] || params["job_id"]),
      run_id: normalize_string(params["runId"] || params["run_id"] || params["cronRunId"]),
      action: normalize_string(params["action"])
    ]

    events =
      filters
      |> LemonAutomation.CronStore.list_audit_events()
      |> maybe_filter_since(normalize_optional_integer(params["sinceMs"] || params["since_ms"]))
      |> Enum.map(&format_event/1)

    response_filters = %{
      "limit" => limit,
      "jobId" => Keyword.get(filters, :job_id),
      "runId" => Keyword.get(filters, :run_id),
      "action" => Keyword.get(filters, :action),
      "sinceMs" => normalize_optional_integer(params["sinceMs"] || params["since_ms"])
    }

    {:ok,
     %{
       "events" => events,
       "total" => length(events),
       "filters" => response_filters,
       "summary" => summary(events, response_filters)
     }}
  end

  defp format_event(event) do
    %{
      "id" => event.id,
      "action" => event.action,
      "tsMs" => event.ts_ms,
      "jobId" => Map.get(event, :job_id),
      "runId" => Map.get(event, :run_id),
      "routerRunId" => Map.get(event, :router_run_id),
      "source" => Map.get(event, :source),
      "status" => Map.get(event, :status),
      "triggeredBy" => Map.get(event, :triggered_by),
      "reason" => Map.get(event, :reason),
      "changedFields" => Map.get(event, :changed_fields, [])
    }
  end

  defp maybe_filter_since(events, nil), do: events

  defp maybe_filter_since(events, since_ms) do
    Enum.filter(events, fn event ->
      is_integer(event.ts_ms) and event.ts_ms >= since_ms
    end)
  end

  defp normalize_limit(value) when is_integer(value) do
    value
    |> max(1)
    |> min(@max_limit)
  end

  defp normalize_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> normalize_limit(parsed)
      _ -> @default_limit
    end
  end

  defp normalize_limit(_), do: @default_limit

  defp normalize_optional_integer(nil), do: nil

  defp normalize_optional_integer(value) when is_integer(value), do: value

  defp normalize_optional_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp normalize_optional_integer(_), do: nil

  defp normalize_string(nil), do: nil
  defp normalize_string(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_string(value) when is_binary(value) and value != "", do: value
  defp normalize_string(_), do: nil

  defp summary(events, filters) do
    %{
      "eventCount" => length(events),
      "actionCounts" => events |> Enum.map(& &1["action"]) |> Enum.frequencies(),
      "filteredByJobId" => present?(filters["jobId"]),
      "filteredByRunId" => present?(filters["runId"]),
      "filteredByAction" => present?(filters["action"]),
      "filteredBySinceMs" => is_integer(filters["sinceMs"]),
      "rawIdsReturned" => true,
      "reasonTextReturned" => Enum.any?(events, &present?(&1["reason"])),
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

  defp present?(value), do: not is_nil(value) and String.trim(to_string(value)) != ""
end
