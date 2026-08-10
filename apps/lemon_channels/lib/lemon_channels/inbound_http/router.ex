defmodule LemonChannels.InboundHttp.Router do
  @moduledoc """
  Dispatches inbound HTTP to the adapter registered for the first path segment.

  Deliberately thin: parsing, dispatch, and turning an unregistered segment or a
  crashing handler into a plain status code. Everything else — signature
  verification, idempotency, payload shape — belongs to the adapter, because
  those rules differ per provider and baking any of them in here would recreate
  `LemonGateway.Transports.Webhook` inside `lemon_channels`.
  """

  use Plug.Router

  require Logger

  alias LemonChannels.InboundHttp

  plug(:match)

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

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
      # A adapter blowing up must not take the listener down with it, and the
      # caller is a third party who should learn nothing about why.
      Logger.error(
        "inbound http handler crashed segment=#{inspect(segment)} " <>
          "handler=#{inspect(handler)} error=#{Exception.message(error)}"
      )

      send_resp(conn, 500, "internal error")
  end
end
