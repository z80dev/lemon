defmodule LemonControlPlane.UsageTokens do
  @moduledoc """
  Project a run's `LemonCore.Events.Usage` into the one shape clients get on the wire.

  A plain map is coerced with `LemonCore.Events.Usage.from_map/1`, so only the canonical
  field names are read; other spellings are not usage.

  `contextTokens` is `LemonCore.Events.Usage.context_tokens/1`: the reported latest-call
  context, else the last provider call's cache-inclusive input. The run's cumulative
  counters are never substituted for current context. `totalTokens` is the reported
  cumulative total, else the sum of cumulative input, cache reads and writes, and
  output. Derived sums require every component; an unreported component is never
  treated as zero. Explicit positive costs are independent of token completeness; an
  explicit `price_known: false` still suppresses an unavailable price.
  """

  alias LemonCore.Events.Usage

  @doc """
  `nil` when the map carries no usable numbers at all, so callers can omit the key rather
  than publish a frame of zeros that looks like a run which used no tokens.
  """
  @spec normalize(Usage.t() | map() | term()) :: map() | nil
  def normalize(usage) when is_map(usage) do
    usage = Usage.from_map(usage)
    input = count(usage.input)
    output = count(usage.output)
    cache_read = count(usage.cache_read)
    cache_write = count(usage.cache_write)

    total =
      count(usage.total_tokens) || sum_or_nil([input, cache_read, cache_write, output])

    reported_cost = cost_usd(usage.cost)

    cost =
      if usage.price_known != false and
           ((is_number(reported_cost) and reported_cost > 0) or
              Enum.all?([input, output, total], &is_integer/1)),
         do: reported_cost,
         else: nil

    normalized = %{
      "inputTokens" => input,
      "outputTokens" => output,
      "cacheReadTokens" => cache_read,
      "cacheWriteTokens" => cache_write,
      "totalTokens" => total,
      "contextTokens" => Usage.context_tokens(usage),
      "costUsd" => cost,
      "turns" => count(usage.turns),
      "tool_errors" => count(usage.tool_errors)
    }

    if Enum.all?(Map.values(normalized), &is_nil/1), do: nil, else: normalized
  rescue
    _ -> nil
  end

  def normalize(_), do: nil

  defp sum_or_nil(values) do
    if Enum.all?(values, &is_integer/1), do: Enum.sum(values), else: nil
  end

  defp cost_usd(%{} = cost), do: number(Map.get(cost, :total, Map.get(cost, "total")))
  defp cost_usd(cost), do: number(cost)

  defp count(value) when is_integer(value) and value >= 0, do: value
  defp count(_), do: nil

  defp number(value) when is_number(value), do: value
  defp number(_), do: nil
end
