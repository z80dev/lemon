defmodule LemonWeb.Router do
  @moduledoc "Phoenix router for LemonWeb — serves authenticated session views and public games lobby."

  use LemonWeb, :router

  pipeline :public_browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {LemonWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

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

  scope "/games", LemonWeb.Games do
    pipe_through :public_browser

    live "/", LobbyLive, :index
    live "/:match_id", MatchLive, :show
  end

  # Health check endpoint for load balancers
  scope "/", LemonWeb do
    get "/healthz", HealthController, :index
  end

end
