defmodule LemonGateway.Sms.WebhookRouterTest do
  use ExUnit.Case, async: false

  alias LemonGateway.Sms.Inbox
  alias LemonGateway.Sms.TwilioSignature
  alias LemonGateway.Sms.WebhookRouter

  @table :sms_inbox
  @token "router-test-token"

  setup do
    saved = Map.new(~w(TWILIO_AUTH_TOKEN TWILIO_WEBHOOK_URL), &{&1, System.get_env(&1)})
    System.put_env("TWILIO_AUTH_TOKEN", @token)
    System.delete_env("TWILIO_WEBHOOK_URL")

    {:ok, _} = Application.ensure_all_started(:lemon_gateway)

    for {k, _v} <- LemonCore.Store.list(@table) do
      _ = LemonCore.Store.delete(@table, k)
    end

    start_supervised!(Inbox)

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      for {k, _v} <- LemonCore.Store.list(@table) do
        _ = LemonCore.Store.delete(@table, k)
      end
    end)

    :ok
  end

  test "signed POST /webhooks/twilio/sms stores message and returns empty TwiML" do
    sid = "SM#{System.unique_integer([:positive])}"

    params = %{
      "MessageSid" => sid,
      "From" => "+15551230100",
      "To" => "+15551239999",
      "Body" => "Your code is 999999"
    }

    signature =
      TwilioSignature.signature(@token, "http://www.example.com/webhooks/twilio/sms", params)

    conn =
      Plug.Test.conn(:post, "/webhooks/twilio/sms", params)
      |> Plug.Conn.put_req_header("x-twilio-signature", signature)
      |> WebhookRouter.call([])

    assert conn.status == 200
    assert conn.resp_body =~ "<Response"

    msgs = Inbox.list_messages(limit: 10, include_claimed: true)
    assert Enum.any?(msgs, fn msg -> msg["message_sid"] == sid end)
  end
end
