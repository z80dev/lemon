defmodule Ai.Providers.RetryHelper do
  @moduledoc """
  Shared retry utilities for AI provider implementations.

  Provides exponential backoff with jitter, retryable HTTP status detection,
  transport error classification, and error text pattern matching.
  """

  @default_retryable_statuses [408, 409, 425, 429, 500, 502, 503, 504, 520, 521, 522, 523, 524]

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
  Check whether an HTTP status code is retryable.

  Uses the comprehensive default list when called with one argument.
  Pass an explicit list of statuses as second argument to override.
  """
  @spec retryable_http_status?(integer()) :: boolean()
  def retryable_http_status?(status) when is_integer(status) do
    status in @default_retryable_statuses
  end

  def retryable_http_status?(_), do: false

  @spec retryable_http_status?(integer(), list(integer())) :: boolean()
  def retryable_http_status?(status, statuses) when is_integer(status) and is_list(statuses) do
    status in statuses
  end

  @doc """
  Check whether a transport error is retryable.

  Accepts a `Req.TransportError` struct or a raw reason term.
  """
  @spec retryable_transport_error?(term()) :: boolean()
  def retryable_transport_error?(%Req.TransportError{reason: reason}) do
    retryable_transport_reason?(reason)
  end

  def retryable_transport_error?(reason), do: retryable_transport_reason?(reason)

  @doc """
  Check whether a transport reason term is retryable.
  """
  @spec retryable_transport_reason?(term()) :: boolean()
  def retryable_transport_reason?(reason)
      when reason in [
             :timeout,
             :closed,
             :econnrefused,
             :econnreset,
             :enetdown,
             :enetwork_unreachable,
             :nxdomain,
             :ehostunreach,
             :unreachable
           ],
      do: true

  def retryable_transport_reason?({:tls_alert, {_alert, _detail}}), do: true
  def retryable_transport_reason?({:failed_connect, _}), do: true
  def retryable_transport_reason?({:closed, _}), do: true

  def retryable_transport_reason?(reason) when is_tuple(reason) do
    reason_text = reason |> inspect() |> String.downcase()

    String.contains?(reason_text, "timeout") or
      String.contains?(reason_text, "temporarily unavailable") or
      String.contains?(reason_text, "bad_record_mac")
  end

  def retryable_transport_reason?(_), do: false

  @doc """
  Check whether an error text matches known retryable patterns via regex.

  Matches: rate limit, overloaded, service unavailable, upstream connect,
  connection refused, resource exhausted, other side closed.
  """
  @spec retryable_error_text?(String.t()) :: boolean()
  def retryable_error_text?(error_text) when is_binary(error_text) do
    Regex.match?(
      ~r/rate.?limit|overloaded|service.?unavailable|upstream.?connect|connection.?refused|resource.?exhausted|other.?side.?closed/i,
      error_text
    )
  end

  def retryable_error_text?(_), do: false

  @doc """
  Extract a provider retry delay from headers or error text.

  Returns milliseconds with a 1s buffer, matching the existing provider retry
  behavior for `retry-after`, `x-ratelimit-reset-after`, `retryDelay`, and
  common text retry hints.
  """
  @spec extract_retry_delay_ms(String.t(), map() | list()) :: non_neg_integer() | nil
  def extract_retry_delay_ms(error_text, headers \\ %{}) do
    headers = normalize_headers(headers)

    delay_from_headers =
      cond do
        retry_after = Map.get(headers, "retry-after") ->
          parse_seconds_delay(retry_after)

        retry_after_ms = Map.get(headers, "retry-after-ms") ->
          parse_milliseconds_delay(retry_after_ms)

        retry_after_ms = Map.get(headers, "x-ms-retry-after-ms") ->
          parse_milliseconds_delay(retry_after_ms)

        reset_after = Map.get(headers, "x-ratelimit-reset-after") ->
          parse_seconds_delay(reset_after)

        true ->
          nil
      end

    delay_from_headers || extract_retry_delay_from_text(error_text)
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
  defp normalize_header_value(value), do: to_string(value)

  defp parse_seconds_delay(value) do
    case Float.parse(value) do
      {seconds, ""} when seconds > 0 -> normalize_delay_ms(seconds * 1000)
      _ -> nil
    end
  end

  defp parse_milliseconds_delay(value) do
    case Float.parse(value) do
      {milliseconds, ""} when milliseconds > 0 -> normalize_delay_ms(milliseconds)
      _ -> nil
    end
  end

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
