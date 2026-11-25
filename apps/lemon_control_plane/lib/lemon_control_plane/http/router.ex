defmodule LemonControlPlane.HTTP.Router do
  @moduledoc """
  HTTP router for the control plane.

  Provides:
  - `/ws` - WebSocket endpoint for the control plane protocol
  - `/acp/ws` - operator-authenticated ACP WebSocket used by `lemon acp`
  - `/healthz` - Health check endpoint (HTTP GET)

  Remote peers reach only `GET /ws` and `GET /healthz`.
  """

  use Plug.Router

  alias LemonControlPlane.Auth.Authorize
  alias LemonControlPlane.HTTP.RequestOrigin
  alias LemonControlPlane.Protocol.Errors

  plug(Plug.Logger, log: :debug)
  plug(:require_trusted_host)
  plug(:restrict_non_loopback)
  plug(:match)
  plug(:dispatch)

  get "/healthz" do
    send_resp(conn, 200, Jason.encode!(%{ok: true}))
  end

  get "/acp/ws" do
    with_trusted_origin(conn, &upgrade_acp/1)
  end

  get "/ws" do
    with_trusted_origin(conn, fn conn ->
      conn
      |> WebSockAdapter.upgrade(
        LemonControlPlane.WS.Connection,
        [peer: conn.remote_ip],
        timeout: 60_000
      )
      |> halt()
    end)
  end

  defp upgrade_acp(conn) do
    local? = Authorize.tokenless_loopback_allowed?(conn.remote_ip)

    params = %{"role" => "operator", "auth" => %{"token" => bearer_token(conn)}}

    case Authorize.from_params(params, local?: local?) do
      {:ok, %{role: :operator, scopes: scopes}} ->
        if Enum.all?([:read, :write, :approvals, :content], &(&1 in scopes)) do
          conn
          |> WebSockAdapter.upgrade(
            LemonControlPlane.ACP.Connection,
            [scopes: scopes],
            timeout: :infinity
          )
          |> halt()
        else
          http_error(
            conn,
            403,
            Errors.forbidden(
              operator_auth_message(
                "ACP requires operator read, write, approval and content scopes."
              )
            )
          )
        end

      _ ->
        http_error(
          conn,
          401,
          Errors.unauthorized(operator_auth_message("Operator authentication is required."))
        )
    end
  end

  defp with_trusted_origin(conn, fun) do
    if RequestOrigin.control_plane_origin_allowed?(conn) do
      fun.(conn)
    else
      http_error(
        conn,
        403,
        Errors.forbidden(
          "WebSocket Origin is not allowed. Add it to LEMON_CONTROL_PLANE_ALLOWED_ORIGINS to permit a browser client."
        )
      )
    end
  end

  defp require_trusted_host(conn, _opts) do
    if RequestOrigin.control_plane_host_allowed?(conn) do
      conn
    else
      conn
      |> http_error(403, Errors.forbidden("Host header is not a loopback or configured host."))
      |> halt()
    end
  end

  match _ do
    http_error(conn, 404, Errors.not_found("Not found"))
  end

  defp restrict_non_loopback(conn, _opts) do
    allowed? =
      Authorize.loopback_address?(conn.remote_ip) or
        (conn.method == "GET" and conn.request_path in ["/ws", "/healthz"])

    if allowed?, do: conn, else: conn |> http_error(404, Errors.not_found("Not found")) |> halt()
  end

  defp http_error(conn, status, error) do
    json(conn, status, %{"error" => Errors.to_payload(error)})
  end

  defp operator_auth_message(reason) do
    reason <>
      " Send Authorization: Bearer <token> using LEMON_CONTROL_PLANE_OPERATOR_TOKEN or the launcher's ~/.lemon/run/control-plane-<port>.token file."
  end

  defp bearer_token(conn) do
    conn
    |> get_req_header("authorization")
    |> List.first()
    |> case do
      "Bearer " <> token when token != "" -> token
      _ -> nil
    end
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
