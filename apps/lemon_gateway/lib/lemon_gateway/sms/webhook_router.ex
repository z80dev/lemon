defmodule LemonGateway.Sms.WebhookRouter do
  @moduledoc false

  use Plug.Router

  require Logger

  alias LemonGateway.Sms.Config
  alias LemonGateway.Sms.Inbox
  alias LemonGateway.Sms.TwilioSignature

  plug(Plug.Logger, log: :debug)

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

      {:error, reason} ->
        Logger.warning("Twilio webhook validation failed: #{inspect(reason)}")
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
      url = Config.webhook_url_override() || request_url_for_signature(conn)

      if TwilioSignature.valid?(auth_token, url, params, provided) do
        :ok
      else
        {:error, :unauthorized}
      end
    else
      :ok
    end
  end

  defp request_url_for_signature(conn) do
    # Twilio signature expects the public URL. Prefer configuring TWILIO_WEBHOOK_URL
    # when running behind tunnels/proxies.
    scheme =
      case Plug.Conn.get_req_header(conn, "x-forwarded-proto") do
        [proto | _] when is_binary(proto) and proto != "" -> proto
        _ -> Atom.to_string(conn.scheme)
      end

    host =
      case Plug.Conn.get_req_header(conn, "x-forwarded-host") do
        [h | _] when is_binary(h) and h != "" -> h
        _ -> conn.host
      end

    # If host already includes a port, keep it; otherwise only include non-default ports.
    port =
      case Plug.Conn.get_req_header(conn, "x-forwarded-port") do
        [p | _] ->
          case Integer.parse(p) do
            {n, _} -> n
            _ -> conn.port
          end

        _ ->
          conn.port
      end

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

    base <>
      conn.request_path <> if(conn.query_string != "", do: "?" <> conn.query_string, else: "")
  end

  defp send_twiml(conn, status, xml) when is_binary(xml) do
    conn
    |> Plug.Conn.put_resp_content_type("application/xml")
    |> Plug.Conn.send_resp(status, xml)
  end
end
