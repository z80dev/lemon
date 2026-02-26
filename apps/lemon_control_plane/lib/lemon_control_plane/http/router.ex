defmodule LemonControlPlane.HTTP.Router do
  @moduledoc """
  HTTP router for the control plane.

  Provides:
  - `/ws` - WebSocket endpoint for the control plane protocol
  - `/healthz` - Health check endpoint (HTTP GET)
  """

  use Plug.Router

  plug(Plug.Logger, log: :debug)
  plug Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason
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

  # Games API
  get "/v1/games/lobby" do
    LemonControlPlane.HTTP.GamesAPI.call(conn, :lobby)
  end

  get "/v1/games/matches/:id" do
    LemonControlPlane.HTTP.GamesAPI.call(conn, :get_match)
  end

  get "/v1/games/matches/:id/events" do
    LemonControlPlane.HTTP.GamesAPI.call(conn, :list_events)
  end

  post "/v1/games/matches" do
    LemonControlPlane.HTTP.GamesAPI.call(conn, :create_match)
  end

  post "/v1/games/matches/:id/accept" do
    LemonControlPlane.HTTP.GamesAPI.call(conn, :accept_match)
  end

  post "/v1/games/matches/:id/moves" do
    LemonControlPlane.HTTP.GamesAPI.call(conn, :submit_move)
  end

  match _ do
    send_resp(conn, 404, Jason.encode!(%{error: "Not found"}))
  end
end
