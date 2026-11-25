defmodule LemonControlPlane.Methods.SessionsCreate do
  @moduledoc "Explicit, idempotent native session allocation before the first prompt."
  @behaviour LemonControlPlane.Method

  alias LemonCore.AgentRuntime
  alias LemonControlPlane.Methods.NativeSessions

  @impl true
  def name, do: "sessions.create"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    with {:ok, key, cwd} <- NativeSessions.target(params),
         :ok <- canonical_key(key) do
      case AgentRuntime.mutate(:session_create, [key, cwd]) do
        {:ok, %{"sessionId" => id, "created" => created}}
        when is_binary(id) and id != "" and is_boolean(created) ->
          {:ok, %{"sessionKey" => key, "sessionId" => id, "created" => created}}

        {:error, reason} ->
          NativeSessions.failure(reason)

        # A malformed acknowledgement does not prove the session was not created.
        _ ->
          NativeSessions.failure(:outcome_unknown)
      end
    end
  end

  defp canonical_key(key) do
    if LemonCore.SessionKey.agent_id(key) in [nil, ""],
      do: NativeSessions.invalid("sessionKey must be a canonical agent session key"),
      else: :ok
  end
end
