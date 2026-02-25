defmodule LemonControlPlane.Methods.SessionsList do
  @moduledoc """
  Handler for the sessions.list method.

  Lists all sessions with optional filtering and pagination.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "sessions.list"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    limit = params["limit"] || 100
    offset = params["offset"] || 0
    agent_id = params["agentId"]

    # Get sessions from LemonCore.Store which maintains sessions_index
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

    {:ok, %{"sessions" => paginated, "total" => total}}
  end

  defp get_sessions_index do
    LemonCore.Store.list(:sessions_index)
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
end
