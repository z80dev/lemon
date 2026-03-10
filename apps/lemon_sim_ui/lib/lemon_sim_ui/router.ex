defmodule LemonSimUi.Router do
  use LemonSimUi, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {LemonSimUi.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", LemonSimUi do
    pipe_through :browser

    live "/", SimDashboardLive, :index
    live "/sims/:sim_id", SimDashboardLive, :show
  end
end
