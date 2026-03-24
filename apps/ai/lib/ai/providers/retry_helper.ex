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
end
