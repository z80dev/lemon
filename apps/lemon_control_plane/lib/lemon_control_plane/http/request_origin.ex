defmodule LemonControlPlane.HTTP.RequestOrigin do
  @moduledoc """
  Browser-origin guards for Lemon's loopback HTTP listeners.

  Loopback trust is decided from the socket peer, so a browser on the operator's
  machine is a loopback peer too. Two checks keep web pages out:

  - `host_allowed?/2` (every route, loopback peers only): `Host` must be
    `localhost`, a loopback IP literal, or a listener-specific extra host. This
    defeats DNS rebinding, where the attacker's hostname resolves to 127.0.0.1.
    `*.localhost` names are not accepted.
  - `origin_allowed?/2` (WebSocket upgrades): `Origin` must be absent (native
    clients) or exactly one of the trusted origins, compared by scheme, host
    and port. Other loopback ports and subdomains are different web origins and
    are refused.

  The generic functions take explicit allowlists so any Plug listener can use
  them (`lemon_web` depends on this app; `lemon_core` has no Plug dependency).
  The `control_plane_*` and `a2a_*` functions derive the lists from each
  listener's own configuration.
  """

  alias LemonControlPlane.Auth.Authorize

  @wildcards [{0, 0, 0, 0}, {0, 0, 0, 0, 0, 0, 0, 0}]

  ## Generic guards

  @spec host_allowed?(Plug.Conn.t(), [String.t()]) :: boolean()
  def host_allowed?(%Plug.Conn{} = conn, extra_hosts) do
    not Authorize.loopback_address?(conn.remote_ip) or
      loopback_host?(conn.host) or
      normalize_host(conn.host) in Enum.map(extra_hosts, &normalize_host/1)
  end

  @spec origin_allowed?(Plug.Conn.t(), [String.t()]) :: boolean()
  def origin_allowed?(%Plug.Conn{} = conn, trusted_origins) do
    case Plug.Conn.get_req_header(conn, "origin") do
      [] ->
        true

      [origin] ->
        case normalize_origin(origin) do
          nil -> false
          origin -> origin in Enum.map(trusted_origins, &normalize_origin/1)
        end

      _multiple ->
        false
    end
  end

  @doc "The loopback spellings of `scheme://<loopback>:port`."
  @spec loopback_origins(String.t(), :inet.port_number()) :: [String.t()]
  def loopback_origins(scheme, port) do
    for host <- ["localhost", "127.0.0.1", "[::1]"], do: "#{scheme}://#{host}:#{port}"
  end

  @doc "Canonical `scheme://host:port` for a bare http(s) origin, or nil."
  @spec normalize_origin(term()) :: String.t() | nil
  def normalize_origin(origin) when is_binary(origin) do
    case URI.new(String.trim(origin)) do
      {:ok,
       %URI{scheme: scheme, host: host, port: port, userinfo: nil, query: nil, fragment: nil} =
           uri}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        if uri.path in [nil, "", "/"] do
          host = String.downcase(host)
          host = if String.contains?(host, ":"), do: "[#{host}]", else: host
          "#{scheme}://#{host}:#{port}"
        end

      _ ->
        nil
    end
  end

  def normalize_origin(_origin), do: nil

  ## Control-plane main listener

  @spec control_plane_host_allowed?(Plug.Conn.t()) :: boolean()
  def control_plane_host_allowed?(conn) do
    extra =
      bind_hosts(Application.get_env(:lemon_control_plane, :ip)) ++
        Enum.flat_map(allowed_origins(), &origin_host/1)

    host_allowed?(conn, extra)
  end

  @doc """
  Exact origins trusted on `/ws` and `/acp/ws`: this listener's own origin
  (the port the validated loopback `Host` names), LemonWeb's configured origins
  and `LEMON_CONTROL_PLANE_ALLOWED_ORIGINS`.
  """
  @spec control_plane_origin_allowed?(Plug.Conn.t()) :: boolean()
  def control_plane_origin_allowed?(conn) do
    scheme = Atom.to_string(conn.scheme)

    own =
      loopback_origins(scheme, conn.port) ++
        Enum.map(
          bind_hosts(Application.get_env(:lemon_control_plane, :ip)),
          &"#{scheme}://#{&1}:#{conn.port}"
        )

    origin_allowed?(conn, own ++ lemon_web_origins() ++ allowed_origins())
  end

  ## A2A listener

  @spec a2a_host_allowed?(Plug.Conn.t(), map()) :: boolean()
  def a2a_host_allowed?(conn, config) do
    bind = if is_binary(config[:host]), do: bind_hosts(parse_ip(config.host)), else: []
    public = if is_binary(config[:public_url]), do: url_host(config.public_url), else: []
    host_allowed?(conn, bind ++ public)
  end

  ## Helpers

  defp lemon_web_origins do
    endpoint = Application.get_env(:lemon_web, LemonWeb.Endpoint, [])
    http = Keyword.get(endpoint, :http, [])
    url = Keyword.get(endpoint, :url, [])
    port = Keyword.get(http, :port)

    listener =
      if is_integer(port) and port > 0 do
        loopback_origins("http", port) ++
          Enum.map(bind_hosts(Keyword.get(http, :ip)), &"http://#{&1}:#{port}")
      else
        []
      end

    public =
      case {Keyword.get(url, :host), Keyword.get(url, :port, port)} do
        {host, url_port} when is_binary(host) and is_integer(url_port) ->
          ["#{Keyword.get(url, :scheme, "http")}://#{host}:#{url_port}"]

        _ ->
          []
      end

    listener ++ public
  end

  defp allowed_origins, do: Application.get_env(:lemon_control_plane, :allowed_origins, [])

  defp origin_host(origin) do
    case normalize_origin(origin) do
      nil -> []
      normalized -> [URI.parse(normalized).host]
    end
  end

  # Host of a full URL (path allowed): A2A public_url names an endpoint, not an origin.
  defp url_host(url) do
    case URI.new(String.trim(url)) do
      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        [host]

      _ ->
        []
    end
  end

  defp bind_hosts(ip) when is_tuple(ip) and ip not in @wildcards do
    host = ip |> :inet.ntoa() |> to_string()
    [if(tuple_size(ip) == 8, do: "[#{host}]", else: host)]
  end

  defp bind_hosts(_ip), do: []

  defp parse_ip(host) do
    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, ip} -> ip
      _ -> nil
    end
  end

  defp loopback_host?(host) when is_binary(host) do
    host = normalize_host(host)

    host == "localhost" or
      case parse_ip(host |> String.trim_leading("[") |> String.trim_trailing("]")) do
        nil -> false
        ip -> Authorize.loopback_address?(ip)
      end
  end

  defp loopback_host?(_host), do: false

  defp normalize_host(host) when is_binary(host),
    do:
      host
      |> String.trim_trailing(".")
      |> String.downcase()
      |> String.trim_leading("[")
      |> String.trim_trailing("]")

  defp normalize_host(_host), do: nil
end
