defmodule LemonControlPlane.Methods.SessionsList do
  @moduledoc """
  Handler for the sessions.list method.

  Lists all sessions with optional filtering and pagination.
  """

  @behaviour LemonControlPlane.Method

  @default_limit 100
  @default_offset 0

  @impl true
  def name, do: "sessions.list"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}
    limit = normalize_positive(get_param(params, "limit"), @default_limit)
    offset = normalize_non_negative(get_param(params, "offset"), @default_offset)
    agent_id = get_param(params, "agentId")

    sessions =
      get_sessions_index()
      |> Enum.map(fn {_key, session} -> session end)
      |> maybe_filter_by_agent(agent_id)
      |> Enum.sort_by(& &1[:updated_at_ms], :desc)

    total = length(sessions)

    paginated =
      sessions
      |> Enum.drop(offset)
      |> Enum.take(limit)
      |> Enum.map(&format_session/1)

    filters = %{"agentId" => agent_id, "limit" => limit, "offset" => offset}

    {:ok,
     %{
       "sessions" => paginated,
       "total" => total,
       "filters" => filters,
       "summary" => summary(paginated, total, filters)
     }}
  end

  defp get_sessions_index do
    LemonCore.RunStore.list_sessions()
  rescue
    _ -> []
  end

  defp maybe_filter_by_agent(sessions, nil), do: sessions

  defp maybe_filter_by_agent(sessions, agent_id) do
    Enum.filter(sessions, fn s -> s[:agent_id] == agent_id end)
  end

  defp format_session(session) do
    %{
      "sessionKey" => session[:session_key],
      "agentId" => session[:agent_id],
      "origin" => to_string(session[:origin] || :unknown),
      "createdAtMs" => session[:created_at_ms],
      "updatedAtMs" => session[:updated_at_ms],
      "runCount" => session[:run_count] || 0
    }
  end

  defp summary(sessions, total, filters) do
    updated_values =
      sessions
      |> Enum.map(& &1["updatedAtMs"])
      |> Enum.filter(&is_integer/1)

    %{
      "count" => length(sessions),
      "totalAvailable" => total,
      "agentCount" => unique_count(sessions, "agentId"),
      "originCounts" => count_by(sessions, "origin"),
      "runCount" => sum_integer(sessions, "runCount"),
      "oldestUpdatedAtMs" => min_or_nil(updated_values),
      "newestUpdatedAtMs" => max_or_nil(updated_values),
      "filtersApplied" => filters_applied(filters),
      "cleanup" => %{
        "includesMessages" => false,
        "includesRunEvents" => false,
        "includesRunRecords" => false,
        "includesCredentials" => false,
        "includesSecretValues" => false
      }
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

  defp sum_integer(rows, key) do
    rows
    |> Enum.map(& &1[key])
    |> Enum.filter(&is_integer/1)
    |> Enum.sum()
  end

  defp filters_applied(filters) do
    filters
    |> Enum.reject(fn {key, value} -> key in ["limit", "offset"] or blank?(value) end)
    |> Enum.map(fn {key, _value} -> key end)
    |> Enum.sort()
  end

  defp min_or_nil([]), do: nil
  defp min_or_nil(values), do: Enum.min(values)

  defp max_or_nil([]), do: nil
  defp max_or_nil(values), do: Enum.max(values)

  defp normalize_positive(value, _default) when is_integer(value) and value > 0, do: value

  defp normalize_positive(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp normalize_positive(_value, default), do: default

  defp normalize_non_negative(value, _default) when is_integer(value) and value >= 0, do: value

  defp normalize_non_negative(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} when parsed >= 0 -> parsed
      _ -> default
    end
  end

  defp normalize_non_negative(_value, default), do: default

  defp get_param(params, key) when is_map(params) and is_binary(key) do
    underscored = Macro.underscore(key)

    cond do
      Map.has_key?(params, key) -> Map.get(params, key)
      Map.has_key?(params, underscored) -> Map.get(params, underscored)
      true -> nil
    end
  end

  defp get_param(_params, _key), do: nil

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false
end
