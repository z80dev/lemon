defmodule LemonControlPlane.HTTP.Router do
  @moduledoc """
  HTTP router for the control plane.

  Provides:
  - `/ws` - WebSocket endpoint for the control plane protocol
  - `/healthz` - Health check endpoint (HTTP GET)
  """

  use Plug.Router

  plug(Plug.Logger, log: :debug)
  plug(:match)
  plug(:dispatch)

  get "/healthz" do
    send_resp(conn, 200, Jason.encode!(%{ok: true}))
  end

  get "/ws" do
    conn
    |> WebSockAdapter.upgrade(LemonControlPlane.WS.Connection, [], timeout: 60_000)
    |> halt()
  end

  match _ do
    send_resp(conn, 404, Jason.encode!(%{error: "Not found"}))
  end
end
