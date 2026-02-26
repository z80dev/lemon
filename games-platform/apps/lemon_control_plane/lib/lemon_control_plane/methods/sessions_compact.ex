defmodule LemonControlPlane.Methods.SessionsCompact do
  @moduledoc """
  Handler for the sessions.compact method.

  Triggers context compaction for a session.
  """

  @behaviour LemonControlPlane.Method

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
          {:ok, %{
            "success" => true,
            "sessionKey" => session_key,
            "tokensBefore" => result[:tokens_before],
            "tokensAfter" => result[:tokens_after]
          }}

        {:error, reason} ->
          {:error, {:internal_error, "Failed to compact session", reason}}
      end
    end
  end

  defp compact_session(session_key, params) do
    force = params["force"] || false
    summary = params["summary"]

    # Try to find the active session and compact it
    if Code.ensure_loaded?(CodingAgent.SessionRegistry) do
      case Registry.lookup(CodingAgent.SessionRegistry, session_key) do
        [{pid, _}] ->
          opts = [force: force]
          opts = if summary, do: Keyword.put(opts, :summary, summary), else: opts

          case CodingAgent.Session.compact(pid, opts) do
            :ok -> {:ok, %{}}
            {:error, reason} -> {:error, reason}
          end

        [] ->
          {:error, :session_not_found}
      end
    else
      {:error, :session_registry_not_available}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end
end
