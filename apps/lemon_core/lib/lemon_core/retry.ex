defmodule LemonCore.Retry.Policy do
  @moduledoc "Bounded retry policy. Attempts include the initial call; attempt indexes are zero-based."
  defstruct max_attempts: 3,
            base_delay_ms: 500,
            max_delay_ms: 30_000,
            max_retry_after_ms: nil,
            jitter: :equal,
            jitter_fraction: 0.25,
            jitter_fun: &:rand.uniform/1,
            sleep_fun: nil,
            alternate_available: false,
            classify: nil,
            factor: 2

  @type t :: %__MODULE__{}
end

defmodule LemonCore.Retry do
  @moduledoc """
  Shared bounded retry policy for platform delivery and durable scheduling.
  Attempts include the first call; failed attempt indexes start at zero.
  Schedulers use `retry_allowed?/2` and `delay/3` without blocking owners.
  `delay/3` returns `:give_up` once the total-attempt budget is exhausted,
  including when a server hint is present. Raw backoff helpers are unbounded
  by the attempt budget.
  AI is an independent foundation package and owns its provider retry policy.
  """
  alias LemonCore.Retry.Policy
  @type policy :: Policy.t()

  def policy(options \\ [])
  def policy(%Policy{} = policy), do: policy

  def policy(options) do
    options = Map.new(options)
    policy = struct!(Policy, Map.take(options, Map.keys(Map.from_struct(%Policy{}))))

    Enum.each([:max_attempts, :base_delay_ms, :max_delay_ms], fn key ->
      value = Map.fetch!(policy, key)
      minimum = if key == :max_attempts, do: 1, else: 0

      valid =
        (key == :max_delay_ms and value == :infinity) or
          (is_integer(value) and value >= minimum)

      if not valid,
        do: raise(ArgumentError, "#{key} must be an integer >= #{minimum}")
    end)

    policy
  end

  def retry_allowed?(attempt, %{max_attempts: maximum}), do: attempt + 1 < maximum

  def backoff_delay_ms(attempt, policy) do
    capped =
      min(
        round(policy.base_delay_ms * :math.pow(Map.get(policy, :factor, 2), min(attempt, 30))),
        policy.max_delay_ms
      )

    random = Map.get(policy, :jitter_fun, &:rand.uniform/1)

    case Map.get(policy, :jitter, :equal) do
      :none ->
        capped

      :equal ->
        half = div(capped, 2)
        if capped == 0, do: 0, else: half + random.(max(capped - half, 1))

      :symmetric ->
        fraction = Map.get(policy, :jitter_fraction, 0.25)
        max(0, round(capped * (1 + fraction * (2 * random.(1_000_000) / 1_000_000 - 1))))
    end
  end

  def delay(policy, attempt, hint \\ nil) do
    ceiling = Map.get(policy, :max_retry_after_ms) || policy.max_delay_ms

    cond do
      not retry_allowed?(attempt, policy) -> :give_up
      is_integer(hint) and hint > ceiling -> :give_up
      is_integer(hint) -> max(hint, 0)
      true -> backoff_delay_ms(attempt, policy)
    end
  end

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
    fraction = Keyword.get(opts, :jitter, 0)

    retry_policy =
      policy(
        base_delay_ms: base_ms,
        max_delay_ms: max_ms,
        factor: Keyword.get(opts, :factor, 2),
        jitter: if(fraction > 0, do: :symmetric, else: :none),
        jitter_fraction: fraction
      )

    backoff_delay_ms(attempt, retry_policy)
  end

  @doc """
  Parses a retry-after value from an HTTP response body.

  Supports:
  - JSON body with `parameters.retry_after` (chat-platform style)
  - Plain text with "retry after N" pattern

  Returns milliseconds, or 0 if not found.
  """
  @spec parse_retry_after(term()) :: non_neg_integer()
  def parse_retry_after(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> parse_retry_after(decoded)
      _ -> parse_platform_retry_after_from_text(body)
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

  defp parse_platform_retry_after_from_text(body) do
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
