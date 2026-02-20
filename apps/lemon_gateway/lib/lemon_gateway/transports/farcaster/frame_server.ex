defmodule LemonGateway.Transports.Farcaster.FrameServer do
  @moduledoc false

  use Plug.Router

  require Logger

  alias LemonGateway.Transports.Farcaster.CastHandler

  @default_port 4043

  plug(Plug.Logger, log: :debug)

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(:match)
  plug(:dispatch)

  def start_link(opts \\ []) do
    cfg = normalize_config(Keyword.get(opts, :config))

    if frame_enabled?(cfg) do
      ip = bind_ip(cfg)
      port = port(cfg)

      Logger.info("Starting Farcaster frame server on #{inspect(ip)}:#{port}")

      Bandit.start_link(
        plug: __MODULE__,
        ip: ip,
        port: port,
        scheme: :http
      )
    else
      Logger.info("farcaster frame server disabled")
      :ignore
    end
  end

  post _ do
    if conn.request_path == CastHandler.action_path() do
      html = CastHandler.handle_action(conn.params || %{}, full_request_url(conn))
      send_html(conn, 200, html)
    else
      send_resp(conn, 404, "not found")
    end
  end

  get _ do
    if conn.request_path == CastHandler.action_path() do
      html = CastHandler.initial_frame(full_request_url(conn))
      send_html(conn, 200, html)
    else
      send_resp(conn, 404, "not found")
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp send_html(conn, status, html) when is_binary(html) do
    conn
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.send_resp(status, html)
  end

  defp frame_enabled?(cfg) do
    case Map.get(cfg, :frame_enabled) do
      nil -> true
      v -> truthy?(v)
    end
  end

  defp port(cfg) do
    cfg
    |> Map.get(:port)
    |> int_value(@default_port)
  end

  defp bind_ip(cfg) do
    bind = normalize_blank(Map.get(cfg, :bind))

    case bind do
      nil -> :loopback
      "127.0.0.1" -> :loopback
      "localhost" -> :loopback
      "0.0.0.0" -> :any
      "any" -> :any
      other -> parse_ip(other) || :loopback
    end
  end

  defp full_request_url(conn) do
    scheme = Atom.to_string(conn.scheme)
    host = conn.host
    port = conn.port

    include_port? =
      not String.contains?(host || "", ":") and
        not (scheme == "http" and port == 80) and
        not (scheme == "https" and port == 443)

    base =
      if include_port? do
        "#{scheme}://#{host}:#{port}"
      else
        "#{scheme}://#{host}"
      end

    path = conn.request_path || "/"
    query = normalize_blank(conn.query_string)

    if is_binary(query) do
      base <> path <> "?" <> query
    else
      base <> path
    end
  end

  defp normalize_config(nil), do: LemonGateway.Transports.Farcaster.config()

  defp normalize_config(cfg) when is_list(cfg) do
    cfg
    |> Enum.into(%{})
    |> normalize_config()
  end

  defp normalize_config(cfg) when is_map(cfg), do: cfg
  defp normalize_config(_), do: %{}

  defp truthy?(value) when is_boolean(value), do: value
  defp truthy?(value) when is_integer(value), do: value != 0

  defp truthy?(value) when is_binary(value) do
    String.downcase(String.trim(value)) in ["1", "true", "yes", "on"]
  end

  defp truthy?(_), do: false

  defp int_value(value, _default) when is_integer(value) and value >= 0, do: value

  defp int_value(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, _} when n >= 0 -> n
      _ -> default
    end
  end

  defp int_value(_, default), do: default

  defp normalize_blank(nil), do: nil

  defp normalize_blank(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_blank(_), do: nil

  defp parse_ip(str) when is_binary(str) do
    case String.split(str, ".", parts: 8) do
      [a, b, c, d] ->
        with {a, ""} <- Integer.parse(a),
             {b, ""} <- Integer.parse(b),
             {c, ""} <- Integer.parse(c),
             {d, ""} <- Integer.parse(d),
             true <- Enum.all?([a, b, c, d], &(&1 >= 0 and &1 <= 255)) do
          {a, b, c, d}
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp parse_ip(_), do: nil
end
