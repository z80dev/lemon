defmodule LemonAi.Providers.RetryHelper do
  @moduledoc """
  Shared retry utilities for AI provider implementations.

  Provides the in-provider retry policy (attempt count, capped exponential
  backoff with jitter, `retry-after` honoring), retryable HTTP status
  detection, transport error classification, and error text pattern matching.

  ## Configuration

      config :lemon_ai, :provider_retry,
        max_attempts: 4,            # total attempts, including the first
        base_delay_ms: 1_000,       # first backoff delay
        max_delay_ms: 30_000,       # backoff cap
        max_retry_after_ms: 60_000, # longer server-requested waits are not slept in-provider
        sleep_fun: &Process.sleep/1 # injectable for tests

  When the server asks for a longer wait than `max_retry_after_ms`, the
  provider stops retrying and surfaces the delay as
  `LemonAi.Types.AssistantMessage.retry_after_ms` so the caller can decide.
  """

  @default_max_attempts 4
  @default_base_delay_ms 1_000
  @default_max_delay_ms 30_000
  @default_max_retry_after_ms 60_000

  @type policy :: %{
          max_attempts: pos_integer(),
          base_delay_ms: pos_integer(),
          max_delay_ms: pos_integer(),
          max_retry_after_ms: non_neg_integer()
        }

  @anthropic_rate_limit_kinds ["requests", "tokens", "input-tokens", "output-tokens"]
  @http_months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  @doc "The configured provider retry policy (see moduledoc)."
  @spec policy() :: policy()
  def policy do
    config = Application.get_env(:lemon_ai, :provider_retry, [])

    %{
      max_attempts: positive(config, :max_attempts, @default_max_attempts),
      base_delay_ms: positive(config, :base_delay_ms, @default_base_delay_ms),
      max_delay_ms: positive(config, :max_delay_ms, @default_max_delay_ms),
      max_retry_after_ms: positive(config, :max_retry_after_ms, @default_max_retry_after_ms)
    }
  end

  @doc """
  The provider policy with per-request overrides from `StreamOptions`.
  Completion retries set `max_attempts: 1` here so HTTP and completion loops
  share one bounded attempt budget instead of multiplying each other.
  """
  @spec policy(LemonAi.Types.StreamOptions.t()) :: policy()
  def policy(%{provider_retry: overrides}) when is_map(overrides) do
    Enum.reduce(policy(), %{}, fn {key, default}, acc ->
      value = Map.get(overrides, key, default)
      Map.put(acc, key, if(is_integer(value) and value > 0, do: value, else: default))
    end)
  end

  def policy(_options), do: policy()

  defp positive(config, key, default) do
    case Keyword.get(config, key, default) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  @doc """
  Whether another attempt is allowed after the 0-based `attempt` failed.
  """
  @spec retry_allowed?(non_neg_integer(), policy()) :: boolean()
  def retry_allowed?(attempt, %{max_attempts: max_attempts}), do: attempt + 1 < max_attempts

  @doc """
  Backoff before retrying after the 0-based `attempt`: exponential from
  `base_delay_ms`, capped at `max_delay_ms`, with equal jitter (a random delay
  in the upper half of the capped value).
  """
  @spec backoff_delay_ms(non_neg_integer(), policy()) :: pos_integer()
  def backoff_delay_ms(attempt, %{base_delay_ms: base, max_delay_ms: cap}) do
    capped = min(base * Integer.pow(2, min(attempt, 30)), cap)
    half = max(div(capped, 2), 1)
    half + :rand.uniform(half)
  end

  @doc """
  Delay to wait before retrying an HTTP failure: the server's retry-after
  hint when present, otherwise `backoff_delay_ms/2`. Returns `:give_up` when
  the server asks for more than the policy's `max_retry_after_ms`.
  """
  @spec http_retry_delay_ms(non_neg_integer(), map() | list(), policy()) ::
          pos_integer() | :give_up
  def http_retry_delay_ms(attempt, headers, policy) do
    case retry_after_ms(headers) do
      nil -> backoff_delay_ms(attempt, policy)
      ms when ms > policy.max_retry_after_ms -> :give_up
      ms -> ms
    end
  end

  @doc "Sleep for `ms` using the configured `:sleep_fun` (default `Process.sleep/1`)."
  @spec sleep(non_neg_integer()) :: :ok
  def sleep(ms) do
    sleep_fun =
      :lemon_ai
      |> Application.get_env(:provider_retry, [])
      |> Keyword.get(:sleep_fun, &Process.sleep/1)

    _ = sleep_fun.(ms)
    :ok
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

    parse_retry_after(Map.get(headers, "retry-after"), now) ||
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

  defp parse_retry_after(value, now) when is_binary(value) do
    parse_seconds_delay(value) || parse_http_date_delay(value, now)
  end

  defp parse_retry_after(_, _), do: nil

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
  Compute exponential backoff delay with jitter.

  Returns a random delay between `base * 2^attempt / 2` and `base * 2^attempt`.
  """
  @spec exponential_backoff_with_jitter(pos_integer(), non_neg_integer()) :: pos_integer()
  def exponential_backoff_with_jitter(base_ms, attempt) do
    base = (base_ms * :math.pow(2, attempt)) |> trunc()
    half = max(div(base, 2), 1)
    half + :rand.uniform(half)
  end

  @doc """
  Check whether an HTTP status code is retryable in place against the SAME
  provider (immediate retry with backoff).

  The status set is sourced from `LemonAi.Error.transport_retry_statuses/0`.
  This status-only predicate cannot inspect permanent provider-body evidence.
  When the error body is available, use `retryable_http_error?/2` instead.

  Pass an explicit list of statuses as second argument to override.
  """
  @spec retryable_http_status?(integer()) :: boolean()
  def retryable_http_status?(status) when is_integer(status) do
    status in LemonAi.Error.transport_retry_statuses()
  end

  def retryable_http_status?(_), do: false

  @spec retryable_http_status?(integer(), list(integer())) :: boolean()
  def retryable_http_status?(status, statuses) when is_integer(status) and is_list(statuses) do
    status in statuses
  end

  @doc """
  Whether an HTTP failure is retryable against the same credential.

  Delegates status and provider-body classification to `LemonAi.Error`, so
  authentication, client, context overflow and account quota exhaustion never
  retry even when the HTTP status alone is retryable.
  """
  @spec retryable_http_error?(integer(), term()) :: boolean()
  def retryable_http_error?(status, body),
    do: LemonAi.Error.retryable?({:http_error, status, body})

  @doc """
  Check whether a transport error is retryable.

  Accepts a `Req.TransportError` struct or a raw reason term.
  """
  @spec retryable_transport_error?(term()) :: boolean()
  def retryable_transport_error?(reason), do: LemonAi.Error.retryable?(reason)

  @doc """
  Check whether a transport reason term is retryable.
  """
  @spec retryable_transport_reason?(term()) :: boolean()
  def retryable_transport_reason?(reason), do: LemonAi.Error.retryable?(reason)

  @doc """
  Check whether error text is retryable using the common public classifier.

  Persistent quota limits and permanent auth/client/context errors take
  precedence over transient phrases such as "try again later".
  """
  @spec retryable_error_text?(String.t()) :: boolean()
  def retryable_error_text?(error_text) when is_binary(error_text),
    do: LemonAi.Error.retryable?(error_text)

  def retryable_error_text?(_), do: false

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
