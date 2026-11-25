defmodule LemonCore.Events.Usage do
  @moduledoc """
  Token usage for a run, carried in `LemonCore.Events.Completion.usage`, and for each
  provider call inside it.

  Field names are canonical: there are no alternative spellings to probe. Counters are
  nullable — `nil` means the provider did not report the value, never a measured zero —
  and `input` excludes cache-read and cache-write tokens. `cache_write_long` is the hourly
  cache-write subset of `cache_write`, not an additional count.

  On a run, `input`, `output`, `cache_read`, `cache_write`, `cache_write_long`,
  `total_tokens` and `cost` sum every provider call in the run: they measure spend, not
  the size of the model context. An N-call run reports roughly N times its context.
  `context_tokens` is the latest call's context, and `occurrences` lists each call in
  order as `%{model, provider, at_ms, usage}`, where `usage` is this struct without
  run-level fields. Read the context size with `context_tokens/1`. A native session also
  attaches its measured request `context_budget` (tokens, window, reserve, headroom).

  `cost` is `%{input, output, cache_read, cache_write, cache_write_long, total}` in USD;
  `price_known: false` means the total is not a known price.
  """

  use LemonCore.Events.Payload,
    type: :usage,
    fields: [
      input: nil,
      output: nil,
      cache_read: nil,
      cache_write: nil,
      cache_write_long: nil,
      total_tokens: nil,
      cost: nil,
      price_known: nil,
      context_tokens: nil,
      context_budget: nil,
      turns: nil,
      tool_errors: nil,
      occurrences: nil
    ]

  @type occurrence :: %{
          model: String.t() | nil,
          provider: atom() | String.t() | nil,
          at_ms: integer() | nil,
          usage: t()
        }

  @type t :: %__MODULE__{
          input: non_neg_integer() | nil,
          output: non_neg_integer() | nil,
          cache_read: non_neg_integer() | nil,
          cache_write: non_neg_integer() | nil,
          cache_write_long: non_neg_integer() | nil,
          total_tokens: non_neg_integer() | nil,
          cost: map() | nil,
          price_known: boolean() | nil,
          context_tokens: non_neg_integer() | nil,
          context_budget: map() | nil,
          turns: non_neg_integer() | nil,
          tool_errors: non_neg_integer() | nil,
          occurrences: [occurrence()] | nil
        }

  @occurrence_fields [:model, :provider, :at_ms, :usage]

  @doc """
  Build from a map that may arrive over the wire, coercing each occurrence's usage too.
  Keys other than the canonical field names are dropped.
  """
  @spec from_map(map() | struct() | keyword()) :: t()
  def from_map(%__MODULE__{} = usage), do: usage

  def from_map(attrs) when is_map(attrs) or is_list(attrs) do
    usage = super(attrs)

    case usage.occurrences do
      occurrences when is_list(occurrences) ->
        %{usage | occurrences: Enum.map(occurrences, &occurrence_from_map/1)}

      _ ->
        usage
    end
  end

  @doc """
  Tokens in the model context after the latest provider call: `context_tokens` when
  reported, otherwise the last occurrence's `input + cache_read + cache_write`.

  Never derived from the run's cumulative counters. `nil` when unknown.
  """
  @spec context_tokens(t() | term()) :: non_neg_integer() | nil
  def context_tokens(%__MODULE__{context_tokens: tokens})
      when is_integer(tokens) and tokens >= 0,
      do: tokens

  def context_tokens(%__MODULE__{occurrences: [_ | _] = occurrences}) do
    case List.last(occurrences) do
      %{usage: %__MODULE__{input: input, cache_read: read, cache_write: write}}
      when is_integer(input) and input >= 0 and is_integer(read) and read >= 0 and
             is_integer(write) and write >= 0 ->
        input + read + write

      _ ->
        nil
    end
  end

  def context_tokens(_usage), do: nil

  defp occurrence_from_map(occurrence) when is_map(occurrence) do
    occurrence =
      Enum.reduce(occurrence, %{}, fn {key, value}, acc ->
        case LemonCore.Events.Payload.normalize_key(key, @occurrence_fields) do
          {:ok, field} -> Map.put(acc, field, value)
          :error -> acc
        end
      end)

    case Map.get(occurrence, :usage) do
      usage when is_map(usage) -> %{occurrence | usage: from_map(usage)}
      _ -> occurrence
    end
  end

  defp occurrence_from_map(occurrence), do: occurrence
end
