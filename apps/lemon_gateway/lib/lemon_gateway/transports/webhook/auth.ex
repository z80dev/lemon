defmodule LemonGateway.Transports.Webhook.Auth do
  @moduledoc """
  Request verification and token-based authentication for webhook transport.

  Supports multiple token sources: Authorization header, X-Webhook-Token header,
  and optionally query parameters and payload fields when explicitly enabled
  per integration.
  """

  import LemonGateway.Transports.Webhook.Helpers

  @doc """
  Authorizes a webhook request by comparing the provided token against
  the expected token configured for the integration.

  Returns `:ok` if the token matches, `{:error, :unauthorized}` otherwise.
  """
  @spec authorize_request(Plug.Conn.t(), map(), map()) :: :ok | {:error, :unauthorized}
  def authorize_request(conn, _payload, integration) do
    expected = normalize_blank(fetch(integration, :token))

    provided =
      first_non_blank(
        [
          authorization_token(conn),
          List.first(Plug.Conn.get_req_header(conn, "x-webhook-token"))
        ] ++
          optional_values(allow_query_token?(integration), [query_token(conn)]) ++
          optional_values(allow_payload_token?(integration), [payload_token(conn)])
      )

    if secure_compare(expected, provided) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Performs a constant-time comparison of two binary values.
  Returns false for nil or mismatched-length inputs.
  """
  @spec secure_compare(term(), term()) :: boolean()
  def secure_compare(expected, provided)
      when is_binary(expected) and is_binary(provided) and
             byte_size(expected) == byte_size(provided) do
    Plug.Crypto.secure_compare(expected, provided)
  rescue
    _ -> false
  end

  def secure_compare(_, _), do: false

  # --- Private helpers ---

  defp optional_values(true, values) when is_list(values), do: values
  defp optional_values(_, _), do: []

  defp query_token(conn) do
    fetch_any(query_params(conn), [["token"], ["webhook_token"]])
  end

  defp payload_token(conn) do
    fetch_any(body_params(conn), [["token"], ["webhook_token"]])
  end

  defp query_params(conn) do
    conn
    |> Plug.Conn.fetch_query_params()
    |> Map.get(:query_params, %{})
    |> normalize_map()
  rescue
    _ -> %{}
  end

  defp body_params(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}}), do: %{}
  defp body_params(%Plug.Conn{body_params: params}) when is_map(params), do: params
  defp body_params(_), do: %{}

  defp authorization_token(conn) do
    conn
    |> Plug.Conn.get_req_header("authorization")
    |> List.first()
    |> normalize_blank()
    |> case do
      nil ->
        nil

      "Bearer " <> token ->
        normalize_blank(token)

      "bearer " <> token ->
        normalize_blank(token)

      token ->
        normalize_blank(token)
    end
  end

  defp allow_query_token?(integration) do
    resolve_boolean([fetch(integration, :allow_query_token)], false)
  end

  defp allow_payload_token?(integration) do
    resolve_boolean([fetch(integration, :allow_payload_token)], false)
  end
end
