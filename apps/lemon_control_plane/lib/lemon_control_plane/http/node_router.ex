defmodule LemonControlPlane.HTTP.NodeRouter do
  @moduledoc """
  Node-only edge for tunnels and TLS proxies. No operator or HTTP API access.
  """
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/healthz" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{ok: true, service: "lemon-node-gateway"}))
  end

  get "/ws" do
    conn
    |> WebSockAdapter.upgrade(
      LemonControlPlane.WS.Connection,
      [peer: conn.remote_ip, allowed_roles: [:node, :enrollment], tokenless: false],
      timeout: 60_000
    )
    |> halt()
  end

  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{error: %{code: "NOT_FOUND", message: "Not found"}}))
  end
end
