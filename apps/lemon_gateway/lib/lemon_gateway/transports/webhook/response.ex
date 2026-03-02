defmodule LemonGateway.Transports.Webhook.Response do
  @moduledoc """
  Reply shaping for webhook transport.

  Formats HTTP responses, builds request metadata for logging,
  and handles query string redaction for sensitive parameters.
  """

  @doc """
  Sends a JSON response with the given status and payload.
  """
  @spec json(Plug.Conn.t(), integer(), map()) :: Plug.Conn.t()
  def json(conn, status, payload) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(payload))
  end

  @doc """
  Sends a JSON error response with a standard `%{error: message}` body.
  """
  @spec json_error(Plug.Conn.t(), integer(), String.t()) :: Plug.Conn.t()
  def json_error(conn, status, message) do
    json(conn, status, %{error: message})
  end

  @doc """
  Extracts request metadata from a Plug connection for logging/tracing.
  Sensitive query parameters are automatically redacted.
  """
  @spec request_metadata(Plug.Conn.t()) :: map()
  def request_metadata(conn) do
    %{
      method: conn.method,
      path: conn.request_path,
      query: redact_query_string(conn.query_string),
      remote_ip: remote_ip_to_string(conn.remote_ip),
      user_agent: List.first(Plug.Conn.get_req_header(conn, "user-agent")),
      request_id: List.first(Plug.Conn.get_req_header(conn, "x-request-id"))
    }
  end

  # --- Query string redaction ---

  defp redact_query_string(value) when value in [nil, ""], do: nil

  defp redact_query_string(value) when is_binary(value) do
    value
    |> URI.query_decoder()
    |> Enum.map(fn {key, query_value} ->
      if sensitive_query_key?(key) do
        {key, "[REDACTED]"}
      else
        {key, query_value}
      end
    end)
    |> URI.encode_query()
  rescue
    _ -> "[REDACTED]"
  end

  defp redact_query_string(_value), do: nil

  defp sensitive_query_key?(key) do
    normalized_key = String.downcase(to_string(key))

    Enum.any?(
      [
        "token",
        "secret",
        "password",
        "auth",
        "authorization",
        "api_key",
        "apikey",
        "signature",
        "sig"
      ],
      &String.contains?(normalized_key, &1)
    )
  end

  # --- IP formatting ---

  defp remote_ip_to_string({a, b, c, d}) do
    "#{a}.#{b}.#{c}.#{d}"
  end

  defp remote_ip_to_string({a, b, c, d, e, f, g, h}) do
    [a, b, c, d, e, f, g, h]
    |> Enum.map(&Integer.to_string(&1, 16))
    |> Enum.join(":")
  end

  defp remote_ip_to_string(_), do: nil
end
