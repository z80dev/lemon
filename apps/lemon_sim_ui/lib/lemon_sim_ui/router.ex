defmodule LemonSimUi.Router do
  @moduledoc """
  Phoenix router for the LemonSim UI.

  Public routes: `/` (lobby), `/leaderboards`, `/arena/:domain` (always-on
  arenas: werewolf, space_station, stock_market, survivor, poker),
  `/arena/:domain/leaderboard` (league standings), `/watch/:sim_id`
  (spectator), `/healthz`. `/werewolf` remains as a legacy alias.
  Admin routes: `/admin` and `/admin/sims/:id` (dashboard, requires access token).
  API routes: `/api/admin/*` (JSON API, requires access token).
  """

  use LemonSimUi, :router

  pipeline :public_browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {LemonSimUi.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {LemonSimUi.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(LemonSimUi.Plugs.RequireAccessToken)
  end

  pipeline :api do
    plug(:accepts, ["json"])
    plug(:fetch_session)
    plug(LemonSimUi.Plugs.RequireAccessToken)
  end

  scope "/", LemonSimUi do
    pipe_through(:public_browser)

    live("/", LobbyLive, :index)
    live("/leaderboards", LeaderboardLive, :index)
    live("/arena/:domain", ArenaLive, :index)
    live("/arena/:domain/leaderboard", ArenaLeaderboardLive, :index)
    get("/werewolf", ArenaRedirectController, :werewolf)
    get("/werewolf/leaderboard", ArenaRedirectController, :werewolf_leaderboard)
    live("/watch/:sim_id", SpectatorLive, :show)
    get("/vending_bench/start/:preset_id", VendingBenchLaunchController, :create)
    post("/vending_bench/start", VendingBenchLaunchController, :create)
    get("/healthz", HealthController, :index)
  end

  scope "/admin", LemonSimUi do
    pipe_through(:browser)

    live("/", SimDashboardLive, :index)
    live("/sims/:sim_id", SimDashboardLive, :show)
  end

  scope "/api/admin", LemonSimUi do
    pipe_through(:api)

    post("/sims", AdminSimController, :create)
    post("/sims/:sim_id/stop", AdminSimController, :stop)
  end
end
