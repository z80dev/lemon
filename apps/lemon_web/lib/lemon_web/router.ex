defmodule LemonWeb.Router do
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

  pipeline :require_games do
    plug :ensure_games_started
  end

  scope "/games", LemonWeb.Games do
    pipe_through [:public_browser, :require_games]

    live "/", LobbyLive, :index
    live "/:match_id", MatchLive, :show
  end

  # Health check endpoint for load balancers
  scope "/", LemonWeb do
    get "/healthz", HealthController, :index
  end

  defp ensure_games_started(conn, _opts) do
    started_apps = Application.started_applications() |> Enum.map(&elem(&1, 0))

    if :lemon_games in started_apps do
      conn
    else
      conn
      |> put_status(:not_found)
      |> Phoenix.Controller.text("Not Found")
      |> halt()
    end
  end
end
