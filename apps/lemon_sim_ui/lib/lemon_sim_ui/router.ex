defmodule LemonSimUi.Router do
  @moduledoc """
  Phoenix router for the LemonSim UI.

  Public routes: `/` (lobby), `/leaderboards`, `/arena/:domain` (always-on
  arenas: werewolf, space_station, stock_market, survivor, poker),
  `/arena/:domain/leaderboard` (league standings), `/watch/:sim_id`
  (spectator), hosted Werewolf `/play`, `/join/:join_code`, and `/rooms/:id/*`
  surfaces, `/healthz`, `/readyz`. `/werewolf` remains as a legacy alias.
  Admin routes: `/admin/login`, `/admin`, and `/admin/sims/:id` (operator
  control room, requires an expiring authenticated browser session).
  API routes: `/api/admin/*` (JSON API, requires access token).
  """

  use LemonSimUi, :router

  @browser_security_headers %{
    "content-security-policy" =>
      "default-src 'self'; base-uri 'self'; object-src 'none'; frame-ancestors 'none'; " <>
        "form-action 'self'; img-src 'self' data:; font-src 'self'; script-src 'self'; " <>
        "style-src 'self' 'unsafe-inline'; connect-src 'self' ws: wss:",
    "permissions-policy" => "camera=(), microphone=(), geolocation=(), payment=()",
    "referrer-policy" => "strict-origin-when-cross-origin"
  }

  pipeline :public_browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {LemonSimUi.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers, @browser_security_headers)
  end

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {LemonSimUi.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers, @browser_security_headers)
    plug(:put_no_store)
    plug(LemonSimUi.Plugs.RequireAccessToken, sources: [:session], on_failure: :redirect)
  end

  pipeline :api do
    plug(:accepts, ["json"])
    plug(LemonSimUi.Plugs.RequireAccessToken, sources: [:authorization])
  end

  pipeline :public_json do
    plug(:accepts, ["json"])
    plug(LemonSimUi.Plugs.ChatCors)
  end

  # SSE stream: EventSource always sends `Accept: text/event-stream`, which the
  # `:accepts` plug would reject as not-json (406). Skip format negotiation
  # here — the stream action sets its own content type.
  pipeline :chat_stream do
    plug(LemonSimUi.Plugs.ChatCors)
  end

  # Open access since Aug 2026: the password gate (RequireChatSession) was
  # removed from the pipeline. Re-add `plug(LemonSimUi.Plugs.RequireChatSession)`
  # to restore it.
  pipeline :chat_api do
    plug(:accepts, ["json"])
    plug(LemonSimUi.Plugs.ChatCors)
  end

  pipeline :no_store do
    plug(:put_no_store)
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
    get("/readyz", HealthController, :ready)
  end

  scope "/", LemonSimUi do
    pipe_through([:public_browser, :no_store])

    live("/play", HostedLobbyLive, :index)
    live("/join/:join_code", HostedJoinLive, :show)
    post("/rooms", HostedGameSessionController, :create)
    post("/rooms/join", HostedGameSessionController, :join)
    live("/rooms/:room_id/host", HostedHostLive, :show)
    live("/rooms/:room_id/play", HostedPlayerLive, :show)
    live("/rooms/:room_id/watch", HostedWatchLive, :show)
    get("/rooms/:room_id/export", HostedGameSessionController, :export)
  end

  scope "/admin", LemonSimUi do
    pipe_through([:public_browser, :no_store])

    get("/login", AdminSessionController, :new)
    post("/login", AdminSessionController, :create)
    post("/logout", AdminSessionController, :delete)
  end

  scope "/admin", LemonSimUi do
    pipe_through(:browser)

    live("/", SimDashboardLive, :index)
    live("/sims/:sim_id", SimDashboardLive, :show)
  end

  scope "/api/admin", LemonSimUi do
    pipe_through(:api)

    get("/metrics", MetricsController, :index)
    post("/sims", AdminSimController, :create)
    post("/sims/:sim_id/stop", AdminSimController, :stop)
  end

  # Public: session login, CORS preflight (EventSource cannot set headers, so
  # the stream route skips format negotiation via :chat_stream).
  scope "/api/chat", LemonSimUi do
    pipe_through(:public_json)

    match(:options, "/*path", PhilosopherChatApiController, :preflight)
    post("/session", PhilosopherChatApiController, :session)
  end

  scope "/api/chat", LemonSimUi do
    pipe_through(:chat_stream)

    get("/threads/:id/stream", PhilosopherChatApiController, :stream)
  end

  scope "/api/chat", LemonSimUi do
    pipe_through(:chat_api)

    get("/roster", PhilosopherChatApiController, :roster)
    post("/stream-ticket", PhilosopherChatApiController, :stream_ticket)
    get("/threads", PhilosopherChatApiController, :index)
    post("/threads", PhilosopherChatApiController, :create)
    get("/threads/:id", PhilosopherChatApiController, :show)
    post("/threads/:id/messages", PhilosopherChatApiController, :create_message)
    post("/threads/:id/nudge", PhilosopherChatApiController, :nudge)
    post("/threads/:id/pause", PhilosopherChatApiController, :pause)
    post("/threads/:id/resume", PhilosopherChatApiController, :resume)
    get("/threads/:id/memories/:agent_id", PhilosopherChatApiController, :memories)
    get("/threads/:id/events", PhilosopherChatApiController, :events)
  end

  defp put_no_store(conn, _opts) do
    conn
    |> Plug.Conn.put_resp_header("cache-control", "private, no-store")
    |> Plug.Conn.put_resp_header("pragma", "no-cache")
  end
end
