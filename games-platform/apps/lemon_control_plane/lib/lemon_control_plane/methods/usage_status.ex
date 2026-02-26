defmodule LemonControlPlane.Methods.UsageStatus do
  @moduledoc """
  Handler for the usage.status control plane method.

  Returns current usage metrics and quotas.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "usage.status"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(_params, _ctx) do
    # Gather usage stats from various sources
    stats = gather_usage_stats()

    {:ok, stats}
  end

  defp gather_usage_stats do
    now = System.system_time(:millisecond)
    today_start = div(now, 86_400_000) * 86_400_000

    # Get run counts from telemetry/store
    %{
      "period" => "today",
      "periodStart" => today_start,
      "runs" => get_run_count(today_start),
      "tokens" => get_token_count(today_start),
      "cost" => get_cost_estimate(today_start),
      "quotas" => %{
        "runsLimit" => get_quota(:runs_limit),
        "tokensLimit" => get_quota(:tokens_limit),
        "costLimit" => get_quota(:cost_limit)
      }
    }
  end

  defp get_run_count(_since_ms) do
    case LemonCore.Store.get(:usage_stats, :runs_today) do
      nil -> 0
      stats -> stats[:count] || 0
    end
  rescue
    _ -> 0
  end

  defp get_token_count(_since_ms) do
    case LemonCore.Store.get(:usage_stats, :tokens_today) do
      nil -> %{"input" => 0, "output" => 0}
      stats -> %{
        "input" => stats[:input] || 0,
        "output" => stats[:output] || 0
      }
    end
  rescue
    _ -> %{"input" => 0, "output" => 0}
  end

  defp get_cost_estimate(_since_ms) do
    case LemonCore.Store.get(:usage_stats, :cost_today) do
      nil -> 0.0
      stats -> stats[:total] || 0.0
    end
  rescue
    _ -> 0.0
  end

  defp get_quota(type) do
    Application.get_env(:lemon_control_plane, type, nil)
  end
end
