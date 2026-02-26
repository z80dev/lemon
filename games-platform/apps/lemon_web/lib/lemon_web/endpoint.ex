defmodule LemonWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :lemon_web

  @session_options [
    store: :cookie,
    key: "_lemon_web_key",
    signing_salt: "lemonweb"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: false

  plug Plug.Static,
    at: "/",
    from: :lemon_web,
    gzip: false,
    only: LemonWeb.static_paths()

  if code_reloading? do
    plug Phoenix.CodeReloader
    plug Phoenix.LiveReloader
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug LemonWeb.Router
end
