defmodule LemonWeb.Endpoint do
  @moduledoc "Phoenix endpoint for the LemonWeb application."

  use Phoenix.Endpoint, otp_app: :lemon_web

  # The cookie is signed and encrypted with secret_key_base and is httpOnly.
  # It carries only the derived operator marker (see LemonWeb.Auth).
  @session_options [
    store: :cookie,
    key: "_lemon_web_key",
    signing_salt: "lemonweb",
    encryption_salt: "lemonweb-operator",
    same_site: "Lax",
    http_only: true,
    max_age: 14 * 24 * 60 * 60
  ]

  @plain_session Plug.Session.init(@session_options)
  @secure_session Plug.Session.init(Keyword.put(@session_options, :secure, true))

  @doc false
  def session_options, do: @session_options

  # The origin check is part of the socket, not endpoint config, so no
  # environment can turn it off (see LemonWeb.RequestGuard).
  socket("/live", Phoenix.LiveView.Socket,
    websocket: [
      connect_info: [:peer_data, session: @session_options],
      check_origin: {LemonWeb.RequestGuard, :origin_allowed?, []}
    ],
    longpoll: false
  )

  # Host validation runs before everything, including the /live upgrade that
  # Phoenix dispatches ahead of the plug pipeline.
  def call(conn, opts) do
    if LemonWeb.RequestGuard.host_allowed?(conn),
      do: super(conn, opts),
      else: LemonWeb.RequestGuard.reject(conn)
  end

  plug(Plug.Static,
    at: "/",
    from: :lemon_web,
    gzip: false,
    only: LemonWeb.static_paths()
  )

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(:session)
  plug(LemonWeb.Router)

  # The cookie is Secure when the request itself arrived over TLS, or when the
  # operator declared TLS terminates in front (LEMON_WEB_SECURE_COOKIES). The
  # proxy's forwarded headers are never consulted.
  defp session(conn, _opts) do
    if conn.scheme == :https or Application.get_env(:lemon_web, :secure_cookies, false) == true,
      do: Plug.Session.call(conn, @secure_session),
      else: Plug.Session.call(conn, @plain_session)
  end
end
