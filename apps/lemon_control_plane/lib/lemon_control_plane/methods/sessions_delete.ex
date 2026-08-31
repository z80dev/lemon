defmodule LemonControlPlane.Methods.SessionsDelete do
  @moduledoc """
  Handler for the sessions.delete method.

  Deletes a session and its history.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "sessions.delete"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    session_key = params["sessionKey"]

    if is_nil(session_key) do
      {:error, {:invalid_request, "sessionKey is required", nil}}
    else
      case LemonCore.SessionLifecycle.delete(session_key) do
        {:ok, deletion} ->
          {:ok,
           %{
             "deleted" => true,
             "sessionKey" => session_key,
             "summary" => %{
               "sessionKey" => session_key,
               "deleted" => true,
               "existed" => deletion.existed,
               "verified" => deletion.verified,
               "cleanup" => %{
                 "deletedRunSession" => true,
                 "deletedChatState" => true,
                 "deletedSessionPolicy" => true,
                 "deletedLifecycleMetadata" => true,
                 "includesMessages" => false,
                 "includesPolicy" => false,
                 "includesSecretValues" => false
               }
             }
           }}

        {:error, _reason} ->
          {:error, {:internal_error, "Failed to delete session safely", nil}}
      end
    end
  end
end
