defmodule LemonControlPlane.Methods.SessionsHistory do
  @moduledoc """
  Read bounded redacted durable run history from the daemon's session lifecycle.

  Prompts, answers, errors and tool titles/details/messages are content and need
  `operator.content`; read-only callers get each run's id, timing, status, engine
  and event/tool counts.
  """
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Auth.Authorize
  alias LemonControlPlane.Methods.NativeSessions
  alias LemonControlPlane.SessionLifecycle

  @metadata_fields [:run_id, :started_at_ms, :engine, :ok, :duration_ms, :event_count]

  @impl true
  def name, do: "sessions.history"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, ctx) do
    params = params || %{}
    content? = Authorize.content?(ctx)

    with {:ok, key} <- NativeSessions.string(params, "sessionKey", 1024),
         {:ok, limit} <- NativeSessions.integer(params, "limit", 50, 1, 200) do
      case SessionLifecycle.get(key) do
        nil ->
          {:error, {:not_found, "Session not found", nil}}

        session ->
          history = SessionLifecycle.history(key, limit: limit, redact: true)

          {:ok,
           %{
             "session" => session,
             "history" => if(content?, do: history, else: Enum.map(history, &metadata/1)),
             "contentWithheld" => not content?
           }}
      end
    end
  rescue
    _ -> {:error, {:unavailable, "Session history is unavailable", nil}}
  catch
    :exit, _ -> {:error, {:unavailable, "Session history is unavailable", nil}}
  end

  defp metadata(run) do
    run
    |> Map.take(@metadata_fields)
    |> Map.put(:tool_count, length(Map.get(run, :tools, [])))
  end
end
