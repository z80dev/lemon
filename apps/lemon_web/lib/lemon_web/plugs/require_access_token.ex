defmodule LemonWeb.Plugs.RequireAccessToken do
  @moduledoc """
  Token gate for browser routes.

  When `:lemon_web, :access_token` is configured, requests must provide the
  token via one of:

  - `Authorization: Bearer <token>`
  - query string `?token=<token>`
  - existing session auth marker (`:lemon_web_auth`)

  Routes that pass `required: true` fail closed with HTTP 503 when no token is
  configured. This is used for the management surface while the local chat
  route keeps the backwards-compatible optional gate. A valid query token is
  consumed with a server-side redirect to the same URL without `token`; bearer
  authentication does not redirect.
  """

  @behaviour Plug

  import Plug.Conn

  @session_key :lemon_web_auth

  def init(opts), do: opts

  def call(conn, opts) do
    required? = Keyword.get(opts, :required, false) == true

    case configured_token() do
      token when token in [nil, ""] ->
        if required?, do: unavailable(conn), else: conn

      expected ->
        header_token = token_from_authorization_header(conn)
        query_token = token_from_query(conn)

        cond do
          is_binary(header_token) ->
            if secure_equal?(header_token, expected) do
              put_session(conn, @session_key, session_marker(expected))
            else
              conn |> delete_session(@session_key) |> unauthorized()
            end

          is_binary(query_token) ->
            if secure_equal?(query_token, expected) do
              conn
              |> put_session(@session_key, session_marker(expected))
              |> redirect_without_query_token()
            else
              conn |> delete_session(@session_key) |> unauthorized()
            end

          valid_session_marker?(token_from_session(conn), expected) ->
            conn

          true ->
            conn |> delete_session(@session_key) |> unauthorized()
        end
    end
  end

  defp configured_token do
    Application.get_env(:lemon_web, :access_token)
  end

  defp token_from_session(conn), do: get_session(conn, @session_key)

  defp token_from_query(conn) do
    token =
      conn
      |> fetch_query_params()
      |> Map.get(:query_params, %{})
      |> Map.get("token")

    normalize_token(token)
  end

  defp token_from_authorization_header(conn) do
    conn
    |> get_req_header("authorization")
    |> List.first()
    |> case do
      "Bearer " <> token -> normalize_token(token)
      _ -> nil
    end
  end

  defp session_marker(token) when is_binary(token) do
    :crypto.hash(:sha256, token)
    |> Base.encode64(padding: false)
  end

  defp valid_session_marker?(provided, expected)
       when is_binary(provided) and is_binary(expected) do
    secure_equal?(provided, session_marker(expected))
  end

  defp valid_session_marker?(_provided, _expected), do: false

  defp normalize_token(token) when is_binary(token) do
    case String.trim(token) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_token(_), do: nil

  defp secure_equal?(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and Plug.Crypto.secure_compare(left, right)
  end

  defp secure_equal?(_left, _right), do: false

  defp unauthorized(conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(401, "Unauthorized")
    |> halt()
  end

  defp redirect_without_query_token(conn) do
    query =
      conn
      |> fetch_query_params()
      |> Map.fetch!(:query_params)
      |> Map.delete("token")
      |> URI.encode_query()

    location = if query == "", do: conn.request_path, else: "#{conn.request_path}?#{query}"

    conn
    |> put_resp_header("location", location)
    |> send_resp(302, "")
    |> halt()
  end

  defp unavailable(conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(503, "Management access token is not configured")
    |> halt()
  end
end
