defmodule LemonWeb.Router do
  @moduledoc "Phoenix router for LemonWeb."

  use LemonWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {LemonWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(LemonWeb.Plugs.RequireAccessToken)
  end

  scope "/", LemonWeb do
    pipe_through(:browser)

    live("/", SessionLive, :index)
    live("/sessions/:session_key", SessionLive, :show)
  end

  # Health check endpoint for load balancers
  scope "/", LemonWeb do
    get("/healthz", HealthController, :index)
  end
end
