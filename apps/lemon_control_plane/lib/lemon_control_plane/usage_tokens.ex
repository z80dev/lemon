defmodule LemonControlPlane.UsageTokens do
  @moduledoc """
  Normalize an engine's token-usage map into the one shape clients get on the wire.

  Every engine reports usage slightly differently — `:input_tokens` here, `:prompt_tokens`
  there, cache reads split across two keys — so this collapses the variants once, at the
  boundary, instead of asking each client to guess.

  `contextTokens` is the number a context gauge wants: the input side of the last turn
  *including* cached reads, which is how large the conversation actually was going into the
  model. It deliberately excludes output. The arithmetic matches
  `LemonRouter.RunProcess.CompactionTrigger.usage_input_tokens/1`, which is what the router
  itself compacts against — a gauge that disagreed with the compactor would be worse than none.
  """

  @input_keys [:input_tokens, :input, :prompt_tokens]
  @output_keys [:output_tokens, :output, :completion_tokens]
  @cache_read_keys [:cached_input_tokens, :cache_read_input_tokens]
  @cache_write_keys [:cache_creation_input_tokens, :cache_write_input_tokens]
  @total_keys [:total_tokens, :total, :tokens]

  @doc """
  `nil` when the map carries no usable numbers at all, so callers can omit the key rather
  than publish a frame of zeros that looks like a run which used no tokens.
  """
  @spec normalize(map() | term()) :: map() | nil
  def normalize(usage) when is_map(usage) do
    input = first_integer(usage, @input_keys)
    output = first_integer(usage, @output_keys)
    cache_read = first_integer(usage, @cache_read_keys)
    cache_write = first_integer(usage, @cache_write_keys)
    total = first_integer(usage, @total_keys)
    cost = cost_usd(usage)

    context = context_tokens(usage, input, cache_read, cache_write)

    normalized = %{
      "inputTokens" => input,
      "outputTokens" => output,
      "cacheReadTokens" => cache_read,
      "cacheWriteTokens" => cache_write,
      "totalTokens" => total || sum_or_nil([input, output]),
      "contextTokens" => context,
      "costUsd" => cost
    }

    if Enum.all?(Map.values(normalized), &is_nil/1), do: nil, else: normalized
  rescue
    _ -> nil
  end

  def normalize(_), do: nil

  # `:prompt_tokens` is already cache-inclusive in the APIs that report it, so only the
  # `:input`/`:input_tokens` spellings get the cache added on top.
  defp context_tokens(usage, input, cache_read, cache_write) do
    cached = (cache_read || 0) + (cache_write || 0)

    cond do
      is_integer(input) and cache_inclusive?(usage) -> input
      is_integer(input) -> input + cached
      cached > 0 -> cached
      true -> nil
    end
  end

  defp cache_inclusive?(usage) do
    is_nil(first_integer(usage, [:input_tokens, :input])) and
      is_integer(first_integer(usage, [:prompt_tokens]))
  end

  defp first_integer(usage, keys) do
    Enum.find_value(keys, fn key -> to_non_negative_integer(fetch(usage, key)) end)
  end

  defp sum_or_nil(values) do
    case Enum.filter(values, &is_integer/1) do
      [] -> nil
      present -> Enum.sum(present)
    end
  end

  defp cost_usd(usage) do
    case fetch(usage, :cost) do
      cost when is_map(cost) -> to_number(fetch(cost, :total))
      cost -> to_number(cost)
    end
  end

  defp fetch(map, key) when is_map(map) do
    case Map.get(map, key) do
      nil -> Map.get(map, Atom.to_string(key))
      value -> value
    end
  end

  defp fetch(_map, _key), do: nil

  defp to_non_negative_integer(value) when is_integer(value) and value >= 0, do: value

  defp to_non_negative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _rest} when parsed >= 0 -> parsed
      _ -> nil
    end
  end

  defp to_non_negative_integer(_), do: nil

  defp to_number(value) when is_number(value), do: value
  defp to_number(_), do: nil
end
