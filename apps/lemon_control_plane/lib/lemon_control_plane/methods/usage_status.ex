defmodule LemonControlPlane.Methods.UsageStatus do
  @moduledoc """
  Handler for the usage.status control plane method.

  Returns current usage metrics and quotas.
  """

  @behaviour LemonControlPlane.Method

  alias LemonCore.UsageDiagnostics

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
    diagnostics = UsageDiagnostics.status()
    runs = diagnostics.total_requests
    tokens = format_tokens(diagnostics.total_tokens)
    cost = diagnostics.total_cost
    quotas = format_quotas(diagnostics.quotas)

    %{
      "period" => "today",
      "periodStart" => today_start,
      "runs" => runs,
      "tokens" => tokens,
      "cost" => cost,
      "quotas" => quotas,
      "providers" => Enum.map(diagnostics.providers, &format_provider/1),
      "summary" => summary(runs, tokens, cost, quotas),
      "includesPrompts" => false,
      "includesResponses" => false,
      "includesMessageBodies" => false,
      "includesCredentials" => false,
      "includesSecretValues" => false
    }
  end

  defp format_tokens(tokens) do
    %{
      "input" => Map.get(tokens, :input, 0),
      "output" => Map.get(tokens, :output, 0)
    }
  end

  defp format_quotas(quotas) do
    %{
      "runsLimit" => Map.get(quotas, :runs_limit),
      "tokensLimit" => Map.get(quotas, :tokens_limit),
      "costLimit" => Map.get(quotas, :cost_limit)
    }
  end

  defp format_provider(provider) do
    %{
      "provider" => provider.provider,
      "cost" => provider.cost,
      "requests" => provider.requests,
      "inputTokens" => provider.input_tokens,
      "outputTokens" => provider.output_tokens
    }
  end

  defp summary(runs, tokens, cost, quotas) do
    total_tokens = Map.get(tokens, "input", 0) + Map.get(tokens, "output", 0)
    runs_limit = quotas["runsLimit"]
    tokens_limit = quotas["tokensLimit"]
    cost_limit = quotas["costLimit"]

    checks = [
      limit_check(runs, runs_limit),
      limit_check(total_tokens, tokens_limit),
      limit_check(cost, cost_limit)
    ]

    %{
      "status" => limit_status(checks),
      "runsLimitConfigured" => is_number(runs_limit),
      "tokensLimitConfigured" => is_number(tokens_limit),
      "costLimitConfigured" => is_number(cost_limit),
      "totalTokens" => total_tokens,
      "remainingRuns" => remaining(runs, runs_limit),
      "remainingTokens" => remaining(total_tokens, tokens_limit),
      "remainingCost" => remaining(cost, cost_limit)
    }
  end

  defp limit_check(_value, limit) when not is_number(limit), do: :unconfigured
  defp limit_check(value, limit) when value > limit, do: :over
  defp limit_check(_value, _limit), do: :within

  defp limit_status(checks) do
    cond do
      :over in checks -> "over_limit"
      :within in checks -> "within_limits"
      true -> "unlimited"
    end
  end

  defp remaining(_value, limit) when not is_number(limit), do: nil
  defp remaining(value, limit), do: max(limit - value, 0)
end
