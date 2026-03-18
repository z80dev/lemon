defmodule LemonSimUi.Router do
  @moduledoc """
  Phoenix router for the LemonSim UI.

  Mounts `SimDashboardLive` at `/` and `/sims/:sim_id`, plus the public
  read-only `SpectatorLive` route at `/watch/:sim_id` for shareable werewolf
  viewing.
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
    pipe_through(:browser)

    live("/", SimDashboardLive, :index)
    live("/sims/:sim_id", SimDashboardLive, :show)
  end

  scope "/", LemonSimUi do
    pipe_through(:public_browser)

    live("/watch/:sim_id", SpectatorLive, :show)
    get("/healthz", HealthController, :index)
  end

  scope "/api/admin", LemonSimUi do
    pipe_through(:api)

    post("/sims", AdminSimController, :create)
    post("/sims/:sim_id/stop", AdminSimController, :stop)
  end
end
