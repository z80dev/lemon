defmodule LemonControlPlane.Methods.SessionsActive do
  @moduledoc """
  Handler for the sessions.active method.

  Returns the active (in-flight) run for a given sessionKey.

  This is backed by router-owned best-effort local-node activity state and is therefore:
  - Best-effort (only reflects the current node state)
  - Strict single-flight (at most one active run per sessionKey)
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "sessions.active"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    session_key = params["sessionKey"]

    if is_nil(session_key) or session_key == "" do
      {:error, {:invalid_request, "sessionKey is required", nil}}
    else
      run_id =
        case LemonCore.RouterBridge.active_run(session_key) do
          {:ok, active_run_id} -> active_run_id
          :none -> nil
        end

      {:ok, %{"sessionKey" => session_key, "runId" => run_id}}
    end
  rescue
    _ ->
      key = (params || %{})["sessionKey"]
      {:ok, %{"sessionKey" => key, "runId" => nil}}
  end
end
