defmodule LemonControlPlane.Methods.SessionsReset do
  @moduledoc """
  Handler for the sessions.reset method.

  Resets a session's conversation history.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "sessions.reset"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    session_key = params["sessionKey"]

    if is_nil(session_key) do
      {:error, {:invalid_request, "sessionKey is required", nil}}
    else
      case reset_session(session_key) do
        :ok ->
          {:ok, %{"success" => true, "sessionKey" => session_key}}

        {:error, reason} ->
          {:error, {:internal_error, "Failed to reset session", reason}}
      end
    end
  end

  defp reset_session(session_key) do
    # Delete session history
    LemonCore.Store.delete(:run_history, session_key)

    # Clear chat state if exists
    if Code.ensure_loaded?(LemonGateway.Store) do
      LemonGateway.Store.delete_chat_state(session_key)
    end

    # Reset session overrides
    LemonCore.Store.delete(:session_overrides, session_key)

    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end
end
