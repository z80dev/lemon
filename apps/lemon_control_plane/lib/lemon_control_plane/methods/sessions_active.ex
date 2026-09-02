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
      case LemonCore.RouterBridge.active_run(session_key) do
        {:ok, run_id} ->
          {:ok, response(session_key, run_id)}

        :none ->
          {:ok, response(session_key, nil)}

        {:error, reason} ->
          {:error, {:unavailable, "router unavailable: #{inspect(reason)}", nil}}
      end
    end
  end

  defp response(session_key, run_id) do
    %{
      "sessionKey" => session_key,
      "runId" => run_id,
      "summary" => summary(session_key, run_id)
    }
  end

  defp summary(session_key, run_id) do
    %{
      "action" => "sessions.active",
      "active" => is_binary(run_id) and run_id != "",
      "sessionKeyReturned" => is_binary(session_key) and session_key != "",
      "runIdReturned" => is_binary(run_id) and run_id != "",
      "cleanup" => %{
        "includesRunRecord" => false,
        "includesRunEvents" => false,
        "includesMessageText" => false,
        "includesCredentialValues" => false,
        "includesSecretValues" => false
      }
    }
  end
end
