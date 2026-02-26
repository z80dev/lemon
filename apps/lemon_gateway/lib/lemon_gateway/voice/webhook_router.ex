defmodule LemonGateway.Voice.WebhookRouter do
  @moduledoc """
  Plug router that handles Twilio voice webhooks.

  Exposes:
  - POST /webhooks/twilio/voice - Incoming call webhook
  - POST /webhooks/twilio/voice/status - Call status callbacks
  - POST /webhooks/twilio/voice/recording - Recording status callback (auto-downloads)
  - WebSocket /webhooks/twilio/voice/stream - Media stream
  """

  use Plug.Router

  require Logger

  alias LemonGateway.Voice.RecordingDownloader

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

    Logger.info(
      "Incoming Twilio voice call: #{inspect(Map.take(params, ["CallSid", "From", "To"]))}"
    )

    # Generate TwiML to connect to Media Stream
    # Use the host from the incoming request so Twilio connects back to the same URL
    twiml = generate_twiml(conn, params)

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

  # Recording status callback - triggered when a recording is ready
  post "/webhooks/twilio/voice/recording" do
    params = conn.params || %{}

    recording_sid = params["RecordingSid"]
    call_sid = params["CallSid"]
    status = params["RecordingStatus"]
    duration = params["RecordingDuration"]

    Logger.info(
      "Recording #{recording_sid} for call #{call_sid}: " <>
        "status=#{status}, duration=#{duration}s"
    )

    if status == "completed" do
      # Download the recording in a background task so we don't block the webhook response
      Task.start(fn ->
        case RecordingDownloader.download(params) do
          {:ok, path} ->
            Logger.info("Recording downloaded: #{path}")

          {:error, reason} ->
            Logger.error("Recording download failed: #{inspect(reason)}")
        end
      end)
    end

    send_resp(conn, 200, "OK")
  end

  # WebSocket upgrade for media stream
  get "/webhooks/twilio/voice/stream" do
    # Extract call info from query params or headers
    call_sid = conn.params["callSid"] || conn.params["CallSid"] || fallback_call_sid()
    from_number = conn.params["from"] || conn.params["From"] || "unknown"
    to_number = conn.params["to"] || conn.params["To"] || "unknown"

    if call_sid == "unknown" or from_number == "unknown" do
      Logger.warning(
        "Voice stream connected without full metadata: " <>
          "query=#{inspect(conn.query_string)}, params=#{inspect(conn.params)}"
      )
    end

    Logger.info("WebSocket connection request for call #{call_sid}")

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

  defp generate_twiml(conn, params) do
    # Get the host from the incoming request
    # Check for X-Forwarded-Host header first (set by proxies/tunnels)
    host =
      conn
      |> Plug.Conn.get_req_header("x-forwarded-host")
      |> List.first()
      |> case do
        nil -> conn.host || "localhost"
        forwarded -> forwarded
      end

    # Check for X-Forwarded-Proto to determine if we're behind HTTPS
    proto =
      conn
      |> Plug.Conn.get_req_header("x-forwarded-proto")
      |> List.first()
      |> case do
        "https" -> "wss"
        _ -> if conn.scheme == :https, do: "wss", else: "ws"
      end

    base_stream_url = "#{proto}://#{host}/webhooks/twilio/voice/stream"

    query_params =
      [{"callSid", params["CallSid"]}, {"from", params["From"]}, {"to", params["To"]}]
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)

    stream_url =
      case query_params do
        [] -> base_stream_url
        _ -> base_stream_url <> "?" <> URI.encode_query(query_params)
      end

    Logger.info("TwiML Stream URL: #{stream_url} (host=#{host}, proto=#{proto})")
    escaped_stream_url = xml_escape_attr(stream_url)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <Response>
      <Connect>
        <Stream url="#{escaped_stream_url}" />
      </Connect>
    </Response>
    """
    |> String.trim()
  end

  defp xml_escape_attr(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("\"", "&quot;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp fallback_call_sid do
    "temp_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
