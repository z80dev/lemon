defmodule LemonGateway.Voice.WebhookRouterTest do
  use ExUnit.Case, async: false

  alias LemonGateway.Sms.TwilioSignature
  alias LemonGateway.Voice.{StreamToken, WebhookRouter}

  @gateway_config_key :"Elixir.LemonGateway.Config"
  @auth_token "router-test-token"

  setup do
    old = Application.get_env(:lemon_gateway, @gateway_config_key)

    Application.put_env(:lemon_gateway, @gateway_config_key, %{
      voice: %{twilio_auth_token: @auth_token, public_url: "https://lemon-voice.loca.lt/"}
    })

    on_exit(fn ->
      if old,
        do: Application.put_env(:lemon_gateway, @gateway_config_key, old),
        else: Application.delete_env(:lemon_gateway, @gateway_config_key)
    end)
  end

  test "POST /webhooks/twilio/voice emits a query-free public wss Stream with Parameters" do
    params = %{
      "CallSid" => "CA123",
      "From" => "+15551230100",
      "To" => "+15551239999"
    }

    signature =
      TwilioSignature.signature(
        @auth_token,
        "https://lemon-voice.loca.lt/webhooks/twilio/voice",
        params
      )

    conn =
      Plug.Test.conn(:post, "/webhooks/twilio/voice", params)
      # Forwarded headers must not influence the stream destination.
      |> Plug.Conn.put_req_header("x-forwarded-host", "attacker.example")
      |> Plug.Conn.put_req_header("x-forwarded-proto", "http")
      |> Plug.Conn.put_req_header("x-twilio-signature", signature)
      |> WebhookRouter.call([])

    assert conn.status == 200
    body = conn.resp_body

    assert body =~ ~s(<Stream url="wss://lemon-voice.loca.lt/webhooks/twilio/voice/stream">)
    refute body =~ "stream?"
    refute body =~ "attacker.example"
    assert body =~ ~s(<Parameter name="callSid" value="CA123" />)
    assert body =~ ~s(<Parameter name="from" value="+15551230100" />)
    assert body =~ ~s(<Parameter name="to" value="+15551239999" />)

    [_, token] = Regex.run(~r/<Parameter name="token" value="([^"]+)" \/>/, body)
    assert :ok = StreamToken.verify(token, "CA123", "+15551230100", "+15551239999")
    assert {:error, _} = StreamToken.verify(token, "CAother", "+15551230100", "+15551239999")
  end
end
