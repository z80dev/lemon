defmodule LemonControlPlane.Methods.SessionsCompact do
  @moduledoc """
  Handler for the sessions.compact method.

  Triggers context compaction for a session.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.AgentRuntime

  @impl true
  def name, do: "sessions.compact"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    session_key = params["sessionKey"]

    if is_nil(session_key) do
      {:error, {:invalid_request, "sessionKey is required", nil}}
    else
      case compact_session(session_key, params) do
        {:ok, result} ->
          {:ok,
           %{
             "success" => true,
             "sessionKey" => session_key,
             "tokensBefore" => result[:tokens_before],
             "tokensAfter" => result[:tokens_after],
             "summary" => summary(session_key, result, params)
           }}

        {:error, reason} ->
          {:error, {:internal_error, "Failed to compact session", reason}}
      end
    end
  end

  defp compact_session(session_key, params) do
    force = params["force"] || false
    summary = params["summary"]

    opts = [force: force]
    opts = if summary, do: Keyword.put(opts, :summary, summary), else: opts

    case AgentRuntime.call(
           :compact_session,
           [session_key, opts],
           {:error, :session_registry_not_available}
         ) do
      :ok -> {:ok, %{}}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp summary(session_key, result, params) do
    %{
      "sessionKeyReturned" => is_binary(session_key) and session_key != "",
      "compacted" => true,
      "force" => params["force"] == true,
      "customSummaryProvided" => is_binary(params["summary"]) and params["summary"] != "",
      "tokensBeforeReturned" => is_integer(result[:tokens_before]),
      "tokensAfterReturned" => is_integer(result[:tokens_after]),
      "cleanup" => %{
        "includesPromptText" => false,
        "includesSummaryText" => false,
        "includesMessageBodies" => false,
        "includesCredentials" => false,
        "includesSecretValues" => false
      }
    }
  end
end
