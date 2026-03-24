defmodule LemonCore.Retry do
  @moduledoc """
  Shared retry backoff utilities extracted from duplicated implementations
  across lemon_channels and lemon_gateway.
  """

  @doc """
  Exponential backoff: `base_ms * 2^attempt`.

  ## Examples

      iex> LemonCore.Retry.exponential_backoff(500, 0)
      500
      iex> LemonCore.Retry.exponential_backoff(500, 3)
      4000
  """
  @spec exponential_backoff(pos_integer(), non_neg_integer()) :: pos_integer()
  def exponential_backoff(base_ms, attempt) do
    multiplier = trunc(:math.pow(2, attempt))
    base_ms * max(multiplier, 1)
  end

  @doc """
  Exponential backoff with a configurable multiplier (factor).

  Useful when the growth factor is not 2 (e.g. WhatsApp reconnect uses 1.8).

  ## Examples

      iex> LemonCore.Retry.exponential_backoff(2000, 0, 1.8)
      2000
  """
  @spec exponential_backoff(pos_integer(), non_neg_integer(), number()) :: pos_integer()
  def exponential_backoff(base_ms, attempt, factor) do
    round(base_ms * :math.pow(factor, attempt))
  end

  @doc """
  Adds symmetric jitter to a delay value.

  Returns a value in the range `[delay * (1 - jitter_fraction), delay * (1 + jitter_fraction)]`.

  ## Examples

      iex> result = LemonCore.Retry.with_jitter(1000, 0.25)
      iex> result >= 750 and result <= 1250
      true
  """
  @spec with_jitter(number(), float()) :: non_neg_integer()
  def with_jitter(delay_ms, jitter_fraction \\ 0.25) do
    jitter = delay_ms * jitter_fraction * (:rand.uniform() * 2 - 1)
    round(delay_ms + jitter) |> max(0)
  end

  @doc """
  Exponential backoff capped at a maximum value, with optional jitter.

  ## Options

    * `:factor` - growth factor (default: 2)
    * `:jitter` - jitter fraction, 0 to disable (default: 0)

  ## Examples

      iex> LemonCore.Retry.capped_backoff(500, 2, 10_000)
      2000
      iex> LemonCore.Retry.capped_backoff(500, 10, 10_000)
      10_000
  """
  @spec capped_backoff(pos_integer(), non_neg_integer(), pos_integer(), keyword()) ::
          pos_integer()
  def capped_backoff(base_ms, attempt, max_ms, opts \\ []) do
    factor = Keyword.get(opts, :factor, 2)
    jitter_fraction = Keyword.get(opts, :jitter, 0)

    delay = round(base_ms * :math.pow(factor, attempt)) |> min(max_ms)

    if jitter_fraction > 0 do
      with_jitter(delay, jitter_fraction)
    else
      delay
    end
  end

  @doc """
  Parses a retry-after value from an HTTP response body.

  Supports:
  - JSON body with `parameters.retry_after` (Telegram-style)
  - Plain text with "retry after N" pattern

  Returns milliseconds, or 0 if not found.
  """
  @spec parse_retry_after(term()) :: non_neg_integer()
  def parse_retry_after(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> parse_retry_after(decoded)
      _ -> parse_retry_after_from_text(body)
    end
  end

  def parse_retry_after(body) when is_map(body) do
    with params when is_map(params) <- body["parameters"] || body[:parameters],
         seconds when is_number(seconds) <- params["retry_after"] || params[:retry_after],
         true <- seconds > 0 do
      trunc(seconds * 1000)
    else
      _ -> 0
    end
  end

  def parse_retry_after(_body), do: 0

  defp parse_retry_after_from_text(body) do
    case Regex.run(~r/retry after (\d+(?:\.\d+)?)/i, body, capture: :all_but_first) do
      [seconds] ->
        case Float.parse(seconds) do
          {value, _} when value > 0 -> trunc(value * 1000)
          _ -> 0
        end

      _ ->
        0
    end
  end
end
