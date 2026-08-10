defmodule LemonChannels.Adapters.Email.Webhook do
  @moduledoc """
  Receives inbound email webhooks on `LemonChannels.InboundHttp`.

  Thin by design: authenticate, normalize, hand off. Provider-specific payload
  shapes are `LemonChannels.Adapters.Email`'s business and routing is the
  router's, so this only decides *whether* to accept a request and what status
  the provider sees.

  ## Authentication

  A shared token, compared in constant time:

      config :lemon_channels, LemonChannels.Adapters.Email, webhook_token: "..."

  With no token configured the endpoint **rejects everything** with 401 rather
  than running open. An inbound mail endpoint that accepts unauthenticated
  POSTs is a spam relay into someone's agent.
  """

  @behaviour LemonChannels.InboundHttp.Handler

  require Logger

  alias LemonChannels.Adapters.Email

  @impl true
  def handle_inbound(conn) do
    if authorized?(conn) do
      accept(conn)
    else
      Plug.Conn.send_resp(conn, 401, "unauthorized")
    end
  end

  defp accept(conn) do
    case Email.normalize_inbound(conn.body_params) do
      {:ok, message} ->
        # 202: the provider's job is done once we have the message. Whether a
        # run results is not something it should wait on.
        _ = deliver_to_router(message)
        Plug.Conn.send_resp(conn, 202, "accepted")

      {:error, reason} ->
        Logger.warning("email webhook rejected payload: #{inspect(reason)}")
        Plug.Conn.send_resp(conn, 400, "bad request")
    end
  end

  # Routed through LemonCore.RouterBridge so channels keeps no compile-time
  # dependency on lemon_router (see the §2 dependency rules). The bridge already
  # answers {:error, :unavailable} when no router is wired, so no guard here.
  defp deliver_to_router(message), do: LemonCore.RouterBridge.handle_inbound(message)

  defp authorized?(conn) do
    case configured_token() do
      nil ->
        false

      token ->
        conn
        |> Plug.Conn.get_req_header("x-webhook-token")
        |> List.first()
        |> secure_equal?(token)
    end
  end

  defp secure_equal?(nil, _token), do: false

  defp secure_equal?(given, token) when is_binary(given) do
    # Byte-size check first; :crypto.hash_equals/2 requires equal-length inputs.
    byte_size(given) == byte_size(token) and :crypto.hash_equals(given, token)
  end

  defp secure_equal?(_, _), do: false

  defp configured_token do
    :lemon_channels
    |> Application.get_env(Email, [])
    |> Keyword.get(:webhook_token)
    |> case do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end
end
