defmodule LemonWeb.Router do
  @moduledoc """
  Phoenix router for LemonWeb.

  Every page requires operator access (`LemonWeb.Plugs.RequireOperator` for
  HTTP, `LemonWeb.LiveAuth` for each LiveView mount). Only `/login` and
  `/healthz` are reachable without it.
  """

  use LemonWeb, :router

  pipeline :browser do
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {LemonWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers, %{"referrer-policy" => "no-referrer"})
  end

  pipeline :accept_html do
    plug(:accepts, ["html"])
  end

  pipeline :operator do
    plug(LemonWeb.Plugs.RequireOperator)
  end

  scope "/", LemonWeb do
    pipe_through([:browser, :accept_html])

    get("/login", LoginController, :new)
    post("/login", LoginController, :create)
    delete("/logout", LoginController, :delete)
  end

  scope "/", LemonWeb do
    pipe_through([:browser, :operator, :accept_html])

    get("/sessions/:session_key/export/:format", SessionExportController, :show)
    get("/profiles/:id/export", ProfileExportController, :show)

    live_session :operator, on_mount: [{LemonWeb.LiveAuth, :require_operator}] do
      live("/", ChatLive, :home)
      live("/chat/:session_key", ChatLive, :show)
      live("/sessions", ManagementLive, :index)
      live("/sessions/:session_key", ManagementLive, :show)
      live("/omp", OmpLive, :index)
      live("/omp/:id", OmpLive, :show)
      live("/automation", WorkManagementLive, :index)
      live("/blueprints", BlueprintManagementLive, :index)
      live("/skills", SkillsLive, :index)
      live("/memory", MemoryManagementLive, :index)
      live("/mcp", McpLive, :index)
      live("/profiles", ProfileManagementLive, :index)
      live("/models", ProviderManagementLive, :index)
      live("/usage", UsageLive, :index)
      live("/diagnostics", DiagnosticsLive, :index)
      live("/settings", SettingsLive, :index)
      live("/nodes", NodesLive, :index)
    end
  end

  # Health check endpoint for load balancers
  scope "/", LemonWeb do
    get("/healthz", HealthController, :index)
  end
end
