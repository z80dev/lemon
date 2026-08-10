defmodule LemonChannels.Adapters.Email.Webhook do
  @moduledoc """
  Receives inbound email webhooks on `LemonChannels.InboundHttp`.

  Thin by design: authenticate, normalize, hand off. Provider-specific payload
  shapes are `LemonChannels.Adapters.Email`'s business and routing is the
  router's, so this only decides *whether* to accept a request and what status
  the provider sees.

  ## Authentication

  A shared token in the `x-webhook-token` header, compared in constant time:

      config :lemon_channels, LemonChannels.Adapters.Email, webhook_token: "..."

  With no token configured the endpoint **rejects everything** with 401 rather
  than running open. An inbound mail endpoint that accepts unauthenticated
  POSTs is a spam relay into someone's agent.

  The token is in a header rather than the body on purpose: that lets the check
  run as `c:LemonChannels.InboundHttp.Handler.authorized?/1`, which
  `LemonChannels.InboundHttp.Router` calls *before* parsing, so an
  unauthenticated caller cannot make the server decode a body — with
  attachments, the most expensive thing this endpoint does.

  `LemonChannels.Adapters.Email.Config` resolves the token, so the TOML
  `[gateway]` config's `email.webhook_token` (or `email.inbound.token`) is
  honoured too — an existing deployment does not have to re-issue its token to
  cut over. A malformed config yields no token, and therefore a 401: unreadable
  configuration must not fail open.
  """

  @behaviour LemonChannels.InboundHttp.Handler

  require Logger

  alias LemonChannels.Adapters.Email

  @impl true
  def authorized?(conn) do
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

  @impl true
  def handle_inbound(conn) do
    # Re-checked rather than assumed. The router has already run `authorized?/1`
    # for anything arriving through it, but this stays correct for a handler
    # invoked directly, and the cost of the second check is one comparison.
    if authorized?(conn) do
      accept(conn)
    else
      Plug.Conn.send_resp(conn, 401, "unauthorized")
    end
  end

  defp accept(conn) do
    case Email.normalize_inbound(conn.body_params) do
      {:ok, message} ->
        handoff(conn, message)

      {:error, reason} ->
        Logger.warning("email webhook rejected payload: #{inspect(reason)}")
        Plug.Conn.send_resp(conn, 400, "bad request")
    end
  end

  defp handoff(conn, message) do
    case deliver_to_router(message) do
      {:error, :unavailable} ->
        # The message is definitively lost, so saying "accepted" would be a lie
        # that costs someone their mail. 503 asks the provider to redeliver,
        # which is what every mail provider does with a 5xx.
        Logger.error("email webhook could not reach the router; asking for redelivery")
        Plug.Conn.send_resp(conn, 503, "unavailable")

      _ ->
        # 202 otherwise: the provider's job is done once we have the message.
        # Whether a run results is not something it should wait on, and it is
        # not something redelivery would fix either.
        Plug.Conn.send_resp(conn, 202, "accepted")
    end
  end

  # Routed through LemonCore.RouterBridge so channels keeps no compile-time
  # dependency on lemon_router (see the §2 dependency rules).
  #
  # The bridge answers `{:error, :unavailable}` for every way a router can fail
  # to take the message — unconfigured, process dead, call timed out — so there
  # is nothing to catch here. It did not always: it rescued exceptions but not
  # exits, and this webhook carried its own `catch :exit` until that was fixed
  # centrally. Deciding what an unavailable router *means to a mail provider*
  # is still this module's job, and that decision is `handoff/2`.
  defp deliver_to_router(message), do: LemonCore.RouterBridge.handle_inbound(message)

  defp secure_equal?(nil, _token), do: false

  defp secure_equal?(given, token) when is_binary(given) do
    # Byte-size check first; :crypto.hash_equals/2 requires equal-length inputs.
    byte_size(given) == byte_size(token) and :crypto.hash_equals(given, token)
  end

  defp secure_equal?(_, _), do: false

  defp configured_token, do: Email.Config.webhook_token()
end
