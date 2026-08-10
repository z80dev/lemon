defmodule LemonChannels.InboundHttp.Router do
  @moduledoc """
  Dispatches inbound HTTP to the adapter registered for the first path segment.

  Deliberately thin: parsing, dispatch, and turning an unregistered segment or a
  crashing handler into a plain status code. Everything else — signature
  verification, idempotency, payload shape — belongs to the adapter, because
  those rules differ per provider and baking any of them in here would recreate
  `LemonGateway.Transports.Webhook` inside `lemon_channels`.

  ## Authenticate first where the handler can

  A handler that can authenticate from the request line and headers alone —
  a shared token, an API key — implements
  `c:LemonChannels.InboundHttp.Handler.authorized?/1`, and it runs **before**
  `Plug.Parsers`. Otherwise an anonymous caller can make this process read and
  decode a body on every request and only then be told 401, which is free for
  them and expensive here.

  Not every handler can: most providers sign the *raw or parsed* payload, which
  cannot be checked before the body exists. Those omit the callback and are
  parsed for as before, which is why the body limit below still matters.

  ## Body limit

  `LemonChannels.InboundHttp.max_body_bytes/0`, 2 MB by default — well under
  `Plug.Parsers`' 8 MB — and configurable for adapters that must accept larger
  payloads. Over the limit, `Plug.Parsers` raises and the caller gets a 413.

  The limit is resolved per request rather than frozen into the pipeline at
  compile time, so a value set in `config/runtime.exs` or at boot is honoured
  rather than silently ignored.
  """

  use Plug.Router

  require Logger

  alias LemonChannels.InboundHttp

  plug(:match)
  plug(:authorize)
  plug(:parse_body)
  plug(:dispatch)

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  match _ do
    case conn.path_info do
      [segment | _rest] -> dispatch_to_handler(conn, segment)
      [] -> send_resp(conn, 404, "not found")
    end
  end

  defp authorize(conn, _opts) do
    with [segment | _rest] <- conn.path_info,
         handler when not is_nil(handler) <- InboundHttp.handler_for(segment),
         false <- authorized?(handler, conn) do
      conn |> send_resp(401, "unauthorized") |> halt()
    else
      # No segment, no registered handler, or authorized: `:dispatch` decides
      # between 404 and the handler from here.
      _ -> conn
    end
  end

  defp authorized?(handler, conn) do
    if Code.ensure_loaded?(handler) and function_exported?(handler, :authorized?, 1) do
      handler.authorized?(conn) == true
    else
      # No pre-parse check offered. Not a denial — the handler authenticates
      # later, from a body that does not exist yet.
      true
    end
  rescue
    error ->
      Logger.error(
        "inbound http pre-parse auth crashed handler=#{inspect(handler)} " <>
          "error=#{Exception.message(error)}"
      )

      false
  catch
    kind, reason ->
      Logger.error(
        "inbound http pre-parse auth crashed handler=#{inspect(handler)} " <>
          "error=#{kind} #{inspect(reason)}"
      )

      false
  end

  defp parse_body(conn, _opts) do
    Plug.Parsers.call(conn, parser_opts())
  end

  defp parser_opts do
    Plug.Parsers.init(
      parsers: [:urlencoded, :multipart, :json],
      pass: ["*/*"],
      length: InboundHttp.max_body_bytes(),
      json_decoder: Jason
    )
  end

  defp dispatch_to_handler(conn, segment) do
    case InboundHttp.handler_for(segment) do
      nil ->
        send_resp(conn, 404, "not found")

      handler ->
        safely_handle(conn, segment, handler)
    end
  end

  defp safely_handle(conn, segment, handler) do
    handler.handle_inbound(conn)
  rescue
    error ->
      fail(conn, segment, handler, Exception.message(error))
  catch
    # A handler that calls into a dead adapter process *exits*; it does not
    # raise. Rescuing alone would let that skip both the log line and the
    # response we chose, and hand the third party whatever the web server
    # produces for an unhandled exit instead.
    :exit, reason ->
      fail(conn, segment, handler, "exit #{inspect(reason)}")

    kind, reason ->
      fail(conn, segment, handler, "#{kind} #{inspect(reason)}")
  end

  defp fail(conn, segment, handler, detail) do
    # An adapter blowing up must not take the listener down with it, and the
    # caller is a third party who should learn nothing about why.
    Logger.error(
      "inbound http handler crashed segment=#{inspect(segment)} " <>
        "handler=#{inspect(handler)} error=#{detail}"
    )

    # A handler that answered and *then* blew up has already sent; sending again
    # raises `Plug.Conn.AlreadySentError` out of the rescue clause that was
    # supposed to contain the failure.
    if conn.state in [:sent, :chunked, :upgraded] do
      conn
    else
      send_resp(conn, 500, "internal error")
    end
  end
end
