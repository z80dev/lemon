defmodule LemonControlPlane.Methods.RateLimitPauseGet do
  @moduledoc """
  Handler for the rate_limit_pause.get method.

  Gets details of a specific rate limit pause by ID.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "rate_limit_pause.get"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}
    
    case params["pauseId"] || params["pause_id"] || params["id"] do
      nil ->
        {:error, {:invalid_request, "pauseId is required", nil}}

      pause_id ->
        case CodingAgent.RateLimitPause.get(pause_id) do
          {:ok, pause} ->
            {:ok, %{"pause" => format_pause(pause)}}

          {:error, :not_found} ->
            {:error, {:not_found, "Rate limit pause not found", %{"pauseId" => pause_id}}}
        end
    end
  end

  defp format_pause(pause) do
    %{
      "id" => pause.id,
      "sessionId" => pause.session_id,
      "provider" => to_string(pause.provider),
      "status" => to_string(pause.status),
      "pausedAt" => DateTime.to_iso8601(pause.paused_at),
      "retryAfterMs" => pause.retry_after_ms,
      "resumeAt" => pause.resume_at && DateTime.to_iso8601(pause.resume_at),
      "resumedAt" => pause.resumed_at && DateTime.to_iso8601(pause.resumed_at),
      "metadata" => pause.metadata || %{},
      "readyToResume" => CodingAgent.RateLimitPause.ready_to_resume?(pause.id)
    }
  end
end
