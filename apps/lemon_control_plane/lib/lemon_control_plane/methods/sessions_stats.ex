defmodule LemonControlPlane.Methods.SessionsStats do
  @moduledoc "Returns bounded, redacted aggregate statistics over durable sessions."

  @behaviour LemonControlPlane.Method

  @max_query_bytes 512

  @impl true
  def name, do: "sessions.stats"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}

    with {:ok, query} <- query(params["query"]),
         {:ok, group_limit} <- group_limit(params["groupLimit"]),
         {:ok, report} <-
           LemonCore.SessionLifecycle.stats(
             query: query,
             agent_id: params["agentId"],
             pinned: boolean_filter(params["pinned"]),
             archived: boolean_filter(params["archived"]),
             group_limit: group_limit
           ) do
      {:ok, format(report)}
    else
      {:error, :invalid_query} ->
        {:error, {:invalid_params, "query must be at most 512 bytes", nil}}

      {:error, :invalid_group_limit} ->
        {:error, {:invalid_params, "groupLimit must be between 1 and 50", nil}}

      {:error, :session_store_unavailable} ->
        {:error, {:internal_error, "Session statistics are unavailable", nil}}
    end
  end

  defp query(nil), do: {:ok, nil}

  defp query(value) when is_binary(value) and byte_size(value) <= @max_query_bytes,
    do: {:ok, value}

  defp query(_value), do: {:error, :invalid_query}

  defp group_limit(nil), do: {:ok, 10}
  defp group_limit(value) when is_integer(value) and value in 1..50, do: {:ok, value}
  defp group_limit(_value), do: {:error, :invalid_group_limit}

  defp boolean_filter(value) when is_boolean(value), do: value
  defp boolean_filter(_value), do: :all

  defp format(report) do
    %{
      "version" => report.version,
      "redacted" => report.redacted,
      "filters" => %{
        "agentId" => report.filters.agent_id,
        "pinned" => report.filters.pinned,
        "archived" => report.filters.archived,
        "query" => report.filters.query,
        "queryBytes" => report.filters.query_bytes
      },
      "totals" => %{
        "storeSessions" => report.totals.store_sessions,
        "matchedSessions" => report.totals.matched_sessions,
        "activeSessions" => report.totals.active_sessions,
        "archivedSessions" => report.totals.archived_sessions,
        "pinnedSessions" => report.totals.pinned_sessions,
        "unpinnedSessions" => report.totals.unpinned_sessions,
        "titledSessions" => report.totals.titled_sessions,
        "runs" => report.totals.runs,
        "oldestUpdatedAtMs" => report.totals.oldest_updated_at_ms,
        "newestUpdatedAtMs" => report.totals.newest_updated_at_ms
      },
      "breakdowns" => %{
        "agents" => breakdown(report.breakdowns.agents),
        "origins" => breakdown(report.breakdowns.origins)
      },
      "cleanup" => %{
        "includesSessionKeys" => report.cleanup.includes_session_keys,
        "includesTitles" => report.cleanup.includes_titles,
        "includesMessages" => report.cleanup.includes_messages,
        "includesPrompts" => report.cleanup.includes_prompts,
        "includesAnswers" => report.cleanup.includes_answers,
        "includesPaths" => report.cleanup.includes_paths,
        "includesUrls" => report.cleanup.includes_urls,
        "includesCredentials" => report.cleanup.includes_credentials,
        "maxDimensionEntries" => report.cleanup.max_dimension_entries
      }
    }
  end

  defp breakdown(value) do
    %{
      "entries" => Enum.map(value.entries, &%{"value" => &1.value, "count" => &1.count}),
      "distinct" => value.distinct,
      "omitted" => value.omitted
    }
  end
end
