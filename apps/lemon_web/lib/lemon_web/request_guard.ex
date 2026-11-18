defmodule LemonWeb.RequestGuard do
  @moduledoc """
  Browser-origin guards for `LemonWeb.Endpoint`.

  Loopback peers are trusted by `LemonWeb.Auth` when tokenless loopback
  compatibility is enabled, and a browser on the operator's machine is a
  loopback peer too. Two checks keep other web pages out:

  - `host_allowed?/1` runs before every request, including the `/live` socket
    upgrade: a loopback peer must name a loopback `Host`, LemonWeb's configured
    public host or bind address. A foreign `Host` (DNS rebinding) is refused.
  - `origin_allowed?/1` is the `/live` socket's `check_origin`: a browser
    `Origin` must exactly equal (scheme, host, port) one of
    `config :lemon_web, :trusted_origins`, which `config/runtime.exs` derives from
    `LEMON_WEB_PORT`, `LEMON_WEB_BIND_IP` and `LEMON_WEB_HOST`/`_URL_SCHEME`/`_URL_PORT`.
    An unset list trusts no browser origin.

  Both delegate to `LemonControlPlane.HTTP.RequestOrigin`, the guard the control
  plane uses for its own loopback listeners.
  """

  alias LemonControlPlane.HTTP.RequestOrigin

  @spec host_allowed?(Plug.Conn.t()) :: boolean()
  def host_allowed?(%Plug.Conn{} = conn) do
    url_host = LemonWeb.Endpoint.config(:url)[:host]
    hosts = Enum.flat_map(trusted_origins(), &origin_host/1)

    RequestOrigin.host_allowed?(
      conn,
      if(is_binary(url_host), do: [url_host | hosts], else: hosts)
    )
  end

  @doc "`check_origin` callback for the `/live` socket; receives the parsed `Origin`."
  @spec origin_allowed?(URI.t()) :: boolean()
  def origin_allowed?(%URI{} = origin) do
    case RequestOrigin.normalize_origin(URI.to_string(origin)) do
      nil -> false
      origin -> origin in Enum.map(trusted_origins(), &RequestOrigin.normalize_origin/1)
    end
  end

  @spec reject(Plug.Conn.t()) :: Plug.Conn.t()
  def reject(conn) do
    conn
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.send_resp(421, "Misdirected Request")
    |> Plug.Conn.halt()
  end

  defp trusted_origins, do: Application.get_env(:lemon_web, :trusted_origins, [])

  defp origin_host(origin) do
    case RequestOrigin.normalize_origin(origin) do
      nil -> []
      normalized -> [URI.parse(normalized).host]
    end
  end
end
