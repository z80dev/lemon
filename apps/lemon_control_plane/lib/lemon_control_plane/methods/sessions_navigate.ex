defmodule LemonControlPlane.Methods.SessionsNavigate do
  @moduledoc """
  Switches a native session's active branch to a tree entry.

  Non-destructive: the abandoned branch stays in the tree, so no preview or
  confirmation is needed. A streaming session is refused.
  """
  @behaviour LemonControlPlane.Method

  alias LemonCore.AgentRuntime
  alias LemonControlPlane.Methods.NativeSessions

  @impl true
  def name, do: "sessions.navigate"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    with {:ok, key, cwd} <- NativeSessions.target(params),
         {:ok, entry_id} <- NativeSessions.string(params, "entryId", 256),
         {:ok, summarize} <- NativeSessions.boolean(params, "summarize", false) do
      case AgentRuntime.call(
             :session_navigate,
             [key, cwd, entry_id, [summarize: summarize]],
             {:error, :unavailable}
           ) do
        {:ok, result} when is_map(result) ->
          {:ok,
           result
           |> Map.take(~w(sessionId entryId leafId prompt summarizing))
           |> Map.put("sessionKey", key)}

        {:error, reason} ->
          NativeSessions.failure(reason)

        _ ->
          NativeSessions.failure(:invalid_response)
      end
    end
  end
end
