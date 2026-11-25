defmodule LemonControlPlane.Methods.SessionDetail do
  @moduledoc """
  Handler for `session.detail`: one session's routing projection.

  Answers what the session's next run resolves to (`model`, `provider`,
  `contextWindow`, `maxOutput`, `thinkingLevel`, `modelSource`, `modelOverride`)
  plus its durable lifecycle row (agent, title, pin/archive state, run count and
  timestamps). It reads one session-index row and the session policy; it never
  reads run history, events or run records. Those belong to the bounded,
  redacted `chat.history`, `sessions.history` and `runs.timeline.get`.

  An unknown key still answers with its routing, so a client can label a
  session before its first run; `sessions.get` is the strict lookup.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.SessionModel
  alias LemonCore.SessionKey
  alias LemonControlPlane.SessionLifecycle

  @impl true
  def name, do: "session.detail"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    with {:ok, session_key} <- require_session_key(params || %{}),
         {:ok, row} <- fetch_row(session_key) do
      agent_id = row["agentId"] || SessionKey.agent_id(session_key)

      session =
        row
        |> Map.merge(%{"sessionKey" => session_key, "agentId" => agent_id})
        |> Map.merge(SessionModel.resolve(session_key, agent_id))
        |> Map.put("modelOverride", SessionModel.override(session_key))

      {:ok, %{"sessionKey" => session_key, "session" => session}}
    end
  end

  defp require_session_key(params) do
    case Map.get(params, "sessionKey") do
      session_key when is_binary(session_key) and session_key != "" -> {:ok, session_key}
      _ -> {:error, {:bad_request, "sessionKey is required", nil}}
    end
  end

  defp fetch_row(session_key) do
    case SessionLifecycle.fetch(session_key) do
      {:ok, nil} ->
        {:ok, %{}}

      {:ok, session} ->
        {:ok,
         %{
           "agentId" => session.agent_id,
           "origin" => to_string(session.origin),
           "runCount" => session.run_count,
           "createdAtMs" => session.created_at_ms,
           "updatedAtMs" => session.updated_at_ms,
           "title" => session.title,
           "pinned" => session.pinned,
           "archived" => session.archived,
           "metadataUpdatedAtMs" => session.metadata_updated_at_ms
         }}

      {:error, _reason} ->
        directory_unavailable()
    end
  rescue
    _ -> directory_unavailable()
  catch
    :exit, _ -> directory_unavailable()
  end

  defp directory_unavailable,
    do: {:error, {:unavailable, "Session directory is unavailable", nil}}
end
