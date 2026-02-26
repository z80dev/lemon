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
      # Delete session index
      LemonCore.Store.delete(:sessions_index, session_key)

      # Delete run history
      LemonCore.Store.delete(:run_history, session_key)

      # Delete chat state if exists
      LemonCore.Store.delete(:chat_state, session_key)

      {:ok, %{"deleted" => true, "sessionKey" => session_key}}
    end
  end
end
