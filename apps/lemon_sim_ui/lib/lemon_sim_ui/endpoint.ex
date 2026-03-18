defmodule LemonSimUi.Endpoint do
  @moduledoc "Phoenix endpoint for the LemonSim UI application."

  use Phoenix.Endpoint, otp_app: :lemon_sim_ui

  @session_options [
    store: :cookie,
    key: "_lemon_sim_ui_key",
    signing_salt: "lemonsimui"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: false

  plug Plug.Static,
    at: "/",
    from: :lemon_sim_ui,
    gzip: false,
    only: LemonSimUi.static_paths()

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
  plug LemonSimUi.Router
end
