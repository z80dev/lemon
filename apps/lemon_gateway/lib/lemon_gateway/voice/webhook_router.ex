defmodule LemonGateway.Voice.WebhookRouter do
  @moduledoc """
  Plug router that handles Twilio voice webhooks.

  Exposes:
  - POST /webhooks/twilio/voice - Incoming call webhook
  - POST /webhooks/twilio/voice/status - Call status callbacks
  - WebSocket /webhooks/twilio/voice/stream - Media stream
  """

  use Plug.Router

  require Logger

  alias LemonGateway.Voice.Config

  plug(Plug.Logger, log: :debug)

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(:match)
  plug(:dispatch)

  # Twilio voice webhook - incoming calls
  post "/webhooks/twilio/voice" do
    params = conn.params || %{}

    Logger.info("Incoming Twilio voice call: #{inspect(Map.take(params, ["CallSid", "From", "To"]))}")

    # Generate TwiML to connect to Media Stream
    twiml = generate_twiml()

    conn
    |> Plug.Conn.put_resp_content_type("application/xml")
    |> Plug.Conn.send_resp(200, twiml)
  end

  # Call status callbacks
  post "/webhooks/twilio/voice/status" do
    params = conn.params || %{}

    call_sid = params["CallSid"]
    status = params["CallStatus"]

    Logger.info("Call #{call_sid} status: #{status}")

    send_resp(conn, 200, "OK")
  end

  # WebSocket upgrade for media stream
  get "/webhooks/twilio/voice/stream" do
    # Extract call info from query params or headers
    call_sid = conn.params["callSid"] || generate_call_sid()
    from_number = conn.params["from"] || "unknown"
    to_number = conn.params["to"] || "unknown"

    # Upgrade to WebSocket using WebSockAdapter
    conn
    |> WebSockAdapter.upgrade(
      LemonGateway.Voice.TwilioWebSocket,
      [call_sid: call_sid, from_number: from_number, to_number: to_number],
      timeout: 60_000
    )
    |> halt()
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  # Private Functions

  defp generate_twiml do
    public_url = Config.public_url()

    stream_url =
      if public_url do
        "wss://#{public_url}/webhooks/twilio/voice/stream"
      else
        # Fallback for local development
        "ws://localhost:#{Config.websocket_port()}/webhooks/twilio/voice/stream"
      end

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <Response>
      <Connect>
        <Stream url="#{stream_url}" />
      </Connect>
    </Response>
    """
    |> String.trim()
  end

  defp generate_call_sid do
    "CA" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end
end
