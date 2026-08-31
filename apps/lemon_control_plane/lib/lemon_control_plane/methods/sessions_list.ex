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
    query = get_param(params, "query")
    pinned = boolean_filter(get_param(params, "pinned"))
    archived = boolean_filter(get_param(params, "archived"))

    result =
      LemonCore.SessionLifecycle.list(
        limit: limit,
        offset: offset,
        agent_id: agent_id,
        query: query,
        pinned: pinned,
        archived: archived
      )

    paginated = Enum.map(result.sessions, &format_session/1)

    filters = %{
      "agentId" => agent_id,
      "limit" => limit,
      "offset" => offset,
      "pinned" => filter_value(pinned),
      "archived" => filter_value(archived),
      "queryBytes" => if(is_binary(query), do: byte_size(query), else: 0)
    }

    {:ok,
     %{
       "sessions" => paginated,
       "total" => result.matched,
       "filters" => filters,
       "summary" => summary(paginated, result, filters)
     }}
  end

  # `model` here is the session's own override and nothing more — one session-policy read per
  # row. Full resolution (profile model, config default, provider, context window) costs an
  # `AgentProfiles` call per row and lives in `session.detail` instead; a null `model` on a row
  # means "inherits", not "no model".
  defp format_session(session) do
    session_key = session.session_key

    %{
      "sessionKey" => session_key,
      "agentId" => session.agent_id,
      "origin" => to_string(session.origin || :unknown),
      "createdAtMs" => session.created_at_ms,
      "updatedAtMs" => session.updated_at_ms,
      "runCount" => session.run_count || 0,
      "title" => session.title,
      "pinned" => session.pinned,
      "archived" => session.archived,
      "metadataUpdatedAtMs" => session.metadata_updated_at_ms,
      "model" => LemonControlPlane.SessionModel.override(session_key)
    }
  end

  defp summary(sessions, result, filters) do
    updated_values =
      sessions
      |> Enum.map(& &1["updatedAtMs"])
      |> Enum.filter(&is_integer/1)

    %{
      "count" => length(sessions),
      "totalAvailable" => result.matched,
      "storeTotal" => result.total,
      "agentCount" => unique_count(sessions, "agentId"),
      "originCounts" => count_by(sessions, "origin"),
      "runCount" => sum_integer(sessions, "runCount"),
      "pinnedCount" => Enum.count(sessions, &(&1["pinned"] == true)),
      "archivedCount" => Enum.count(sessions, &(&1["archived"] == true)),
      "titledCount" => Enum.count(sessions, &(not blank?(&1["title"]))),
      "oldestUpdatedAtMs" => min_or_nil(updated_values),
      "newestUpdatedAtMs" => max_or_nil(updated_values),
      "filtersApplied" => filters_applied(filters),
      "cleanup" => %{
        "includesMessages" => false,
        "includesRunEvents" => false,
        "includesRunRecords" => false,
        "includesTitles" => true,
        "includesSearchQuery" => false,
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
    |> Enum.flat_map(fn
      {"queryBytes", value} when is_integer(value) and value > 0 ->
        ["query"]

      {key, value} when key not in ["limit", "offset", "queryBytes"] and not is_nil(value) ->
        [key]

      _other ->
        []
    end)
    |> Enum.sort()
  end

  defp boolean_filter(value) when is_boolean(value), do: value
  defp boolean_filter(_value), do: :all

  defp filter_value(:all), do: nil
  defp filter_value(value), do: value

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
