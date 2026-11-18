defmodule LemonGateway.Voice.WebhookRouter do
  @moduledoc """
  Plug router that handles Twilio voice webhooks.

  Exposes:
  - POST /webhooks/twilio/voice - Incoming call webhook
  - POST /webhooks/twilio/voice/status - Call status callbacks
  - POST /webhooks/twilio/voice/recording - Recording status callback (auto-downloads)
  - WebSocket /webhooks/twilio/voice/stream - Media stream

  Every request, including the media-stream WebSocket handshake, must carry a
  valid `X-Twilio-Signature` computed with the configured Twilio auth token over
  the URL derived from `[gateway.voice] public_url` (never from request or
  forwarded headers) and the POST form parameters. Unsigned or mis-signed
  requests, and all requests when no auth token or `public_url` is configured,
  are rejected with 403 before any parameter is used.

  The TwiML `<Stream>` URL is the query-free `wss://` form of `public_url`; call
  metadata and an expiring `LemonGateway.Voice.StreamToken` bound to the
  authenticated CallSid travel as `<Parameter>` elements.
  """

  use Plug.Router

  require Logger

  alias LemonGateway.Sms.TwilioSignature
  alias LemonGateway.Voice.{Config, RecordingDownloader, StreamToken}

  plug(Plug.Logger, log: :debug)
  plug(LemonGateway.DrainGuard)

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(:verify_twilio_signature)

  plug(:match)
  plug(:dispatch)

  # Twilio voice webhook - incoming calls
  post "/webhooks/twilio/voice" do
    params = conn.params || %{}

    Logger.info(
      "Incoming Twilio voice call: #{inspect(Map.take(params, ["CallSid", "From", "To"]))}"
    )

    case params["CallSid"] do
      call_sid when is_binary(call_sid) and call_sid != "" ->
        conn
        |> Plug.Conn.put_resp_content_type("application/xml")
        |> Plug.Conn.send_resp(200, generate_twiml(params))

      _ ->
        send_resp(conn, 400, "missing CallSid")
    end
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
  # Twilio's <Stream> url does not support query strings; call metadata and the
  # per-call stream token arrive in the `start` message's customParameters and
  # are verified by TwilioWebSocket before any call resource is created.
  get "/webhooks/twilio/voice/stream" do
    conn
    |> WebSockAdapter.upgrade(LemonGateway.Voice.TwilioWebSocket, [], timeout: 60_000)
    |> halt()
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  # Private Functions

  defp verify_twilio_signature(conn, _opts) do
    provided = List.first(Plug.Conn.get_req_header(conn, "x-twilio-signature"))
    auth_token = Config.twilio_auth_token()

    valid? =
      case signed_urls(conn) do
        {:ok, urls} ->
          # Twilio signs POST form params; the WebSocket handshake is signed over the URL only.
          signed_params =
            case {conn.method, conn.body_params} do
              {"POST", %{} = body} -> body
              _ -> %{}
            end

          Enum.any?(urls, &TwilioSignature.valid?(auth_token, &1, signed_params, provided))

        :error ->
          Logger.warning(
            "Voice webhooks require an https [gateway.voice] public_url; rejecting request"
          )

          false
      end

    if valid? do
      conn
    else
      Logger.warning("Rejected voice webhook with invalid Twilio signature: #{conn.request_path}")

      conn
      |> send_resp(403, "forbidden")
      |> halt()
    end
  end

  # Candidate URLs Twilio may have signed, built only from the configured https
  # public origin (never from request or forwarded headers). Per Twilio's security
  # docs, voice HTTPS callbacks are signed without the port. The WSS handshake's
  # exact canonical form is not documented, so both the wss:// and https:// forms,
  # each with and without a trailing "/", are accepted (all HMAC'd with the same
  # auth token).
  defp signed_urls(conn) do
    with {:ok, origin} <- public_origin() do
      path = conn.request_path

      case conn.method do
        "GET" ->
          urls =
            for base <- [stream_origin(origin), URI.to_string(origin)],
                suffix <- ["", "/"],
                do: base <> path <> suffix

          {:ok, urls}

        _ ->
          query = if conn.query_string != "", do: "?" <> conn.query_string, else: ""
          {:ok, [URI.to_string(origin) <> path <> query]}
      end
    end
  end

  # Voice requires an https public_url: Twilio only streams to wss://, and the
  # signed callback URL must be the public TLS origin.
  defp public_origin do
    with base when is_binary(base) and base != "" <- Config.public_url(),
         {:ok, %URI{scheme: "https", host: host} = uri}
         when is_binary(host) and host != "" <- URI.new(base) do
      {:ok, %URI{scheme: "https", host: host, path: String.trim_trailing(uri.path || "", "/")}}
    else
      _ -> :error
    end
  end

  defp stream_origin(%URI{} = origin), do: URI.to_string(%URI{origin | scheme: "wss"})

  defp generate_twiml(params) do
    # The signature plug already proved public_url is configured.
    {:ok, origin} = public_origin()
    stream_url = stream_origin(origin) <> "/webhooks/twilio/voice/stream"
    call_sid = params["CallSid"]
    from = params["From"] || ""
    to = params["To"] || ""

    parameters =
      [
        {"callSid", call_sid},
        {"from", from},
        {"to", to},
        {"token", StreamToken.sign(call_sid, from, to)}
      ]
      |> Enum.map_join("\n", fn {name, value} ->
        ~s(      <Parameter name="#{name}" value="#{xml_escape_attr(value)}" />)
      end)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <Response>
      <Connect>
        <Stream url="#{xml_escape_attr(stream_url)}">
    #{parameters}
        </Stream>
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
end
