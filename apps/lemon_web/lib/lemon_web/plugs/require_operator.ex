defmodule LemonWeb.Plugs.RequireOperator do
  @moduledoc """
  Gate for every browser route except `/login` and `/healthz`.

  Admits a request when its session holds the marker for the configured
  control-plane operator token, or when explicit tokenless loopback
  compatibility applies to the actual socket peer (`conn.remote_ip`; forwarded
  headers are never consulted). Unauthenticated HTML GETs redirect to `/login`
  with a validated relative `return_to`; other requests get 401. With no token
  configured (and no tokenless loopback), the UI fails closed with 503.
  """

  @behaviour Plug

  import Plug.Conn

  alias LemonWeb.Auth

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case Auth.verify(get_session(conn, Auth.session_key()), conn.remote_ip) do
      {:ok, access} ->
        assign(conn, :operator_access, access)

      {:error, :unauthenticated} ->
        conn |> delete_session(Auth.session_key()) |> unauthenticated()

      {:error, :not_configured} ->
        not_configured(conn)
    end
  end

  defp unauthenticated(%Plug.Conn{method: "GET"} = conn) do
    location = "/login?" <> URI.encode_query(%{"return_to" => return_path(conn)})

    conn
    |> put_resp_header("location", location)
    |> send_resp(302, "")
    |> halt()
  end

  defp unauthenticated(conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(401, "Unauthorized")
    |> halt()
  end

  defp not_configured(%Plug.Conn{method: "GET"} = conn) do
    if Enum.any?(get_req_header(conn, "accept"), &String.contains?(&1, "text/html")) do
      conn
      |> put_resp_content_type("text/html")
      |> send_resp(503, """
      <!doctype html>
      <html lang="en"><head><meta charset="utf-8"><title>Operator token required · Lemon</title></head>
      <body><main><h1>No operator token is configured</h1>
      <p>Lemon Web needs an operator token. Start Lemon with
      <code>LEMON_CONTROL_PLANE_OPERATOR_TOKEN</code> set (the launcher manages one automatically).</p>
      <a href="/login">Go to login</a></main></body></html>
      """)
      |> halt()
    else
      not_configured_plain(conn)
    end
  end

  defp not_configured(conn), do: not_configured_plain(conn)

  defp not_configured_plain(conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(
      503,
      "Lemon Web needs an operator token. Start Lemon with LEMON_CONTROL_PLANE_OPERATOR_TOKEN " <>
        "set (the launcher manages one automatically)."
    )
    |> halt()
  end

  # Drop any query token-like parameters; only the path and remaining query
  # survive into the login redirect.
  defp return_path(conn) do
    query =
      conn
      |> fetch_query_params()
      |> Map.fetch!(:query_params)
      |> Map.drop(["token"])
      |> URI.encode_query()

    if query == "", do: conn.request_path, else: conn.request_path <> "?" <> query
  end
end
