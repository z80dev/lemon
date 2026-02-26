defmodule LemonWeb.Router do
  use LemonWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {LemonWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug LemonWeb.Plugs.RequireAccessToken
  end

  scope "/", LemonWeb do
    pipe_through :browser

    live "/", SessionLive, :index
    live "/sessions/:session_key", SessionLive, :show

    live "/games", Games.LobbyLive, :index
    live "/games/:match_id", Games.MatchLive, :show
  end
end
