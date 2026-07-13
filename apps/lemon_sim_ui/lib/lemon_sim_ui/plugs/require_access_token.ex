defmodule LemonSimUi.Plugs.RequireAccessToken do
  @moduledoc """
  Token gate for the LemonSim admin surfaces.

  When `:lemon_sim_ui, :access_token` is configured, requests must provide the
  token via one of:

  - `Authorization: Bearer <token>`
  - browser-only query string `?token=<token>`, exchanged immediately for a
    session and redirected to a URL without the token
  - browser-only existing session auth marker (`:lemon_sim_ui_auth`)

  API routes configure this plug with `sources: [:authorization]` and never
  accept query or cookie credentials.
  """

  @behaviour Plug

  import Plug.Conn

  @session_key :lemon_sim_ui_auth

  def init(opts), do: Keyword.get(opts, :sources, [:authorization, :query, :session])

  def call(conn, sources) do
    case configured_token() do
      token when token in [nil, ""] ->
        conn

      expected ->
        authorization =
          if :authorization in sources, do: token_from_authorization_header(conn)

        query = if :query in sources, do: token_from_query(conn)

        cond do
          is_binary(authorization) ->
            if secure_equal?(authorization, expected) do
              put_session(conn, @session_key, session_marker(expected))
            else
              conn |> delete_session(@session_key) |> unauthorized()
            end

          is_binary(query) ->
            if secure_equal?(query, expected) do
              conn
              |> put_session(@session_key, session_marker(expected))
              |> redirect_without_query_token()
            else
              conn |> delete_session(@session_key) |> unauthorized()
            end

          :session in sources and valid_session_marker?(token_from_session(conn), expected) ->
            conn

          true ->
            conn |> delete_session(@session_key) |> unauthorized()
        end
    end
  end

  defp configured_token do
    Application.get_env(:lemon_sim_ui, :access_token)
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

  defp redirect_without_query_token(conn) do
    query =
      conn.query_params
      |> Map.delete("token")
      |> URI.encode_query()

    location = conn.request_path <> if(query == "", do: "", else: "?#{query}")

    conn
    |> put_resp_header("location", location)
    |> send_resp(:see_other, "")
    |> halt()
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(401, "Unauthorized")
    |> halt()
  end
end
