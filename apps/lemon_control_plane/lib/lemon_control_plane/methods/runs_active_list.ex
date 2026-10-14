defmodule LemonControlPlane.Methods.RunsActiveList do
  @moduledoc """
  Handler for the `runs.active.list` method.

  Lists all currently active runs through the `LemonRouter` facade.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Protocol.Errors

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
    profile_id = get_param(params, "profileId")
    session_key = get_param(params, "sessionKey")
    limit = normalize_limit(get_param(params, "limit"), @default_limit, @max_limit)

    filters = %{
      "agentId" => agent_id,
      "profileId" => profile_id,
      "sessionKey" => session_key,
      "limit" => limit
    }

    case LemonRouter.run_presence(%{
           agent_id: agent_id,
           profile_id: profile_id,
           session_key: session_key
         }) do
      {:ok, %{runs: runs, presence: presence}} ->
        runs = runs |> Enum.take(limit) |> Enum.map(&build_run_entry/1)
        {:ok, response(runs, filters, presence)}

      {:error, _reason} ->
        {:error, Errors.error(:unavailable, "Run presence is unavailable")}
    end
  end

  defp response(runs, filters, presence) do
    %{
      "runs" => runs,
      "total" => length(runs),
      "filters" => filters,
      "summary" => summary(runs, filters),
      "presence" => Map.new(presence, fn {key, value} -> {Atom.to_string(key), value} end)
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

  defp build_run_entry(run) do
    %{
      "runId" => run.run_id,
      "sessionKey" => run.session_key,
      "agentId" => run.agent_id,
      "profileId" => run.profile_id,
      "engine" => "lemon",
      "startedAtMs" => run.started_at_ms,
      "status" => "active"
    }
  end

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
