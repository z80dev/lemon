defmodule LemonGateway.Sms.WebhookRouter do
  @moduledoc """
  Plug router that handles inbound Twilio SMS webhooks.

  Exposes a `POST /webhooks/twilio/sms` endpoint that validates the Twilio
  request signature, ingests the message into the SMS inbox, and responds with
  an empty TwiML `<Response>`. Every request is signature-checked; a missing
  auth token, missing signature or bad signature is rejected with 403 before
  anything is stored.
  """

  use Plug.Router

  alias LemonGateway.Sms.Config
  alias LemonGateway.Sms.Inbox
  alias LemonGateway.Sms.TwilioSignature

  plug(Plug.Logger, log: :debug)
  plug(LemonGateway.DrainGuard)

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(:match)
  plug(:dispatch)

  post "/webhooks/twilio/sms" do
    params = body_params(conn)

    case validate_twilio(conn, params) do
      :ok ->
        case Inbox.ingest_twilio_sms(params) do
          {:ok, _stored_or_duplicate} ->
            send_twiml(conn, 200, "<Response></Response>")

          {:error, :missing_message_sid} ->
            send_resp(conn, 400, "bad request")

          # Not stored: ask Twilio to retry; a replay cannot overwrite (insert-if-absent).
          {:error, _reason} ->
            send_resp(conn, 503, "unavailable")
        end

      {:error, :forbidden} ->
        send_resp(conn, 403, "forbidden")
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp body_params(%Plug.Conn{body_params: params}) when is_map(params) and not is_struct(params),
    do: params

  defp body_params(_conn), do: %{}

  defp validate_twilio(conn, params) do
    auth_token = Config.auth_token()
    provided = List.first(Plug.Conn.get_req_header(conn, "x-twilio-signature"))
    url = Config.webhook_url_override() || TwilioSignature.request_url(conn)

    if TwilioSignature.valid?(auth_token, url, params, provided) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp send_twiml(conn, status, xml) when is_binary(xml) do
    conn
    |> Plug.Conn.put_resp_content_type("application/xml")
    |> Plug.Conn.send_resp(status, xml)
  end
end
