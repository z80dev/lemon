defmodule LemonGateway.Voice.WebhookRouterTest do
  use ExUnit.Case, async: true

  alias LemonGateway.Voice.WebhookRouter

  test "POST /webhooks/twilio/voice embeds call metadata in stream URL query params" do
    conn =
      Plug.Test.conn(:post, "/webhooks/twilio/voice", %{
        "CallSid" => "CA123",
        "From" => "+15551230100",
        "To" => "+15551239999"
      })
      |> Plug.Conn.put_req_header("x-forwarded-host", "lemon-voice.loca.lt")
      |> Plug.Conn.put_req_header("x-forwarded-proto", "https")
      |> WebhookRouter.call([])

    assert conn.status == 200

    assert conn.resp_body =~
             "<Stream url=\"wss://lemon-voice.loca.lt/webhooks/twilio/voice/stream?callSid=CA123&amp;from=%2B15551230100&amp;to=%2B15551239999\" />"
  end
end
