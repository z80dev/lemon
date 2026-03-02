defmodule LemonControlPlane.Methods.RateLimitPauseList do
  @moduledoc """
  Handler for the rate_limit_pause.list method.

  Lists all rate limit pauses for a session with optional status filtering.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "rate_limit_pause.list"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}
    
    case params["sessionId"] || params["session_id"] do
      nil ->
        {:error, {:invalid_request, "sessionId is required", nil}}

      session_id ->
        status_filter = params["status"] || params["status_filter"]
        
        pauses = 
          case status_filter do
            "pending" ->
              CodingAgent.RateLimitPause.list_pending(session_id)
              
            nil ->
              CodingAgent.RateLimitPause.list_all(session_id)
              
            _ ->
              # For other status filters, get all and filter
              CodingAgent.RateLimitPause.list_all(session_id)
              |> Enum.filter(fn pause -> 
                status_str = to_string(pause.status)
                status_str == status_filter
              end)
          end

        formatted_pauses = Enum.map(pauses, &format_pause/1)
        
        {:ok, %{
          "sessionId" => session_id,
          "pauses" => formatted_pauses,
          "total" => length(formatted_pauses)
        }}
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
