defmodule LemonAi.Retry.Policy do
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
            classify: &LemonAi.Error.classify/1,
            error_retry_after_ms: nil,
            factor: 2

  @type t :: %__MODULE__{}
end

defmodule LemonAi.Retry do
  @moduledoc """
  Shared bounded retry execution, timing and server hints.

  Build a policy with `policy/1`. Provider, completion and agent response
  retries share this helper without a dependency on another foundation package.
  `run/2` takes a one-based callback and keeps one total-attempt budget.
  Only side-effect-free operations may be replayed.
  Delay helpers return `:give_up` when the total-attempt budget is exhausted;
  `backoff_delay_ms/2` computes raw backoff without that budget gate.

  `run/2` accepts `:failure` (result to `{:failed, error}` or `:success`),
  `:retryable?`, `:classify`, and policy fields. Cancellation subscribes before
  the first check through `:subscribe_cancel`, returning
  `{:message, exact_message, unsubscribe_fun}`; cleanup runs on every exit.
  `:cancelled?` returns false, true (aborted), or a cancellation reason atom.
  Default waits receive exact cancellation messages without polling. Custom
  `:sleep_fun` callbacks own responsiveness and may return `{:error, reason}`.
  Cancellation after a failed attempt preserves its result; cancellation while
  waiting returns `{:error, reason}`. Providers nested under a response retry
  owner must receive `max_attempts: 1`, not a second budget.
  """
  alias LemonAi.Retry.Policy
  @anthropic_rate_limit_kinds ["requests", "tokens", "input-tokens", "output-tokens"]
  @http_months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)
  @type policy :: Policy.t()

  def policy(options \\ [])
  def policy(%Policy{} = policy), do: policy

  def policy(options) do
    options = Map.new(options)
    policy = struct!(Policy, Map.take(options, Map.keys(Map.from_struct(%Policy{}))))

    Enum.each([:max_attempts, :base_delay_ms, :max_delay_ms], fn key ->
      value = Map.fetch!(policy, key)

      if not is_integer(value),
        do: raise(ArgumentError, "#{key} must be an integer")
    end)

    %{
      policy
      | max_attempts: max(1, policy.max_attempts),
        base_delay_ms: max(1, policy.base_delay_ms),
        max_delay_ms: max(0, policy.max_delay_ms)
    }
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

  defp classify(error, policy) do
    case Map.get(policy, :classify) do
      nil -> :unknown
      fun -> fun.(error)
    end
  end

  def rotate_rate_limit?(policy, error),
    do: Map.get(policy, :alternate_available, false) and classify(error, policy) == :rate_limit

  def http_retry_delay_ms(attempt, headers, policy, error \\ nil) do
    if rotate_rate_limit?(policy, error),
      do: :give_up,
      else: retry_delay_ms(error, attempt, policy, retry_after_ms(headers))
  end

  def retry_delay_ms(error, attempt, policy, hint \\ nil) do
    if retry_allowed?(attempt, policy) do
      hint =
        hint ||
          case Map.get(policy, :error_retry_after_ms) do
            nil -> error_retry_after_ms(error)
            callback -> callback.(error)
          end

      ceiling = Map.get(policy, :max_retry_after_ms) || policy.max_delay_ms

      if classify(error, policy) == :rate_limit do
        random = Map.get(policy, :jitter_fun, &:rand.uniform/1)
        base = min(policy.base_delay_ms * Integer.pow(2, min(attempt, 30)), policy.max_delay_ms)
        delay = max(hint || 0, max(10_000, base) + random.(5_000))
        if delay > ceiling, do: :give_up, else: delay
      else
        delay(policy, attempt, hint)
      end
    else
      :give_up
    end
  end

  def run(callback, options \\ []) do
    options = Map.new(options)
    policy = policy(options)

    case Map.get(options, :subscribe_cancel) do
      nil ->
        attempt(callback, options, policy, 1)

      subscribe ->
        {:message, message, unsubscribe} = subscribe.()

        try do
          attempt(callback, Map.put(options, :cancel_message, message), policy, 1)
        after
          unsubscribe.()
        end
    end
  end

  defp attempt(callback, options, policy, number) do
    case cancellation(options) do
      false ->
        result = callback.(number)
        failure = Map.get(options, :failure, &default_failure/1)
        retryable = Map.get(options, :retryable?, &LemonAi.Error.retryable?/1)

        case failure.(result) do
          {:failed, error} ->
            if cancellation(options) == false and retry_allowed?(number - 1, policy) and
                 retryable.(error) do
              case retry_delay_ms(error, number - 1, policy) do
                :give_up ->
                  result

                delay ->
                  case wait(delay, options) do
                    :ok -> attempt(callback, options, policy, number + 1)
                    {:error, _} = canceled -> canceled
                  end
              end
            else
              result
            end

          :success ->
            result
        end

      reason ->
        {:error, reason}
    end
  end

  defp default_failure(
         %{__struct__: LemonAi.Types.AssistantMessage, stop_reason: :error} = error
       ), do: {:failed, error}

  defp default_failure(
         {:ok, %{__struct__: LemonAi.Types.AssistantMessage, stop_reason: :error} = error}
       ), do: {:failed, error}

  defp default_failure(
         {:error, %{__struct__: LemonAi.Types.AssistantMessage, stop_reason: reason}}
       )
       when reason in [:aborted, :redirected], do: :success

  defp default_failure({:error, reason}), do: {:failed, reason}
  defp default_failure(_), do: :success

  defp cancellation(options) do
    case Map.get(options, :cancelled?, fn -> false end).() do
      false -> false
      true -> :aborted
      reason when is_atom(reason) -> reason
    end
  end

  def wait(delay, options \\ []) do
    options = Map.new(options)

    case cancellation(options) do
      false ->
        case Map.get(options, :sleep_fun) do
          nil ->
            wait_until(System.monotonic_time(:millisecond) + delay, options)

          sleep ->
            case sleep.(delay) do
              {:error, _} = canceled -> canceled
              _ -> cancellation_result(options)
            end
        end

      reason ->
        {:error, reason}
    end
  end

  defp cancellation_result(options) do
    case cancellation(options) do
      false -> :ok
      reason -> {:error, reason}
    end
  end

  defp wait_until(deadline, options) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    messages =
      Map.get(options, :cancel_messages, []) ++
        if(Map.has_key?(options, :cancel_message), do: [options.cancel_message], else: [])

    message_set = Map.new(messages, &{&1, true})

    case cancellation(options) do
      false when remaining > 0 ->
        receive do
          message when is_map_key(message_set, message) ->
            case cancellation(options) do
              false ->
                if Map.get(options, :cancel_message_requires_state, false),
                  do: wait_until(deadline, options),
                  else: {:error, :aborted}

              reason ->
                {:error, reason}
            end
        after
          remaining -> cancellation_result(options)
        end

      false ->
        :ok

      reason ->
        {:error, reason}
    end
  end

  @doc """
  Server-requested retry delay in milliseconds from response headers, or nil.

  Reads, in order: `retry-after` (delta-seconds or HTTP-date),
  `retry-after-ms`, `x-ms-retry-after-ms`, `x-ratelimit-reset-after`, then the
  latest `anthropic-ratelimit-<kind>-reset` (RFC 3339) among limits whose
  `-remaining` header is `0`. Invalid or non-positive hints fall through to
  the next header; if none is valid, returns nil.
  """
  @spec retry_after_ms(map() | list(), DateTime.t()) :: pos_integer() | nil
  def retry_after_ms(headers, now \\ DateTime.utc_now()) do
    headers = normalize_headers(headers)

    parse_header_retry_after(Map.get(headers, "retry-after"), now) ||
      parse_milliseconds_delay(Map.get(headers, "retry-after-ms")) ||
      parse_milliseconds_delay(Map.get(headers, "x-ms-retry-after-ms")) ||
      parse_seconds_delay(Map.get(headers, "x-ratelimit-reset-after")) ||
      anthropic_rate_limit_reset_ms(headers, now)
  end

  @doc """
  Retry timing from a failed completion or transport result.

  Structured error details take precedence over the message's explicit
  `retry_after_ms`, then top-level rate-limit metadata, response headers and
  finally error text. Invalid or missing values fall through. Header priority
  remains the same as `retry_after_ms/2`; timing never changes retry eligibility.
  """
  @spec error_retry_after_ms(term()) :: non_neg_integer() | nil
  def error_retry_after_ms({:error, reason}), do: error_retry_after_ms(reason)

  def error_retry_after_ms({:http_error, status, body, headers}) do
    retry_after_ms(headers) ||
      error_retry_after_ms(LemonAi.Error.parse_http_error(status, body, headers))
  end

  def error_retry_after_ms({:http_error, status, body}),
    do: error_retry_after_ms(LemonAi.Error.parse_http_error(status, body))

  def error_retry_after_ms(error) when is_map(error) do
    error_retry_after_ms(field(error, :error_details)) ||
      valid_delay(field(error, :retry_after_ms)) ||
      rate_limit_delay(field(error, :rate_limit_info)) ||
      retry_after_ms(field(error, :headers)) ||
      error_retry_after_ms(field(error, :error_message)) ||
      error_retry_after_ms(field(error, :provider_message)) ||
      error_retry_after_ms(field(error, :message))
  end

  def error_retry_after_ms(error) when is_binary(error), do: extract_retry_delay_ms(error)
  def error_retry_after_ms(_error), do: nil

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp valid_delay(delay) when is_integer(delay) and delay >= 0, do: delay
  defp valid_delay(_), do: nil
  defp rate_limit_delay(info) when is_map(info), do: valid_delay(field(info, :retry_after))
  defp rate_limit_delay(_), do: nil

  defp parse_header_retry_after(value, now) when is_binary(value) do
    parse_seconds_delay(value) || parse_http_date_delay(value, now)
  end

  defp parse_header_retry_after(_, _), do: nil

  defp anthropic_rate_limit_reset_ms(headers, now) do
    @anthropic_rate_limit_kinds
    |> Enum.filter(&(Map.get(headers, "anthropic-ratelimit-#{&1}-remaining") == "0"))
    |> Enum.map(&Map.get(headers, "anthropic-ratelimit-#{&1}-reset"))
    |> Enum.map(&parse_rfc3339_delay(&1, now))
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> nil end)
  end

  defp parse_rfc3339_delay(value, now) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, reset_at, _offset} -> positive_delay(DateTime.diff(reset_at, now, :millisecond))
      _ -> nil
    end
  end

  defp parse_rfc3339_delay(_value, _now), do: nil

  # IMF-fixdate, e.g. "Wed, 21 Oct 2015 07:28:00 GMT" (RFC 9110 §5.6.7).
  defp parse_http_date_delay(value, now) do
    with [_, day, month, year, time] <-
           Regex.run(~r/^\w{3}, (\d{2}) (\w{3}) (\d{4}) (\d{2}:\d{2}:\d{2}) GMT$/, value),
         month_index when is_integer(month_index) <-
           Enum.find_index(@http_months, &(&1 == month)),
         {:ok, date} <-
           Date.new(String.to_integer(year), month_index + 1, String.to_integer(day)),
         {:ok, time} <- Time.from_iso8601(time),
         {:ok, at} <- DateTime.new(date, time, "Etc/UTC") do
      positive_delay(DateTime.diff(at, now, :millisecond))
    else
      _ -> nil
    end
  end

  defp positive_delay(ms) when is_number(ms) and ms > 0, do: ceil(ms)
  defp positive_delay(_), do: nil

  @doc """
  Extract a provider retry delay from headers or error text.

  Returns milliseconds with a 1s buffer, matching the existing provider retry
  behavior for `retry-after`, `x-ratelimit-reset-after`, `retryDelay`, and
  common text retry hints.
  """
  @spec extract_retry_delay_ms(String.t(), map() | list()) :: non_neg_integer() | nil
  def extract_retry_delay_ms(error_text, headers \\ %{}) do
    case retry_after_ms(headers) do
      nil -> extract_retry_delay_from_text(error_text)
      ms -> ms + 1000
    end
  end

  defp normalize_headers(headers) when is_map(headers) do
    Map.new(headers, fn {key, value} ->
      {normalize_header_key(key), normalize_header_value(value)}
    end)
  end

  defp normalize_headers(headers) when is_list(headers) do
    Map.new(headers, fn {key, value} ->
      {normalize_header_key(key), normalize_header_value(value)}
    end)
  end

  defp normalize_headers(_), do: %{}

  defp normalize_header_key(key), do: key |> to_string() |> String.downcase()

  defp normalize_header_value([value | _]), do: normalize_header_value(value)
  defp normalize_header_value(value), do: value |> to_string() |> String.trim()

  defp parse_seconds_delay(value) when is_binary(value) do
    case Float.parse(value) do
      {seconds, ""} -> positive_delay(seconds * 1000)
      _ -> nil
    end
  end

  defp parse_seconds_delay(_), do: nil

  defp parse_milliseconds_delay(value) when is_binary(value) do
    case Float.parse(value) do
      {milliseconds, ""} -> positive_delay(milliseconds)
      _ -> nil
    end
  end

  defp parse_milliseconds_delay(_), do: nil

  defp extract_retry_delay_from_text(text) when is_binary(text) do
    duration_pattern = ~r/reset after (?:(\d+)h)?(?:(\d+)m)?(\d+(?:\.\d+)?)s/i

    case Regex.run(duration_pattern, text) do
      [_, hours, minutes, seconds] ->
        h = if hours && hours != "", do: String.to_integer(hours), else: 0
        m = if minutes && minutes != "", do: String.to_integer(minutes), else: 0
        {s, _} = Float.parse(seconds)
        normalize_delay_ms(((h * 60 + m) * 60 + s) * 1000)

      _ ->
        extract_retry_in_delay(text)
    end
  end

  defp extract_retry_delay_from_text(_), do: nil

  defp extract_retry_in_delay(text) do
    retry_in_pattern = ~r/Please retry in ([0-9.]+)(ms|s)/i

    case Regex.run(retry_in_pattern, text) do
      [_, value, unit] ->
        parse_unit_delay(value, unit)

      _ ->
        extract_json_retry_delay(text)
    end
  end

  defp extract_json_retry_delay(text) do
    retry_delay_pattern = ~r/"retryDelay":\s*"([0-9.]+)(ms|s)"/i

    case Regex.run(retry_delay_pattern, text) do
      [_, value, unit] -> parse_unit_delay(value, unit)
      _ -> nil
    end
  end

  defp parse_unit_delay(value, unit) do
    case Float.parse(value) do
      {num, _} ->
        ms = if String.downcase(unit) == "ms", do: num, else: num * 1000
        normalize_delay_ms(ms)

      _ ->
        nil
    end
  end

  defp normalize_delay_ms(ms) when ms > 0, do: ceil(ms) + 1000
  defp normalize_delay_ms(_), do: nil
end
