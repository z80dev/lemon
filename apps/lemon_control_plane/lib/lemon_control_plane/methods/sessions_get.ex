defmodule LemonControlPlane.Methods.SessionsGet do
  @moduledoc "Read one real durable lifecycle row; unlike session.detail, never fabricate a new session."
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.{NativeSessions, SessionsList}
  alias LemonCore.SessionLifecycle

  @impl true
  def name, do: "sessions.get"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    with {:ok, key} <- NativeSessions.string(params || %{}, "sessionKey", 1024) do
      case SessionLifecycle.fetch(key) do
        {:ok, nil} ->
          {:error, {:not_found, "Session not found", nil}}

        {:ok, session} ->
          {:ok, %{"session" => SessionsList.format_session(session)}}

        {:error, :session_store_unavailable} ->
          {:error, {:unavailable, "Session directory is unavailable", nil}}
      end
    end
  rescue
    _ -> {:error, {:unavailable, "Session directory is unavailable", nil}}
  catch
    :exit, _ -> {:error, {:unavailable, "Session directory is unavailable", nil}}
  end
end
