defmodule LemonSimUi.Plugs.ChatCors do
  @moduledoc """
  CORS headers for the PhilosopherChat JSON API.

  The frontend (e.g. z80.wtf/chat) is served from a different origin than
  the API, so browsers preflight every POST (JSON + Authorization) and
  require `Access-Control-Allow-Origin` on the SSE stream.

  Allowed origins come from `:lemon_sim_ui, :philosopher_chat_cors_origins`
  (env `LEMON_PHILOSOPHER_CHAT_CORS_ORIGINS`, comma-separated). Defaults to
  `"*"`: the API is bearer-token only (no cookies), so a wildcard origin
  grants no credentialed access. When a list is configured, the request's
  `Origin` is echoed only if present in it.
  """

  @behaviour Plug

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    conn
    |> put_resp_header("access-control-allow-origin", allowed_origin(conn))
    |> put_resp_header("access-control-allow-methods", "GET, POST, OPTIONS")
    |> put_resp_header("access-control-allow-headers", "authorization, content-type")
    |> put_resp_header("access-control-max-age", "86400")
    |> maybe_vary()
  end

  defp allowed_origin(conn) do
    case configured_origins() do
      :any ->
        "*"

      origins ->
        origin = conn |> get_req_header("origin") |> List.first()
        if origin && origin in origins, do: origin, else: "null"
    end
  end

  defp maybe_vary(conn) do
    if configured_origins() == :any do
      conn
    else
      put_resp_header(conn, "vary", "Origin")
    end
  end

  defp configured_origins do
    case Application.get_env(:lemon_sim_ui, :philosopher_chat_cors_origins) do
      nil ->
        :any

      "" ->
        :any

      "*" ->
        :any

      value when is_binary(value) ->
        value |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

      value when is_list(value) ->
        value
    end
  end
end
