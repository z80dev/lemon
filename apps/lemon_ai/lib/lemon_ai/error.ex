defmodule LemonAi.Error do
  @moduledoc """
  Error handling utilities for AI provider responses.

  This module provides functions for:
  - Parsing HTTP error responses from various providers
  - Extracting rate limit information from response headers
  - Classifying errors for appropriate handling
  - Generating user-friendly error messages

  `classify/1` is shared by HTTP, transport and stream-terminal errors.
  `retryable?/1` retries rate limits, transient/network failures and server
  errors, but never authentication, client or context-overflow failures.
  Missing local API keys are authentication failures, not provider outages, and
  must not contribute to the provider-wide circuit breaker.
  Account quota/credit/spend exhaustion is classified as `:rate_limit` for
  credential failover, but is not retryable against the same credential.
  Retry timing metadata is a hint, not permission to retry.
  """

  alias LemonAi.Models.Presets
  alias LemonAi.Providers.RetryHelper

  require Logger

  @category_names %{
    "rate_limit" => :rate_limit,
    "auth" => :auth,
    "client" => :client,
    "context_length" => :context_length,
    "server" => :server,
    "transient" => :transient,
    "unknown" => :unknown
  }

  # ============================================================================
  # Types
  # ============================================================================

  @type error_category ::
          :rate_limit | :auth | :client | :context_length | :server | :transient | :unknown

  @type failover_action :: :retry_same | :next_credential | :next_provider | :compact | :fail

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

      iex> LemonAi.Error.parse_http_error(429, %{"error" => %{"message" => "Rate limit exceeded"}}, headers)
      %{category: :rate_limit, status: 429, message: "Rate limit exceeded", ...}

      iex> LemonAi.Error.parse_http_error(500, "Internal Server Error", [])
      %{category: :server, status: 500, message: "Internal server error", ...}
  """
  @spec parse_http_error(
          non_neg_integer(),
          term(),
          map() | [{term(), term()}],
          atom() | String.t() | nil
        ) :: parsed_error()
  def parse_http_error(status, body, headers \\ [], provider \\ nil) do
    body = normalize_error_body(body)
    provider_message = extract_provider_message(body) |> preserve_error_marker(body)
    category = classify_error(status, body, provider_message)

    info = extract_rate_limit_info(headers, body)

    rate_limit_info =
      if category == :rate_limit or Enum.any?(info, fn {_key, value} -> not is_nil(value) end),
        do: info,
        else: nil

    %{
      category: category,
      status: status,
      message: build_error_message(status, provider_message, category, provider),
      provider_message: provider_message,
      rate_limit_info: rate_limit_info,
      retryable: retryable_category?(category) and not quota_exhausted_message?(provider_message)
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
  @spec format_error(term(), atom() | String.t() | nil) :: String.t()
  def format_error(error, provider \\ nil)

  def format_error({:http_error, status, body}, provider) do
    parse_http_error(status, body, [], provider).message
  end

  def format_error(:rate_limited, _provider),
    do: "Request rate limited. Please wait before retrying."

  def format_error(:circuit_open, _provider),
    do: "Service temporarily unavailable (circuit breaker open). Please try again later."

  def format_error(:max_concurrency, _provider),
    do: "Too many concurrent requests. Please try again shortly."

  def format_error(reason, provider)
      when reason in [:timeout, :closed, :econnrefused, :econnreset, :nxdomain] do
    service =
      if is_nil(provider), do: "the model provider", else: "provider #{provider_name(provider)}"

    case reason do
      :timeout ->
        "Request to #{service} timed out. Please try again."

      :closed ->
        "Connection to #{service} closed unexpectedly. Please try again."

      :econnrefused ->
        "Connection to #{service} was refused. Check base_url and that the server is running, then try again."

      :econnreset ->
        "Connection to #{service} was reset. Please try again."

      :nxdomain ->
        "DNS lookup for #{service} failed. Check base_url and your network connection, then try again."
    end
  end

  def format_error({:unknown_api, api}, _provider) when is_atom(api) or is_binary(api) do
    "Unknown API type \"#{api}\" for this model. Check the model's api setting and run `lemon doctor`."
  end

  def format_error(%{__struct__: module, reason: reason}, provider)
      when module in [Req.TransportError, Finch.TransportError, Mint.TransportError],
      do: format_error(reason, provider)

  def format_error(%{message: message}, _provider) when is_binary(message), do: message
  def format_error(error, _provider) when is_exception(error), do: Exception.message(error)
  def format_error(%{"message" => message}, _provider) when is_binary(message), do: message
  def format_error(error, _provider) when is_binary(error), do: error

  def format_error(error, _provider) do
    Logger.warning("Unexpected model provider error: #{inspect(error)}")

    "An unexpected error occurred with the model provider. Try again; if it keeps happening, run `lemon doctor`."
  end

  @doc """
  Check if an error is retryable against the same provider and credential.

  Accepts the same inputs as `classify/1`. A parsed `retryable: false`
  decision is retained; `retryable: true` cannot override a permanent category.
  Quota exhaustion rotates credentials via `failover_action/1` instead of
  spinning in the seconds-scale provider retry loop.
  """
  @spec retryable?(term()) :: boolean()
  def retryable?({:http_error, status, body}),
    do: parse_http_error(status, body, []).retryable

  def retryable?({:http_error, status, body, headers}),
    do: parse_http_error(status, body, headers).retryable

  def retryable?(%{error_details: details}) when is_map(details), do: retryable?(details)

  def retryable?(%{"category" => _} = error) do
    error["retryable"] != false and retryable_category?(classify(error)) and
      not quota_exhausted_message?(error["provider_message"]) and
      not quota_exhausted_message?(error["message"])
  end

  def retryable?({:error, _stop_reason, message}), do: retryable?(message)
  def retryable?({:error, reason}), do: retryable?(reason)
  def retryable?(%{retryable: false}), do: false

  def retryable?(%{category: category} = error) do
    retryable_category?(category) and
      not quota_exhausted_message?(Map.get(error, :provider_message)) and
      not quota_exhausted_message?(Map.get(error, :message))
  end

  def retryable?(%{error_message: message}) when is_binary(message), do: retryable?(message)

  def retryable?(error) do
    retryable_category?(classify(error)) and not quota_exhausted_error?(error)
  end

  @doc """
  Canonical, serializable error metadata for assistant stream terminals.
  Transport exceptions are classified from their typed reason, not their
  display text. SDK structs and request internals are not exposed to clients.
  """
  @spec to_error_details(term()) :: parsed_error()
  def to_error_details({:http_error, status, body}),
    do: parse_http_error(status, body, [])

  def to_error_details({:http_error, status, body, headers}),
    do: parse_http_error(status, body, headers)

  def to_error_details(%{error_details: details}) when is_map(details),
    do: to_error_details(details)

  def to_error_details(error) do
    defaults = %{
      category: classify(error),
      status: if(is_binary(error), do: status_from_message(error)),
      message: format_error(error),
      provider_message: nil,
      rate_limit_info: nil,
      retryable: retryable?(error)
    }

    if is_map(error) and (Map.has_key?(error, :category) or Map.has_key?(error, "category")) do
      result =
        Enum.reduce([:status, :message, :provider_message], defaults, fn key, acc ->
          case error_field(error, key) do
            nil -> acc
            value -> Map.put(acc, key, value)
          end
        end)

      %{
        result
        | rate_limit_info: normalize_error_rate_limit_info(error_field(error, :rate_limit_info))
      }
    else
      defaults
    end
  end

  defp error_field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp normalize_error_rate_limit_info(nil), do: nil

  defp normalize_error_rate_limit_info(info) when is_map(info) do
    reset_at =
      case error_field(info, :reset_at) do
        %DateTime{} = datetime ->
          datetime

        value when is_binary(value) ->
          case DateTime.from_iso8601(value) do
            {:ok, datetime, _} -> datetime
            _ -> nil
          end

        _ ->
          nil
      end

    Enum.reduce([:limit, :remaining, :retry_after], %{reset_at: reset_at}, fn key, acc ->
      value = error_field(info, key)
      Map.put(acc, key, if(is_integer(value) and value >= 0, do: value))
    end)
  end

  defp normalize_error_rate_limit_info(_), do: nil

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
      iex> LemonAi.Error.suggested_retry_delay_from_error(error)
      30_000

      iex> error = %{status: 503, rate_limit_info: nil}
      iex> LemonAi.Error.suggested_retry_delay_from_error(error)
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

      iex> LemonAi.Error.auth_error?({:http_error, 401, "Unauthorized"})
      true

      iex> LemonAi.Error.auth_error?({:http_error, 500, "Server Error"})
      false
  """
  @spec auth_error?(term()) :: boolean()
  def auth_error?({:http_error, status, _}) when status in [401, 403], do: true
  def auth_error?(%{category: :auth}), do: true
  def auth_error?(_), do: false

  @doc """
  Check if the error represents a rate limit error.

  ## Examples

      iex> LemonAi.Error.rate_limit_error?({:http_error, 429, "Rate limited"})
      true

      iex> LemonAi.Error.rate_limit_error?(:rate_limited)
      true

      iex> LemonAi.Error.rate_limit_error?({:http_error, 500, "Server Error"})
      false
  """
  @spec rate_limit_error?(term()) :: boolean()
  def rate_limit_error?({:http_error, 429, _}), do: true

  def rate_limit_error?({:http_error, status, body}) do
    parse_http_error(status, body, []).category == :rate_limit
  end

  def rate_limit_error?(:rate_limited), do: true
  def rate_limit_error?(%{category: :rate_limit}), do: true
  def rate_limit_error?(_), do: false

  @doc """
  Check if the error represents a context length exceeded error.

  ## Examples

      iex> LemonAi.Error.context_length_error?({:http_error, 400, %{"error" => %{"code" => "context_length_exceeded"}}})
      true

      iex> LemonAi.Error.context_length_error?({:http_error, 429, "Rate limited"})
      false
  """
  @spec context_length_error?(term()) :: boolean()
  def context_length_error?(error), do: classify(error) == :context_length

  @doc """
  Format rate limit information for display.

  ## Examples

      iex> info = %{limit: 100, remaining: 50, reset_at: DateTime.utc_now()}
      iex> LemonAi.Error.format_rate_limit_info(info)
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

  @doc """
  Classify an arbitrary error term into an `t:error_category/0`.

  Accepts flexible input:

  - a parsed error map (`t:parsed_error/0`, or any map with a `:category` key)
  - an `{:http_error, status, body}` tuple
  - an `{:error, stop_reason, message}` stream-terminal event, where `message`
    is an `LemonAi.Types.AssistantMessage` (or any map with an `:error_message`
    string) — classification falls back to the message text, since stream
    events carry no structured status
  - an exception struct (classified on `Exception.message/1`)
  - a transport reason atom (`:timeout`, `:econnrefused`, ...)
  - a raw error string

  Anything unclassifiable returns `:unknown`.
  """
  @spec classify(term()) :: error_category()
  def classify(%{category: category})
      when category in [
             :rate_limit,
             :auth,
             :client,
             :context_length,
             :server,
             :transient,
             :unknown
           ],
      do: category

  def classify(%{error_details: details}) when is_map(details), do: classify(details)
  def classify(%{"category" => category}), do: Map.get(@category_names, category, :unknown)
  def classify({:http_error, status, body}), do: parse_http_error(status, body, []).category

  def classify({:http_error, status, body, headers}),
    do: parse_http_error(status, body, headers).category

  def classify({:error, _stop_reason, message}), do: classify(message)
  def classify({:error, reason}), do: classify(reason)
  def classify(:context_length_exceeded), do: :context_length
  def classify(:rate_limited), do: :rate_limit
  def classify(reason) when reason in [:circuit_open, :max_concurrency], do: :transient

  def classify(%{__struct__: module, reason: reason})
      when module in [Req.TransportError, Finch.TransportError, Mint.TransportError],
      do: classify(reason)

  def classify({:closed, _}), do: :transient

  def classify({:tls_alert, {alert, detail}}) do
    if alert in [:internal_error, :bad_record_mac, :decrypt_error] or
         transient_message?(inspect(detail)),
       do: :transient,
       else: :unknown
  end

  def classify({:failed_connect, details}), do: classify_message_text(inspect(details))

  def classify(reason)
      when reason in [
             :timeout,
             :closed,
             :econnrefused,
             :econnreset,
             :nxdomain,
             :enetdown,
             :enetunreach,
             :enetwork_unreachable,
             :unreachable,
             :ehostunreach
           ],
      do: :transient

  def classify(%{error_message: message}) when is_binary(message),
    do: classify_message_text(message)

  def classify(exception) when is_exception(exception),
    do: classify_message_text(Exception.message(exception))

  def classify(message) when is_binary(message), do: classify_message_text(message)
  def classify(reason) when is_tuple(reason), do: classify_message_text(inspect(reason))
  def classify(_), do: :unknown

  @doc """
  Decide how the live provider-fallback path should react to an error.

  Classifies the error via `classify/1` and maps the category to an action:

  | Category          | Action             | Rationale                                                        |
  |-------------------|--------------------|------------------------------------------------------------------|
  | `:auth`           | `:next_credential` | The credential is bad, not the provider — rotate credentials.     |
  | `:rate_limit`     | `:next_credential` | The current key is throttled; another credential may have quota.  |
  | `:transient`      | `:next_provider`   | Provider-side hiccup — another provider can serve the request.    |
  | `:server`         | `:next_provider`   | Provider-side failure — another provider can serve the request.   |
  | `:context_length` | `:compact`         | See below.                                                        |
  | `:client`         | `:fail`            | The request itself is malformed; every provider would reject it.  |
  | `:unknown`        | `:next_provider`   | Fail-open: keeps failover for genuinely unclassifiable errors.    |

  `:context_length` never fails over: the context is too large for the model,
  a condition no fallback candidate can satisfy — retrying the same oversized
  context would just burn every provider in the chain. Context-overflow
  recovery belongs to the caller that owns the conversation (for coding
  sessions, `CodingAgent.Session.OverflowRecovery` compacts the session and
  retries the turn), so the error must surface to it (`:compact`) instead of
  walking the fallback chain.

  `:retry_same` is reserved in the type for callers that retry in place (see
  `transport_retry_statuses/0` for that set); no category currently maps to it.
  """
  @spec failover_action(term()) :: failover_action()
  def failover_action(error) do
    case classify(error) do
      :auth -> :next_credential
      :rate_limit -> :next_credential
      :transient -> :next_provider
      :server -> :next_provider
      :context_length -> :compact
      :client -> :fail
      :unknown -> :next_provider
    end
  end

  @doc """
  Whether a request-level error indicates the SERVICE is unhealthy and should
  count against the provider's circuit breaker.

  Encodes the failure set used by `LemonAi.CallDispatcher.dispatch/2` for
  request-level results: HTTP >= 500, transport failures (`:timeout`,
  `:closed`, `:econnrefused`, `:econnreset`, `:nxdomain`), and timeout-ish
  error strings. Explicitly NOT 4xx: client errors (400/413), rate limits
  (429), and auth errors (401/403) are caused by the request or credential,
  not the service, and must not trip the breaker.
  """
  @spec circuit_breaker_failure?(term()) :: boolean()
  def circuit_breaker_failure?({:http_error, status, _body}) do
    status >= 500
  end

  def circuit_breaker_failure?(:timeout), do: true
  def circuit_breaker_failure?(:closed), do: true
  def circuit_breaker_failure?(:econnrefused), do: true
  def circuit_breaker_failure?(:econnreset), do: true
  def circuit_breaker_failure?(:nxdomain), do: true

  def circuit_breaker_failure?(reason) when is_binary(reason) do
    downcased = String.downcase(reason)
    String.contains?(downcased, "timeout") or String.contains?(downcased, "econnrefused")
  end

  def circuit_breaker_failure?(_), do: false

  @doc """
  Whether a stream-terminal error should count against a provider's circuit
  breaker.

  Stream-terminal errors are not automatically service failures: a 401/429/400
  can surface after the connection is established — the provider rejects the
  request mid-stream, or the HTTP error body arrives as the stream's terminal
  event. Classifies the error (via `classify/1`) and exempts the categories
  caused by the request or credential (`:auth`, `:rate_limit`, `:client`,
  `:context_length`). Everything else — `:server`, `:transient`, and
  unclassifiable errors such as broken connections, timeouts, or crashed
  streaming tasks — counts as a service failure.

  Consumer-driven cancellations are also exempt: `{:canceled, reason}` with a
  user/consumer reason (abort, redirect, explicit cancel, deliberate
  `:shutdown` teardown) says nothing about the provider's health — a user
  redirecting or stopping five calls in a row must not open a healthy
  provider's breaker. `{:canceled, :owner_down}` (owner crash) and
  `{:canceled, :timeout}` (stream hang) still count as failures.
  """
  @consumer_cancel_reasons [
    :aborted,
    :redirected,
    :canceled,
    :user_abort,
    :user_requested,
    :assistant_aborted,
    :shutdown
  ]

  @spec stream_terminal_breaker_failure?(term()) :: boolean()
  def stream_terminal_breaker_failure?({:canceled, reason})
      when reason in @consumer_cancel_reasons,
      do: false

  def stream_terminal_breaker_failure?(reason) do
    classify(reason) not in [:auth, :rate_limit, :client, :context_length]
  end

  @transport_retry_statuses [408, 409, 425, 429] ++ Enum.to_list(500..599)

  @doc """
  HTTP status codes worth retrying in place against the SAME provider (with
  backoff). Used by `LemonAi.Providers.RetryHelper.retryable_http_status?/1`.

  These statuses are transient request failures (408/409/425), rate limits
  (429), or server failures (5xx). This status-only set cannot override
  permanent provider-body evidence. Providers with an error body must use
  `LemonAi.Providers.RetryHelper.retryable_http_error?/2`.
  """
  @spec transport_retry_statuses() :: [pos_integer()]
  def transport_retry_statuses, do: @transport_retry_statuses

  # ============================================================================
  # Private Helpers
  # ============================================================================

  # Classify an error that only carries message text (stream-terminal events,
  # exceptions, raw strings). Providers usually strip the HTTP status when the
  # error body parses, so this leans on message patterns first and any embedded
  # "HTTP <status>" mention second. Unmatched text stays :unknown, which the
  # failover path treats fail-open (:next_provider).
  defp classify_message_text(message) do
    status = status_from_message(message)

    cond do
      context_length_error_string?(status, message) -> :context_length
      auth_message?(message) or status in [401, 403] -> :auth
      quota_exhausted_message?(message) -> :rate_limit
      client_message?(message) -> :client
      provider_rate_limit_message?(message) or status == 429 -> :rate_limit
      provider_transient_message?(message) -> :transient
      is_integer(status) -> classify_status(status)
      server_message?(message) -> :server
      transient_message?(message) -> :transient
      true -> :unknown
    end
  end

  defp status_from_message(message) do
    case Regex.run(~r/(?:HTTP(?:\/\d(?:\.\d)?)?|status|code)[ :]+(\d{3})\b/i, message) do
      [_, code] -> String.to_integer(code)
      nil -> nil
    end
  end

  defp auth_message?(message) when not is_binary(message), do: false

  defp auth_message?(message) do
    downcased = String.downcase(message)

    String.contains?(downcased, "unauthorized") or
      String.contains?(downcased, "authentication") or
      String.contains?(downcased, "invalid api key") or
      String.contains?(downcased, "invalid_api_key") or
      String.contains?(downcased, "no api key provided") or
      String.contains?(downcased, "api key is required") or
      String.contains?(downcased, "invalid x-api-key") or
      String.contains?(downcased, "api key not valid") or
      String.contains?(downcased, "permission denied") or
      String.contains?(downcased, "authentication_error") or
      String.contains?(downcased, "forbidden")
  end

  defp transient_message?(message) do
    downcased = String.downcase(message)

    Regex.match?(
      ~r/timeout|timed out|econnrefused|econnreset|enetdown|enetunreach|enetwork_unreachable|ehostunreach|nxdomain|connection[ _]?(?:refused|reset|closed|error)|(?:transporterror|connection failed).*reason:\s*:(?:closed|econnreset|timeout)\b|network[ _]?error|fetch failed|upstream[ _]?connect|other[ _]?side[ _]?closed|socket hang up|socket connection was closed|bad[ _]record[ _]mac|temporarily unavailable|stream error.*received from peer/i,
      downcased
    )
  end

  defp classify_error(status, body, provider_message) do
    cond do
      context_length_error_string?(status, provider_message) ->
        :context_length

      status in [401, 403] or auth_message?(provider_message) ->
        :auth

      quota_exhausted_message?(provider_message) ->
        :rate_limit

      client_message?(provider_message) ->
        :client

      status == 429 or provider_rate_limit_message?(provider_message) ->
        :rate_limit

      do_provider_rate_limit_body?(body) ->
        :rate_limit

      status in [408, 409, 425] ->
        :transient

      status == 0 and is_binary(provider_message) and transient_message?(provider_message) ->
        :transient

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
      status in [408, 409, 425] -> :transient
      status >= 400 and status < 500 -> :client
      status in [502, 503, 504, 529] -> :transient
      status >= 500 -> :server
      true -> :unknown
    end
  end

  defp retryable_category?(category), do: category in [:rate_limit, :transient, :server]

  defp quota_exhausted_error?(%Req.TransportError{}), do: false

  defp quota_exhausted_error?(exception) when is_exception(exception),
    do: quota_exhausted_message?(Exception.message(exception))

  defp quota_exhausted_error?(message), do: quota_exhausted_message?(message)

  defp quota_exhausted_message?(message) when is_binary(message) do
    transient_interval? =
      Regex.match?(~r/per[ _](?:second|minute)|requests?\/min|tokens?\/min/i, message)

    dashscope_throttle? =
      String.contains?(message, "#token-limit") and
        String.contains?(String.downcase(message), "you exceeded your current quota")

    not dashscope_throttle? and
      (Regex.match?(
         ~r/insufficient_quota|quota_exhausted|usage_limit_reached|usage_not_included|insufficient_g1_credits_balance|spend(?:ing)?[ _-]limit|monthly spend|(?:insufficient|not enough|out of|run out of|exceed.{0,40}available)[ _]credits?|credits?.{0,40}(?:exhausted|depleted)|insufficient[ _]balance|quota will reset|exhausted your capacity|hit your .*usage limit|(?:额度|配额)已?(?:用|耗)(?:完|尽)|余额不足/i,
         message
       ) or
         (not transient_interval? and
            Regex.match?(
              ~r/account(?:'s)?.{0,80}rate.?limit|rate.?limit.{0,80}account|(?:subscription|plan|membership).{0,80}(?:quota|cap|rate.?limit)|quota (?:exhausted|depleted)|exceeded your current quota/i,
              message
            )))
  end

  defp quota_exhausted_message?(_), do: false

  defp server_message?(message) do
    Regex.match?(~r/internal[ _](?:server[ _])?error|server[ _]error/i, message)
  end

  defp client_message?(message) when is_binary(message) do
    Regex.match?(
      ~r/invalid[ _]request|bad request|validation[ _]error|invalid tool (?:schema|arguments)|model_not_supported|model_not_available_for_integrator|payload too large|request_too_large/i,
      message
    )
  end

  defp client_message?(_), do: false

  # Some wire formats carry a generic type/message but the decisive code or
  # Google ErrorInfo reason lives elsewhere. Keep that marker in terminal text,
  # which has no structured status/body in the common AssistantMessage API.
  defp preserve_error_marker(message, body) do
    marker = find_error_marker(body)

    if marker && not (is_binary(message) and String.contains?(message, marker)) do
      if is_binary(message) and message != "", do: "#{marker}: #{message}", else: marker
    else
      message
    end
  end

  defp find_error_marker(body) when is_map(body) do
    Enum.find_value(["code", "type", "reason"], fn key ->
      value = Map.get(body, key)

      if is_binary(value) and
           (quota_exhausted_message?(value) or context_length_error_string?(nil, value) or
              auth_message?(value)),
         do: value
    end) || Enum.find_value(Map.values(body), &find_error_marker/1)
  end

  defp find_error_marker(body) when is_list(body), do: Enum.find_value(body, &find_error_marker/1)
  defp find_error_marker(_), do: nil

  defp provider_rate_limit_message?(message) when is_binary(message) do
    Regex.match?(~r/rate.?limit|too many requests|throttl|resource.?exhausted/i, message)
  end

  defp provider_rate_limit_message?(_), do: false

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

  defp extract_provider_message(%{"errors" => errors}) when is_list(errors),
    do: extract_detail_message(errors)

  defp extract_provider_message(%{"error" => %{"type" => type, "message" => message} = error_map})
       when is_binary(type) and is_binary(message) do
    message = effective_error_message(error_map, message)

    if message == "" do
      type
    else
      symbolic_provider_message(type, message)
    end
  end

  defp extract_provider_message(%{"error" => %{"code" => code, "message" => message} = error_map})
       when is_binary(code) and is_binary(message) do
    message = effective_error_message(error_map, message)

    if message == "" do
      code
    else
      symbolic_provider_message(code, message)
    end
  end

  # Anthropic/OpenAI generic message format
  defp extract_provider_message(%{"error" => %{"message" => message} = error_map})
       when is_binary(message) do
    effective_error_message(error_map, message)
  end

  defp extract_provider_message(%{"error" => %{"code" => code}}) when is_binary(code), do: code

  defp extract_provider_message(%{"error" => %{"detail" => detail}})
       when is_binary(detail) or is_list(detail),
       do: extract_detail_message(detail)

  defp extract_provider_message(%{"error" => %{"details" => details}})
       when is_binary(details) or is_list(details),
       do: extract_detail_message(details)

  defp extract_provider_message(%{"error" => code, "error_description" => description})
       when is_binary(code) and is_binary(description) do
    "#{code}: #{description}"
  end

  defp extract_provider_message(%{"error" => code, "message" => message})
       when is_binary(code) and is_binary(message) do
    "#{code}: #{message}"
  end

  defp extract_provider_message(%{"error" => code, "detail" => message})
       when is_binary(code) and is_binary(message) do
    "#{code}: #{message}"
  end

  defp extract_provider_message(%{"error" => code, "description" => message})
       when is_binary(code) and is_binary(message) do
    "#{code}: #{message}"
  end

  # Generic error formats
  defp extract_provider_message(%{"error" => error}) when is_binary(error), do: error

  defp extract_provider_message(%{"error" => error}) when is_list(error),
    do: extract_detail_message(error)

  defp extract_provider_message(%{"error" => error_map}) when is_map(error_map) do
    # Try to extract nested error information
    nested_message =
      if is_binary(error_map["message"]) do
        nil
      else
        error_map
        |> Map.drop(["type", "code", "param"])
        |> find_nested_provider_message()
      end

    parts = []
    parts = if error_map["type"], do: [error_map["type"] | parts], else: parts
    parts = if error_map["code"], do: [error_map["code"] | parts], else: parts
    parts = if error_map["message"], do: [error_map["message"] | parts], else: parts
    parts = if nested_message, do: [nested_message | parts], else: parts
    parts = if error_map["param"], do: ["param: #{error_map["param"]}" | parts], else: parts

    case parts do
      [] -> find_nested_provider_message(error_map) || inspect(error_map) |> truncate_message(200)
      _ -> Enum.join(parts, " - ")
    end
  end

  # Direct message fields
  defp extract_provider_message(%{"message" => message}) when is_binary(message), do: message
  defp extract_provider_message(%{"Message" => message}) when is_binary(message), do: message

  defp extract_provider_message(%{"error_description" => message}) when is_binary(message),
    do: message

  defp extract_provider_message(%{"error_message" => message}) when is_binary(message),
    do: message

  defp extract_provider_message(%{"detail" => detail})
       when is_binary(detail) or is_list(detail) or is_map(detail),
       do: extract_detail_message(detail)

  defp extract_provider_message(%{"details" => details})
       when is_binary(details) or is_list(details) or is_map(details),
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
  defp extract_detail_message(%{} = detail), do: find_nested_provider_message(detail)
  defp extract_detail_message([message | _]) when is_binary(message), do: message

  defp extract_detail_message([%{"message" => message} | _]) when is_binary(message),
    do: message

  defp extract_detail_message([%{"msg" => message} | _]) when is_binary(message), do: message
  defp extract_detail_message([%{"reason" => message} | _]) when is_binary(message), do: message
  defp extract_detail_message([%{"detail" => message} | _]) when is_binary(message), do: message
  defp extract_detail_message([%{"details" => message} | _]) when is_binary(message), do: message
  defp extract_detail_message([%{"title" => message} | _]) when is_binary(message), do: message

  defp extract_detail_message([%{"description" => message} | _]) when is_binary(message),
    do: message

  defp extract_detail_message([%{"error" => message} | _]) when is_binary(message),
    do: message

  defp extract_detail_message([%{"error" => error} | _]) when is_map(error),
    do: find_nested_provider_message(error)

  defp extract_detail_message([%{"error_description" => message} | _]) when is_binary(message),
    do: message

  defp extract_detail_message([%{"error_message" => message} | _]) when is_binary(message),
    do: message

  defp extract_detail_message([_ | rest]), do: extract_detail_message(rest)
  defp extract_detail_message(_), do: nil

  defp find_nested_provider_message(%{} = map) do
    direct_message(map) ||
      map
      |> Map.values()
      |> Enum.find_value(&find_nested_provider_message/1)
  end

  defp find_nested_provider_message([head | tail]) do
    find_nested_provider_message(head) || find_nested_provider_message(tail)
  end

  defp find_nested_provider_message(_), do: nil

  defp effective_error_message(error_map, message)
       when is_map(error_map) and is_binary(message) do
    nested_message =
      error_map
      |> Map.drop(["message", "type", "code", "param"])
      |> find_nested_provider_message()

    if String.trim(message) == "" and is_binary(nested_message) and nested_message != "" do
      nested_message
    else
      message
    end
  end

  defp symbolic_provider_message(symbol, message) when symbol == message, do: message
  defp symbolic_provider_message(symbol, message), do: "#{symbol}: #{message}"

  defp direct_message(%{"message" => message}) when is_binary(message), do: message
  defp direct_message(%{"msg" => message}) when is_binary(message), do: message
  defp direct_message(%{"reason" => message}) when is_binary(message), do: message
  defp direct_message(%{"detail" => message}) when is_binary(message), do: message
  defp direct_message(%{"details" => message}) when is_binary(message), do: message
  defp direct_message(%{"title" => message}) when is_binary(message), do: message
  defp direct_message(%{"description" => message}) when is_binary(message), do: message
  defp direct_message(%{"error_description" => message}) when is_binary(message), do: message
  defp direct_message(%{"error_message" => message}) when is_binary(message), do: message
  defp direct_message(_), do: nil

  defp normalize_error_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> normalize_error_body(decoded)
      _ -> body
    end
  end

  defp normalize_error_body(body) when is_map(body) do
    Map.new(body, fn {key, value} ->
      {normalize_error_key(key), normalize_error_value(value)}
    end)
  end

  defp normalize_error_body(body) when is_list(body), do: Enum.map(body, &normalize_error_value/1)

  defp normalize_error_body(body), do: body

  defp normalize_error_value(body) when is_map(body), do: normalize_error_body(body)

  defp normalize_error_value(body) when is_list(body),
    do: Enum.map(body, &normalize_error_value/1)

  defp normalize_error_value(body)
       when is_atom(body) and not is_nil(body) and not is_boolean(body),
       do: Atom.to_string(body)

  defp normalize_error_value(body), do: body

  defp normalize_error_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_error_key(key), do: key

  defp truncate_message(msg, max_length) when byte_size(msg) > max_length do
    LemonAi.Text.truncate_chars(msg, max_length, force: true)
  end

  defp truncate_message(msg, _), do: msg

  defp build_error_message(status, provider_message, category, provider) do
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

    message =
      if provider_message do
        "#{base_message} (HTTP #{status}): #{provider_message}"
      else
        "#{base_message} (HTTP #{status})"
      end

    if category == :auth do
      message <> ". " <> auth_hint(provider)
    else
      message
    end
  end

  defp auth_hint(provider) do
    name = provider_name(provider)

    env_vars =
      case name do
        "anthropic" ->
          ["ANTHROPIC_API_KEY"]

        "openai" ->
          ["OPENAI_API_KEY"]

        "google" ->
          ["GOOGLE_GENERATIVE_AI_API_KEY", "GOOGLE_API_KEY", "GEMINI_API_KEY"]

        "azure_openai_responses" ->
          ["AZURE_OPENAI_API_KEY"]

        "openai_codex" ->
          ["OPENAI_CODEX_API_KEY", "CHATGPT_TOKEN"]

        "groq" ->
          ["GROQ_API_KEY"]

        "mistral" ->
          ["MISTRAL_API_KEY"]

        "xai" ->
          ["XAI_API_KEY"]

        "cerebras" ->
          ["CEREBRAS_API_KEY"]

        "deepseek" ->
          ["DEEPSEEK_API_KEY"]

        "openrouter" ->
          ["OPENROUTER_API_KEY"]

        "opencode" ->
          ["OPENCODE_API_KEY"]

        "zai" ->
          ["ZAI_API_KEY"]

        "minimax" ->
          ["MINIMAX_API_KEY"]

        "fireworks" ->
          ["FIREWORKS_API_KEY"]

        _ ->
          Enum.find_value(Presets.all(), [], fn preset ->
            if Atom.to_string(preset.id) == name, do: preset.env_vars
          end)
      end

    env_hint = if env_vars == [], do: "", else: "set #{Enum.join(env_vars, " or ")} or "
    "Check the API key for #{name}; #{env_hint}run `lemon secrets set` to configure it."
  end

  defp provider_name(nil), do: "the model provider"

  defp provider_name(provider) when is_atom(provider) or is_binary(provider),
    do: to_string(provider)

  defp provider_name(_provider), do: "the model provider"

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
    RetryHelper.retry_after_ms(headers_map)
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

  defp merge_body_rate_limit_info(info, body) do
    retry_after = info.retry_after || extract_body_retry_after(body)

    %{info | retry_after: retry_after}
  end

  defp extract_body_retry_after(body) do
    body
    |> normalize_error_body()
    |> find_retry_delay()
  end

  defp find_retry_delay(%{"retry_after_ms" => retry_after}) do
    parse_body_retry_after_ms(retry_after)
  end

  defp find_retry_delay(%{"retryAfterMs" => retry_after}) do
    parse_body_retry_after_ms(retry_after)
  end

  defp find_retry_delay(%{"retry_after" => retry_after}) do
    parse_body_retry_after_seconds(retry_after)
  end

  defp find_retry_delay(%{"retryAfter" => retry_after}) do
    parse_body_retry_after_seconds(retry_after)
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

  defp parse_body_retry_after_seconds(value) when is_integer(value) and value >= 0,
    do: value * 1000

  defp parse_body_retry_after_seconds(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {seconds, ""} when seconds >= 0 -> trunc(seconds * 1000)
      _ -> nil
    end
  end

  defp parse_body_retry_after_seconds(_), do: nil

  defp parse_body_retry_after_ms(value) when is_integer(value) and value >= 0, do: value

  defp parse_body_retry_after_ms(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {milliseconds, ""} when milliseconds >= 0 -> trunc(milliseconds)
      _ -> nil
    end
  end

  defp parse_body_retry_after_ms(_), do: nil

  defp parse_duration_ms(value) do
    value
    |> String.trim()
    |> parse_reset_duration_ms()
  end

  # ============================================================================
  # Context Length Error Helpers
  # ============================================================================

  defp context_length_error_string?(status, body) when is_binary(body) do
    downcased = String.downcase(body)

    Regex.match?(
      ~r/context[_ ]length[_ ]exceeded|max_tokens_exceeded|token_limit_exceeded|model_context_window_exceeded|context length|prompt is too long|input is too long for requested model|exceeds (?:the |available )?context (?:window|size)|input token count.*exceeds the maximum|maximum prompt length is \d+|reduce the length of the messages|requested tokens?.*exceed.*context|context (?:window|size).*(?:exceeded|overflow|too small)|greater than the context length|exceeded model token limit|too many tokens|token limit exceeded|exceeds the limit of \d+ tokens/i,
      downcased
    ) or
      (status in [400, 413, 422] and String.contains?(downcased, "maximum context"))
  end

  defp context_length_error_string?(_, _), do: false
end
