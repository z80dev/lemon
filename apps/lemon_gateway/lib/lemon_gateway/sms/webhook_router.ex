defmodule LemonGateway.Sms.WebhookRouter do
  @moduledoc """
  Plug router that handles inbound Twilio SMS webhooks.

  Exposes a `POST /webhooks/twilio/sms` endpoint that validates the request
  signature (when configured), ingests the message into the SMS inbox, and
  responds with an empty TwiML `<Response>`.
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
    params = conn.params || %{}

    case maybe_validate_twilio(conn, params) do
      :ok ->
        _ = Inbox.ingest_twilio_sms(params)
        send_twiml(conn, 200, "<Response></Response>")

      {:error, :unauthorized} ->
        send_resp(conn, 401, "unauthorized")
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp maybe_validate_twilio(conn, params) do
    if Config.validate_webhook?() do
      auth_token = Config.auth_token()
      provided = List.first(Plug.Conn.get_req_header(conn, "x-twilio-signature"))
      url = Config.webhook_url_override() || TwilioSignature.request_url(conn)

      if TwilioSignature.valid?(auth_token, url, params, provided) do
        :ok
      else
        {:error, :unauthorized}
      end
    else
      :ok
    end
  end

  defp send_twiml(conn, status, xml) when is_binary(xml) do
    conn
    |> Plug.Conn.put_resp_content_type("application/xml")
    |> Plug.Conn.send_resp(status, xml)
  end
end
