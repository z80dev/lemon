defmodule LemonCore.Doctor.Checks.Usage do
  @moduledoc "Checks usage aggregate and quota visibility."

  alias LemonCore.Doctor.Check

  @spec run(keyword()) :: [Check.t()]
  def run(opts \\ []) do
    diagnostics = LemonCore.UsageDiagnostics.status(opts)

    [
      usage_check(diagnostics)
    ]
  end

  defp usage_check(%{status: "unknown", error: error}) do
    Check.warn(
      "usage.status",
      "Usage diagnostics are unavailable.",
      "Inspect usage stores and retry doctor. Error: #{error}"
    )
  end

  defp usage_check(%{total_requests: 0, total_cost: cost, total_tokens: %{total: 0}})
       when cost == 0 do
    Check.skip("usage.status", "No current usage summary has been recorded yet.")
  end

  defp usage_check(%{status: "over_limit"} = diagnostics) do
    Check.warn(
      "usage.status",
      "Usage is over a configured quota: #{usage_summary(diagnostics)}.",
      "Review `usage.status` or `usage.cost`, then adjust limits or reduce run volume."
    )
  end

  defp usage_check(diagnostics) do
    Check.pass(
      "usage.status",
      "Usage summary available: #{usage_summary(diagnostics)}."
    )
  end

  defp usage_summary(diagnostics) do
    tokens = diagnostics.total_tokens

    [
      "#{diagnostics.total_requests} request(s)",
      "#{tokens.total} token(s)",
      "#{format_cost(diagnostics.total_cost)} cost",
      "#{diagnostics.provider_count} provider(s)",
      "status #{diagnostics.status}"
    ]
    |> Enum.join(", ")
  end

  defp format_cost(cost) when is_number(cost),
    do: "$" <> :erlang.float_to_binary(cost * 1.0, decimals: 4)

  defp format_cost(_cost), do: "$0.0000"
end
