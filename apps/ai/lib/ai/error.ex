defmodule Ai.Error do
  @moduledoc """
  Error handling utilities for AI provider responses.

  This module provides functions for:
  - Parsing HTTP error responses from various providers
  - Extracting rate limit information from response headers
  - Classifying errors for appropriate handling
  - Generating user-friendly error messages
  """

  require Logger

  # ============================================================================
  # Types
  # ============================================================================

  @type error_category ::
          :rate_limit | :auth | :client | :context_length | :server | :transient | :unknown

  @type rate_limit_info :: %{
          limit: non_neg_integer() | nil,
          remaining: non_neg_integer() | nil,
          reset_at: DateTime.t() | nil,
          retry_after: non_neg_integer() | nil
        }

  @type parsed_error :: %{
          category: error_category(),
          status: non_neg_integer() | nil,
          message: String.t(),
          provider_message: String.t() | nil,
          rate_limit_info: rate_limit_info() | nil,
          retryable: boolean()
        }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Parse an HTTP error response into a structured error.

  ## Examples

      iex> Ai.Error.parse_http_error(429, %{"error" => %{"message" => "Rate limit exceeded"}}, headers)
      %{category: :rate_limit, status: 429, message: "Rate limit exceeded", ...}

      iex> Ai.Error.parse_http_error(500, "Internal Server Error", [])
      %{category: :server, status: 500, message: "Internal server error", ...}
  """
  @spec parse_http_error(non_neg_integer(), term(), map() | [{term(), term()}]) :: parsed_error()
  def parse_http_error(status, body, headers \\ []) do
    provider_message = extract_provider_message(body)
    category = classify_error(status, body, provider_message)

    rate_limit_info =
      if category == :rate_limit, do: extract_rate_limit_info(headers, body), else: nil

    %{
      category: category,
      status: status,
      message: build_error_message(status, provider_message, category),
      provider_message: provider_message,
      rate_limit_info: rate_limit_info,
      retryable: retryable_category?(category) or retryable_status?(status)
    }
  end

  @doc """
  Extract rate limit information from response headers.

  Handles common rate limit header formats from OpenAI, Anthropic, and other providers.

  ## Headers checked

  - `x-ratelimit-limit-requests`, `x-ratelimit-limit-tokens` - Total limit
  - `x-ratelimit-remaining-requests`, `x-ratelimit-remaining-tokens` - Remaining
  - `x-ratelimit-reset-requests`, `x-ratelimit-reset-tokens` - Reset timestamp
  - `retry-after` - Seconds until retry is allowed
  - `retry-after-ms`, `x-ms-retry-after-ms` - Milliseconds until retry is allowed
  """
  @spec extract_rate_limit_info(map() | [{term(), term()}]) :: rate_limit_info()
  def extract_rate_limit_info(headers) do
    headers_map = headers_to_map(headers)

    %{
      limit:
        get_rate_limit_value(headers_map, [
          "x-ratelimit-limit-requests",
          "x-ratelimit-limit-tokens",
          "ratelimit-limit"
        ]),
      remaining:
        get_rate_limit_value(headers_map, [
          "x-ratelimit-remaining-requests",
          "x-ratelimit-remaining-tokens",
          "ratelimit-remaining"
        ]),
      reset_at: get_reset_time(headers_map),
      retry_after: get_retry_after(headers_map)
    }
  end

  defp extract_rate_limit_info(headers, body) do
    headers
    |> extract_rate_limit_info()
    |> merge_body_rate_limit_info(body)
  end

  @doc """
  Generate a user-friendly error message from an error term.
  """
  @spec format_error(term()) :: String.t()
  def format_error({:http_error, status, body}) do
    parsed = parse_http_error(status, body, [])
    parsed.message
  end

  def format_error(:rate_limited), do: "Request rate limited. Please wait before retrying."

  def format_error(:circuit_open),
    do: "Service temporarily unavailable (circuit breaker open). Please try again later."

  def format_error(:max_concurrency),
    do: "Too many concurrent requests. Please try again shortly."

  def format_error(:timeout), do: "Request timed out. Please try again."
  def format_error(:closed), do: "Connection closed unexpectedly. Please try again."
  def format_error(:econnrefused), do: "Connection refused. The service may be unavailable."
  def format_error(:econnreset), do: "Connection reset. Please try again."
  def format_error(:nxdomain), do: "DNS lookup failed. Please check your network connection."

  def format_error({:unknown_api, api}) do
    "Unknown API type: #{inspect(api)}. Please check your model configuration."
  end

  def format_error(error) when is_binary(error), do: error

  def format_error(error) do
    "An unexpected error occurred: #{inspect(error)}"
  end

  @doc """
  Check if an error is retryable.
  """
  @spec retryable?(term()) :: boolean()
  def retryable?({:http_error, status, _}), do: retryable_status?(status)
  def retryable?(:rate_limited), do: true
  def retryable?(:timeout), do: true
  def retryable?(:closed), do: true
  def retryable?(:econnrefused), do: true
  def retryable?(:econnreset), do: true
  def retryable?(:circuit_open), do: true
  def retryable?(:max_concurrency), do: true
  def retryable?({:unknown_api, _}), do: false

  def retryable?(error) when is_binary(error) do
    downcased = String.downcase(error)

    String.contains?(downcased, "timeout") or
      String.contains?(downcased, "rate limit") or
      String.contains?(downcased, "overloaded") or
      String.contains?(downcased, "temporarily") or
      String.contains?(downcased, "503") or
      String.contains?(downcased, "502") or
      String.contains?(downcased, "504")
  end

  def retryable?(_), do: false

  @doc """
  Suggest a retry delay based on the error.

  Returns the suggested delay in milliseconds, or nil if not applicable.
  Uses rate limit headers if available for more accurate retry timing.
  """
  @spec suggested_retry_delay(term()) :: non_neg_integer() | nil
  def suggested_retry_delay({:http_error, 429, _body}), do: 60_000
  def suggested_retry_delay({:http_error, 503, _body}), do: 5_000
  def suggested_retry_delay({:http_error, 502, _body}), do: 5_000
  def suggested_retry_delay({:http_error, 504, _body}), do: 10_000
  def suggested_retry_delay(:rate_limited), do: 60_000
  def suggested_retry_delay(:timeout), do: 5_000
  def suggested_retry_delay(:econnrefused), do: 10_000
  def suggested_retry_delay(:circuit_open), do: 30_000
  def suggested_retry_delay(_), do: nil

  @doc """
  Suggest a retry delay based on parsed error with rate limit info.

  This version considers rate limit headers for more accurate retry timing.

  ## Examples

      iex> error = %{rate_limit_info: %{retry_after: 30_000}}
      iex> Ai.Error.suggested_retry_delay_from_error(error)
      30_000

      iex> error = %{status: 503, rate_limit_info: nil}
      iex> Ai.Error.suggested_retry_delay_from_error(error)
      5_000
  """
  @spec suggested_retry_delay_from_error(parsed_error()) :: non_neg_integer() | nil
  def suggested_retry_delay_from_error(%{rate_limit_info: %{retry_after: retry_after}})
      when is_integer(retry_after) and retry_after > 0 do
    retry_after
  end

  def suggested_retry_delay_from_error(%{rate_limit_info: %{reset_at: reset_at}})
      when not is_nil(reset_at) do
    now = DateTime.utc_now()

    case DateTime.diff(reset_at, now, :millisecond) do
      diff when diff > 0 -> diff
      _ -> nil
    end
  end

  def suggested_retry_delay_from_error(%{category: :rate_limit}), do: 60_000
  def suggested_retry_delay_from_error(%{category: :transient}), do: 5_000

  def suggested_retry_delay_from_error(%{status: status}) do
    suggested_retry_delay({:http_error, status, nil})
  end

  def suggested_retry_delay_from_error(_), do: nil

  @doc """
  Check if the error represents an authentication failure.

  ## Examples

      iex> Ai.Error.auth_error?({:http_error, 401, "Unauthorized"})
      true

      iex> Ai.Error.auth_error?({:http_error, 500, "Server Error"})
      false
  """
  @spec auth_error?(term()) :: boolean()
  def auth_error?({:http_error, status, _}) when status in [401, 403], do: true
  def auth_error?(%{category: :auth}), do: true
  def auth_error?(_), do: false

  @doc """
  Check if the error represents a rate limit error.

  ## Examples

      iex> Ai.Error.rate_limit_error?({:http_error, 429, "Rate limited"})
      true

      iex> Ai.Error.rate_limit_error?(:rate_limited)
      true

      iex> Ai.Error.rate_limit_error?({:http_error, 500, "Server Error"})
      false
  """
  @spec rate_limit_error?(term()) :: boolean()
  def rate_limit_error?({:http_error, 429, _}), do: true
  def rate_limit_error?(:rate_limited), do: true
  def rate_limit_error?(%{category: :rate_limit}), do: true
  def rate_limit_error?(_), do: false

  @doc """
  Check if the error represents a context length exceeded error.

  ## Examples

      iex> Ai.Error.context_length_error?({:http_error, 400, %{"error" => %{"code" => "context_length_exceeded"}}})
      true

      iex> Ai.Error.context_length_error?({:http_error, 429, "Rate limited"})
      false
  """
  @spec context_length_error?(term()) :: boolean()
  def context_length_error?({:http_error, status, body}) when is_map(body) do
    context_length_error_code?(body) or
      context_length_error_message?(status, body)
  end

  def context_length_error?({:http_error, status, body}) when is_binary(body) do
    context_length_error_string?(status, body)
  end

  def context_length_error?(:context_length_exceeded), do: true

  def context_length_error?(error) when is_binary(error) do
    context_length_error_string?(nil, error)
  end

  def context_length_error?(%{category: :context_length}), do: true

  def context_length_error?(_), do: false

  @doc """
  Format rate limit information for display.

  ## Examples

      iex> info = %{limit: 100, remaining: 50, reset_at: DateTime.utc_now()}
      iex> Ai.Error.format_rate_limit_info(info)
      "Rate limit: 50/100 remaining"
  """
  @spec format_rate_limit_info(rate_limit_info() | nil) :: String.t()
  def format_rate_limit_info(nil), do: "Rate limit information unavailable"

  def format_rate_limit_info(%{limit: limit, remaining: remaining, reset_at: reset_at}) do
    base = "Rate limit: #{remaining || "unknown"}/#{limit || "unknown"} remaining"

    if reset_at do
      now = DateTime.utc_now()
      seconds = DateTime.diff(reset_at, now, :second)

      if seconds > 0 do
        time_str =
          cond do
            seconds < 60 -> "#{seconds}s"
            seconds < 3600 -> "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
            true -> "#{div(seconds, 3600)}h #{rem(div(seconds, 60), 60)}m"
          end

        "#{base} (resets in #{time_str})"
      else
        base
      end
    else
      base
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp classify_error(status, body, provider_message) do
    cond do
      context_length_error?({:http_error, status, body}) ->
        :context_length

      status in [401, 403] ->
        :auth

      status == 429 or provider_rate_limit_message?(provider_message) ->
        :rate_limit

      provider_rate_limit_body?(body) ->
        :rate_limit

      provider_transient_message?(provider_message) ->
        :transient

      true ->
        classify_status(status)
    end
  end

  defp classify_status(status) do
    cond do
      status == 429 -> :rate_limit
      status in [401, 403] -> :auth
      status >= 400 and status < 500 -> :client
      status in [502, 503, 504, 529] -> :transient
      status >= 500 -> :server
      true -> :unknown
    end
  end

  defp retryable_status?(status) do
    status in [429, 502, 503, 504, 520, 521, 522, 523, 524, 529]
  end

  defp retryable_category?(category), do: category in [:rate_limit, :transient]

  defp provider_rate_limit_message?(message) when is_binary(message) do
    downcased = String.downcase(message)

    String.contains?(downcased, "rate limit") or
      String.contains?(downcased, "rate_limit") or
      String.contains?(downcased, "too many requests")
  end

  defp provider_rate_limit_message?(_), do: false

  defp provider_rate_limit_body?(body) do
    body
    |> normalize_error_body()
    |> do_provider_rate_limit_body?()
  end

  defp do_provider_rate_limit_body?(%{"error" => error}) when is_map(error) do
    rate_limit_field?(error["type"]) or
      rate_limit_field?(error["code"]) or
      rate_limit_field?(error["status"])
  end

  defp do_provider_rate_limit_body?(%{"__type" => type}), do: rate_limit_field?(type)

  defp do_provider_rate_limit_body?(body) when is_map(body) do
    rate_limit_field?(body["type"]) or
      rate_limit_field?(body["code"]) or
      rate_limit_field?(body["status"])
  end

  defp do_provider_rate_limit_body?(_), do: false

  defp rate_limit_field?(value) when is_binary(value) do
    value
    |> String.downcase()
    |> then(fn value ->
      String.contains?(value, "rate_limit") or
        String.contains?(value, "ratelimit") or
        String.contains?(value, "throttl") or
        String.contains?(value, "too_many_requests") or
        String.contains?(value, "resource_exhausted")
    end)
  end

  defp rate_limit_field?(429), do: true
  defp rate_limit_field?(_), do: false

  defp provider_transient_message?(message) when is_binary(message) do
    downcased = String.downcase(message)

    String.contains?(downcased, "overloaded") or
      String.contains?(downcased, "temporarily unavailable") or
      String.contains?(downcased, "service unavailable") or
      String.contains?(downcased, "try again later") or
      String.contains?(downcased, "deadline exceeded")
  end

  defp provider_transient_message?(_), do: false

  defp extract_provider_message(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> extract_provider_message(decoded)
      _ -> truncate_message(body, 200)
    end
  end

  # Provider-specific error message extraction
  # Google API format (prefer first entry in errors array when present)
  defp extract_provider_message(%{"error" => %{"errors" => [%{"message" => message} | _]}})
       when is_binary(message),
       do: message

  defp extract_provider_message(%{"errors" => [%{"message" => message} | _]})
       when is_binary(message),
       do: message

  # Anthropic format
  defp extract_provider_message(%{"error" => %{"message" => message}}) when is_binary(message),
    do: message

  defp extract_provider_message(%{"error" => %{"type" => type, "message" => message}})
       when is_binary(type) and is_binary(message) do
    "#{type}: #{message}"
  end

  # OpenAI format
  defp extract_provider_message(%{"error" => %{"code" => code, "message" => message}})
       when is_binary(code) and is_binary(message) do
    "#{code}: #{message}"
  end

  defp extract_provider_message(%{"error" => %{"code" => code}}) when is_binary(code), do: code

  defp extract_provider_message(%{"error" => %{"detail" => detail}})
       when is_binary(detail) or is_list(detail),
       do: extract_detail_message(detail)

  defp extract_provider_message(%{"error" => %{"details" => details}})
       when is_binary(details) or is_list(details),
       do: extract_detail_message(details)

  # Generic error formats
  defp extract_provider_message(%{"error" => error}) when is_binary(error), do: error

  defp extract_provider_message(%{"error" => error_map}) when is_map(error_map) do
    # Try to extract nested error information
    parts = []
    parts = if error_map["type"], do: [error_map["type"] | parts], else: parts
    parts = if error_map["code"], do: [error_map["code"] | parts], else: parts
    parts = if error_map["message"], do: [error_map["message"] | parts], else: parts
    parts = if error_map["param"], do: ["param: #{error_map["param"]}" | parts], else: parts

    case parts do
      [] -> inspect(error_map) |> truncate_message(200)
      _ -> Enum.join(parts, " - ")
    end
  end

  # Direct message fields
  defp extract_provider_message(%{"message" => message}) when is_binary(message), do: message
  defp extract_provider_message(%{"Message" => message}) when is_binary(message), do: message
  defp extract_provider_message(%{"detail" => detail}) when is_binary(detail), do: detail

  defp extract_provider_message(%{"detail" => detail}) when is_list(detail),
    do: extract_detail_message(detail)

  defp extract_provider_message(%{"details" => details})
       when is_binary(details) or is_list(details),
       do: extract_detail_message(details)

  # Google API format
  defp extract_provider_message(%{"error" => %{"status" => status, "message" => message}})
       when is_binary(status) and is_binary(message) do
    "#{status}: #{message}"
  end

  # AWS/Bedrock format
  defp extract_provider_message(%{"__type" => type, "message" => message})
       when is_binary(type) and is_binary(message) do
    "#{type}: #{message}"
  end

  # Fallback for maps
  defp extract_provider_message(body) when is_map(body),
    do: inspect(body) |> truncate_message(200)

  defp extract_provider_message(_), do: nil

  defp extract_detail_message(message) when is_binary(message), do: message
  defp extract_detail_message([message | _]) when is_binary(message), do: message

  defp extract_detail_message([%{"message" => message} | _]) when is_binary(message),
    do: message

  defp extract_detail_message([%{"msg" => message} | _]) when is_binary(message), do: message
  defp extract_detail_message([%{"reason" => message} | _]) when is_binary(message), do: message

  defp extract_detail_message([_ | rest]), do: extract_detail_message(rest)
  defp extract_detail_message(_), do: nil

  defp normalize_error_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      _ -> body
    end
  end

  defp normalize_error_body(body), do: body

  defp truncate_message(msg, max_length) when byte_size(msg) > max_length do
    String.slice(msg, 0, max_length) <> "..."
  end

  defp truncate_message(msg, _), do: msg

  defp build_error_message(status, provider_message, category) do
    base_message =
      case category do
        :rate_limit -> "Rate limit exceeded"
        :auth -> "Authentication failed"
        :client -> "Invalid request"
        :context_length -> "Context length exceeded"
        :server -> "Server error"
        :transient -> "Service temporarily unavailable"
        :unknown -> "Request failed"
      end

    if provider_message do
      "#{base_message} (HTTP #{status}): #{provider_message}"
    else
      "#{base_message} (HTTP #{status})"
    end
  end

  defp headers_to_map(headers) when is_map(headers) or is_list(headers) do
    Enum.reduce(headers, %{}, fn {key, value}, acc ->
      Map.put(acc, key |> to_string() |> String.downcase(), normalize_header_value(value))
    end)
  end

  defp headers_to_map(_), do: %{}

  defp normalize_header_value([value | _]), do: normalize_header_value(value)
  defp normalize_header_value(value), do: value

  defp get_rate_limit_value(headers_map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(headers_map, key) do
        nil -> nil
        value -> parse_integer(value)
      end
    end)
  end

  defp get_reset_time(headers_map) do
    reset_keys = ["x-ratelimit-reset-requests", "x-ratelimit-reset-tokens", "ratelimit-reset"]

    Enum.find_value(reset_keys, fn key ->
      case Map.get(headers_map, key) do
        nil -> nil
        value -> parse_reset_time(value)
      end
    end)
  end

  defp get_retry_after(headers_map) do
    Enum.find_value(["retry-after", "retry-after-ms", "x-ms-retry-after-ms"], fn key ->
      case Map.get(headers_map, key) do
        nil -> nil
        value -> parse_retry_after(key, value)
      end
    end)
  end

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp parse_integer(value) when is_integer(value), do: value
  defp parse_integer(_), do: nil

  defp parse_reset_time(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      duration_ms = parse_reset_duration_ms(value) ->
        DateTime.utc_now() |> DateTime.add(duration_ms, :millisecond)

      dt = parse_reset_iso8601(value) ->
        dt

      Regex.match?(~r/^\d+$/, value) ->
        parse_reset_unix_time(value)

      true ->
        nil
    end
  end

  defp parse_reset_time(_), do: nil

  defp parse_reset_iso8601(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_reset_unix_time(value) do
    {timestamp, ""} = Integer.parse(value)
    unit = if String.length(value) >= 13, do: :millisecond, else: :second

    case DateTime.from_unix(timestamp, unit) do
      {:ok, datetime} -> datetime
      {:error, reason} -> reason
    end
  end

  defp parse_reset_duration_ms(value) do
    normalized = String.replace(value, " ", "")
    matches = Regex.scan(~r/(\d+(?:\.\d+)?)(ms|h|m|s)/, normalized)

    if matches == [] or Enum.map_join(matches, "", &Enum.at(&1, 0)) != normalized do
      nil
    else
      matches
      |> Enum.reduce(0.0, fn [_, amount, unit], total ->
        {number, ""} = Float.parse(amount)

        total +
          case unit do
            "h" -> number * 60 * 60 * 1000
            "m" -> number * 60 * 1000
            "s" -> number * 1000
            "ms" -> number
          end
      end)
      |> round()
    end
  end

  defp parse_retry_after("retry-after", value) when is_binary(value) do
    value = String.trim(value)

    case Float.parse(value) do
      {seconds, ""} when seconds >= 0 -> trunc(seconds) * 1000
      _ -> parse_retry_after_http_date(value)
    end
  end

  defp parse_retry_after("retry-after", value) when is_integer(value), do: value * 1000

  defp parse_retry_after(key, value)
       when key in ["retry-after-ms", "x-ms-retry-after-ms"] and is_binary(value) do
    case Integer.parse(value) do
      {milliseconds, _} -> milliseconds
      :error -> nil
    end
  end

  defp parse_retry_after(key, value)
       when key in ["retry-after-ms", "x-ms-retry-after-ms"] and is_integer(value),
       do: value

  defp parse_retry_after(_, _), do: nil

  defp merge_body_rate_limit_info(info, body) do
    retry_after = info.retry_after || extract_body_retry_after(body)

    %{info | retry_after: retry_after}
  end

  defp extract_body_retry_after(body) do
    body
    |> normalize_error_body()
    |> find_retry_delay()
  end

  defp find_retry_delay(%{"error" => error}) when is_map(error), do: find_retry_delay(error)

  defp find_retry_delay(%{"details" => details}) when is_list(details) do
    Enum.find_value(details, &find_retry_delay/1)
  end

  defp find_retry_delay(%{"@type" => type, "retryDelay" => retry_delay})
       when is_binary(type) and is_binary(retry_delay) do
    if String.ends_with?(type, "/google.rpc.RetryInfo") do
      parse_duration_ms(retry_delay)
    end
  end

  defp find_retry_delay(%{"retryDelay" => retry_delay}) when is_binary(retry_delay) do
    parse_duration_ms(retry_delay)
  end

  defp find_retry_delay(_), do: nil

  defp parse_duration_ms(value) do
    value
    |> String.trim()
    |> parse_reset_duration_ms()
  end

  defp parse_retry_after_http_date(value) do
    with {{year, month, day}, {hour, minute, second}} <- convert_http_date(value),
         {:ok, naive} <- NaiveDateTime.new(year, month, day, hour, minute, second),
         {:ok, datetime} <- DateTime.from_naive(naive, "Etc/UTC") do
      diff = DateTime.diff(datetime, DateTime.utc_now(), :millisecond)
      if diff > 0, do: diff, else: nil
    else
      _ -> nil
    end
  end

  defp convert_http_date(value) do
    case Regex.run(
           ~r/^(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun),\s+(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})\s+(\d{2}):(\d{2}):(\d{2})\s+GMT$/i,
           value
         ) do
      [_, day, month, year, hour, minute, second] ->
        with {:ok, month} <- http_month(month),
             {:ok, year} <- parse_http_date_int(year),
             {:ok, day} <- parse_http_date_int(day),
             {:ok, hour} <- parse_http_date_int(hour),
             {:ok, minute} <- parse_http_date_int(minute),
             {:ok, second} <- parse_http_date_int(second) do
          {{year, month, day}, {hour, minute, second}}
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp parse_http_date_int(value) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _ -> :error
    end
  end

  defp http_month(value) do
    case String.downcase(value) do
      "jan" -> {:ok, 1}
      "feb" -> {:ok, 2}
      "mar" -> {:ok, 3}
      "apr" -> {:ok, 4}
      "may" -> {:ok, 5}
      "jun" -> {:ok, 6}
      "jul" -> {:ok, 7}
      "aug" -> {:ok, 8}
      "sep" -> {:ok, 9}
      "oct" -> {:ok, 10}
      "nov" -> {:ok, 11}
      "dec" -> {:ok, 12}
      _ -> :error
    end
  end

  # ============================================================================
  # Context Length Error Helpers
  # ============================================================================

  defp context_length_error_code?(%{"error" => %{"code" => code}}) do
    code in ["context_length_exceeded", "max_tokens_exceeded", "token_limit_exceeded"]
  end

  defp context_length_error_code?(%{"error" => %{"type" => type}}) do
    type in ["context_length_exceeded", "max_tokens_exceeded"]
  end

  defp context_length_error_code?(_), do: false

  defp context_length_error_message?(status, body) when status in [400, 413, 422] do
    message = extract_message_text(body) || ""
    downcased = String.downcase(message)

    String.contains?(downcased, "context length") or
      String.contains?(downcased, "maximum context") or
      String.contains?(downcased, "token limit") or
      String.contains?(downcased, "too many tokens") or
      String.contains?(downcased, "exceeds maximum")
  end

  defp context_length_error_message?(_, _), do: false

  defp context_length_error_string?(status, body) when is_binary(body) do
    downcased = String.downcase(body)

    String.contains?(downcased, "context_length_exceeded") or
      String.contains?(downcased, "context length") or
      (status in [400, 413, 422] and
         (String.contains?(downcased, "maximum context") or
            String.contains?(downcased, "token limit")))
  end

  defp context_length_error_string?(_, _), do: false

  defp extract_message_text(%{"error" => %{"message" => message}}) when is_binary(message) do
    message
  end

  defp extract_message_text(%{"message" => message}) when is_binary(message) do
    message
  end

  defp extract_message_text(_), do: nil
end
