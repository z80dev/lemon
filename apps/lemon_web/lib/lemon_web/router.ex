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

  pipeline :management_browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {LemonWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(LemonWeb.Plugs.RequireAccessToken, required: true)
  end

  scope "/", LemonWeb do
    pipe_through(:browser)

    live("/", SessionLive, :index)
    live("/sessions/:session_key", SessionLive, :show)
  end

  scope "/manage", LemonWeb do
    pipe_through(:management_browser)

    live("/", ManagementLive, :index)
    live("/blueprints", BlueprintManagementLive, :index)
    live("/providers", ProviderManagementLive, :index)
    live("/sessions/:session_key", ManagementLive, :show)
    get("/sessions/:session_key/export/:format", SessionExportController, :show)
  end

  # Health check endpoint for load balancers
  scope "/", LemonWeb do
    get("/healthz", HealthController, :index)
  end
end
