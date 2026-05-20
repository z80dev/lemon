defmodule LemonControlPlane.Methods.RunsActiveList do
  @moduledoc """
  Handler for the `runs.active.list` method.

  Lists all currently active runs from `LemonRouter.RunRegistry`.
  """

  @behaviour LemonControlPlane.Method

  @default_limit 100
  @max_limit 200

  @impl true
  def name, do: "runs.active.list"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}

    agent_id = get_param(params, "agentId")
    session_key = get_param(params, "sessionKey")
    limit = normalize_limit(get_param(params, "limit"), @default_limit, @max_limit)

    runs = fetch_active_runs(agent_id, session_key, limit)

    filters = %{
      "agentId" => agent_id,
      "sessionKey" => session_key,
      "limit" => limit
    }

    {:ok, response(runs, filters)}
  rescue
    _ ->
      filters = %{"agentId" => nil, "sessionKey" => nil, "limit" => @default_limit}
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
    started_values =
      runs
      |> Enum.map(& &1["startedAtMs"])
      |> Enum.filter(&is_integer/1)

    %{
      "count" => length(runs),
      "statusCounts" => count_by(runs, "status"),
      "engineCounts" => count_by(runs, "engine"),
      "agentCount" => unique_count(runs, "agentId"),
      "sessionCount" => unique_count(runs, "sessionKey"),
      "oldestStartedAtMs" => min_or_nil(started_values),
      "newestStartedAtMs" => max_or_nil(started_values),
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

  defp fetch_active_runs(agent_id, session_key, limit) do
    if Code.ensure_loaded?(Registry) and Code.ensure_loaded?(LemonRouter.RunRegistry) do
      entries =
        Registry.select(LemonRouter.RunRegistry, [
          {{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}
        ])

      entries
      |> Enum.map(&build_run_entry/1)
      |> Enum.filter(&filter_by_agent(&1, agent_id))
      |> Enum.filter(&filter_by_session(&1, session_key))
      |> Enum.take(limit)
    else
      []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp build_run_entry({run_id, pid, _value}) when is_pid(pid) do
    metadata = fetch_run_metadata(pid)

    %{
      "runId" => run_id,
      "sessionKey" => metadata[:session_key],
      "agentId" => metadata[:agent_id],
      "engine" => metadata[:engine],
      "startedAtMs" => metadata[:started_at_ms],
      "status" => "active"
    }
  end

  defp build_run_entry({run_id, _pid, _value}) do
    %{
      "runId" => run_id,
      "sessionKey" => nil,
      "agentId" => nil,
      "engine" => nil,
      "startedAtMs" => nil,
      "status" => "active"
    }
  end

  defp fetch_run_metadata(pid) when is_pid(pid) do
    GenServer.call(pid, :get_metadata, 1000)
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  defp fetch_run_metadata(_), do: %{}

  defp filter_by_agent(_run, nil), do: true
  defp filter_by_agent(%{"agentId" => agent_id}, filter), do: agent_id == filter
  defp filter_by_agent(_, _), do: false

  defp filter_by_session(_run, nil), do: true
  defp filter_by_session(%{"sessionKey" => session_key}, filter), do: session_key == filter
  defp filter_by_session(_, _), do: false

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

  defp min_or_nil([]), do: nil
  defp min_or_nil(values), do: Enum.min(values)

  defp max_or_nil([]), do: nil
  defp max_or_nil(values), do: Enum.max(values)

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

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
