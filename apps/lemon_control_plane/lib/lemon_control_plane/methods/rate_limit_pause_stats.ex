defmodule LemonControlPlane.Methods.RateLimitPauseStats do
  @moduledoc """
  Handler for the rate_limit_pause.stats method.

  Returns aggregate statistics for rate limit pauses across all sessions.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "rate_limit_pause.stats"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(_params, _ctx) do
    stats = CodingAgent.RateLimitPause.stats()

    # Convert provider keys to strings for JSON serialization
    by_provider = 
      stats.by_provider
      |> Enum.map(fn {provider, count} -> 
        {to_string(provider), count}
      end)
      |> Enum.into(%{})

    {:ok, %{
      "totalPauses" => stats.total_pauses,
      "pendingPauses" => stats.pending_pauses,
      "resumedPauses" => stats.resumed_pauses,
      "byProvider" => by_provider
    }}
  end
end
